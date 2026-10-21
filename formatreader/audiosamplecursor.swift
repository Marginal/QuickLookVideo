//
//  audiosamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to loadSampleBufferContainingSamples to provide packets of audio data converted to PCM.
//  Used to supply audio data for formats that CoreAudio doesn't understand.
//

import MediaExtension

class AudioSampleCursor: SampleCursor {

    // used by stepInDecodeOrderByCount
    var lastDelivered = 0
    var nextHandle: PacketHandle? = nil

    override init(format: FormatReader, track: TrackReader, index: Int, atPresentationTimeStamp presentationTimeStamp: CMTime)
        throws
    {
        try super.init(format: format, track: track, index: index, atPresentationTimeStamp: presentationTimeStamp)
        self.lastDelivered = 0
        self.nextHandle = nil
    }

    init(copying: AudioSampleCursor) {
        super.init(copying: copying)
        self.lastDelivered = copying.lastDelivered
        self.nextHandle = copying.nextHandle
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        return AudioSampleCursor(copying: self)
    }

    // https://developer.apple.com/documentation/mediaextension/mesamplecursor
    // Core Media's preferred way of accessing sample data is to be provided with an offset and length into
    // the file via sampleLocation() and chunkDetails(), and reading it directly. But FFmpeg doesn't expose this info.
    // FFmpeg works by reading data from the file until it has a valid packet for one of the streams.
    override func loadSampleBufferContainingSamples(
        to endSampleCursor: (any MESampleCursor)?,
        completionHandler: @escaping (CMSampleBuffer?, (any Error)?) -> Void
    ) {
        // "If endSampleCursor is nil or refers to the same sample as the receiver,
        //  only a single sample should be returned in the new sample buffer."
        guard let track = track as? AudioTrackReader,
            let endSampleCursor = endSampleCursor != nil ? endSampleCursor as? SampleCursor : self,
            let startPkt = demuxer?.get(stream: streamIndex, handle: handle),
            demuxer?.get(stream: streamIndex, handle: endSampleCursor.handle) != nil
        else {
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public)"
            )
            return completionHandler(nil, MEError(.endOfStream))
        }
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public) packetCount=\(endSampleCursor.handle.index - self.handle.index + 1)"
            )
        }
        // "If endSampleCursor refers to a sample earlier than the receiver,
        //  this method should fail and return MEErrorNoSamples as error code."
        guard handle.index <= endSampleCursor.handle.index else {
            return completionHandler(nil, MEError(.noSamples))
        }

        let params = track.stream.pointee.codecpar!
        let sampleRate = params.pointee.sample_rate
        let sampleFormat = AVSampleFormat(params.pointee.format)
        let sampleSize = Int(av_get_bytes_per_sample(sampleFormat))
        var frameSize = sampleSize * Int(params.pointee.ch_layout.nb_channels)
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }  // safe to call if frame is NULL
        guard let frame else { return completionHandler(nil, MEError(.allocationFailure)) }

        if discontinuity { avcodec_flush_buffers(track.dec_ctx) }
        lastDelivered = 0

        var blockBuffer: CMBlockBuffer? = nil
        var status = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: UInt32(endSampleCursor.handle.index - self.handle.index + 1),
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMBlockBufferCreateEmpty returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        // decode packets and add the decoded data to the blockBuffer
        for idx in handle.index...endSampleCursor.handle.index {
            // we only expect to be asked to provide data in the range of packets that we've previously reported as
            // existing, so treat any errors in retreiving and decoding as unexpected and unrecoverable
            nextHandle = PacketHandle(generation: handle.generation, index: idx, isLast: false)
            guard let pkt = demuxer?.get(stream: streamIndex, handle: nextHandle!) else {
                logger.error(
                    "AudioSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(idx) [no packet] loadSampleBufferContainingSamples"
                )
                break
            }
            var ret = avcodec_send_packet(track.dec_ctx, pkt)
            if ret < 0 {
                let error = AVERROR(errorCode: ret, context: "avcodec_send_packet")
                logger.warning(
                    "AudioSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples: \(error.errorDescription, privacy: .public)"
                )
                if ret == AVERROR_INVALIDDATA { continue }  // Hope AVFoundation can cope with missed data
                return completionHandler(nil, error)
            }

            while true {
                ret = avcodec_receive_frame(track.dec_ctx, frame)
                if ret == AVERROR_EAGAIN {
                    break
                } else if ret < 0 {
                    let error = AVERROR(errorCode: ret, context: "avcodec_receive_frame")
                    logger.error(
                        "AudioSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples: \(error.errorDescription, privacy: .public)"
                    )
                    return completionHandler(nil, error)
                }
                let frameCount = Int(frame.pointee.nb_samples)
                let capacity = frameCount * frameSize
                var childBuffer: CMBlockBuffer?

                if track.swr_ctx != nil {
                    // planar / non-interleaved - convert to packed
                    // CoreMedia doesn't like planar PCM (error "SSP::Render: CopySlice returned 1") so convert to packed/interleaved
                    // http://www.openradar.me/45068930
                    status = CMBlockBufferCreateWithMemoryBlock(
                        allocator: kCFAllocatorDefault,
                        memoryBlock: nil,  // let CoreMedia allocate
                        blockLength: capacity,
                        blockAllocator: kCFAllocatorDefault,
                        customBlockSource: nil,
                        offsetToData: 0,
                        dataLength: capacity,  // we intend to fill the whole block
                        flags: kCMBlockBufferAssureMemoryNowFlag,
                        blockBufferOut: &childBuffer
                    )
                    guard status == noErr else {
                        let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                        logger.error(
                            "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
                        )
                        return completionHandler(nil, error)
                    }

                    var dataPtr: UnsafeMutablePointer<Int8>?
                    status = CMBlockBufferGetDataPointer(
                        childBuffer!,
                        atOffset: 0,
                        lengthAtOffsetOut: nil,
                        totalLengthOut: nil,
                        dataPointerOut: &dataPtr
                    )
                    var outPtr = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))
                    let inPtrs: UnsafePointer<UnsafePointer<UInt8>?>? = frame.pointee.extended_data?.withMemoryRebound(
                        to: UnsafePointer<UInt8>?.self,
                        capacity: Int(params.pointee.ch_layout.nb_channels)
                    ) { return UnsafePointer($0) }
                    ret = swr_convert(
                        track.swr_ctx,
                        &outPtr,
                        frame.pointee.nb_samples,
                        inPtrs,
                        frame.pointee.nb_samples
                    )
                    if ret < 0 {
                        let error = AVERROR(errorCode: ret, context: "swr_convert")
                        logger.error(
                            "AudioSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public) loadSampleBufferContainingSamples: \(error.errorDescription, privacy: .public)"
                        )
                        return completionHandler(nil, error)
                    }
                    assert(
                        ret == frame.pointee.nb_samples,
                        "AudioSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)) loadSampleBufferContainingSamples: Expected \(frame.pointee.nb_samples), received \(ret) samples"
                    )
                } else {
                    // packed / interleaved - pass the AVFrame data through
                    assert(
                        av_sample_fmt_is_planar(sampleFormat) == 0,
                        "AudioSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(self.nextHandle!.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)) loadSampleBufferContainingSamples: Sample format mismatch"
                    )

                    // Arrange for CoreMedia to free the frame data when no longer needed.
                    // See CMBlockBufferCustomBlockSource in CMBlockBuffer.h for why we're constructing this on the fly
                    var dataFrame = av_frame_clone(frame)
                    var blockSource = CMBlockBufferCustomBlockSource(
                        version: 0,
                        AllocateBlock: nil,
                        FreeBlock: {
                            var frame: UnsafeMutablePointer<AVFrame>? = $0!.assumingMemoryBound(to: AVFrame.self)
                            let _ = $1  // doomedMemoryBlock unused - av_frame_free() will free it
                            let _ = $2  // sizeInBytes unused
                            av_frame_free(&frame)
                        },
                        refCon: dataFrame,
                    )
                    let status = CMBlockBufferCreateWithMemoryBlock(
                        allocator: kCFAllocatorDefault,
                        memoryBlock: dataFrame!.pointee.data.0,
                        blockLength: Int(dataFrame!.pointee.linesize.0),
                        blockAllocator: kCFAllocatorNull,
                        customBlockSource: &blockSource,
                        offsetToData: 0,
                        dataLength: capacity,
                        flags: kCMBlockBufferAssureMemoryNowFlag,  // not sure if this does anything useful
                        blockBufferOut: &childBuffer
                    )
                    guard status == noErr else {
                        let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                        logger.error(
                            "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
                        )
                        av_frame_free(&dataFrame)
                        return completionHandler(nil, error)
                    }
                }

                let status = CMBlockBufferAppendBufferReference(
                    blockBuffer!,
                    targetBBuf: childBuffer!,
                    offsetToData: 0,
                    dataLength: 0,
                    flags: kCMBlockBufferAssureMemoryNowFlag
                )
                guard status == noErr else {
                    let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                    logger.error(
                        "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMBlockBufferAppendBufferReference returned \(error, privacy:.public)"
                    )
                    return completionHandler(nil, error)
                }
                av_frame_unref(frame)
                lastDelivered += frameCount
            }
        }
        nextHandle =
            endSampleCursor.handle.isLast
            ? nil
            : demuxer?.step(stream: streamIndex, from: endSampleCursor.handle, by: 1)

        // At this point the data is packed / interleaved residing in multiple children of blockBuffer
        var sampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),  // duration of one sample
            presentationTimeStamp: CMTime(value: startPkt.pointee.pts, timeBase: timeBase),
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: track.formatDescription,
            sampleCount: lastDelivered,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &frameSize,  // size in bytes of the frame not of a sample
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMSampleBufferCreateReady returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }

        return completionHandler(sampleBuffer, nil)
    }

    // MARK: navigation

    // Step by number of frames (not by packets or timestamp)
    override func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {

        if stepCount == lastDelivered, let next = nextHandle, next.generation == handle.generation {
            // Being asked to step by the number of audio samples we last delivered in loadSampleBufferContainingSamples
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount) = lastDelivered")
            }
            let steppedBy = Int64(lastDelivered)
            handle = next
            nextHandle = nil
            lastDelivered = 0
            _ = demuxer?.get(stream: streamIndex, handle: handle, consumed: true)  // trim up to returned packet
            return completionHandler(steppedBy, nil)
        } else {
            return super.stepInDecodeOrder(by: stepCount, completionHandler: completionHandler)
        }
    }

}
