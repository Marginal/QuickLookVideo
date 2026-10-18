//
//  videodecoder.swift
//  QLVideo
//
//  Created by Jonathan Harris on 21/01/2026.
//

import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

#if DEBUG
    let TRACE_VIDEODECODER: Bool = true
#else
    let TRACE_VIDEODECODER: Bool = false
#endif

// Swift Error wrapper for CoreVideo CVReturn codes
struct CVReturnError: LocalizedError, CustomNSError {
    let errorCode: Int
    let context: String?

    static var errorDomain: String { "CoreVideoErrorDomain" }
    var errorDescription: String? { "\(context ?? "") failed with CVReturn \(errorCode)" }
}

class VideoDecoder: NSObject, MEVideoDecoder {

    // Supported fourCCs that might be sent to us by the CoreMedia demuxer i.e. seen in .asf, .avi or .mov files
    static let supported: [CMVideoCodecType: AVCodecID] = [
        kCMVideoCodecType_Animation: AV_CODEC_ID_QTRLE,  // 'rle '
        0x7270_7a61: AV_CODEC_ID_RPZA,  // 'rpza'
        0x6963_6f64: AV_CODEC_ID_AIC,  // 'icod'
        kCMVideoCodecType_Cinepak: AV_CODEC_ID_CINEPAK,  // 'cvid'
        0x4861_7031: AV_CODEC_ID_HAP,  // 'Hap1'
        0x4861_7035: AV_CODEC_ID_HAP,  // 'Hap5'
        0x4861_7059: AV_CODEC_ID_HAP,  // 'HapY'
        0x4861_704D: AV_CODEC_ID_HAP,  // 'HapM'
        0x4861_7041: AV_CODEC_ID_HAP,  // 'HapA'
        0x4458_4449: AV_CODEC_ID_DXV,  // 'DXDI'
        0x4458_4433: AV_CODEC_ID_DXV,  // 'DXD3'
        0x666C_6963: AV_CODEC_ID_FLIC,  // 'flic'
        0x4146_4C43: AV_CODEC_ID_FLIC,  // 'AFLC'
        0x6e63_6c63: AV_CODEC_ID_NOTCHLC,  // 'nclc'
        0x5254_3231: AV_CODEC_ID_INDEO2,  // 'RT21'
        0x4956_3331: AV_CODEC_ID_INDEO3,  // 'IV31'
        0x4956_3332: AV_CODEC_ID_INDEO3,  // 'IV32'
        0x4956_3431: AV_CODEC_ID_INDEO4,  // 'IV41'
        0x4956_3530: AV_CODEC_ID_INDEO5,  // 'IV50'
        kCMVideoCodecType_SorensonVideo: AV_CODEC_ID_SVQ1,  // 'SVQ1'
        kCMVideoCodecType_SorensonVideo3: AV_CODEC_ID_SVQ3,  // 'SVQ3'
        0x464d_5034: AV_CODEC_ID_MPEG4,  // 'FMP4'
        0x4449_5658: AV_CODEC_ID_MPEG4,  // 'DIVX'
        0x5856_4944: AV_CODEC_ID_MPEG4,  // 'XVID'
        0x4458_3530: AV_CODEC_ID_MPEG4,  // 'DX50'
        0x4d50_3431: AV_CODEC_ID_MSMPEG4V1,  // 'MP41'
        0x4d50_4734: AV_CODEC_ID_MSMPEG4V1,  // 'MPG4'
        0x4d50_3432: AV_CODEC_ID_MSMPEG4V2,  // 'MP42'
        0x4449_5632: AV_CODEC_ID_MSMPEG4V2,  // 'DIV2'
        0x4d50_3433: AV_CODEC_ID_MSMPEG4V3,  // 'MP43'
        0x4449_5633: AV_CODEC_ID_MSMPEG4V3,  // 'DIV3'
        0x4449_5634: AV_CODEC_ID_MSMPEG4V3,  // 'DIV4'
        0x4449_5635: AV_CODEC_ID_MSMPEG4V3,  // 'DIV5'
        0x4449_5636: AV_CODEC_ID_MSMPEG4V3,  // 'DIV6'
    ]

    let codecType: CMVideoCodecType
    let formatDescription: CMVideoFormatDescription
    let specifications: [String: Any]
    let manager: MEVideoDecoderPixelBufferManager

    // properties
    var isReadyForMoreMediaData: Bool = true
    var actualThreadCount: Int { return Int(dec_ctx?.pointee.thread_count ?? 0) }

    var params = avcodec_parameters_alloc()!
    var dec_ctx: UnsafeMutablePointer<AVCodecContext>?

