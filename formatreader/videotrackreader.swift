//
//  videotrackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 18/11/2025.
//

import Foundation
import MediaExtension
import OSLog

#if DEBUG
    let SOFTWARE_DECODE = false
#else
    let SOFTWARE_DECODE = false
#endif

class VideoTrackReader: TrackReader, METrackReader {

    // See https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/matroska.c for the codec_ids that FFmpeg expects in a Matroska container
    static let supported: [AVCodecID: CMVideoCodecType] = [
        // Made up FourCCs that match those registered by our videodecoder in order to bypass CoreVideo
        AV_CODEC_ID_MPEG1VIDEO: 0x4d50_3156,  // 'MP1V' FFmpeg is more tolerant of poor encoding than CoreVideo
        AV_CODEC_ID_MPEG2VIDEO: 0x4d50_3256,  // 'MP2V' FFmpeg is more tolerant of poor encoding than CoreVideo
        AV_CODEC_ID_MPEG4: 0x4d50_3456,  // 'MP4V' FFmpeg is more tolerant of DivX and MS flavours of MPEG4 than VideoToolbox
        AV_CODEC_ID_H264: 0x4832_3634,  // 'H264' fallback for missing sample configuration
        AV_CODEC_ID_HEVC: 0x4845_5643,  // 'HEVC' fallback for missing sample configuration
        AV_CODEC_ID_VP8: 0x5650_3820,  // 'VP8 ' somehow supported in Safari but not by AVFoundation
        AV_CODEC_ID_VP9: 0x5650_3920,  // 'VP9 ' not supported by AVFoundation unless client calls VTRegisterSupplementalVideoDecoderIfAvailable
        AV_CODEC_ID_AV1: 0x4156_3120,  // 'AV1 ' only supported by AVFoundation on M3 CPUs and later
        // Selected real FourCCs that videodecoder registers
        AV_CODEC_ID_QTRLE: kCMVideoCodecType_Animation,  // 'rle ' not supported by AVFoundation
        AV_CODEC_ID_CINEPAK: kCMVideoCodecType_Cinepak,  // 'cvid' not supported by AVFoundation
        AV_CODEC_ID_SVQ1: kCMVideoCodecType_SorensonVideo,  // 'SVQ1' not supported by AVFoundation
        AV_CODEC_ID_SVQ3: kCMVideoCodecType_SorensonVideo3,  // 'SVQ3' not supported by AVFoundation
        AV_CODEC_ID_THEORA: 0x7468_656f,  // 'theo'
        AV_CODEC_ID_VVC: 0x7676_6331,  // 'vvc1'
        AV_CODEC_ID_VC1: 0x7663_2D31,  // 'vc-1',
        AV_CODEC_ID_CAVS: 0x6176_7332,  // 'avs2'
        AV_CODEC_ID_FLIC: 0x666C_6963,  // 'flic'
        AV_CODEC_ID_APV: 0x6170_7631,  // 'apv1'
        AV_CODEC_ID_FLV1: 0x464C_5631,  // 'FLV1'
        AV_CODEC_ID_FLASHSV: 0x4653_5631,  // 'FSV1'
        AV_CODEC_ID_VP6: 0x5650_3620,  // 'VP6 ' (actually 'VP60' or 'VP61')
        AV_CODEC_ID_VP6A: 0x5650_3620,  // 'VP6 ' (actually VP6A')
        AV_CODEC_ID_VP6F: 0x5650_3620,  // 'VP6 ' (actually 'VP6F' or 'FLV4')
        AV_CODEC_ID_WMV1: 0x574D_5631,  // 'WMV1'
        AV_CODEC_ID_WMV2: 0x574D_5632,  // 'WMV2'
        AV_CODEC_ID_WMV3: 0x574D_5633,  // 'WMV3'
        AV_CODEC_ID_RV10: 0x5256_3130,  // 'RV10'
        AV_CODEC_ID_RV20: 0x5256_3230,  // 'RV20'
        AV_CODEC_ID_RV30: 0x5256_3330,  //  RV30'
        AV_CODEC_ID_RV40: 0x5256_3430,  // 'RV40'
        AV_CODEC_ID_RV60: 0x5256_3630,  // 'RV60'
        AV_CODEC_ID_CLEARVIDEO: 0x434C_5631,  // 'CLV1'
        AV_CODEC_ID_INDEO2: 0x5254_3231,  // 'RT21'
        AV_CODEC_ID_INDEO3: 0x4956_3332,  // 'IV32'
        AV_CODEC_ID_INDEO4: 0x4956_3431,  // 'IV41'
        AV_CODEC_ID_INDEO5: 0x4956_3530,  // 'IV50'
        AV_CODEC_ID_MSMPEG4V1: 0x4d50_3431,  // 'MP41'
        AV_CODEC_ID_MSMPEG4V2: 0x4d50_3432,  // 'MP42'
        AV_CODEC_ID_MSMPEG4V3: 0x4d50_3433,  // 'MP43'
    ]
    static let kVideoCodecType_VP8 = CMVideoCodecType(0x7670_3038)  // 'vp08'
    static let kVideoCodecType_catchall = CMVideoCodecType(0x514c_5620)  // 'QLV '

