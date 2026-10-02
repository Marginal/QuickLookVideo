//
//  CodecName.swift
//  QLVideo
//
// Some of AVCodec.long_name can be too wordy (see libavcodec/codec_desc.c) but .name too cryptic,
// so special-case some common codecs to give more compact & Applesque names
//

import MediaExtension

class CodecName {

    private static let mediaTypes: [Int32: CMMediaType] = [
        AVMEDIA_TYPE_VIDEO.rawValue: kCMMediaType_Video,
        AVMEDIA_TYPE_AUDIO.rawValue: kCMMediaType_Audio,
        AVMEDIA_TYPE_SUBTITLE.rawValue: kCMMediaType_Subtitle,
    ]

    private static let mapping: [AVCodecID: UInt32] = [
        // AudioFormatIDs from CoreAudioBaseTypes.h
        // Copy of AudioTrackReader.formatIDs, but with disabled mappings enabled
        AV_CODEC_ID_PCM_S8: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_U8: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S16BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S16LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S24BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S24LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S32BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_S32LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F32BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F32LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F64BE: kAudioFormatLinearPCM,
        AV_CODEC_ID_PCM_F64LE: kAudioFormatLinearPCM,
        AV_CODEC_ID_AC3: kAudioFormatAC3,
        AV_CODEC_ID_ADPCM_IMA_QT: kAudioFormatAppleIMA4,
        // kAudioFormat60958AC3
        AV_CODEC_ID_AAC: kAudioFormatMPEG4AAC,
        // MPEG4CELP: kAudioFormatMPEG4CELP, // not supported by FFmpeg
        // MPEG4HVXC: kAudioFormatMPEG4HVXC, // not supported by FFmpeg
        // MPEG4TwinVQ: kAudioFormatMPEG4TwinVQ, // not supported by FFmpeg
        AV_CODEC_ID_MACE3: kAudioFormatMACE3,
        AV_CODEC_ID_MACE6: kAudioFormatMACE6,
        AV_CODEC_ID_PCM_MULAW: kAudioFormatULaw,
        AV_CODEC_ID_PCM_ALAW: kAudioFormatALaw,
        AV_CODEC_ID_QDMC: kAudioFormatQDesign,
        AV_CODEC_ID_QDM2: kAudioFormatQDesign2,
        AV_CODEC_ID_QCELP: kAudioFormatQUALCOMM,
        AV_CODEC_ID_MP1: kAudioFormatMPEGLayer1,
        AV_CODEC_ID_MP2: kAudioFormatMPEGLayer2,
        AV_CODEC_ID_MP3: kAudioFormatMPEGLayer3,
        // kAudioFormatTimeCode,
        // kAudioFormatMIDIStream,
        // kAudioFormatParameterValueStream,
        AV_CODEC_ID_ALAC: kAudioFormatAppleLossless,
        // kAudioFormatMPEG4AAC_* treated as profiles
        AV_CODEC_ID_AMR_NB: kAudioFormatAMR,
        AV_CODEC_ID_AMR_WB: kAudioFormatAMR_WB,
        // kAudioFormatAudible, not supported by FFmpeg
        AV_CODEC_ID_ILBC: kAudioFormatiLBC,
        AV_CODEC_ID_ADPCM_IMA_WAV: kAudioFormatDVIIntelIMA,
        AV_CODEC_ID_GSM_MS: kAudioFormatMicrosoftGSM,
        // kAudioFormatAES3, just treated as PCM by FFmpeg
        AV_CODEC_ID_EAC3: kAudioFormatEnhancedAC3,
        AV_CODEC_ID_FLAC: kAudioFormatFLAC,  // requires frame_size, error "kAudioCodecPropertyPacketFrameSize is zero"
        AV_CODEC_ID_OPUS: kAudioFormatOpus,  // no errors, but doesn't decode well
        // kAudioFormatAPAC, not supported by FFmpeg

        // CMVideoCodecTypes, ordered by listing in CMFormatDescription.h
        // kCMVideoCodecType_422YpCbCr8 special handling for rawvideo
        AV_CODEC_ID_QTRLE: kCMVideoCodecType_Animation,  // 'rle '
        AV_CODEC_ID_CINEPAK: kCMVideoCodecType_Cinepak,  // 'cvid'
        AV_CODEC_ID_MJPEG: kCMVideoCodecType_JPEG,  // 'jpeg'
        // kCMVideoCodecType_JPEG_OpenDML,     // 'dmb1'
        AV_CODEC_ID_JPEGXL: kCMVideoCodecType_JPEG_XL,  // 'jxlc'
        AV_CODEC_ID_SVQ1: kCMVideoCodecType_SorensonVideo,  // 'SVQ1'
        AV_CODEC_ID_SVQ3: kCMVideoCodecType_SorensonVideo3,  // 'SVQ3'
        AV_CODEC_ID_H263: kCMVideoCodecType_H263,  // 'h263'
        AV_CODEC_ID_H264: kCMVideoCodecType_H264,  // 'avc1'
        AV_CODEC_ID_HEVC: kCMVideoCodecType_HEVC,  // 'hvc1'
        // kCMVideoCodecType_HEVCWithAlpha not supported as a separate codec in FFmpeg ,    // 'muxa'
        // kCMVideoCodecType_DolbyVisionHEVC not supported as a separate codec - special handling,  // 'dvh1'
        AV_CODEC_ID_MPEG4: kCMVideoCodecType_MPEG4Video,  // 'mp4v'
        AV_CODEC_ID_MSMPEG4V1: kCMVideoCodecType_MPEG4Video,
        AV_CODEC_ID_MSMPEG4V2: kCMVideoCodecType_MPEG4Video,
        AV_CODEC_ID_MSMPEG4V3: kCMVideoCodecType_MPEG4Video,
        AV_CODEC_ID_MPEG2VIDEO: kCMVideoCodecType_MPEG2Video,  // 'mp2v'
        AV_CODEC_ID_MPEG1VIDEO: kCMVideoCodecType_MPEG1Video,  // 'mp1v'
        AV_CODEC_ID_VP9: kCMVideoCodecType_VP9,  // 'vp09'
        // kCMVideoCodecType_DVC* not broken out into separate codecs by FFmpeg
        // kCMVideoCodecType_AppleProRes* treated as profiles by FFmpeg
        // kCMVideoCodecType_DisparityHEVC ???    // 'dish'
        // kCMVideoCodecType_DepthHEVC ???,        // 'deph'
        AV_CODEC_ID_AV1: kCMVideoCodecType_AV1,  // 'av01'
    ]

