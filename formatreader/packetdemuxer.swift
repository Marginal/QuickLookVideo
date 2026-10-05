//
//  packetdemuxer.swift
//  QLVideo
//
//  Provide per-stream buffers of AVPackets to be consumed by MESampleCursor.
//
//  FFmpeg expects packets to be demuxed and decoded in a linear order, and goes to some effort to enable that.
//  However AVFoundation skips around creating MESampleCursors before and after the packet being decoded. Further,
//  we don't know which streams AVFoundation wants to consume.
//  Observations:
//  * Some streams can be much sparser than others e.g. half as many video packets than audio in a 30fps AAC file.
//  * Audio packets are typically much smaller than video packets, so we can afford to keep more of them buffered.
//  * Video streams are consumed serially so SampleCursor moves by 2-3 packets at a time
//  * Audio streams are typically consumed two seconds at a time in loadSampleBufferContainingSamples (=86 AAC packets)
//    but can be as high as 23s and ~1500! packets for variable duration streams like Vorbis, so audio SampleCursor
//    jumps a lot while video SampleCursor lags.
//

import AVFoundation
import CoreMedia
import Foundation
import MediaExtension

#if DEBUG
    let TRACE_PACKET_DEMUXER = false
#else
    let TRACE_PACKET_DEMUXER = false
#endif

let QLThumbnailTime = CMTime(value: 10_000_000, timescale: 1_000_000)  // QuickLook generates its thumbnail at 10s