    // Cached pixel buffer config - rebuilt only when frame dimensions, color properties or HDR metadata change
    var pixelBufferKey: PixelBufferCacheKey? = nil
    var pixelBufferConfig: PixelBufferConfig? = nil

    // For format conversion using macOS Accelerate API
    var conversionInfo: vImage_YpCbCrToARGB? = nil
    var scaleYBuffer: vImage_Buffer? = nil
    var scaleCbBuffer: vImage_Buffer? = nil
    var scaleCrBuffer: vImage_Buffer? = nil
    var scaleYTemp: UnsafeMutableRawPointer? = nil
    var scaleCbTemp: UnsafeMutableRawPointer? = nil
    var scaleCrTemp: UnsafeMutableRawPointer? = nil

    // For RGB conversion using FFmpeg's swscale
    var sws_ctx: UnsafeMutablePointer<SwsContext>? = nil
    var qtPalette: Data? = nil  // 1024-byte AV_PKT_DATA_PALETTE for PAL8 codecs when available

    // For format conversion using FFmpeg's zscale filter
    var filterGraph: UnsafeMutablePointer<AVFilterGraph>? = nil
    var src_ctx: UnsafeMutablePointer<AVFilterContext>? = nil
    var sink_ctx: UnsafeMutablePointer<AVFilterContext>? = nil

