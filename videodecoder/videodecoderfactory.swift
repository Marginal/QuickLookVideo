//
//  videodecoder.swift
//
//  Created by Jonathan Harris on 21/01/2026.
//

import Foundation
import MediaExtension
import OSLog

let logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "videodecoder")

class VideoDecoderFactory: NSObject, MEVideoDecoderExtension {

    private var infoSignal: DispatchSourceSignal?
    private var decoders = NSHashTable<VideoDecoder>.weakObjects()  // for dumpState()

    required override init() {
        super.init()
        // Send FFmpeg logs to system log
        #if DEBUG
            logger.debug("VideoDecoderFactory init")
            av_log_set_level(AV_LOG_DEBUG | AV_LOG_SKIP_REPEATED)
        #else
            av_log_set_level(AV_LOG_WARNING | AV_LOG_SKIP_REPEATED)
        #endif
        setup_av_log_callback()

        // Dump state to log on receipt of SIGINFO
        // See https://blog.smittytone.net/2021/07/19/tackle-async-signal-safety-in-swift/
        signal(SIGINFO, SIG_IGN)  // should be default behaviour, but lets be sure
        infoSignal = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .global(qos: .background))
        infoSignal?.setEventHandler { [self] in
            _ = infoSignal?.data  // Indicate that we're handling the signal. Is this necessary?
            dumpState()
        }
        infoSignal?.resume()
    }

    func makeVideoDecoder(
        codecType: CMVideoCodecType,
        videoFormatDescription: CMVideoFormatDescription,
        videoDecoderSpecifications: [String: Any],
        pixelBufferManager extensionDecoderPixelBufferManager: MEVideoDecoderPixelBufferManager
    ) throws -> any MEVideoDecoder {
        #if DEBUG
            logger.debug(
                "VideoDecoderFactory makeVideoDecoder format:\(String(describing: videoFormatDescription), privacy:.public) specifications:\(videoDecoderSpecifications, privacy:.public)"
            )
        #endif  // DEBUG
        let decoder = try VideoDecoder(
            codecType: codecType,
            videoFormatDescription: videoFormatDescription,
            videoDecoderSpecifications: videoDecoderSpecifications,
            pixelBufferManager: extensionDecoderPixelBufferManager
        )
        decoders.add(decoder)
        return decoder
    }

    func dumpState() {
        logger.info("VideoDecoder state:")
        for decoder in decoders.allObjects {
            logger.info(
                """
                VideoDecoder for \(decoder.formatDescription.extensions[kCMFormatDescriptionExtension_FormatName] as? String ?? MTCopyLocalizedNameForMediaSubType(decoder.formatDescription.mediaType.rawValue, decoder.formatDescription.mediaSubType.rawValue) as? String ?? String(describing: decoder.formatDescription.mediaSubType), privacy: .public) \
                \(decoder.formatDescription.dimensions.width)x\(decoder.formatDescription.dimensions.height)
                """
            )
            logger.info("  Next index:\(decoder.nextIndex ?? -1)")
            logger.info("  InFlight count:\(decoder.inFlight.count) first:\(decoder.inFlight.keys.min() ?? -1)")
        }
    }
}