private final class PacketRing {
    private var storage: [UnsafeMutablePointer<AVPacket>?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    private var headLogicalIndex = 0
    let capacity: Int
    var readAhead: Int
    let timeBase: AVRational
    var bsfCtx: UnsafeMutablePointer<AVBSFContext>?
    var highest = 0  // high water mark
    var lastConsumed: Int
    let packetSem: DispatchSemaphore

    init(capacity: Int, readAhead: Int, timeBase: AVRational, bsfCtx: UnsafeMutablePointer<AVBSFContext>?) {
        self.storage = Array(repeating: nil, count: capacity)
        self.capacity = capacity
        self.readAhead = readAhead
        self.timeBase = timeBase
        self.bsfCtx = bsfCtx
        self.lastConsumed = -1
        self.packetSem = DispatchSemaphore(value: 0)
    }

    deinit {
        av_bsf_free(&bsfCtx)
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }
    var isReady: Bool {
        if count == 0 { return false }
        if headLogicalIndex == 0 {
            return storage[head]!.pointee.dts != AV_NOPTS_VALUE
        }
        return true
    }
    var minLogicalIndex: Int {
        assert(count > 0)
        return headLogicalIndex
    }
    var maxLogicalIndex: Int {
        assert(count > 0)
        return headLogicalIndex + count - 1
    }
    var bufferedAhead: Int {
        return isEmpty ? 0 : (maxLogicalIndex - lastConsumed)
    }

    func reset() {
        var idx = head
        for _ in 0..<count {
            av_packet_free(&storage[idx])
            storage[idx] = nil
            idx = (idx + 1) % capacity
        }
        head = 0
        tail = 0
        count = 0
        headLogicalIndex = 0
        lastConsumed = -1
        if let bsf = bsfCtx { av_bsf_flush(bsf) }
    }

    // Increase read-ahead up to capacity
    func increaseReadAhead(requested: Int) {
        readAhead = min(max(readAhead, requested - lastConsumed), capacity)
    }

    func append(packet: UnsafeMutablePointer<AVPacket>) -> UnsafeMutablePointer<AVPacket>? {
        var evicted: UnsafeMutablePointer<AVPacket>? = nil
        if isFull {
            evicted = storage[head]
            storage[head] = nil
            head = (head + 1) % capacity
            headLogicalIndex += 1
            count -= 1
        }
        storage[tail] = packet
        tail = (tail + 1) % capacity
        count += 1
        if count > highest { highest = count }
        return evicted
    }

    func consume(logicalIndex: Int) {
        while count > 0 && headLogicalIndex < logicalIndex {
            av_packet_free(&storage[head])
            storage[head] = nil
            head = (head + 1) % capacity
            headLogicalIndex += 1
            count -= 1
        }
        lastConsumed = max(lastConsumed, logicalIndex)
    }

    func get(logicalIndex: Int) -> UnsafeMutablePointer<AVPacket>? {
        guard !isEmpty, logicalIndex >= minLogicalIndex, logicalIndex <= maxLogicalIndex else { return nil }
        let offset = logicalIndex - headLogicalIndex
        let idx = (head + offset) % capacity
        return storage[idx]
    }

    func nearest(to target: CMTime) -> Int? {
        var below: Int? = nil
        var above: Int? = nil

        // Convert target to stream timebase units.
        if count == 0 || target.timescale == 0 { return nil }
        let targetPts: Int64
        if target.timescale == timeBase.den {
            targetPts = target.value / Int64(timeBase.num)
        } else {
            let src = AVRational(num: 1, den: Int32(target.timescale))
            targetPts = av_rescale_q(target.value, src, timeBase)
        }

        for idx in 0..<count {
            let pkt = storage[(head + idx) % capacity]!
            let tsVal = pkt.pointee.pts
            if tsVal == AV_NOPTS_VALUE {
                continue
            } else if tsVal == targetPts {
                return headLogicalIndex + idx  // early exit
            } else if tsVal < targetPts {
                below = idx
            } else {
                above = idx
                break
            }
        }

        guard let belowIdx = below, let aboveIdx = above else { return nil }
        let belowVal = storage[(head + belowIdx) % capacity]!.pointee.pts
        let aboveVal = storage[(head + aboveIdx) % capacity]!.pointee.pts

        // Choose the closer packet by integer distance in pts units.
        let distBelow = targetPts - belowVal
        let distAbove = aboveVal - targetPts
        return distBelow <= distAbove ? headLogicalIndex + belowIdx : headLogicalIndex + aboveIdx
    }
}

struct PacketHandle {
    let generation: Int
    let index: Int
    let isLast: Bool
}

final class PacketDemuxer {
    private static let videoCapacity = 8192  // normally don't need this many but VBR formats can read ahead a lot
    private static let audioCapacity = 8192
    private static let videoReadAhead = 120  // 2 seconds of video at 60fps
    private static let audioReadAhead = 196  // should be more than enough for at least 2 seconds of audio in typical codecs
    private weak var format: FormatReader?
    private var pktFixup: Int64 = 0
    private var buffers: [PacketRing]
    private var generation: Int = 0
    private var stopping = false
    private var halted = false  // true after EOF or read/seek error until next successful seek
    private var rememberedSeekPTS: CMTime? = nil
    private var lastPkt: [UnsafeMutablePointer<AVPacket>?]  // MediaExtension wants us to report the last packet for each stream

    private let stateLock = NSLock()
    private let demuxGroup = DispatchGroup()  // prevent deinit until demuxLoop has exited
    private let demuxQueue = DispatchQueue(label: "uk.org.marginal.qlvideo.formatreader", qos: .default)
    private let demuxSem = DispatchSemaphore(value: 0)  // wake demuxLoop when paused