    private static let codecNames: [AVCodecID: String] = [
        // audio
        AV_CODEC_ID_AAC: "MPEG-4 AAC",  // CoreMedia.mdimporter uses "MPEG-4 AAC"
        AV_CODEC_ID_AC3: "Dolby Digital",
        AV_CODEC_ID_ADPCM_SWF: "Shockwave Flash",
        AV_CODEC_ID_ALAC: "Apple Lossless",
        AV_CODEC_ID_ATRAC1: "ATRAC1",
        AV_CODEC_ID_ATRAC3P: "ATRAC3+",
        AV_CODEC_ID_COOK: "RealAudio G2",
        AV_CODEC_ID_DTS: "DCA",
        AV_CODEC_ID_EAC3: "Dolby Digital Plus",
        AV_CODEC_ID_FLAC: "FLAC",
        AV_CODEC_ID_MP2: "MPEG Layer 2",
        AV_CODEC_ID_MP3: "MPEG Layer 3",
        AV_CODEC_ID_RA_144: "RealAudio 1.0",
        AV_CODEC_ID_RA_288: "RealAudio 2.0",
        AV_CODEC_ID_SIPR: "RealAudio SIPR",
        AV_CODEC_ID_WMALOSSLESS: "WM Audio Lossless",
        AV_CODEC_ID_WMAPRO: "WM Audio 9 Pro",
        AV_CODEC_ID_WMAV1: "WM Audio 1",
        AV_CODEC_ID_WMAV2: "WM Audio 2",
        AV_CODEC_ID_WMAVOICE: "WM Audio Voice",
        // video
        AV_CODEC_ID_AV1: "AV1",
        AV_CODEC_ID_CAVS: "CAVS",
        AV_CODEC_ID_CLEARVIDEO: "ClearVideo",
        AV_CODEC_ID_DVVIDEO: "DV",
        AV_CODEC_ID_FLIC: "FLIC",
        AV_CODEC_ID_FLV1: "Sorenson Spark",
        AV_CODEC_ID_H263: "H.263",
        AV_CODEC_ID_H263P: "H.263+",
        AV_CODEC_ID_H264: "H.264",
        AV_CODEC_ID_HEVC: "HEVC",  // CoreMedia.mdimporter uses "HEVC"
        AV_CODEC_ID_INDEO4: "Intel Indeo 4",
        AV_CODEC_ID_INDEO5: "Intel Indeo 5",
        AV_CODEC_ID_MPEG1VIDEO: "MPEG-1",
        AV_CODEC_ID_MPEG2VIDEO: "MPEG-2",
        AV_CODEC_ID_MPEG4: "MPEG-4 Video",  // CoreMedia.mdimporter uses "MPEG-4 Video"
        AV_CODEC_ID_MSS2: "WM Video 9 Screen",
        AV_CODEC_ID_PRORES: "Apple ProRes",
        AV_CODEC_ID_QTRLE: "QuickTime Animation",
        AV_CODEC_ID_RAWVIDEO: "Raw",
        AV_CODEC_ID_RPZA: "QuickTime Video",
        AV_CODEC_ID_SVQ1: "Sorenson Video",
        AV_CODEC_ID_SVQ3: "Sorenson Video 3",  // CoreMedia.mdimporter uses "Sorenson Video 3"
        AV_CODEC_ID_VC1: "VC-1",
        AV_CODEC_ID_VC1IMAGE: "WM Video 9 Image v2",
        AV_CODEC_ID_VP6: "VP6",
        AV_CODEC_ID_VP6A: "VP6",
        AV_CODEC_ID_VP6F: "VP6",
        AV_CODEC_ID_VP8: "VP8",
        AV_CODEC_ID_VP9: "VP9",
        AV_CODEC_ID_VVC: "H.266",
        AV_CODEC_ID_WMV1: "WM Video 7",
        AV_CODEC_ID_WMV2: "WM Video 8",
        AV_CODEC_ID_WMV3: "WM Video 9",
        AV_CODEC_ID_WMV3IMAGE: "WM Video 9 Image",
        // subtitles
        AV_CODEC_ID_ASS: "Advanced SSA",
        AV_CODEC_ID_HDMV_PGS_SUBTITLE: "PGS",
        AV_CODEC_ID_MOV_TEXT: "QuickTime",  // CoreMedia.mdimporter uses "QuickTime Text"
        AV_CODEC_ID_PJS: "PJS",
        AV_CODEC_ID_SRT: "SubRip",
        AV_CODEC_ID_SSA: "SSA",
        AV_CODEC_ID_SUBRIP: "SubRip",
        AV_CODEC_ID_WEBVTT: "WebVTT",
    ]

