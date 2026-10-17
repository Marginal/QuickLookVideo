//
//  samplecursor.swift
//  QLVideo
//
// See AVSampleCursor for the consumer's API by analogy. Typical usage pattern:
//
// Both:
//   - SampleCursors are transient - created to perform an operation then discarded. After the first few are created by init,
//     the rest are created by copying and the original soon discarded (but not immediately so can't just re-use orginal).
//   - init at 0/1 for playback, or
//     10,000,000/1,000,000 for thumbnail request (except 26.4 where 0/1 followed by 0/timebase), or
//     mac OS <= 26.3: n/timebase for scrub, or
//     mac OS >= 26.4: or n/90,000 for scrub (apart from rewind to start which is 0/60,000)
//     followed by stepInDecodeOrder +1 a few times.
//   - init at +inf, followed by stepInDecodeOrder +1 to find duration
//
// Audio:
//   1 *stepByDecodeTime* by ~2 seconds in timeScale units from start or step 5
//   2 stepInDecodeOrder by ~3 seconds worth of packets from start or step 5
//   3 stepInDecodeOrder +1 starting from step 2 repeated for about 1 seconds worth of packets ??? (now ~4 seconds ahead)
//   4 loadSampleBufferContainingSamples of the ~2 seconds worth of packets from step 1
//   5 stepInDecodeOrder by the number of *samples* in the buffer returned by step 3 to get to the next buffer's worth of packets
//   6 stepInDecodeOrder +1 starting from step 5 repeated for about 2 seconds worth of packets ???
//   7 VBR: stepByDecodeTime by a delta equivalent to ~1000! packets
//   8 repeat until end of stream
//
// Video:
//   1 stepInDecodeOrder +1
//   2 stepInDecodeOrder by ~3 seconds worth of packets
//   3 loadSampleBufferContainingSamples from next pkt by DTS to indefinite (currently we return one packet at a time)
//   4 samplesWithLaterDTSsMayHaveEarlierPTSs from before step 1 to step 3 - called once after seek?
//   5 *stepInPresentationOrder* by +1 and stepInDecodeOrder +1 from before step 1 a few times - looking for B frames?
//   5 repeat until end of stream
//

import MediaExtension

#if DEBUG
    let TRACE_SAMPLE_CURSOR: Bool = true
#else
    let TRACE_SAMPLE_CURSOR: Bool = false
#endif

class SampleCursor: NSObject, MESampleCursor, NSCopying {

    weak var format: FormatReader? = nil
    weak var track: TrackReader? = nil
    var streamIndex = -1  // FFmpeg stream index
    var handle = PacketHandle(generation: 0, index: -1, isLast: false)
    var discontinuity: Bool = false
    var timeBase = AVRational()
    var demuxer: PacketDemuxer? { format?.demuxer! }

    nonisolated(unsafe) static var instanceCount = 0
    var instance = 0