    init(format: FormatReader) throws {
        self.format = format
        let fmt_ctx = format.fmt_ctx!
        buffers = (0..<Int(fmt_ctx.pointee.nb_streams)).map { idx in
            let stream = fmt_ctx.pointee.streams[idx]!
            var capacity = 0
            var readAhead = 0
            var bsfCtx: UnsafeMutablePointer<AVBSFContext>? = nil
            if stream.pointee.discard != AVDISCARD_ALL {
                if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                    capacity = PacketDemuxer.videoCapacity
                    readAhead = PacketDemuxer.videoReadAhead
                    if stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_MPEG4
                        && [0x4449_5658, 0x5856_4944, 0x4458_3530].contains(stream.pointee.codecpar.pointee.codec_tag),  // 'DIVX', 'XVID', 'DX50'
                        let bsf = av_bsf_get_by_name("mpeg4_unpack_bframes")  // Regularize DivX streams
                    {
                        var ctx: UnsafeMutablePointer<AVBSFContext>?
                        if av_bsf_alloc(bsf, &ctx) == 0 {
                            avcodec_parameters_copy(ctx!.pointee.par_in, stream.pointee.codecpar)
                            ctx!.pointee.time_base_in = stream.pointee.time_base
                            let ret = av_bsf_init(ctx!)
                            if ret == 0 {
                                if TRACE_PACKET_DEMUXER {
                                    logger.debug("PacketDemuxer init: enabled mpeg4_unpack_bframes for stream \(idx)")
                                }
                                bsfCtx = ctx
                            } else {
                                let error = AVERROR(errorCode: ret, context: "av_bsf_init")
                                logger.error(
                                    "PacketDemuxer init: Unable to set up mpeg4_unpack_bframes for stream \(idx): \(error.errorDescription, privacy:.public)"
                                )
                                av_bsf_free(&ctx)
                            }
                        }
                    }
                } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                    capacity = PacketDemuxer.audioCapacity
                    readAhead = PacketDemuxer.audioReadAhead
                }
            }
            return PacketRing(capacity: capacity, readAhead: readAhead, timeBase: stream.pointee.time_base, bsfCtx: bsfCtx)
        }

        if String(cString: fmt_ctx.pointee.iformat.pointee.name).contains("matroska") { pktFixup = 4 }
        if TRACE_PACKET_DEMUXER {
            logger.debug("PacketDemuxer init streams: \(fmt_ctx.pointee.nb_streams) pktFixup: \(self.pktFixup)")
        }

        lastPkt = [UnsafeMutablePointer<AVPacket>?](repeating: nil, count: Int(fmt_ctx.pointee.nb_streams))
        findLastPackets()

