//
//  audiopassthrusamplecursor.swift
//  QLVideo
//
//  A SampleCursor that responds to loadSampleBufferContainingSamples to provide packets of compressed audio data.
//  Used to supply audio data for formats that CoreAudio understands.
//

import MediaExtension

class AudioPassthruSampleCursor: SampleCursor {

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

    init(copying: AudioPassthruSampleCursor) {
        super.init(copying: copying)
        self.lastDelivered = copying.lastDelivered
        self.nextHandle = copying.nextHandle
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        return AudioPassthruSampleCursor(copying: self)
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
        let frameSize = sampleSize * Int(params.pointee.ch_layout.nb_channels)
        let frameCount = Int(params.pointee.frame_size)

        lastDelivered = 0

        let uncompressed = [kAudioFormatLinearPCM, kAudioFormatALaw, kAudioFormatULaw].contains(
            track.formatDescription!.mediaSubType.rawValue
        )
        var sampleSizeArray: [Int] = []
        if uncompressed {
            sampleSizeArray.append(frameSize)  // size in bytes of the frame not of a sample
        } else {
            sampleSizeArray.reserveCapacity(endSampleCursor.handle.index - self.handle.index + 1)
        }

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

        // retrieve packets and add the raw data to the blockBuffer
        for idx in handle.index...endSampleCursor.handle.index {
            // we only expect to be asked to provide data in the range of packets that we've previously reported as
            // existing, so treat any errors in retreiving and decoding as unexpected and unrecoverable
            nextHandle = PacketHandle(generation: handle.generation, index: idx, isLast: false)
            guard let pkt = demuxer?.get(stream: streamIndex, handle: nextHandle!) else {
                logger.error(
                    "AudioPassthruSampleCursor \(self.instance) stream \(self.streamIndex) at idx:\(idx) [no packet] loadSampleBufferContainingSamples"
                )
                break
            }

            // Arrange for CoreMedia to free the packet data when no longer needed.
            // See CMBlockBufferCustomBlockSource in CMBlockBuffer.h for why we're constructing this on the fly
            var dataPkt = av_packet_clone(pkt)
            var blockSource = CMBlockBufferCustomBlockSource(
                version: 0,
                AllocateBlock: nil,
                FreeBlock: {
                    var pkt: UnsafeMutablePointer<AVPacket>? = $0!.assumingMemoryBound(to: AVPacket.self)
                    let _ = $1  // doomedMemoryBlock unused - av_buffer_unref() or av_packet_free() will free it
                    let _ = $2  // sizeInBytes unused
                    av_packet_free(&pkt)
                },
                refCon: dataPkt,
            )
            var childBuffer: CMBlockBuffer? = nil
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: dataPkt!.pointee.data,
                blockLength: Int(dataPkt!.pointee.size),
                blockAllocator: kCFAllocatorNull,
                customBlockSource: &blockSource,
                offsetToData: 0,
                dataLength: Int(pkt.pointee.size),
                flags: kCMBlockBufferAssureMemoryNowFlag,  // not sure if this does anything useful
                blockBufferOut: &childBuffer
            )
            guard status == noErr else {
                let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                logger.error(
                    "\(self.debugDescription, privacy: .public) loadSampleBufferContainingSamples to \(endSampleCursor.debugDescription, privacy: .public): CMBlockBufferCreateWithMemoryBlock returned \(error, privacy:.public)"
                )
                av_packet_free(&dataPkt)
                return completionHandler(nil, error)
            }
            status = CMBlockBufferAppendBufferReference(
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
            if uncompressed {
                lastDelivered += Int(pkt.pointee.size) / frameSize
            } else {
                sampleSizeArray.append(Int(pkt.pointee.size))
                lastDelivered += 1
            }
        }
        nextHandle =
            endSampleCursor.handle.isLast
            ? nil
            : demuxer?.step(stream: streamIndex, from: endSampleCursor.handle, by: 1)

        // At this point the data is compressed or uncompressed+interleaved residing in multiple children of blockBuffer
        var sampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: uncompressed ? 1 : CMTimeValue(frameCount), timescale: sampleRate),  // duration of one sample or one compressed packet if known
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
            sampleSizeEntryCount: sampleSizeArray.count,
            sampleSizeArray: &sampleSizeArray,
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

    // Step by number of uncompressed frames or compressed packets
    override func stepInDecodeOrder(by stepCount: Int64, completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void) {

        if stepCount == lastDelivered, let next = nextHandle, next.generation == handle.generation {
            // Being asked to step by the number of frames/packets we last delivered in loadSampleBufferContainingSamples
            if TRACE_SAMPLE_CURSOR {
                logger.debug("\(self.debugDescription, privacy: .public) stepInDecodeOrder by \(stepCount) = lastDelivered")
            }
            // trim up to the *starting* packet - some codecs e.g. HE-AAC want to step from packets that have already been delivered
            _ = demuxer?.get(stream: streamIndex, handle: handle, consumed: true)
            let steppedBy = Int64(lastDelivered)
            handle = next
            nextHandle = nil
            lastDelivered = 0
            return completionHandler(steppedBy, nil)
        } else {
            return super.stepInDecodeOrder(by: stepCount, completionHandler: completionHandler)
        }
    }

}