    init(
        codecType: CMVideoCodecType,
        videoFormatDescription: CMVideoFormatDescription,
        videoDecoderSpecifications: [String: Any],
        pixelBufferManager: MEVideoDecoderPixelBufferManager
    ) throws {
        self.codecType = codecType
        self.formatDescription = videoFormatDescription
        self.specifications = videoDecoderSpecifications
        self.manager = pixelBufferManager

        super.init()

        // Recreate stream's AVCodecParameters from CMVideoFormatDescription extension

        if let imported = formatDescription.extensions["QLVideo" as CFString] as? [CFString: Any],
            let importedParams = imported["AVCodecParameters" as CFString] as? Data,
            importedParams.count == MemoryLayout<AVCodecParameters>.size
        {
            withUnsafeMutableBytes(of: &params.pointee) { $0.copyBytes(from: importedParams) }

            if let importedExtraData = imported["ExtraData" as CFString] as? Data {
                // must pad https://ffmpeg.org/doxygen/8.0/structAVCodecParameters.html#a9befe0b86412646017afb0051d144d13
                let extraData = av_mallocz(Int(params.pointee.extradata_size + AV_INPUT_BUFFER_PADDING_SIZE))!
                params.pointee.extradata = extraData.assumingMemoryBound(to: UInt8.self)
                let dst = params.pointee.extradata  // avoid capturing self in closure
                importedExtraData.withUnsafeBytes { src in
                    let base = src.baseAddress!
                    memcpy(dst, base, importedExtraData.count)
                }
            }

            var nb_sd: Int32 = 0
            while nb_sd < Int(params.pointee.nb_coded_side_data) {
                let importedSideData = imported["SideData\(nb_sd)" as CFString] as! Data
                let importedSideDataType = imported["SideData\(nb_sd)Type" as CFString] as! CFNumber
                let sideData = av_malloc(importedSideData.count)!
                importedSideData.withUnsafeBytes { src in
                    let base = src.baseAddress!
                    memcpy(sideData, base, importedSideData.count)
                }
                if nb_sd == 0 {
                    params.pointee.coded_side_data = av_mallocz(
                        Int(params.pointee.nb_coded_side_data) * MemoryLayout<AVPacketSideData>.stride
                    )!
                    .assumingMemoryBound(to: AVPacketSideData.self)
                }
                av_packet_side_data_add(
                    &params.pointee.coded_side_data,
                    &nb_sd,  // will be incremented
                    AVPacketSideDataType((importedSideDataType) as! UInt32),
                    sideData,
                    importedSideData.count,
                    0
                )
            }
        } else if let codecID = VideoDecoder.supported[codecType] {
            // Didn't come from our formatreader, e.g. from .avi or .mov. Try to decode anyway.
            let depth = videoFormatDescription.extensions[kCMFormatDescriptionExtension_Depth as CFString] as? NSNumber
            switch codecID {

            // RGB
            case AV_CODEC_ID_QTRLE, AV_CODEC_ID_RPZA, AV_CODEC_ID_CINEPAK, AV_CODEC_ID_HAP, AV_CODEC_ID_DXV, AV_CODEC_ID_FLIC:
                // Pixel format is set from codec_tag and/or bits_per_coded_sample in codec _init() under avcodec_open2()
                params.pointee.color_range = AVCOL_RANGE_JPEG
                params.pointee.color_space = AVCOL_SPC_RGB

            // YUV
            case AV_CODEC_ID_AIC, AV_CODEC_ID_INDEO2, AV_CODEC_ID_INDEO3, AV_CODEC_ID_INDEO4, AV_CODEC_ID_INDEO5,
                AV_CODEC_ID_NOTCHLC:
                // Pixel format is set in codec _init() under avcodec_open2()
                params.pointee.color_range = AVCOL_RANGE_MPEG  // will be overridden by some codecs e.g. notch
            case AV_CODEC_ID_SVQ1, AV_CODEC_ID_SVQ3:
                params.pointee.color_range = AVCOL_RANGE_MPEG  // For SVQ1. For SVQ3 svq3_decode_init() will override
                // see FFmpeg svq3_decode_extradata()
                if let sampleDesc = formatDescription.extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
                    as? [CFString: Data],
                    let SMI = sampleDesc["SMI " as CFString]
                {
                    // must pad https://ffmpeg.org/doxygen/8.0/structAVCodecParameters.html#a9befe0b86412646017afb0051d144d13
                    params.pointee.extradata_size = Int32(SMI.count + 8)
                    let extraData = av_mallocz(Int(params.pointee.extradata_size + AV_INPUT_BUFFER_PADDING_SIZE))!
                    params.pointee.extradata = extraData.assumingMemoryBound(to: UInt8.self)
                    let bytes: [UInt8] =
                        [
                            0, 0, UInt8(params.pointee.extradata_size >> 8), UInt8(params.pointee.extradata_size & 0xff),  // size
                            0x53, 0x4d, 0x49, 0x20,  // 'SMI '
                        ] + [UInt8](SMI)
                    memcpy(params.pointee.extradata, bytes, bytes.count)
                }
            case AV_CODEC_ID_MPEG4, AV_CODEC_ID_MSMPEG4V1, AV_CODEC_ID_MSMPEG4V2, AV_CODEC_ID_MSMPEG4V3:
                // DivX or other MPEG4 variant other than 'mp4v'. May or may not have an esds atom.
                params.pointee.format = AV_PIX_FMT_YUV420P.rawValue  // may be overridden
                params.pointee.color_range = AVCOL_RANGE_MPEG
                if let sampleDesc = formatDescription.extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
                    as? [CFString: Data],
                    let esds = sampleDesc["esds" as CFString]
                {
                    func decodeLength(_ bytes: Data, _ offset: inout Int) -> Int? {
                        var len = 0
                        var count = 4
                        while count > 0 && offset < bytes.count {
                            count -= 1
                            let c = Int(bytes[offset])
                            offset += 1
                            len = (len << 7) | (c & 0x7f)
                            if c & 0x80 == 0 { break }
                        }
                        return len
                    }

                    // extradata should contain just the contents of the DecSpecificInfoTag (0x5) - see FFmpeg ff_mp4_read_dec_config_descr()
                    var offset = esds.count >= 4 ? 4 : 0  // Skip version (1 byte) + flags (3 bytes) if present
                    var decoderSpecific: Data? = nil
                    while offset < esds.count {
                        let tag = esds[offset]
                        offset += 1
                        guard let length = decodeLength(esds, &offset) else { break }
                        if tag == 0x05 {  // DecoderSpecificInfoTag
                            decoderSpecific = esds.subdata(in: offset..<min(offset + length, esds.count))
                            break
                        }
                        offset += length
                    }
                    if let dsi = decoderSpecific, dsi.isEmpty == false {
                        params.pointee.extradata_size = Int32(dsi.count)
                        let extraData = av_mallocz(Int(params.pointee.extradata_size + AV_INPUT_BUFFER_PADDING_SIZE))!
                        params.pointee.extradata = extraData.assumingMemoryBound(to: UInt8.self)
                        dsi.withUnsafeBytes { src in
                            _ = memcpy(params.pointee.extradata, src.baseAddress!, dsi.count)
                        }
                    }
                }

            default:
                // Shouldn't get here
                logger.error(
                    "VideoDecoder: No AVCodecParameters in \(String(describing: self.formatDescription), privacy: .public))"
                )
                throw MEError(.unsupportedFeature)
            }
            params.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            params.pointee.codec_id = codecID
            params.pointee.codec_tag = codecType.byteSwapped  // Supplied codecType is big endian
            params.pointee.width = videoFormatDescription.dimensions.width
            params.pointee.height = videoFormatDescription.dimensions.height
            params.pointee.bits_per_coded_sample = depth?.int32Value ?? 0
            logger.warning(
                "VideoDecoder: No AVCodecParameters in \(String(describing: self.formatDescription), privacy: .public))"
            )
        } else {
            logger.error("VideoDecoder: No AVCodecParameters in \(String(describing: self.formatDescription), privacy: .public))")
            throw MEError(.unsupportedFeature)
        }

        // Set up decode context

        guard let codec = avcodec_find_decoder(params.pointee.codec_id) else {
            logger.error(
                "VideoDecoder: No decoder for codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public)"
            )
            throw MEError(.unsupportedFeature)
        }

        dec_ctx = avcodec_alloc_context3(codec)
        if dec_ctx == nil {
            logger.error(
                "VideoDecoder: Can't create decoder context for codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public)"
            )
            throw MEError(.unsupportedFeature)
        }

        // Enable slice threading only. FF_THREAD_FRAME may be more efficient but causes initial frame to be delayed so black thumbnails, black info window, etc.
        if params.pointee.codec_id != AV_CODEC_ID_AV1 {  // dav1d effectively only supports frame slicing, and with a delay
            dec_ctx!.pointee.thread_type = FF_THREAD_SLICE
            var len = MemoryLayout.size(ofValue: dec_ctx!.pointee.thread_count)
            // Get number of *performance* cores /usr/include/sys/sysctl.h
            if sysctlbyname("hw.perflevel0.logicalcpu", &dec_ctx!.pointee.thread_count, &len, nil, 0) != 0 {
                dec_ctx!.pointee.thread_count = 0  // auto
            }
        }

        var ret = avcodec_parameters_to_context(dec_ctx, params)
        if ret < 0 {
            let error = AVERROR(errorCode: ret)
            logger.error(
                "VideDecoder: Can't set decoder parameters for codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public): \(error.localizedDescription)"
            )
            throw MEError(.unsupportedFeature)
        }
        ret = avcodec_open2(dec_ctx, codec, nil)
        if ret < 0 {
            let error = AVERROR(errorCode: ret)
            logger.error(
                "VideoDecoder: Can't open codec \(String(cString:avcodec_get_name(self.params.pointee.codec_id)), privacy: .public): \(error.localizedDescription)"
            )
            throw MEError(.unsupportedFeature)
        }

        // Reconstruct QuickTime palette from VerbatimSampleDescription when available (but not for FLIC where the palette is in-stream).
        if dec_ctx!.pointee.pix_fmt == AV_PIX_FMT_PAL8 && params.pointee.codec_id != AV_CODEC_ID_FLIC {
            qtPalette = VideoDecoder.makeQuickTimePalette(formatDescription: formatDescription)
            guard qtPalette != nil else {
                // We don't have the palette so pointless to decode
                logger.error(
                    "VideoDecoder: Unsupported depth: \(self.params.pointee.bits_per_coded_sample) in \(String(describing: self.formatDescription), privacy: .public))"
                )
                throw MEError(.unsupportedFeature)
            }
        }

        let pix_fmt_name = av_get_pix_fmt_name(dec_ctx!.pointee.pix_fmt)
        let color_space_name = av_color_space_name(dec_ctx!.pointee.colorspace)
        logger.log(
            "VideoDecoder: Decoding \(self.dec_ctx!.pointee.width)x\(self.dec_ctx!.pointee.height), \(pix_fmt_name != nil ? String(cString: pix_fmt_name!) : "unknown", privacy: .public) \(color_space_name != nil ? String(cString: color_space_name!) : "unknown", privacy: .public), B frames:\(self.dec_ctx!.pointee.has_b_frames) Delay:\(self.dec_ctx!.pointee.delay), with \(self.dec_ctx!.pointee.active_thread_type == FF_THREAD_FRAME ? "frame" : (self.dec_ctx!.pointee.active_thread_type == FF_THREAD_SLICE ? "slice" : "no"), privacy: .public) threading \(self.dec_ctx!.pointee.thread_count) threads"
        )
    }