    static let colorPrimaries: [AVColorPrimaries: CFString] = [
        AVCOL_PRI_BT709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        AVCOL_PRI_BT470M: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_BT470BG: kCMFormatDescriptionColorPrimaries_EBU_3213,
        AVCOL_PRI_SMPTE170M: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_SMPTE240M: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_BT2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
        AVCOL_PRI_EBU3213: kCMFormatDescriptionColorPrimaries_EBU_3213,
    ]

    static let colorTransfer: [AVColorTransferCharacteristic: CFString] = [
        AVCOL_TRC_BT709: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        AVCOL_TRC_GAMMA22: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        AVCOL_TRC_GAMMA28: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        AVCOL_TRC_SMPTE170M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
        AVCOL_TRC_SMPTE240M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
        AVCOL_TRC_SMPTE428: kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1,
        AVCOL_TRC_BT2020_10: kCMFormatDescriptionTransferFunction_ITU_R_2020,
        AVCOL_TRC_BT2020_12: kCMFormatDescriptionTransferFunction_ITU_R_2020,
        AVCOL_TRC_SMPTE2084: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
        AVCOL_TRC_ARIB_STD_B67: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
    ]

    static let colorMatrix: [AVColorSpace: CFString] = [
        AVCOL_SPC_BT709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        AVCOL_SPC_BT470BG: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE170M: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE240M: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995,
        AVCOL_SPC_BT2020_NCL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
    ]

    static let chromaLocation: [AVChromaLocation: CFString] = [
        AVCHROMA_LOC_LEFT: kCVImageBufferChromaLocation_Left,
        AVCHROMA_LOC_CENTER: kCVImageBufferChromaLocation_Center,
        AVCHROMA_LOC_TOP: kCVImageBufferChromaLocation_Top,
        AVCHROMA_LOC_BOTTOM: kCVImageBufferChromaLocation_Bottom,
        AVCHROMA_LOC_TOPLEFT: kCVImageBufferChromaLocation_TopLeft,
        AVCHROMA_LOC_BOTTOMLEFT: kCVImageBufferChromaLocation_BottomLeft,
    ]