    static func av_fourcc2str(_ fourcc: UInt32) -> String {
        var buf = [CChar](repeating: 0, count: Int(AV_FOURCC_MAX_STRING_SIZE))
        return String(cString: av_fourcc_make_string(&buf, fourcc.byteSwapped))
    }

    static func name(params: UnsafeMutablePointer<AVCodecParameters>) -> String? {

        let codec: UnsafePointer<AVCodec>? = avcodec_find_decoder(params.pointee.codec_id)

        // Codec name
        let codecName: String
        if let mediaType = self.mediaTypes[params.pointee.codec_type.rawValue],
            let fourCC = self.mapping[params.pointee.codec_id],
            // Apple localized name
            let appleName = MTCopyLocalizedNameForMediaSubType(mediaType, fourCC) as? String,
            appleName != av_fourcc2str(fourCC)  //  if no localisation can just return the fourccc as a string
        {
            codecName = appleName
        } else if let name = self.codecNames[params.pointee.codec_id] {  // Hand-coded names
            if params.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                codecName = "\(name) \(MTCopyLocalizedNameForMediaType(kCMMediaType_Subtitle)!)"
            } else {
                codecName = name
            }
        } else if params.pointee.codec_tag == 0x5741_5243 {  // 'CRAW'
            codecName = "C-RAW"
        } else if let codec {  // FFmpeg names
            if let nameC = codec.pointee.long_name {
                codecName = String(cString: nameC)
            } else {
                codecName = String(cString: codec.pointee.name!)
            }
        } else {
            return nil
        }

        // profile
        if params.pointee.codec_id == AV_CODEC_ID_MPEG4
            && [0x4449_5658, 0x5856_4944, 0x4458_3530].contains(params.pointee.codec_tag)  // 'DIVX', 'XVID', 'DX50'
        {
            return "\(codecName) [DivX]"
        } else if params.pointee.codec_id == AV_CODEC_ID_MSMPEG4V1 {
            return "\(codecName) [MSv1]"
        } else if params.pointee.codec_id == AV_CODEC_ID_MSMPEG4V2 {
            return "\(codecName) [MSv2]"
        } else if params.pointee.codec_id == AV_CODEC_ID_MSMPEG4V3 {
            return "\(codecName) [MSv3]"
        } else if (params.pointee.codec_id == AV_CODEC_ID_EAC3 && params.pointee.profile == AV_PROFILE_EAC3_DDP_ATMOS)
            || (params.pointee.codec_id == AV_CODEC_ID_TRUEHD && params.pointee.profile == AV_PROFILE_TRUEHD_ATMOS)
        {
            return "\(codecName) [Dolby Atmos]"  // way too wordy otherwise
        } else if av_packet_side_data_get(params.pointee.coded_side_data, params.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
            != nil
        {
            return "\(codecName) [Dolby Vision]"
        } else if params.pointee.codec_id == AV_CODEC_ID_RAWVIDEO,
            let pixNameC = av_get_pix_fmt_name(AVPixelFormat(rawValue: params.pointee.format))
        {
            return "\(codecName) [\(String(cString: pixNameC))]"
        } else if let codec,
            let profileC = av_get_profile_name(codec, params.pointee.profile)
        {
            return "\(codecName) [\(String(cString: profileC))]"
        } else {
            return codecName
        }
    }

}