        // Reset to start
        let ret = avformat_seek_file(format.fmt_ctx, -1, Int64.min, Int64.min, 0, 0)
        guard ret >= 0 else {
            throw AVERROR(errorCode: ret, context: "avformat_seek_file(min)")  // If we can't seek to start we can't demux
        }
        startDemuxLoop()
    }

    deinit {
        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer deinit") }
        logger.info("PacketDemuxer \(self.status(), privacy: .public)")
        logger.info("Buffer usage:")
        for i in 0..<buffers.count { logger.info("  \(i): \(self.status(stream: i), privacy: .public)") }
        stop()  // if not already stopping
        stateLock.lock()
        for i in 0..<buffers.count { buffers[i].reset() }
        for i in 0..<lastPkt.count { av_packet_free(&lastPkt[i]) }
        stateLock.unlock()
    }

    func status() -> String {
        if stopping {
            return "stopping"
        } else if halted {
            return "halted"
        } else if demuxPause() {
            return "paused"
        } else {
            return "running"
        }
    }

    func status(stream: Int) -> String {
        return
            "currently: \(buffers[stream].count)/\(buffers[stream].capacity) highest: \(buffers[stream].highest) readAhead: \(buffers[stream].readAhead)"
    }

    func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
        demuxSem.signal()
        buffers.forEach { $0.packetSem.signal() }
    }

    func join() {
        demuxGroup.wait()
    }

    func get(stream: Int, handle: PacketHandle, consumed: Bool = false) -> UnsafeMutablePointer<AVPacket>? {
        if handle.isLast {
            return lastPkt[stream]  // may be nil if couldn't find last packet
        } else {
            guard handle.generation == generation else {
                // AVFoundation tries to step from an old video SampleCursor after a seek
                // Fortunately doesn't seem a problem for the SampleCursor to return an Error
                if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer get stream \(stream) idx \(handle.index) stale") }
                return nil
            }
            stateLock.lock()
            defer { stateLock.unlock() }
            if let pkt = buffers[stream].get(logicalIndex: handle.index) {
                if consumed && (pkt.pointee.flags & AV_PKT_FLAG_KEY != 0) {
                    // Packet is being passed to AVFoundation
                    // Keep the last consumed keyframe for stepInPresentationOrder calculations. Discard everyting older.
                    buffers[stream].consume(logicalIndex: handle.index - 1)
                    demuxSem.signal()  // demuxer may now be able to proceed
                }
                return pkt
            } else if self.buffers[stream].isEmpty {
                logger.error("PacketDemuxer get stream \(stream) idx \(handle.index) buffer empty")
            } else if TRACE_PACKET_DEMUXER {
                logger.debug(
                    "PacketDemuxer get stream \(stream) idx \(handle.index) evicted valid:\(self.buffers[stream].minLogicalIndex)-\(self.buffers[stream].maxLogicalIndex) lastConsumed:\(self.buffers[stream].lastConsumed)"
                )
            }
            return nil
        }
    }

    func step(stream: Int, from handle: PacketHandle, by: Int) -> PacketHandle {
        if handle.isLast { return handle }  // Special handling for end-of-stream
        if handle.generation != generation { return PacketHandle(generation: generation, index: -1, isLast: false) }
        let requested = handle.index + by
        while true {
            stateLock.lock()
            if halted {
                let maxIdx = buffers[stream].isEmpty ? handle.index : buffers[stream].maxLogicalIndex
                if TRACE_PACKET_DEMUXER {
                    logger.debug(
                        "PacketDemuxer stream=\(stream) step from:\(handle.index) by:\(by) -> \(min(requested, maxIdx)) (halted)"
                    )
                }
                stateLock.unlock()
                return PacketHandle(generation: generation, index: min(requested, maxIdx), isLast: requested >= maxIdx)
            } else if buffers[stream].get(logicalIndex: requested) != nil {
                if TRACE_PACKET_DEMUXER {
                    logger.debug("PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) -> \(requested)")
                }
                stateLock.unlock()
                return PacketHandle(generation: generation, index: requested, isLast: false)
            } else if requested < buffers[stream].minLogicalIndex {
                logger.warning(
                    "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) overrun, min=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].minLogicalIndex)"
                )
                stateLock.unlock()
                return PacketHandle(
                    generation: generation,
                    index: buffers[stream].minLogicalIndex,
                    isLast: requested >= buffers[stream].maxLogicalIndex
                )
            } else if demuxPause() {
                // Try again after allowing more read-ahead
                buffers[stream].increaseReadAhead(requested: requested)
                if requested - buffers[stream].lastConsumed > buffers[stream].capacity || demuxPause() {
                    // Buffer cannot fill enough to contain the requested packet
                    let maxIdx = buffers[stream].isEmpty ? handle.index : buffers[stream].maxLogicalIndex
                    logger.error(
                        "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) underrun, max=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].maxLogicalIndex)"
                    )
                    stateLock.unlock()
                    return PacketHandle(generation: generation, index: min(requested, maxIdx), isLast: requested >= maxIdx)
                } else {
                    demuxSem.signal()  // Resume with increased read-ahead
                    if TRACE_PACKET_DEMUXER {
                        logger.debug(
                            "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) underrun, max=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].maxLogicalIndex) readahead increased to \(self.buffers[stream].readAhead)"
                        )
                    }
                }
            } else if TRACE_PACKET_DEMUXER {
                logger.debug(
                    "PacketDemuxer stream \(stream) step from:\(handle.index) by:\(by) underrun, max=\(self.buffers[stream].isEmpty ? -1 : self.buffers[stream].maxLogicalIndex)"
                )
            }
            // wait for more packets
            stateLock.unlock()
            buffers[stream].packetSem.wait()
        }  // loop until available
    }

    func seek(stream: Int, presentationTimeStamp: CMTime) throws -> PacketHandle {
        guard let format = format else {
            stop()
            throw AVERROR(errorCode: AVERROR_EOF, context: "PacketDemuxer seek")
        }

        // Special cases
        if presentationTimeStamp.isPositiveInfinity
            // Fix for QuickTime player which asks for a later SampleCursor after asking for one at +inf
            || (lastPkt[stream] != nil
                && presentationTimeStamp >= CMTime(value: lastPkt[stream]!.pointee.pts, timeBase: buffers[stream].timeBase))
        {
            return PacketHandle(generation: generation, index: Int.max, isLast: true)
        } else if let remembered = rememberedSeekPTS,
            remembered.value == presentationTimeStamp.value && remembered.timescale == presentationTimeStamp.timescale
        {
            if TRACE_PACKET_DEMUXER {
                logger.debug("PacketDemuxer stream \(stream) seek \(presentationTimeStamp, privacy: .public) -> 0 [remembered]")
            }
            if buffers[stream].isEmpty {
                try waitForPacketZero(stream: stream)
                return PacketHandle(generation: generation, index: 0, isLast: false)
            } else if buffers[stream].minLogicalIndex == 0 && buffers[stream].isReady {
                return PacketHandle(generation: generation, index: 0, isLast: false)
            } else {
                logger.warning(
                    "PacketDemuxer stream \(stream) seek \(presentationTimeStamp, privacy: .public) remembered but first packet is \(self.buffers[stream].minLogicalIndex)"
                )
            }
        }

        // Snapshot for thumbnail
        var target = presentationTimeStamp
        if (presentationTimeStamp.value == QLThumbnailTime.value && presentationTimeStamp.timescale == QLThumbnailTime.timescale)
            || (presentationTimeStamp.value == 0 && presentationTimeStamp.timescale == buffers[stream].timeBase.den
                && format.bestAudio >= 0 && !format.loadUneditedDurationCalled)  // workaround for macOS 26.4 bug
        {
            // If seeking to exactly QuickLook's thumbnail time, seek instead to the user's choice
            let durationPTS = lastPkt[stream]?.pointee.pts ?? format.fmt_ctx!.pointee.streams[stream]!.pointee.duration
            if durationPTS > 0 {
                target = CMTime(value: CMTimeValue(Double(durationPTS) * format.snapshotTime), timeBase: buffers[stream].timeBase)
            }
            logger.info(
                "PacketDemuxer stream \(stream) seek \(presentationTimeStamp, privacy: .public) treated as thumbnail request at \(target, privacy: .public)"
            )
        }

        stateLock.lock()
        if let hit = buffers[stream].nearest(to: target) {
            stateLock.unlock()
            if TRACE_PACKET_DEMUXER {
                logger.debug("PacketDemuxer stream \(stream) seek \(target, privacy: .public) -> \(hit)")
            }
            return PacketHandle(generation: generation, index: hit, isLast: false)
        }

        // Miss: perform a discontinuous seek
        flushLocked()
        rememberedSeekPTS = presentationTimeStamp  // remember the request, not the actual target
        var ret: Int32
        if target.timescale == buffers[stream].timeBase.den {
            // Asked to seek in this stream's timebase - typical when scrubbing video stream in macOS <= 26.3, also thumbnail snapshot calculated above
            let src = AVRational(num: 1, den: Int32(target.timescale))
            let timestamp = av_rescale_q(target.value, src, buffers[stream].timeBase)
            ret = avformat_seek_file(format.fmt_ctx, Int32(stream), timestamp / 2, timestamp, (timestamp * 3) / 2, 0)
            if ret < 0 {
                ret = avformat_seek_file(format.fmt_ctx, Int32(stream), Int64.min, timestamp, Int64.max, 0)
            }
        } else if target.value == 0 || target.timescale == AV_TIME_BASE {
            // Arbitrary seeks from AVFoundation
            ret = avformat_seek_file(format.fmt_ctx, -1, Int64.min, target.value, Int64.max, 0)
        } else {
            // Seek in arbitrary units - typical when scrubbing video stream in macOS >= 26.4
            let src = AVRational(num: 1, den: Int32(target.timescale))
            let AV_TIME_BASE_Q = AVRational(num: 1, den: Int32(AV_TIME_BASE))
            let timestamp = av_rescale_q(target.value, src, AV_TIME_BASE_Q)
            target = CMTime(value: timestamp, timescale: AV_TIME_BASE)
            ret = avformat_seek_file(format.fmt_ctx, -1, Int64.min, timestamp, Int64.max, 0)
        }
        if ret < 0 {
            let error = AVERROR(errorCode: ret, context: "avformat_seek_file")
            logger.error(
                "PacketDemuxer seek stream \(stream) time \(target, privacy: .public): \(error.errorDescription, privacy:.public)"
            )
            stateLock.unlock()
            throw error
        }
        if TRACE_PACKET_DEMUXER {
            logger.debug("PacketDemuxer stream \(stream) seek \(target, privacy: .public) -> 0 [seek_file]")
        }
        avformat_flush(format.fmt_ctx)
        stateLock.unlock()
        demuxSem.signal()  // kick demux loop to start filling
        try waitForPacketZero(stream: stream)  // Wait for the first packet to arrive after seek
        return PacketHandle(generation: generation, index: 0, isLast: false)
    }

    func seek(stream: Int, decodeTimeStamp: CMTime) throws -> PacketHandle {
        let target = decodeTimeStamp
        let timeBase = buffers[stream].timeBase

        stateLock.lock()
        // Ensure we have at least one packet to start from
        while buffers[stream].isEmpty && !stopping && !halted {
            if demuxPause() { break }  // Cannot make progress
            demuxSem.signal()
            stateLock.unlock()
            buffers[stream].packetSem.wait()
            stateLock.lock()
        }
        if buffers[stream].isEmpty {
            stateLock.unlock()
            return PacketHandle(generation: generation, index: Int.max, isLast: true)
        }
        // Try to find a packet in the current buffer with dts >= target
        let currentGen = generation
        var candidate: Int? = nil
        for offset in 0..<buffers[stream].count {
            if let pkt = buffers[stream].get(logicalIndex: buffers[stream].minLogicalIndex + offset) {
                let dts = pkt.pointee.dts
                if dts == AV_NOPTS_VALUE { continue }
                let ts = CMTime(value: dts, timeBase: timeBase)
                if ts >= target {
                    candidate = buffers[stream].minLogicalIndex + offset
                    break
                }
            }
        }
        if let idx = candidate {
            stateLock.unlock()
            return PacketHandle(generation: currentGen, index: idx, isLast: false)
        }

        // Step forward until we find dts >= target or hit end
        var handle = PacketHandle(generation: currentGen, index: buffers[stream].maxLogicalIndex, isLast: false)
        stateLock.unlock()
        while true {
            handle = step(stream: stream, from: handle, by: 1)
            if handle.isLast || handle.index == -1 {
                return handle
            }
            let pkt = get(stream: stream, handle: handle)
            let ts = CMTime(value: pkt!.pointee.dts, timeBase: timeBase)
            if ts >= target { return handle }
        }
    }

    // MARK: internals

    private func startDemuxLoop() {
        demuxQueue.async { self.demuxLoop() }
    }

    private func demuxLoop() {
        demuxGroup.enter()
        defer { demuxGroup.leave() }
        while true {
            stateLock.lock()
            guard !stopping else {
                stateLock.unlock()
                break
            }
            if demuxPause() {
                stateLock.unlock()
                demuxSem.wait()
                continue
            }
            guard let format, let fmt_ctx = format.fmt_ctx else {
                stateLock.unlock()
                break
            }
            var pkt = av_packet_alloc()
            // Keep FormatReader alive while FFmpeg may invoke AVIO callbacks using its opaque pointer, and
            // until stateLock is released so FormatReader.deinit cannot re-enter demuxer.stop() while locked.
            withExtendedLifetime(format) {
                let ret = av_read_frame(fmt_ctx, pkt)
                if ret != 0 {
                    av_packet_free(&pkt)
                    halted = true
                    stateLock.unlock()
                    if ret == AVERROR_EOF {
                        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer demuxLoop reached EOF") }
                    } else {
                        let error = AVERROR(errorCode: ret, context: "av_read_frame")
                        logger.error("PacketDemuxer demuxLoop: \(error.errorDescription, privacy:.public)")
                    }
                    demuxSem.signal()
                    buffers.forEach { $0.packetSem.signal() }  // wake consumers so they can see halted
                    return
                }
                if pkt!.pointee.size == 0 || Int(pkt!.pointee.stream_index) >= buffers.count
                    || buffers[Int(pkt!.pointee.stream_index)].capacity == 0
                {
                    // Skip empty packets as seen in e.g. Theora since AVFoundation doesn't like them
                    // (-12706 kCMBlockBufferEmptyBBufErr) and skip packets for streams we don't handle
                    av_packet_free(&pkt)
                } else if let filtered = applyBitstreamFilter(stream: Int(pkt!.pointee.stream_index), packet: pkt!) {
                    for pkt in filtered { enqueue(pkt) }
                } else {
                    pkt!.pointee.pos += pktFixup
                    enqueue(pkt!)
                }
                stateLock.unlock()
            }
        }
    }

    // Whether demuxLoop should pause. Assumes stateLock is locked.
    private func demuxPause() -> Bool {
        if halted { return true }
        // Pause if continuing might cause eviction of an unconsumed packet in any stream
        for i in 0..<buffers.count {
            if buffers[i].isFull && !buffers[i].isEmpty && buffers[i].minLogicalIndex >= buffers[i].lastConsumed { return true }
        }
        // Unpause if we haven't reached a read-ahead target in any stream
        for i in 0..<buffers.count {
            let buffer = buffers[i]
            if buffer.bufferedAhead < buffer.readAhead {
                if false {
                    logger.debug("PacketDemuxer demuxLoop stream \(i) idx \(buffer.bufferedAhead) < target \(buffer.readAhead)")
                }
                return false
            }
        }
        if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer demuxLoop pausing") }
        return true  // Reached all read-ahead targets
    }

    private func enqueue(_ packet: UnsafeMutablePointer<AVPacket>) {
        let stream = Int(packet.pointee.stream_index)
        let buffer = buffers[stream]
        assert(buffer.capacity > 0, "PacketDemuxer stream \(stream) unexpected packet in discarded stream")
        var evicted = buffers[stream].append(packet: packet)
        av_packet_free(&evicted)
        if TRACE_PACKET_DEMUXER {
            let pts = packet.pointee.pts
            let dts = packet.pointee.dts
            let dur = packet.pointee.duration
            let pos = packet.pointee.pos
            let size = packet.pointee.size
            let flags = packet.pointee.flags
            logger.debug(
                "PacketDemuxer queue stream \(stream) idx:\(buffer.maxLogicalIndex) dts:\(dts) pts:\(pts) duration:\(dur == AV_NOPTS_VALUE ? -1 : dur) time_base:\(buffer.timeBase.num)/\(buffer.timeBase.den) pos:0x\(pos >= 0 ? UInt64(pos) : 0, format:.hex) size:0x\(UInt(size), format:.hex) flags:\(flags & AV_PKT_FLAG_KEY != 0 ? "K" : "_", privacy: .public)\(flags & AV_PKT_FLAG_DISCARD != 0 ? "D" : "_", privacy: .public)\(flags & AV_PKT_FLAG_CORRUPT != 0 ? "C" : "_", privacy: .public)"
            )
        }

        // AVFoundation doesn't like it if packets don't have a DTS.
        // This can be seen in Matroska files where the first few packets don't have DTSs but later packets do.
        if buffer.minLogicalIndex == 0, let first = buffer.get(logicalIndex: 0), first.pointee.dts == AV_NOPTS_VALUE {
            // Hack: We can fix up DTSs with negative values if we have valid durations/DTSs in later packets.
            if packet.pointee.dts != AV_NOPTS_VALUE {
                if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer stream \(stream) fixing up DTS values") }
                var dts = packet.pointee.dts
                for i in (0..<buffer.count - 1).reversed() {
                    if let pkt = buffer.get(logicalIndex: i) {
                        pkt.pointee.dts = dts - (packet.pointee.duration != AV_NOPTS_VALUE ? pkt.pointee.duration : 1)
                        dts = pkt.pointee.dts
                    }
                }
            } else {
                return  // Don't signal availability of a packet we hope is going to be fixed up later
            }
        }

        // Audio decode depends on packet duration for efficient buffer allocation.
        // Missing duration can be seen in some VBR audio such as WMA in ASF.
        if packet.pointee.duration == 0 {
            if let prev = buffer.get(logicalIndex: buffer.count - 2) {
                if prev.pointee.pts != AV_NOPTS_VALUE, packet.pointee.pts != AV_NOPTS_VALUE,
                    packet.pointee.pts - prev.pointee.pts > 0
                {
                    prev.pointee.duration = packet.pointee.pts - prev.pointee.pts  // Assumes packets demuxed in PTS order
                } else if prev.pointee.dts != AV_NOPTS_VALUE, packet.pointee.dts != AV_NOPTS_VALUE,
                    packet.pointee.dts - prev.pointee.dts > 0  // Fallback
                {
                    prev.pointee.duration = packet.pointee.dts - prev.pointee.dts
                }
            } else {
                if TRACE_PACKET_DEMUXER { logger.debug("PacketDemuxer stream \(stream) fixing up duration values") }
                return  // Don't signal availability of the first packet. The final packet will be signalled with 0 duration when we hit halted.
            }
        }

        buffers[stream].packetSem.signal()  // signal to consumers that a packet arrived
    }

    private func flushLocked() {
        for i in 0..<buffers.count { buffers[i].reset() }
        generation &+= 1
        halted = false
    }

    private func waitForPacketZero(stream: Int) throws {
        defer { stateLock.unlock() }
        while true {
            stateLock.lock()
            if format == nil || stopping || buffers[stream].isReady { return }
            if halted || demuxPause() { throw MEError(.endOfStream) }  // Maybe this stream doesn't contain any packets?
            stateLock.unlock()
            buffers[stream].packetSem.wait()
        }
    }

    // MediaExtension will call us for the last packet for each stream; find this now so it doesn't mess up our demuxing
    private func findLastPackets() {
        let ret = avformat_seek_file(format!.fmt_ctx, -1, 0, Int64.max, Int64.max, 0)
        guard ret >= 0 else {
            // Can't seek to end. Not fatal for now.
            let error = AVERROR(errorCode: ret, context: "avformat_seek_file(max)")
            logger.error("PacketDemuxer init: Failed to get last packets \(error.errorDescription, privacy: .public)")
            return
        }
        repeat {
            var pkt = av_packet_alloc()
            let ret = av_read_frame(format!.fmt_ctx, pkt)
            if ret == AVERROR_EOF {
                av_packet_free(&pkt)
                break
            } else if ret != 0 {
                av_packet_free(&pkt)
                let error = AVERROR(errorCode: ret, context: "av_read_frame")
                logger.error("PacketDemuxer init: Failed to get last packets \(error.errorDescription, privacy: .public)")
                break
            } else if pkt!.pointee.stream_index >= buffers.count {
                logger.warning("PacketDemuxer init: Packet with invalid stream \(pkt!.pointee.stream_index)")
                av_packet_free(&pkt)
            } else {
                let idx = Int(pkt!.pointee.stream_index)
                if lastPkt[idx] != nil { av_packet_free(&lastPkt[idx]) }
                lastPkt[idx] = pkt
            }
        } while true
    }

    private func applyBitstreamFilter(stream: Int, packet: UnsafeMutablePointer<AVPacket>) -> [UnsafeMutablePointer<AVPacket>]? {
        guard let bsf = buffers[stream].bsfCtx else { return nil }
        var ret = av_bsf_send_packet(bsf, packet)  // consumes packet if successful
        if ret < 0 {
            if TRACE_PACKET_DEMUXER {
                let err = AVERROR(errorCode: ret, context: "av_bsf_send_packet")
                logger.error("PacketDemuxer bsf send stream \(stream): \(err.errorDescription, privacy:.public)")
            }
            return nil
        }
        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        while true {
            var outPkt = av_packet_alloc()
            ret = av_bsf_receive_packet(bsf, outPkt)
            if ret == 0 {
                outputs.append(outPkt!)
            } else {
                av_packet_free(&outPkt)
                if TRACE_PACKET_DEMUXER && ret != AVERROR_EOF && ret != AVERROR_EAGAIN {
                    let err = AVERROR(errorCode: ret, context: "av_bsf_receive_packet")
                    logger.error("PacketDemuxer bsf recv stream \(stream): \(err.errorDescription, privacy:.public)")
                }
                break
            }
        }
        return outputs
    }

}