    var maxBFrames = 0  // for VideoSampleCursor.stepInPresentationOrder

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        // Three cases:
        //   1. Codecs that Corevideo doesn't support e.g. DivX, Indeo, Cinepak etc, but that can appear in formats that it does
        //      e.g. .avi, .mov: Use real fourcc so that our video decoder gets to decode it, reconstructing AVCodecParameters
        //      from CMVideoFormatDescription extension in the video decoder as needed.
        //   2. Other codecs that Corevideo doesn't support e.g. APV, VP6 etc: Doesn't really matter what fourcc we use, as long
        //      as our video decoder registers for it: Use catchall as a fallback for codecs we don't explicitly enumerate.
        //   3. Codecs that CoreVideo may or may not support e.g. AV1: Use real fourcc (kCMVideoCodecType_*) if
        //      VTIsHardwareDecodeSupported says that its supported on this computer and if we can construct the sample description
        //      atom that VideoToolkit requires for that codec, otherwise provide a fake fourcc and handle as for case 2.

        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }

        let params = stream.pointee.codecpar!
        guard params.pointee.codec_type == AVMEDIA_TYPE_VIDEO else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        // How many packets to search in VideoSampleCursor.stepInPresentationOrder based on the codec type
        maxBFrames =
            params.pointee.video_delay == 0
            ? 0
            : {
                switch params.pointee.codec_id {
                case AV_CODEC_ID_MPEG1VIDEO, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MSMPEG4V1,
                    AV_CODEC_ID_MSMPEG4V2, AV_CODEC_ID_MSMPEG4V3, AV_CODEC_ID_SVQ3, AV_CODEC_ID_RV30, AV_CODEC_ID_RV40:
                    return 6
                case AV_CODEC_ID_VC1, AV_CODEC_ID_WMV3, AV_CODEC_ID_CAVS, AV_CODEC_ID_RV60, AV_CODEC_ID_VP9: return 8
                case AV_CODEC_ID_AV1: return 10
                case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_VVC: return 16
                default: return 2
                }
            }()

        // Determine whether we want VideoToolbox (codecType!=nil) or FFmpeg (codecType==nil) to do the decoding,
        // and construct a codec configuration for those codecs where CoreVideo/VideoToolbox requires one.
        var codecType: CMVideoCodecType? = nil
        var extensions: [CFString: Any] = [:]
        switch params.pointee.codec_id {
        case AV_CODEC_ID_MJPEG:
            // Need an esds atom, but FFmpeg doesn't provide one. Make a minimal one.
            let bytes: [UInt8] = [
                0, 0, 0, 0, 0x03, 0x80, 0x80, 0x80, 0x1b, 0, 0x01, 0, 0x04, 0x80, 0x80, 0x80, 0x0d, 0x6c, 0x11, 0, 0, 0, 0,
                0x8b, 0xa5, 0xda, 0, 0x8b, 0xa5, 0xda, 0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
            ]
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
            codecType = kCMVideoCodecType_JPEG
        case AV_CODEC_ID_MPEG1VIDEO:
            codecType = kCMVideoCodecType_MPEG1Video  // Not hardware acclerated but playable by AVFoundation anyway
        case AV_CODEC_ID_MPEG2VIDEO:
            codecType = kCMVideoCodecType_MPEG2Video  // Not hardware acclerated but playable by AVFoundation anyway
        case AV_CODEC_ID_H263:
            codecType = kCMVideoCodecType_H263  // Not hardware acclerated but playable by AVFoundation anyway
        case AV_CODEC_ID_MPEG4:
            // MPEG4 part 2
            extract_extradata()  // build extradata if required info is in-band, e.g. .avi
            if params.pointee.extradata_size > 0
                && !([0x4449_5658, 0x5856_4944, 0x4458_3530].contains(params.pointee.codec_tag))  // 'DIVX', 'XVID', 'DX50' - FFmpeg is more tolerant of DivX
            {
                // FFmpeg only retains the decoder-specific info from "esds" in extradata - so rebuild it.
                // https://developer.apple.com/documentation/quicktime-file-format/mpeg-4_elementary_stream_descriptor_atom
                // See videotoolbox_esds_extradata_create in https://ffmpeg.org/doxygen/8.0/videotoolbox_8c_source.html
                let decoder_size = params.pointee.extradata_size  // assumed to be < 16K
                let config_size = 13 + 5 + decoder_size
                let full_size = 3 + 5 + config_size + 6
                let bytes: [UInt8] =
                    [
                        0, 0, 0, 0,  // Version/flags = ESDS
                        0x03,  // ES_DescrTag
                    ]
                    + descriptorLength(full_size) + [
                        0x00, 0x01, 0,  // ES_ID, priority
                        0x04,  // DecoderConfigDescrTag
                    ]
                    + descriptorLength(config_size) + [
                        0x20, 0x11,  // MPEG 4, video
                        0, 0, 0,  // buffer size
                        0, 0, 0, 0,  // max bitrate
                        0, 0, 0, 0,  // avg bitrate
                        0x05,  // DecSpecificInfoTag
                    ]
                    + descriptorLength(decoder_size)
                    + [UInt8](
                        UnsafeBufferPointer<UInt8>(start: params.pointee.extradata, count: Int(params.pointee.extradata_size))
                    ) + [
                        0x06,  // SLConfigDescrTag
                        0x80, 0x80, 0x80, 0x01,
                        0x02,
                    ]
                extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                    ["esds" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
                codecType = kCMVideoCodecType_MPEG4Video
            }
        case AV_CODEC_ID_H264:
            // avc1 / MPEG-4 part 10
            // https://developer.apple.com/documentation/quicktime-file-format/avc_decoder_configuration_atom
            extract_extradata()  // build extradata if required info is in-band
            if params.pointee.extradata_size >= 23 {
                extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                    [
                        "avcC" as CFString: CFDataCreateWithBytesNoCopy(
                            kCFAllocatorDefault,
                            params.pointee.extradata,
                            CFIndex(params.pointee.extradata_size),
                            kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                        )
                    ]
                if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) { codecType = kCMVideoCodecType_H264 }
                logger.log("H264 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))")
            }
        case AV_CODEC_ID_HEVC:
            // MPEG-4 Part 15
            extract_extradata()  // build extradata if required info is in-band
            if params.pointee.extradata_size >= 23 {
                var atoms: [CFString: CFData] = [
                    "hvcC" as CFString: CFDataCreateWithBytesNoCopy(
                        kCFAllocatorDefault,
                        params.pointee.extradata,
                        CFIndex(params.pointee.extradata_size),
                        kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                    )
                ]
                if let dovi = DolbyVisionConfig(),
                    VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
                        && (dovi.pointee.dv_profile == 5 || dovi.pointee.dv_profile == 8)
                {
                    // Not all profiles are supported https://professionalsupport.dolby.com/s/article/Apple-macOS-Overview
                    let dvAtom = DolbyVisionAtom(dovi: dovi.pointee)
                    atoms[dvAtom.0] = dvAtom.1
                    codecType = kCMVideoCodecType_DolbyVisionHEVC
                    logger.log("HEVC w/ Dolby Vision \(dovi.pointee.dv_profile) decode available: true")
                } else if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
                    // Fall back to vanilla HDR. Don't set Dolby Vision atom since it will cause decode to fail.
                    codecType = kCMVideoCodecType_HEVC
                    logger.log("HEVC decode available: true")
                } else {
                    logger.log("HEVC decode available: false")
                }
                extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary
            }
        case AV_CODEC_ID_VP9, AV_CODEC_ID_VP8:
            // https://www.webmproject.org/vp9/mp4/#vp-codec-configuration-box
            // See ff_videotoolbox_vpcc_extradata_create in https://ffmpeg.org/doxygen/8.0/videotoolbox__vp9_8c_source.html#l00065
            let pix_fmt = av_pix_fmt_desc_get(AVPixelFormat(params.pointee.format)).pointee
            let bitDepth = UInt8(pix_fmt.comp.0.depth)  // not always accurate but works for supported formats
            let chromaSubsampling = UInt8(
                pix_fmt.log2_chroma_w == 0
                    ? 3  // 4:4:4
                    : (pix_fmt.log2_chroma_h == 0
                        ? 2  // 4:2:2
                        : (params.pointee.chroma_location == AVCHROMA_LOC_TOPLEFT
                            ? 1  // 4:2:0 colocated with luma
                            : 0))  // 4:2:0 vertical
            )
            let bytes: [UInt8] =
                [
                    0x01, 0x00, 0x00, 0x00,  // version = 1, flags = 0
                    UInt8(params.pointee.profile),
                    params.pointee.level != AV_LEVEL_UNKNOWN ? UInt8(params.pointee.level) : 0,
                    (bitDepth << 4) | (chromaSubsampling << 1) | (params.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0),  // 0x80
                    UInt8(params.pointee.color_primaries.rawValue),  // FFmpeg color enums match MPEG part 8
                    UInt8(params.pointee.color_trc.rawValue),
                    UInt8(params.pointee.color_space.rawValue),
                    0x00, 0x00,  // codecInitializationDataSize
                ]
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                ["vpcC" as CFString: CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))] as CFDictionary
            if params.pointee.codec_id == AV_CODEC_ID_VP8 {
                if VTIsHardwareDecodeSupported(VideoTrackReader.kVideoCodecType_VP8) {
                    codecType = VideoTrackReader.kVideoCodecType_VP8
                }
                logger.log(
                    "VP8 decode available: \(VTIsHardwareDecodeSupported(VideoTrackReader.kVideoCodecType_VP8))"
                )
            } else if params.pointee.codec_id == AV_CODEC_ID_VP9 {
                // TODO: This returns false even if the playing process has called VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9) - how to detect this?
                if VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) { codecType = kCMVideoCodecType_VP9 }
                logger.log("VP9 decode available: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))")
            }
        case AV_CODEC_ID_AV1:
            // https://aomediacodec.github.io/av1-isobmff/#av1codecconfigurationbox-section
            extract_extradata()  // build extradata if required info is in-band
            if params.pointee.extradata_size >= 20 {
                var atoms: [CFString: CFData] = [
                    "av1C" as CFString: CFDataCreateWithBytesNoCopy(
                        kCFAllocatorDefault,
                        params.pointee.extradata,
                        CFIndex(params.pointee.extradata_size),
                        kCFAllocatorNull  // extradata will be deallocated by avformat_close_input()
                    )
                ]
                /* TODO: Re-enable AV1 hardware decode once I can test it on M3 or later
                if let dovi = DolbyVisionConfig(),
                    VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && dovi.pointee.dv_profile == 10
                {
                    let dvAtom = DolbyVisionAtom(dovi: dovi.pointee)
                    atoms[dvAtom.0] = dvAtom.1
                    codecType = kCMVideoCodecType_AV1
                    logger.log("AV1 w/ Dolby Vision \(dovi.pointee.dv_profile) decode available: true")
                } else if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
                    // Fall back to vanilla HDR. Don't set Dolby Vision atom since it will cause decode to fail.
                    codecType = kCMVideoCodecType_AV1
                    logger.log("AV1 decode available: true")
                } else {
                    logger.log("AV1 decode available: false")
                } */
                extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary
            }
        case AV_CODEC_ID_VVC, AV_CODEC_ID_VC1:
            // Not supported by VideoToolbox at time of writing
            extract_extradata()  // build extradata if required info is in-band
        default:
            break
        }

        if SOFTWARE_DECODE || codecType == nil {
            // macOS can't decode - check whether FFmpeg has a decoder
            guard avcodec_find_decoder(params.pointee.codec_id) != nil else {
                logger.error(
                    "VideoTrackReader stream \(self.index) loadTrackInfo: No decoder for codec \(String(cString:avcodec_get_name(params.pointee.codec_id)), privacy: .public)"
                )
                return completionHandler(nil, MEError(.unsupportedFeature))
            }

            // Pass the stream's AVCodecParameters in CMFormatDescription so it can be reconstructed in the MEVideoDecoder
            var parameters: [CFString: Any?] = [
                "AVCodecParameters" as CFString: CFDataCreate(
                    kCFAllocatorDefault,
                    stream.pointee.codecpar,
                    CFIndex(MemoryLayout<AVCodecParameters>.size)
                )
            ]
            if params.pointee.extradata_size > 0 {
                parameters["ExtraData" as CFString] = CFDataCreate(
                    kCFAllocatorDefault,
                    params.pointee.extradata,
                    CFIndex(params.pointee.extradata_size)
                )
            }
            for i in 0..<Int(params.pointee.nb_coded_side_data) {
                parameters["SideData\(i)" as CFString] = CFDataCreate(
                    kCFAllocatorDefault,
                    params.pointee.coded_side_data[i].data,
                    CFIndex(params.pointee.coded_side_data[i].size)
                )
                parameters["SideData\(i)Type" as CFString] = CFNumberCreate(
                    nil,
                    .intType,
                    &params.pointee.coded_side_data[i].type
                )
            }
            extensions["QLVideo" as CFString] = parameters as CFDictionary

            // Give the track a fourcc that ensures our MEVideoDecoder gets to see it
            codecType = VideoTrackReader.supported[params.pointee.codec_id] ?? VideoTrackReader.kVideoCodecType_catchall
        }

        // Other extensions
        if let codecName = CodecName.name(params: params) {
            extensions[kCMFormatDescriptionExtension_FormatName as CFString] = codecName as CFString
        }
        let sar = av_guess_sample_aspect_ratio(format.fmt_ctx, &stream.pointee, nil)
        if sar.num != 0 && (sar.num != 1 || sar.den != 1) {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio as CFString] =
                [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey as CFString: sar.num as CFNumber,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey as CFString: sar.den as CFNumber,
                ] as CFDictionary
        }
        if let colorPrimaries = VideoTrackReader.colorPrimaries[params.pointee.color_primaries] {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as CFString] = colorPrimaries
        }
        if let colorTransfer = VideoTrackReader.colorTransfer[params.pointee.color_trc] {
            extensions[kCMFormatDescriptionExtension_TransferFunction as CFString] = colorTransfer
        }
        if let colorMatrix = VideoTrackReader.colorMatrix[params.pointee.color_space] {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix as CFString] = colorMatrix
        }
        if let chromaLocation = VideoTrackReader.chromaLocation[params.pointee.chroma_location] {
            extensions[kCVImageBufferChromaLocationTopFieldKey as CFString] = chromaLocation
        }
        extensions[kCMFormatDescriptionExtension_FullRangeVideo] =
            params.pointee.color_range == AVCOL_RANGE_JPEG ? kCFBooleanTrue : kCFBooleanFalse

        logger.debug(
            "VideoTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) time_base:\(self.stream.pointee.time_base.num)/\(self.stream.pointee.time_base.den) codecType:\"\(CodecName.av_fourcc2str(codecType!), privacy: .public)\" extensions:\(extensions, privacy:.public) timescale:\(self.stream.pointee.time_base.den) \(params.pointee.width)x\(params.pointee.height) \(av_q2d(self.stream.pointee.avg_frame_rate), format:.fixed(precision:2))fps"
        )

        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType!,
            width: params.pointee.width,
            height: params.pointee.height,
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else {
            let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "VideoTrackReader stream \(self.index) loadTrackInfo CMVideoFormatDescriptionCreate returned \(err, privacy:.public)"
            )
            return completionHandler(nil, err)
        }
        let trackInfo = METrackInfo(
            __mediaType: kCMMediaType_Video,
            trackID: CMPersistentTrackID(index + 1),  // trackIDs can't be zero
            formatDescriptions: [formatDescription!]
        )
        trackInfo.isEnabled = isEnabled
        trackInfo.naturalSize = CGSize(width: Int(params.pointee.width), height: Int(params.pointee.height))
        trackInfo.naturalTimescale = stream.pointee.time_base.den
        trackInfo.nominalFrameRate = Float32(av_q2d(stream.pointee.avg_frame_rate))
        trackInfo.requiresFrameReordering = true  // TODO: do we need this?

        completionHandler(trackInfo, nil)
    }

    // MARK: Navigation

    // The new sample cursor points to the last sample with a presentation time stamp (PTS) less than or equal to
    // presentationTimeStamp, or if there are no such samples, the first sample in PTS order.
    func generateSampleCursor(
        atPresentationTimeStamp presentationTimeStamp: CMTime,
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug(
                "VideoTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public)"
            )
        }
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor = try VideoSampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: presentationTimeStamp
            )
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "VideoTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public): \(error, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("VideoTrackReader stream \(self.index) generateSampleCursorAtFirstSampleInDecodeOrder")
        }
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor = try VideoSampleCursor(
                format: format,
                track: self,
                index: index,
                atPresentationTimeStamp: stream.pointee.start_time != AV_NOPTS_VALUE
                    ? CMTime(value: stream.pointee.start_time, timeBase: stream.pointee.time_base) : .zero
            )
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "VideoTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtFirstSampleInDecodeOrder: \(error, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("VideoTrackReader stream \(self.index) generateSampleCursorAtLastSampleInDecodeOrder")
        }
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor = try VideoSampleCursor(format: format, track: self, index: index, atPresentationTimeStamp: .positiveInfinity)
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "VideoTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtLastSampleInDecodeOrder: \(error, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    // Weird encoding of sizes in ISO sample descriptor atoms
    private func descriptorLength(_ size: Int32) -> [UInt8] {
        [
            UInt8(0x80 | ((size >> 21) & 0x7f)),
            UInt8(0x80 | ((size >> 14) & 0x7f)),
            UInt8(0x80 | ((size >> 7) & 0x7f)),
            UInt8(size & 0x7f),
        ]
    }

    // For streams where the extradata required for decoding is in-band instead of in the container e.g. .avi,
    // and wasn't found and populated into AVCodecParameters during avformat_find_stream_info, try to extract it
    // so we can build a sample description for VideoToolbox and/or we can software decode without skipping initial frames.
    private func extract_extradata() {

        let params = stream.pointee.codecpar!
        if params.pointee.extradata_size > 0 { return }  // already have some extradata, assume its sufficient
        guard let bsf = av_bsf_get_by_name("extract_extradata") else {
            logger.error("VideoTrackReader stream \(self.index) failed to get extract_extradata bsf")
            return
        }

        var ctx: UnsafeMutablePointer<AVBSFContext>? = nil
        guard av_bsf_alloc(bsf, &ctx) == 0,
            avcodec_parameters_copy(ctx!.pointee.par_in, params) == 0,
            av_bsf_init(ctx) == 0
        else {
            // Can fail on unsupported types e.g. AV_CODEC_ID_MSMPEG4V3 which probably don't have sample descriptions anyway
            logger.warning("VideoTrackReader stream \(self.index) failed to setup extract_extradata bsf")
            if ctx != nil { av_bsf_free(&ctx) }
            return
        }

        var packetsScanned = 0
        var pkt = av_packet_alloc()
        let outPkt = av_packet_alloc()
        var ret: Int32 = 0
        while packetsScanned < 50 && params.pointee.extradata_size == 0
            && (ret == 0 || ret == AVERROR_EAGAIN || ret == AVERROR_EOF)
        {
            ret = av_read_frame(format!.fmt_ctx, pkt)
            guard ret == 0 else { break }
            if pkt!.pointee.stream_index != Int32(index) {
                av_packet_unref(pkt)
                continue
            }
            ret = av_bsf_send_packet(ctx, pkt)  // consumes packet if successful
            guard ret == 0 else {
                av_packet_free(&pkt)  // packet is not consumed on error
                break
            }

            packetsScanned += 1
            while ret == 0 {
                ret = av_bsf_receive_packet(ctx, outPkt)
                if ret == 0 {
                    var sz = 0
                    if let sideData = av_packet_get_side_data(outPkt, AV_PKT_DATA_NEW_EXTRADATA, &sz) {
                        params.pointee.extradata_size = Int32(sz)
                        params.pointee.extradata = av_mallocz(sz + Int(AV_INPUT_BUFFER_PADDING_SIZE)).assumingMemoryBound(
                            to: UInt8.self
                        )
                        memcpy(params.pointee.extradata, sideData, sz)
                        av_packet_unref(outPkt)
                        break
                    } else {
                        av_packet_unref(outPkt)
                    }
                }
            }
        }
        av_bsf_free(&ctx)

        // Rewind so demux will start at start
        avformat_seek_file(format!.fmt_ctx, -1, Int64.min, Int64.min, 0, 0)
        avformat_flush(format!.fmt_ctx)

        if TRACE_PACKET_DEMUXER {
            if params.pointee.extradata_size > 0 {
                logger.debug("VideoTrackReader stream \(self.index) synthesized extradata size=\(params.pointee.extradata_size)")
            } else {
                logger.warning("VideoTrackReader stream \(self.index) failed to synthesize extradata")
            }
        }
    }
}