    init(format: FormatReader, track: TrackReader, index: Int, atPresentationTimeStamp presentationTimeStamp: CMTime) throws {
        super.init()
        self.format = format
        self.track = track
        self.streamIndex = index
        self.timeBase = track.stream.pointee.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1

        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(String(describing: type(of: self)), privacy: .public) \(self.instance) stream \(index) init at presentationTimeStamp:\(presentationTimeStamp, privacy: .public)"
            )
        }
        // Creating a SampleCursor means that CoreMedia will want packets. So start demuxing.
        format.fmt_ctxLock.lock() // We want exclusive use of fmt_ctx
        if format.demuxer == nil {
            format.demuxer = try PacketDemuxer(format: format)
        }
        format.fmt_ctxLock.unlock()
        self.handle = try demuxer!.seek(stream: streamIndex, presentationTimeStamp: presentationTimeStamp)
        self.discontinuity = true  // SampleCursors are only initted (as opposed to copied) after a seek
    }

    init(copying: SampleCursor) {
        super.init()
        self.format = copying.format
        self.track = copying.track
        self.streamIndex = copying.streamIndex
        self.timeBase = copying.track!.stream.pointee.time_base
        self.instance = SampleCursor.instanceCount
        SampleCursor.instanceCount += 1
        self.handle = copying.handle
        self.discontinuity = false
        track?.sampleCursors.add(self)
        if TRACE_SAMPLE_CURSOR { logger.debug("\(copying.debugDescription, privacy: .public) copy -> \(self.instance)") }
    }

    deinit {
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(String(describing: type(of: self)), privacy: .public) \(self.instance) stream \(self.streamIndex) at idx:\(self.handle.index) deinit"
            )
        }
    }

    func copy(with zone: NSZone? = nil) -> Any {
        return SampleCursor(copying: self)
    }

    override var debugDescription: String {
        if let pkt = demuxer?.get(stream: self.streamIndex, handle: self.handle) {
            return
                "\(String(describing: type(of: self))) \(self.instance) stream \(self.streamIndex) at idx:\(self.handle.index == Int.max ? "last" : String(self.handle.index)) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase))"
        } else {
            return
                "\(String(describing: type(of: self))) \(self.instance) stream \(self.streamIndex) at idx:\(self.handle.index) [no packet]"
        }
    }

    // MARK: pkt sample info

    var presentationTimeStamp: CMTime {
        if let pkt = demuxer?.get(stream: self.streamIndex, handle: self.handle) {
            let time = CMTime(value: pkt.pointee.pts, timeBase: self.timeBase)  // docs suggest can be invalid for B frames
            if false {
                logger.debug("\(self.debugDescription, privacy: .public) presentationTimeStamp = \(time, privacy: .public)")
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) presentationTimeStamp") }
            return .invalid
        }
    }

    var decodeTimeStamp: CMTime {
        if let pkt = demuxer?.get(stream: self.streamIndex, handle: self.handle) {
            let time = CMTime(value: pkt.pointee.dts, timeBase: self.timeBase)
            if false {
                logger.debug("\(self.debugDescription, privacy: .public) decodeTimeStamp = \(time, privacy: .public)")
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) decodeTimeStamp") }
            return .invalid
        }
    }

    var currentSampleDuration: CMTime {
        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/currentsampleduration
        if let pkt = demuxer?.get(stream: self.streamIndex, handle: self.handle) {
            let time = CMTime(value: pkt.pointee.duration, timeBase: self.timeBase)
            if false {
                logger.debug("\(self.debugDescription, privacy: .public) currentSampleDuration = \(time, privacy: .public)")
            }
            return time
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) currentSampleDuration") }
            return .invalid
        }
    }

    var currentSampleFormatDescription: CMFormatDescription? {
        if demuxer?.get(stream: self.streamIndex, handle: self.handle) != nil {
            if false {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) currentSampleFormatDescription = \(self.track!.formatDescription!.mediaSubType, privacy: .public)"
                )
            }
            return track!.formatDescription
        } else {
            if TRACE_SAMPLE_CURSOR { logger.debug("\(self.debugDescription, privacy: .public) currentSampleFormatDescription") }
            return nil
        }
    }

    // Placeholder for MESampleCursor conformance. Will be overridden in derived classs.
    func loadSampleBufferContainingSamples(
        to endSampleCursor: (any MESampleCursor)?,
        completionHandler: @escaping (CMSampleBuffer?, (any Error)?) -> Void
    ) {
        let endPresentationTimeStamp = endSampleCursor?.presentationTimeStamp ?? CMTime.indefinite
        guard (demuxer?.get(stream: streamIndex, handle: handle)) != nil else {
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public)"
            )
            return completionHandler(nil, MEError(.internalFailure))
        }
    }

    // MARK: navigation

    // Step by number of frames (not by packets or timestamp)
    func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        if demuxer?.get(stream: self.streamIndex, handle: handle) != nil {
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount)")
            }
            guard let newHandle = demuxer?.step(stream: streamIndex, from: handle, by: Int(stepCount)) else {
                return completionHandler(0, MEError(.endOfStream))
            }
            let steppedBy = Int64(newHandle.index - handle.index)
            handle = newHandle
            return completionHandler(steppedBy, nil)
        } else {
            logger.warning("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount)")
            return completionHandler(0, MEError(.endOfStream))
        }
    }

    // Step by number of frames (not by packets or timestamp)
    func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("\(self.debugDescription, privacy: .public) stepInPresentationOrder by \(stepCount)")
        }
        let oldlogicalIndex = handle.index
        guard let newHandle = demuxer?.step(stream: streamIndex, from: handle, by: Int(stepCount)),
            newHandle.index != -1
        else {
            return completionHandler(0, MEError(.endOfStream))
        }
        handle = newHandle

        // https://developer.apple.com/documentation/avfoundation/avsamplecursor/stepinpresentationorder(bycount:)
        // "If the cursor reaches the beginning or the end of the sample sequence before the requested number of samples was
        // traversed, the absolute value of the result will be less than the absolute value of the specified step count"
        return completionHandler(Int64(handle.index - oldlogicalIndex), nil)
    }

    // step by timestamp

    func stepByDecodeTime(_ deltaDecodeTime: CMTime, completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void)
    {
        if let pkt = demuxer?.get(stream: streamIndex, handle: handle) {
            if !deltaDecodeTime.isNumeric || deltaDecodeTime.timescale != timeBase.den {
                logger.error(
                    "\(self.debugDescription, privacy: .public) stepByDecodeTime by \(deltaDecodeTime, privacy: .public) invalid"
                )
                return completionHandler(.invalid, false, MEError(.invalidParameter))
            }
            let decodeTimeStamp = CMTime(value: pkt.pointee.dts, timeBase: timeBase) + deltaDecodeTime
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) stepByDecodeTime by \(deltaDecodeTime, privacy: .public)"
                )
            }
            do {
                guard let newHandle = try demuxer?.seek(stream: streamIndex, decodeTimeStamp: decodeTimeStamp),
                    let pkt = demuxer?.get(stream: self.streamIndex, handle: newHandle)!
                else {
                    return completionHandler(.invalid, false, MEError(.endOfStream))
                }
                handle = newHandle
                return completionHandler(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), handle.isLast, nil)
            } catch {
                return completionHandler(.invalid, false, error)
            }
        } else {
            if TRACE_SAMPLE_CURSOR {
                logger.error(
                    "\(self.debugDescription, privacy: .public) stepByDecodeTime by \(deltaDecodeTime, privacy: .public)"
                )
            }
            return completionHandler(.invalid, false, MEError(.invalidParameter))
        }
    }

    func stepByPresentationTime(
        _ deltaPresentationTime: CMTime,
        completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.error(
                "\(self.debugDescription, privacy: .public) stepByPresentationTime by \(deltaPresentationTime, privacy: .public) not implemented"
            )
        }
        return completionHandler(.invalid, false, MEError(.unsupportedFeature))
    }

    // MARK: GOP

    var syncInfo: AVSampleCursorSyncInfo {
        if let pkt = demuxer?.get(stream: self.streamIndex, handle: self.handle) {
            let info = AVSampleCursorSyncInfo(
                sampleIsFullSync: ObjCBool((pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0),
                sampleIsPartialSync: false,  // I don't know what this means
                sampleIsDroppable: ObjCBool((pkt.pointee.flags & (AV_PKT_FLAG_DISCARD | AV_PKT_FLAG_DISPOSABLE)) != 0)
            )
            if false {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) syncInfo sampleIsFullSync:\(info.sampleIsFullSync, privacy: .public) sampleIsDroppable:\(info.sampleIsDroppable, privacy: .public)"
                )
            }
            return info
        } else {
            if TRACE_SAMPLE_CURSOR { logger.error("\(self.debugDescription, privacy: .public) syncInfo") }
            return AVSampleCursorSyncInfo(sampleIsFullSync: false, sampleIsPartialSync: false, sampleIsDroppable: true)
        }
    }

    var dependencyInfo: AVSampleCursorDependencyInfo {
        if let pkt = demuxer?.get(stream: self.streamIndex, handle: self.handle) {
            let info = AVSampleCursorDependencyInfo(
                sampleIndicatesWhetherItHasDependentSamples: false,
                sampleHasDependentSamples: false,
                sampleIndicatesWhetherItDependsOnOthers: true,
                sampleDependsOnOthers: ObjCBool((pkt.pointee.flags & AV_PKT_FLAG_KEY) == 0),
                sampleIndicatesWhetherItHasRedundantCoding: true,
                sampleHasRedundantCoding: false
            )
            if false {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) dependencyInfo sampleHasDependentSamples:\(info.sampleHasDependentSamples, privacy: .public) sampleDependsOnOthers:\(info.sampleDependsOnOthers, privacy: .public)"
                )
            }
            return info
        } else {
            let info = AVSampleCursorDependencyInfo()
            if TRACE_SAMPLE_CURSOR { logger.error("\(self.debugDescription, privacy: .public) dependencyInfo") }
            return info
        }
    }

    // whether any sample earlier in decode order than the current sample can have a later presentation time than the current sample of the specified cursor
    // Overridden for video tracks
    func samplesWithEarlierDTSsMayHaveLaterPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) samplesWithEarlierDTSsMayHaveLaterPTSs than SampleCursor \(cursor.debugDescription, privacy: .public): false"
            )
        }
        return false
    }

    // whether any sample later in decode order than the current sample can have an earlier presentation time than the current sample of the specified cursor
    // Not called in practice, so not overridden for video tracks
    func samplesWithLaterDTSsMayHaveEarlierPTSs(than cursor: any MESampleCursor) -> Bool {
        let cursor = cursor as! SampleCursor
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) samplesWithLaterDTSsMayHaveEarlierPTSs than SampleCursor \(cursor.debugDescription, privacy: .public): false"
            )
        }
        return false
    }
}