    deinit {
        if dec_ctx != nil { avcodec_free_context(&dec_ctx) }
        if sws_ctx != nil { sws_freeContext(sws_ctx) }
        if sink_ctx != nil { avfilter_free(sink_ctx) }
        if src_ctx != nil { avfilter_free(src_ctx) }
        if filterGraph != nil { avfilter_graph_free(&filterGraph) }
        vImageFreeScaleBuffers()
    }

    // Primary business of this codec

    func decodeFrame(
        from sampleBuffer: CMSampleBuffer,
        options: MEDecodeFrameOptions,
        completionHandler: @escaping @Sendable (CVImageBuffer?, MEDecodeFrameStatus, (any Error)?) -> Void
    ) {

        // Get access to the sample buffer's data and attachments

        guard let blockBuffer = sampleBuffer.dataBuffer, blockBuffer.isEmpty == false, blockBuffer.isContiguous else {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Supplied sample data is not contiguous"
            )
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }
        var totalLength: Int = 0
        var data: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &data
        )
        guard status == kCMBlockBufferNoErr else {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Failed to get sample data:  \(status)"
            )
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)! as NSArray
        let attachment = attachments.firstObject as! NSDictionary

        // Populate an AVPacket with the sample buffer's data

        var pkt = av_packet_alloc()
        pkt!.pointee.data = UnsafeMutableRawPointer(data!).assumingMemoryBound(to: UInt8.self)
        pkt!.pointee.size = Int32(totalLength)
        pkt!.pointee.time_base = AVRational(
            num: 1,
            den: sampleBuffer.presentationTimeStamp.isNumeric
                ? Int32(sampleBuffer.presentationTimeStamp.timescale) : Int32(sampleBuffer.decodeTimeStamp.timescale)
        )
        pkt!.pointee.dts = sampleBuffer.decodeTimeStamp.isNumeric ? sampleBuffer.decodeTimeStamp.value : AV_NOPTS_VALUE
        pkt!.pointee.pts =
            sampleBuffer.presentationTimeStamp.isNumeric ? sampleBuffer.presentationTimeStamp.value : AV_NOPTS_VALUE
        let notSync = (attachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        pkt!.pointee.flags = (!notSync ? AV_PKT_FLAG_KEY : 0) | (options.doNotOutputFrame ? AV_PKT_FLAG_DISCARD : 0)
        var nb_sd: Int32 = 0
        while true {
            guard let importedSideData = attachment["SideData\(nb_sd)" as CFString] as? Data else { break }
            let importedSideDataType = attachment["SideData\(nb_sd)Type" as CFString] as! CFNumber
            let sideData = av_malloc(importedSideData.count)!
            importedSideData.withUnsafeBytes { src in
                let base = src.baseAddress!
                memcpy(sideData, base, importedSideData.count)
            }
            guard
                av_packet_side_data_add(
                    &pkt!.pointee.side_data,
                    &nb_sd,  // will be incremented
                    AVPacketSideDataType((importedSideDataType) as! UInt32),
                    sideData,
                    importedSideData.count,
                    0
                ) != nil
            else { break }
        }
        pkt!.pointee.side_data_elems = nb_sd

        // If demuxing via CoreMedia omitted palette side data, inject one reconstructed from stsd/ctab.
        if let palette = qtPalette, av_packet_get_side_data(pkt, AV_PKT_DATA_PALETTE, nil) == nil,
            let sideData = av_packet_new_side_data(pkt, AV_PKT_DATA_PALETTE, palette.count)
        {
            palette.copyBytes(to: UnsafeMutableRawBufferPointer(start: sideData, count: palette.count))
        }

        // Try to detect a discontinuous seek and flush the decoder if we see one
        let isSeek =
            (CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding, attachmentModeOut: nil)
                as? Bool) ?? false
        if isSeek {
            avcodec_flush_buffers(dec_ctx)
        }

        // Decode
        var ret = avcodec_send_packet(dec_ctx, pkt)
        if ret < 0 {
            let error = AVERROR(errorCode: ret, context: "avcodec_send_packet")
            logger.error(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public): \(error.errorDescription, privacy: .public)"
            )
            av_packet_free(&pkt)
            return completionHandler(nil, .frameDropped, MEError(.parsingFailure))
        }
        if TRACE_VIDEODECODER {
            logger.debug(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) flags:\(pkt!.pointee.flags & AV_PKT_FLAG_KEY != 0 ? "K" : "_", privacy: .public)\(pkt!.pointee.flags & AV_PKT_FLAG_DISCARD != 0 ? "D" : "_", privacy: .public)_ \(isSeek ? "Seek" : "", privacy: .public)"
            )
        }
        av_packet_free(&pkt)  // Free regardless of result since we don't need this any more - actual data lives in CMBlockBuffer

        var frame = av_frame_alloc()
        ret = avcodec_receive_frame(dec_ctx, frame)
        if ret == AVERROR_EAGAIN {
            // Discarded packets won't produce anything from avcodec_receive_frame (but it appears we still have to call it). Complete now.
            av_frame_free(&frame)
            if options.doNotOutputFrame {
                if TRACE_VIDEODECODER {
                    logger.debug(
                        "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) discarded"
                    )
                }
                return completionHandler(nil, .frameDropped, nil)
            } else if isSeek {
                // AVFoundation won't send any more input until the first sampleBuffer after a seek produces output. So we have to return something.
                do {
                    if TRACE_VIDEODECODER {
                        logger.debug(
                            "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) dummy"
                        )
                    }
                    if pixelBufferKey == nil {
                        // We've never seen an output frame.
                        pixelBufferKey = PixelBufferCacheKey(dec_ctx: dec_ctx!)  // best effort, may be updated later on a real frame
                        pixelBufferConfig = makePixelBufferConfig()
                        manager.pixelBufferAttributes = pixelBufferConfig!.pixelBufferAttributes
                    }
                    let pixelBuffer = try manager.makePixelBuffer()
                    fillPixelBufferWithBlack(pixelBuffer)  // otherwise green which is very noticeable
                    return completionHandler(pixelBuffer, .frameDropped, nil)
                } catch {
                    return completionHandler(nil, .frameDropped, error)
                }
            }
        }
        guard ret >= 0 else {
            let error = AVERROR(errorCode: ret, context: "avcodec_receive_frame")
            logger.error(
                "VideoDecoder decodeFrame at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public): \(error.errorDescription, privacy: .public)"
            )
            av_frame_free(&frame)
            return completionHandler(nil, .frameDropped, MEError(.internalFailure))
        }

        // Fix up color info on the decoded frame
        VideoDecoder.fixupColors(frame: frame!)

        var pixelBuffer: CVPixelBuffer
        do {
            // Only update manager.pixelBufferAttributes if frame properties have changed since the last frame
            let newKey = PixelBufferCacheKey(frame: frame!)
            if newKey != pixelBufferKey {
                pixelBufferKey = newKey
                pixelBufferConfig = makePixelBufferConfig()
                manager.pixelBufferAttributes = pixelBufferConfig!.pixelBufferAttributes
            }
            pixelBuffer = try manager.makePixelBuffer()
        } catch {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: Failed to obtain a pixel buffer: \(error.localizedDescription, privacy: .public)"
            )
            return completionHandler(nil, .frameDropped, error)
        }

        // HDR passthrough: shift and interleave into biplanar pixel buffer
        if pixelBufferConfig!.isHDR {
            if let error = hdrConvertToBiPlanar(frame: frame!, pixelBuffer: pixelBuffer) {
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: HDR conversion failed: \(error.localizedDescription, privacy: .public)"
                )
                av_frame_free(&frame)
                return completionHandler(nil, .frameDropped, error)
            }
            av_frame_free(&frame)
            return completionHandler(pixelBuffer, [], nil)
        }

        // can we use macOS's accelerated conversions?
        if let error = vImageConvertToBGRA(frame: &frame!.pointee, pixelBuffer: &pixelBuffer) {
            if error.errorCode != kvImageUnsupportedConversion {
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: vImage conversion failed: \(error.localizedDescription, privacy: .public)"
                )
                av_frame_free(&frame)
                return completionHandler(nil, .frameDropped, error)
            }
        } else {
            av_frame_free(&frame)
            return completionHandler(pixelBuffer, [], nil)
        }

        if let error = RGBConvertToBGRA(frame: &frame!.pointee, pixelBuffer: &pixelBuffer) {
            if error.errorCode != kCVReturnUnsupported {
                logger.error(
                    "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: RGB conversion failed: \(error.localizedDescription, privacy: .public)"
                )
                av_frame_free(&frame)
                return completionHandler(nil, .frameDropped, error)
            }
        } else {
            av_frame_free(&frame)
            return completionHandler(pixelBuffer, [], nil)
        }

        // Fall back to zscale conversion. Should work for pretty-much any source format.
        var error = zscaleConvertToGBRP(frame: &frame, pixelBuffer: &pixelBuffer)
        if error == nil {
            error = vImageCopyToBGRA(frame: &frame!.pointee, pixelBuffer: &pixelBuffer)
        }
        guard error == nil else {
            logger.error(
                "VideoDecoder at dts:\(sampleBuffer.decodeTimeStamp, privacy: .public) pts:\(sampleBuffer.presentationTimeStamp, privacy: .public) dur:\(sampleBuffer.duration, privacy: .public) decodeFrame: zScale conversion failed: \(error!.localizedDescription, privacy: .public)"
            )
            av_frame_free(&frame)
            return completionHandler(nil, .frameDropped, error)
        }
        av_frame_free(&frame)
        return completionHandler(pixelBuffer, [], nil)
    }

    // Infer color info from the decoded frame. Make educated guesses for unspecified values.
    // Mutates the frame's color_primaries, color_trc and colorspace fields in place.
    class func fixupColors(frame: UnsafeMutablePointer<AVFrame>) {

        // RGB space. Set color info in case we somehow end up on the zscale path.
        if frame.pointee.colorspace == AVCOL_SPC_RGB {
            frame.pointee.color_range = AVCOL_RANGE_JPEG
            frame.pointee.color_primaries = AVCOL_PRI_BT709
            frame.pointee.color_trc = AVCOL_TRC_IEC61966_2_1
            return
        }

        // Let presence of SMPTE 2086:2014 side data override anything else in the AVFrame
        if av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) != nil
            || av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) != nil
            || av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA) != nil
        {
            frame.pointee.color_primaries = AVCOL_PRI_BT2020
            frame.pointee.color_trc = AVCOL_TRC_SMPTE2084
            frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL
            return
        }

        // If all fields are specified then assume they're correct
        if frame.pointee.color_primaries != AVCOL_PRI_UNSPECIFIED
            && frame.pointee.color_trc != AVCOL_TRC_UNSPECIFIED
            && frame.pointee.colorspace != AVCOL_SPC_UNSPECIFIED
        {
            return
        }

        // Explicit PQ or HLG
        if frame.pointee.color_trc == AVCOL_TRC_SMPTE2084 || frame.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 {
            if frame.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED { frame.pointee.color_primaries = AVCOL_PRI_BT2020 }
            if frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED { frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL }
            return
        }

        // >8‑bit *with BT.2020 primaries* is probably HDR10.
        let pixDesc = av_pix_fmt_desc_get(AVPixelFormat(frame.pointee.format)).pointee
        let bitDepth = pixDesc.comp.0.depth  // not always accurate but works for supported formats
        if bitDepth > 8 && frame.pointee.color_primaries == AVCOL_PRI_BT2020 {
            frame.pointee.color_primaries = AVCOL_PRI_BT2020
            frame.pointee.color_trc = AVCOL_TRC_SMPTE2084
            frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL
            return
        }

        // SDR. Assume values based on input format and whether HD or SD
        // Follow mpv heursitics https://wiki.x266.mov/docs/colorimetry/primaries
        if frame.pointee.width >= 1280 || frame.pointee.height > 576 || frame.pointee.format != AV_PIX_FMT_YUV420P.rawValue {
            if frame.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED { frame.pointee.color_primaries = AVCOL_PRI_BT709 }
            if frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED { frame.pointee.colorspace = AVCOL_SPC_BT709 }
        } else {
            if frame.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED { frame.pointee.color_primaries = AVCOL_PRI_SMPTE170M }
            if frame.pointee.colorspace == AVCOL_SPC_UNSPECIFIED { frame.pointee.colorspace = AVCOL_SPC_SMPTE170M }
        }
        if frame.pointee.color_trc == AVCOL_TRC_UNSPECIFIED {
            frame.pointee.color_trc = frame.pointee.color_range == AVCOL_RANGE_JPEG ? AVCOL_TRC_IEC61966_2_1 : AVCOL_TRC_BT709
        }
    }

    // Cached pixel buffer configuration. Covers both HDR biplanar and SDR BGRA paths.
    // Includes the fully-built pixelBufferAttributes dictionary for MEVideoDecoderPixelBufferManager.
    struct PixelBufferConfig {
        let pixelBufferAttributes: [String: Any]
        // HDR conversion parameters. nil for SDR frames.
        let bitDepth: UInt32
        let uvShiftX: UInt32  // 0=n/a,444, 1=422,420
        let uvShiftY: UInt32  // 0=n/a,444,422, 1=420
        var isHDR: Bool { bitDepth > 8 }
    }

    // Lightweight key capturing the frame and display properties that affect PixelBufferConfig / CVPixelBuffer attributes.
    // The frame's color fields must already be fixed up by fixupColors() before calling this.
    // Compared each frame to decide whether to rebuild the config or reuse the cached one.
    // In practice this almost always matches because resolution and color properties are
    // uniform within a stream, and FFmpeg propagates the same static MDM/CLL metadata onto every frame.
    struct PixelBufferCacheKey: Equatable {
        let width: Int32
        let height: Int32
        let format: Int32
        let colorTrc: AVColorTransferCharacteristic
        let colorPrimaries: AVColorPrimaries
        let colorspace: AVColorSpace
        let colorRange: AVColorRange
        let chromaLocation: AVChromaLocation
        let mdmBytes: Data?  // 88 bytes raw AVMasteringDisplayMetadata, or nil
        let cllBytes: Data?  // 8 bytes raw AVContentLightMetadata, or nil
        let aveBytes: Data?  // 24 bytes raw AVAmbientViewingEnvironment, or nil

        init(frame: UnsafePointer<AVFrame>) {
            self.width = frame.pointee.width
            self.height = frame.pointee.height
            self.format = frame.pointee.format
            self.colorTrc = frame.pointee.color_trc
            self.colorPrimaries = frame.pointee.color_primaries
            self.colorspace = frame.pointee.colorspace
            self.colorRange = frame.pointee.color_range
            self.chromaLocation = frame.pointee.chroma_location
            if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) {
                self.mdmBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.mdmBytes = nil
            }
            if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) {
                self.cllBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.cllBytes = nil
            }
            if let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT) {
                self.aveBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.aveBytes = nil
            }
        }

        // Fallback version from the AVCodecContext for when we need a pixel buffer but we have not yet seen a valid frame
        init(dec_ctx: UnsafePointer<AVCodecContext>) {
            self.width = dec_ctx.pointee.width
            self.height = dec_ctx.pointee.height
            self.format = dec_ctx.pointee.pix_fmt.rawValue
            self.colorTrc = dec_ctx.pointee.color_trc
            self.colorPrimaries = dec_ctx.pointee.color_primaries
            self.colorspace = dec_ctx.pointee.colorspace
            self.colorRange = dec_ctx.pointee.color_range
            self.chromaLocation = dec_ctx.pointee.chroma_sample_location
            if let sd = av_packet_side_data_get(
                dec_ctx.pointee.coded_side_data,
                dec_ctx.pointee.nb_coded_side_data,
                AV_PKT_DATA_MASTERING_DISPLAY_METADATA
            ) {
                self.mdmBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.mdmBytes = nil
            }
            if let sd = av_packet_side_data_get(
                dec_ctx.pointee.coded_side_data,
                dec_ctx.pointee.nb_coded_side_data,
                AV_PKT_DATA_CONTENT_LIGHT_LEVEL
            ) {
                self.cllBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.cllBytes = nil
            }
            if let sd = av_packet_side_data_get(
                dec_ctx.pointee.coded_side_data,
                dec_ctx.pointee.nb_coded_side_data,
                AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT
            ) {
                self.aveBytes = Data(bytes: sd.pointee.data, count: Int(sd.pointee.size))
            } else {
                self.aveBytes = nil
            }
        }

    }

    // Build PixelBufferConfig from the PixelBufferCacheKey.
    // Handles both HDR biplanar and SDR BGRA paths.
    // The returned config includes the fully-built pixelBufferAttributes dictionary
    // suitable for assigning directly to MEVideoDecoderPixelBufferManager.
    func makePixelBufferConfig() -> PixelBufferConfig {
        let pixelBufferKey = pixelBufferKey!
        var width = Int(pixelBufferKey.width)
        let height = Int(pixelBufferKey.height)

        let config =
            hdrPixelBufferConfig()
            ?? {
                // SDR path: adjust destination width for anamorphic so vImage/zscale will scale into the CVPixelBuffer.
                if let sar = formatDescription.extensions[kCMFormatDescriptionExtension_PixelAspectRatio]
                    as? [CFString: NSNumber],
                    let num = sar[kCVImageBufferPixelAspectRatioHorizontalSpacingKey],
                    let den = sar[kCVImageBufferPixelAspectRatioVerticalSpacingKey]
                {
                    width = Int(av_rescale_rnd(Int64(width), num.int64Value, den.int64Value, AV_ROUND_NEAR_INF))
                }
                return PixelBufferConfig(
                    pixelBufferAttributes: [
                        kCVPixelBufferWidthKey as String: width as CFNumber,
                        kCVPixelBufferHeightKey as String: height as CFNumber,
                        kCVPixelBufferBytesPerRowAlignmentKey as String: 64 as CFNumber,
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                        kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as CFBoolean,
                        kCVBufferPropagatedAttachmentsKey as String: [
                            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_sRGB,
                            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        ],
                    ],
                    bitDepth: 8,
                    uvShiftX: 0,
                    uvShiftY: 0
                )
            }()
        return config
    }

    // MARK: - Pixel buffer fill helper

    private func fillPixelBufferWithBlack(_ pixelBuffer: CVPixelBuffer) {
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            var buf = vImage_Buffer(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
                width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
                rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
            )
            vImageBufferFill_ARGB8888(&buf, [0, 0, 0, 0xff], vImage_Flags(kvImageNoFlags))
            return
        }

        let yBlack10: UInt16 = pixelBufferKey!.colorRange == AVCOL_RANGE_MPEG ? UInt16(64 << 6) : 0  // left-justified 10-bit in 16 bits
        let uvNeutral10: UInt16 = UInt16(512 << 6)

        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)  // number of Cb samples per row
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let dst = yBase.assumingMemoryBound(to: UInt16.self)
            y_fill_u16(dst, Int32(yWidth), Int32(yHeight), Int32(yRowBytes / 2), yBlack10)
        }

        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let dst = uvBase.assumingMemoryBound(to: UInt16.self)
            uv_fill_interleaved_u16(dst, Int32(uvWidth), Int32(uvHeight), Int32(uvRowBytes / 2), uvNeutral10, uvNeutral10)
        }
    }
}
