//
//  videosamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to loadSampleBufferContainingSamples to provide one packet of video data at a time.
//

import MediaExtension

class VideoSampleCursor: SampleCursor {

    override func copy(with zone: NSZone? = nil) -> Any {
        return VideoSampleCursor(copying: self)
    }

    // https://developer.apple.com/documentation/mediaextension/mesamplecursor
    // Core Media's preferred way of accessing sample data is to be provided with an offset and length into
    // the file via sampleLocation() and chunkDetails(), and reading it directly. But FFmpeg doesn't expose this info.
    // FFmpeg works by reading data from the file until it has a valid packet for one of the streams.
    override func loadSampleBufferContainingSamples(
        to endSampleCursor: (any MESampleCursor)?,
        completionHandler: @escaping (CMSampleBuffer?, (any Error)?) -> Void
    ) {
        let endPresentationTimeStamp = endSampleCursor?.presentationTimeStamp ?? CMTime.indefinite
        guard let pkt = demuxer?.get(stream: streamIndex, handle: handle, consumed: true) else {
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public)"
            )
            return completionHandler(nil, MEError(.endOfStream))
        }

        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public)"
            )
        }

        // Arrange for CoreMedia to free the packet data when no longer needed.
        // See CMBlockBufferCustomBlockSource in CMBlockBuffer.h for why we're constructing this on the fly
        var dataPkt = av_packet_clone(pkt)
        var blockSource = CMBlockBufferCustomBlockSource(
            version: 0,
            AllocateBlock: nil,
            FreeBlock: {
                var pkt: UnsafeMutablePointer<AVPacket>? = $0!.assumingMemoryBound(to: AVPacket.self)
                // if TRACE_SAMPLE_CURSOR { logger.debug("AudioSampleCursor free") }
                let _ = $1  // doomedMemoryBlock unused - av_buffer_unref() or av_packet_free() will free it
                let _ = $2  // sizeInBytes unused
                av_packet_free(&pkt)
            },
            refCon: dataPkt,
        )
        var blockBuffer: CMBlockBuffer? = nil
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataPkt!.pointee.data,
            blockLength: Int(dataPkt!.pointee.size),
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &blockSource,
            offsetToData: 0,
            dataLength: Int(pkt.pointee.size),
            flags: kCMBlockBufferAssureMemoryNowFlag,  // not sure if this does anything useful
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
            )
            av_packet_free(&dataPkt)
            return completionHandler(nil, error)
        }

        var sampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: pkt.pointee.duration, timeBase: timeBase),
            presentationTimeStamp: CMTime(value: pkt.pointee.pts, timeBase: timeBase),
            decodeTimeStamp: CMTime(value: pkt.pointee.dts, timeBase: timeBase)
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: track!.formatDescription,
            sampleCount: track!.stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO ? 1 : 0,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endPresentationTimeStamp, privacy: .public): CMSampleBufferCreateReady returned \(error, privacy:.public)"
            )
            return completionHandler(nil, error)
        }
        if discontinuity {
            CMSetAttachment(
                sampleBuffer!,
                key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldNotPropagate
            )
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)! as NSArray
        let attachment = attachments.firstObject as! NSMutableDictionary
        attachment[kCMSampleAttachmentKey_NotSync] =
            ((pkt.pointee.flags & AV_PKT_FLAG_KEY) == 0) ? kCFBooleanTrue : kCFBooleanFalse
        attachment[kCMSampleAttachmentKey_DoNotDisplay] =
            ((pkt.pointee.flags & AV_PKT_FLAG_DISCARD) != 0) ? kCFBooleanTrue : kCFBooleanFalse
        attachment["QLVideoIndex" as CFString] = handle.index as CFNumber
        for i in 0..<Int(pkt.pointee.side_data_elems) {
            attachment["SideData\(i)" as CFString] = CFDataCreate(
                kCFAllocatorDefault,
                pkt.pointee.side_data[i].data,
                CFIndex(pkt.pointee.side_data[i].size)
            )
            attachment["SideData\(i)Type" as CFString] = CFNumberCreate(nil, .intType, &pkt.pointee.side_data[i].type)
        }

        return completionHandler(sampleBuffer, nil)
    }

    // MARK: navigation

    // Step by number of frames (not by packets or timestamp)
    override func stepInPresentationOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void)
    {
        guard let demuxer, let track = track as? VideoTrackReader else { return completionHandler(0, MEError(.endOfStream)) }
        if track.maxBFrames == 0 {  // We can just step if we don't have B frames
            return super.stepInPresentationOrder(by: stepCount, completionHandler: completionHandler)
        }
        assert(stepCount == -1 || stepCount == 1)  // we don't currently handle anything else
        guard let startPkt = demuxer.get(stream: streamIndex, handle: handle) else {
            logger.error("\(self.debugDescription, privacy: .public) stepInPresentationOrder by \(stepCount)")
            return completionHandler(0, MEError(.endOfStream))
        }
        let startPTS = startPkt.pointee.pts
        var bestPTS = stepCount > 0 ? Int64.max : Int64.min
        var bestHandle = handle

        // Search +/-maxBFrames frames but stop earlier if:
        // +1: Can't have an earlier PTS than a keyframe, so search from previous (or current) keyframe to next.
        // -1: Search to the keyfram after next (or next if we're at a keyframe).

        // back to last keyframe (unless we're currently at one)
        if startPkt.pointee.flags & AV_PKT_FLAG_KEY == 0 {
            var stepHandle = handle
            for _ in 0..<track.maxBFrames {
                let prev = demuxer.step(stream: streamIndex, from: stepHandle, by: -1)
                guard prev.index != stepHandle.index,  // we've consumed the required packet(s) or at start of buffer
                    let pkt = demuxer.get(stream: streamIndex, handle: prev)
                else {
                    break
                }
                stepHandle = prev
                let pts = pkt.pointee.pts
                if stepCount > 0 ? (pts > startPTS) && (pts < bestPTS) : (pts < startPTS) && (pts > bestPTS) {
                    bestPTS = pts
                    bestHandle = stepHandle
                }
                if pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 { break }  // stop early at previous keyframe
            }
        }

        // Scan forward up to and including the keyframe after next
        var stepHandle = handle
        var keyFrames = stepCount < 0 || (startPkt.pointee.flags & AV_PKT_FLAG_KEY != 0) ? 1 : 2
        for _ in 0..<track.maxBFrames {
            let next = demuxer.step(stream: streamIndex, from: stepHandle, by: 1)
            guard let pkt = demuxer.get(stream: streamIndex, handle: next) else { break }
            stepHandle = next
            let pts = pkt.pointee.pts
            if stepCount > 0 ? (pts > startPTS) && (pts < bestPTS) : (pts < startPTS) && (pts > bestPTS) {
                bestPTS = pts
                bestHandle = stepHandle
            }
            if pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                keyFrames -= 1
                if keyFrames == 0 { break }  // stop early at 2nd keyframe
            }
        }

        let steppedBy = Int64(bestHandle.index - handle.index)
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) stepInPresentationOrder by \(stepCount) -> idx:\(bestHandle.index) pts:\(CMTime(value:bestPTS, timeBase: track.stream.pointee.time_base), privacy: .public)"
            )
        }
        handle = bestHandle
        return completionHandler(steppedBy, nil)
    }

    // MARK: GOP

    // whether any sample later in decode order than the current sample can have an earlier presentation time than the current sample of the specified cursor
    override func samplesWithLaterDTSsMayHaveEarlierPTSs(than cursor: any MESampleCursor) -> Bool {

        let other = cursor as! SampleCursor
        guard let demuxer, let track = track as? VideoTrackReader,
            track.maxBFrames > 0  // no B frames -> frames are in order
        else {
            if TRACE_SAMPLE_CURSOR {
                logger.debug(
                    "\(self.debugDescription, privacy: .public) samplesWithLaterDTSsMayHaveEarlierPTSs than \(other.debugDescription, privacy: .public) = false (no B frames)"
                )
            }
            return false
        }

        assert(self.handle.index > other.handle.index)
        if let otherPkt = demuxer.get(stream: other.streamIndex, handle: other.handle) {
            // Scan forward up to and including the next keyframe
            let targetPts = otherPkt.pointee.pts
            var stepHandle = handle
            while !stepHandle.isLast {
                let next = demuxer.step(stream: streamIndex, from: stepHandle, by: 1)
                guard let pkt = demuxer.get(stream: streamIndex, handle: next) else { break }
                stepHandle = next
                if pkt.pointee.pts < targetPts {
                    if TRACE_SAMPLE_CURSOR {
                        logger.debug(
                            "\(self.debugDescription, privacy: .public) samplesWithLaterDTSsMayHaveEarlierPTSs than SampleCursor \(other.debugDescription, privacy: .public) = true at idx:\(stepHandle.index) dts:\(CMTime(value: pkt.pointee.dts, timeBase: self.timeBase), privacy: .public) pts:\(CMTime(value: pkt.pointee.pts, timeBase: self.timeBase), privacy: .public)"
                        )
                    }
                    return true
                } else if pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                    break
                }
            }
        }

        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "\(self.debugDescription, privacy: .public) samplesWithLaterDTSsMayHaveEarlierPTSs than SampleCursor \(other.debugDescription, privacy: .public) = false"
            )
        }
        return false
    }

}
