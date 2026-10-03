//
//  audiotrackreader.swift
//  QLVideo
//
//  Created by Jonathan Harris on 18/11/2025.
//

import Foundation
import MediaExtension
import OSLog

class AudioTrackReader: TrackReader, METrackReader {

    // AudioFormatIDs supported for passthrough to CoreAudio, ordered by listing in CoreAudioBaseTypes.h
    static let formatIDs: [AVCodecID: AudioFormatID] = [
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
        // AV_CODEC_ID_ALAC: kAudioFormatAppleLossless,  // Requires magicCookie otherwise AVErrorUndecodableMediaData. Disabled due to weird stepping behaviour breaking packet consumption algo.
        // kAudioFormatMPEG4AAC_* special handling below
        AV_CODEC_ID_AMR_NB: kAudioFormatAMR,
        AV_CODEC_ID_AMR_WB: kAudioFormatAMR_WB,
        // kAudioFormatAudible, not supported by FFmpeg
        AV_CODEC_ID_ILBC: kAudioFormatiLBC,
        AV_CODEC_ID_ADPCM_IMA_WAV: kAudioFormatDVIIntelIMA,
        AV_CODEC_ID_GSM_MS: kAudioFormatMicrosoftGSM,
        // kAudioFormatAES3, just treated as PCM by FFmpeg
        AV_CODEC_ID_EAC3: kAudioFormatEnhancedAC3,
            // AV_CODEC_ID_FLAC: kAudioFormatFLAC,  // requires frame_size, error "kAudioCodecPropertyPacketFrameSize is zero"
            // AV_CODEC_ID_OPUS: kAudioFormatOpus,  // no errors, but doesn't decode well
            // kAudioFormatAPAC, not supported by FFmpeg
    ]

    // https://ffmpeg.org/doxygen/8.0/channel__layout_8h_source.html#l00175
    struct ChannelMasks: OptionSet {
        let rawValue: UInt64
        static let AV_CH_FRONT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_LEFT.rawValue)
        static let AV_CH_FRONT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_RIGHT.rawValue)
        static let AV_CH_FRONT_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_CENTER.rawValue)
        static let AV_CH_LOW_FREQUENCY = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_LOW_FREQUENCY.rawValue)
        static let AV_CH_BACK_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BACK_LEFT.rawValue)
        static let AV_CH_BACK_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BACK_RIGHT.rawValue)
        static let AV_CH_FRONT_LEFT_OF_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_LEFT_OF_CENTER.rawValue)
        static let AV_CH_FRONT_RIGHT_OF_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_FRONT_RIGHT_OF_CENTER.rawValue)
        static let AV_CH_BACK_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BACK_CENTER.rawValue)
        static let AV_CH_SIDE_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_LEFT.rawValue)
        static let AV_CH_SIDE_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_RIGHT.rawValue)
        static let AV_CH_TOP_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_CENTER.rawValue)
        static let AV_CH_TOP_FRONT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_FRONT_LEFT.rawValue)
        static let AV_CH_TOP_FRONT_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_FRONT_CENTER.rawValue)
        static let AV_CH_TOP_FRONT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_FRONT_RIGHT.rawValue)
        static let AV_CH_TOP_BACK_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_BACK_LEFT.rawValue)
        static let AV_CH_TOP_BACK_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_BACK_CENTER.rawValue)
        static let AV_CH_TOP_BACK_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_BACK_RIGHT.rawValue)
        static let AV_CH_STEREO_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_STEREO_LEFT.rawValue)
        static let AV_CH_STEREO_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_STEREO_RIGHT.rawValue)
        static let AV_CH_WIDE_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_WIDE_LEFT.rawValue)
        static let AV_CH_WIDE_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_WIDE_RIGHT.rawValue)
        static let AV_CH_SURROUND_DIRECT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SURROUND_DIRECT_LEFT.rawValue)
        static let AV_CH_SURROUND_DIRECT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SURROUND_DIRECT_RIGHT.rawValue)
        static let AV_CH_LOW_FREQUENCY_2 = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_LOW_FREQUENCY_2.rawValue)
        static let AV_CH_TOP_SIDE_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SIDE_LEFT.rawValue)
        static let AV_CH_TOP_SIDE_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SIDE_RIGHT.rawValue)
        static let AV_CH_BOTTOM_FRONT_CENTER = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BOTTOM_FRONT_CENTER.rawValue)
        static let AV_CH_BOTTOM_FRONT_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BOTTOM_FRONT_LEFT.rawValue)
        static let AV_CH_BOTTOM_FRONT_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BOTTOM_FRONT_RIGHT.rawValue)
        static let AV_CH_SIDE_SURROUND_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_SURROUND_LEFT.rawValue)
        static let AV_CH_SIDE_SURROUND_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_SIDE_SURROUND_RIGHT.rawValue)
        static let AV_CH_TOP_SURROUND_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SURROUND_LEFT.rawValue)
        static let AV_CH_TOP_SURROUND_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_TOP_SURROUND_RIGHT.rawValue)
        static let AV_CH_BINAURAL_LEFT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BINAURAL_LEFT.rawValue)
        static let AV_CH_BINAURAL_RIGHT = ChannelMasks(rawValue: UInt64(1) << AV_CHAN_BINAURAL_RIGHT.rawValue)

        // selected common layouts https://ffmpeg.org/doxygen/8.0/channel__layout_8h_source.html#l00217
        static let AV_CH_LAYOUT_MONO = ChannelMasks.AV_CH_FRONT_CENTER
        static let AV_CH_LAYOUT_STEREO: ChannelMasks = [.AV_CH_FRONT_LEFT, .AV_CH_FRONT_RIGHT]
        static let AV_CH_LAYOUT_SURROUND: ChannelMasks = [.AV_CH_LAYOUT_STEREO, .AV_CH_FRONT_CENTER]
        static let AV_CH_LAYOUT_5POINT0: ChannelMasks = [.AV_CH_LAYOUT_SURROUND, .AV_CH_SIDE_LEFT, .AV_CH_SIDE_RIGHT]
        static let AV_CH_LAYOUT_5POINT0_BACK: ChannelMasks = [.AV_CH_LAYOUT_SURROUND, .AV_CH_BACK_LEFT, .AV_CH_BACK_RIGHT]
        static let AV_CH_LAYOUT_5POINT1: ChannelMasks = [.AV_CH_LAYOUT_5POINT0, .AV_CH_LOW_FREQUENCY]
        static let AV_CH_LAYOUT_5POINT1_BACK: ChannelMasks = [.AV_CH_LAYOUT_5POINT0_BACK, .AV_CH_LOW_FREQUENCY]
        static let AV_CH_LAYOUT_7POINT1: ChannelMasks = [.AV_CH_LAYOUT_5POINT1, .AV_CH_BACK_LEFT, .AV_CH_BACK_RIGHT]
        static let AV_CH_LAYOUT_7POINT1_WIDE: ChannelMasks = [
            .AV_CH_LAYOUT_5POINT1, .AV_CH_FRONT_LEFT_OF_CENTER, .AV_CH_FRONT_RIGHT_OF_CENTER,
        ]
        static let AV_CH_LAYOUT_7POINT1_WIDE_BACK: ChannelMasks = [
            .AV_CH_LAYOUT_5POINT1_BACK, .AV_CH_FRONT_LEFT_OF_CENTER, .AV_CH_FRONT_RIGHT_OF_CENTER,
        ]
    }

    static let channelLabels: [UInt64: AudioChannelLabel] = [
        ChannelMasks.AV_CH_FRONT_LEFT.rawValue: kAudioChannelLabel_Left,
        ChannelMasks.AV_CH_FRONT_RIGHT.rawValue: kAudioChannelLabel_Right,
        ChannelMasks.AV_CH_FRONT_CENTER.rawValue: kAudioChannelLabel_Center,
        ChannelMasks.AV_CH_LOW_FREQUENCY.rawValue: kAudioChannelLabel_LFEScreen,
        ChannelMasks.AV_CH_BACK_LEFT.rawValue: kAudioChannelLabel_LeftBackSurround,
        ChannelMasks.AV_CH_BACK_RIGHT.rawValue: kAudioChannelLabel_RightBackSurround,
        ChannelMasks.AV_CH_FRONT_LEFT_OF_CENTER.rawValue: kAudioChannelLabel_LeftCenter,
        ChannelMasks.AV_CH_FRONT_RIGHT_OF_CENTER.rawValue: kAudioChannelLabel_RightCenter,
        ChannelMasks.AV_CH_BACK_CENTER.rawValue: kAudioChannelLabel_CenterSurround,
        ChannelMasks.AV_CH_SIDE_LEFT.rawValue: kAudioChannelLabel_LeftSurround,
        ChannelMasks.AV_CH_SIDE_RIGHT.rawValue: kAudioChannelLabel_RightSurround,
        ChannelMasks.AV_CH_TOP_CENTER.rawValue: kAudioChannelLabel_TopCenterSurround,
        ChannelMasks.AV_CH_TOP_FRONT_LEFT.rawValue: kAudioChannelLabel_VerticalHeightLeft,
        ChannelMasks.AV_CH_TOP_FRONT_CENTER.rawValue: kAudioChannelLabel_VerticalHeightCenter,
        ChannelMasks.AV_CH_TOP_FRONT_RIGHT.rawValue: kAudioChannelLabel_VerticalHeightRight,
        ChannelMasks.AV_CH_TOP_BACK_LEFT.rawValue: kAudioChannelLabel_TopBackLeft,
        ChannelMasks.AV_CH_TOP_BACK_CENTER.rawValue: kAudioChannelLabel_TopBackCenter,
        ChannelMasks.AV_CH_TOP_BACK_RIGHT.rawValue: kAudioChannelLabel_TopBackRight,
        ChannelMasks.AV_CH_STEREO_LEFT.rawValue: kAudioChannelLabel_Left,  // downmix
        ChannelMasks.AV_CH_STEREO_RIGHT.rawValue: kAudioChannelLabel_Right,  //  "
        ChannelMasks.AV_CH_WIDE_LEFT.rawValue: kAudioChannelLabel_LeftWide,
        ChannelMasks.AV_CH_WIDE_RIGHT.rawValue: kAudioChannelLabel_RightWide,
        ChannelMasks.AV_CH_SURROUND_DIRECT_LEFT.rawValue: kAudioChannelLabel_LeftSurroundDirect,
        ChannelMasks.AV_CH_SURROUND_DIRECT_RIGHT.rawValue: kAudioChannelLabel_RightSurroundDirect,
        ChannelMasks.AV_CH_LOW_FREQUENCY_2.rawValue: kAudioChannelLabel_LFE2,
        ChannelMasks.AV_CH_TOP_SIDE_LEFT.rawValue: kAudioChannelLabel_LeftTopMiddle,
        ChannelMasks.AV_CH_TOP_SIDE_RIGHT.rawValue: kAudioChannelLabel_RightTopMiddle,
        ChannelMasks.AV_CH_BOTTOM_FRONT_CENTER.rawValue: kAudioChannelLabel_CenterBottom,
        ChannelMasks.AV_CH_BOTTOM_FRONT_LEFT.rawValue: kAudioChannelLabel_LeftBottom,
        ChannelMasks.AV_CH_BOTTOM_FRONT_RIGHT.rawValue: kAudioChannelLabel_RightBottom,
        ChannelMasks.AV_CH_SIDE_SURROUND_LEFT.rawValue: kAudioChannelLabel_LeftSideSurround,
        ChannelMasks.AV_CH_SIDE_SURROUND_RIGHT.rawValue: kAudioChannelLabel_RightSideSurround,
        ChannelMasks.AV_CH_TOP_SURROUND_LEFT.rawValue: kAudioChannelLabel_LeftTopSurround,
        ChannelMasks.AV_CH_TOP_SURROUND_RIGHT.rawValue: kAudioChannelLabel_RightTopSurround,
        ChannelMasks.AV_CH_BINAURAL_LEFT.rawValue: kAudioChannelLabel_BinauralLeft,
        ChannelMasks.AV_CH_BINAURAL_RIGHT.rawValue: kAudioChannelLabel_BinauralRight,
    ]

    static let formatFlags: [AVSampleFormat: AudioFormatFlags] = [
        AV_SAMPLE_FMT_U8: 0,
        AV_SAMPLE_FMT_S16: kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_S32: kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_FLT: kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_DBL: kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_S64: kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_U8P: kAudioFormatFlagIsNonInterleaved,
        AV_SAMPLE_FMT_S16P: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_S32P: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsSignedInteger,
        AV_SAMPLE_FMT_FLTP: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_DBLP: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsFloat,
        AV_SAMPLE_FMT_S64P: kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsSignedInteger,
    ]

    static let losslessFormatFlags: [Int: AudioFormatFlags] = [
        16: kAppleLosslessFormatFlag_16BitSourceData,
        20: kAppleLosslessFormatFlag_20BitSourceData,
        24: kAppleLosslessFormatFlag_24BitSourceData,
        32: kAppleLosslessFormatFlag_32BitSourceData,
    ]

    var dec_ctx: UnsafeMutablePointer<AVCodecContext>? = nil  // for decoding audio
    var swr_ctx: UnsafeMutablePointer<SwrContext>? = nil  //  for resampling planar to packed

    deinit {
        if dec_ctx != nil { avcodec_free_context(&dec_ctx) }
        if swr_ctx != nil { swr_free(&swr_ctx) }
    }

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {

        var params = stream.pointee.codecpar.pointee
        guard params.codec_type == AVMEDIA_TYPE_AUDIO else {
            logger.error("Can't get stream parameters for stream #\(self.index)")
            preconditionFailure("Can't get stream parameters for stream #\(self.index)")
        }

        #if DEBUG
            let hex = UnsafeBufferPointer(start: params.extradata, count: Int(params.extradata_size)).map {
                String(format: "%02x", $0)
            }.joined(separator: " ")
            logger.debug(
                "AudioTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) time_base:\(self.stream.pointee.time_base.num)/\(self.stream.pointee.time_base.den) start_time:\(self.stream.pointee.start_time) duration:\(self.stream.pointee.duration == AV_NOPTS_VALUE ? -1 : self.stream.pointee.duration) disposition:\(UInt(self.stream.pointee.disposition), format:.hex) codecpar: codec_id:\(String(cString:avcodec_get_name(params.codec_id)), privacy: .public) codec_tag:\"\(CodecName.av_fourcc2str(params.codec_tag), privacy:.public)\" format:\(String(cString: av_get_sample_fmt_name(AVSampleFormat(rawValue: params.format))), privacy:.public) sample_rate:\(params.sample_rate) frame_size:\(params.frame_size) bits_per_coded_sample:\(params.bits_per_coded_sample) bits_per_raw_sample:\(params.bits_per_raw_sample) layout: order:\(params.ch_layout.order.rawValue) nb_channels:\(params.ch_layout.nb_channels) mask:\(params.ch_layout.u.mask, format: .hex) extradata \(params.extradata_size) bytes: \(hex)"
            )
        #endif

        // Can MacOS decode?
        var formatID = AudioTrackReader.formatIDs[params.codec_id]

        // CoreAudio treats different AAC profiles as different codecs
        if formatID == kAudioFormatMPEG4AAC {
            switch params.profile {
            case AV_PROFILE_AAC_MAIN: formatID = kAudioFormatMPEG4AAC
            case AV_PROFILE_AAC_LOW: formatID = kAudioFormatMPEG4AAC
            case AV_PROFILE_AAC_HE: formatID = kAudioFormatMPEG4AAC_HE
            case AV_PROFILE_AAC_HE_V2: formatID = kAudioFormatMPEG4AAC_HE_V2
            case AV_PROFILE_AAC_LD: formatID = kAudioFormatMPEG4AAC_LD
            case AV_PROFILE_AAC_ELD: formatID = kAudioFormatMPEG4AAC_ELD
            // case AV_PROFILE_AAC_USAC: formatID = kAudioFormatMPEGD_USAC  // needs full sample description - error MP4AudioESDS::Deserialize: the ES_Descriptor tag is incorrect
            default: formatID = nil  // hope FFmpeg can handle it
            }
        }

        if formatID == nil {
            formatID = kAudioFormatLinearPCM  // decode to PCM

            // Check that we can decode and prepare an AVCodecContext for decoding and SwrContext for resampling
            guard let codec = avcodec_find_decoder(params.codec_id) else {
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: No decoder for codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public)"
                )
                return completionHandler(nil, MEError(.unsupportedFeature))
            }

            dec_ctx = avcodec_alloc_context3(codec)
            if dec_ctx == nil {
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: Can't create decoder context for codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public)"
                )
                return completionHandler(nil, MEError(.unsupportedFeature))
            }
            var ret = avcodec_parameters_to_context(dec_ctx, &params)
            if ret < 0 {
                let err = AVERROR(errorCode: ret, context: "avcodec_parameters_to_context")
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: Can't set decoder parameters for codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public): \(err.errorDescription, privacy: .public)"
                )
                return completionHandler(nil, err)
            }
            ret = avcodec_open2(dec_ctx, codec, nil)
            if ret < 0 {
                let err = AVERROR(errorCode: ret, context: "avcodec_open2")
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: Can't open codec \(String(cString:avcodec_get_name(params.codec_id)), privacy: .public): \(err.errorDescription, privacy: .public)"
                )
                return completionHandler(nil, err)
            }

            // CoreMedia doesn't like planar PCM (error "SSP::Render: CopySlice returned 1") so convert to packed/interleaved
            // http://www.openradar.me/45068930
            if av_sample_fmt_is_planar(AVSampleFormat(params.format)) != 0 {
                ret = swr_alloc_set_opts2(
                    &swr_ctx,
                    &params.ch_layout,
                    av_get_packed_sample_fmt(AVSampleFormat(params.format)),  // out
                    params.sample_rate,
                    &params.ch_layout,
                    AVSampleFormat(params.format),  // in
                    params.sample_rate,
                    0,
                    nil
                )
                if ret < 0 {
                    let err = AVERROR(errorCode: ret, context: "swr_alloc_set_opts2")
                    logger.error(
                        "AudioTrackReader stream \(self.index) loadTrackInfo: Can't create resample context for format \(String(cString:av_get_sample_fmt_name(AVSampleFormat(rawValue: params.format))), privacy: .public): \(err.errorDescription, privacy: .public)"
                    )
                    return completionHandler(nil, err)
                }
                ret = swr_init(swr_ctx)
                if ret < 0 {
                    let err = AVERROR(errorCode: ret, context: "swr_init")
                    logger.error(
                        "AudioTrackReader stream \(self.index) loadTrackInfo: Can't initialise resample context for format \(String(cString:av_get_sample_fmt_name(AVSampleFormat(rawValue: params.format))), privacy: .public): \(err.errorDescription, privacy: .public)"
                    )
                    return completionHandler(nil, err)
                }
            }
        }

        // Determine channel layout

        var layoutTag = kAudioChannelLayoutTag_Unknown
        if params.ch_layout.order == AV_CHANNEL_ORDER_NATIVE {
            switch params.ch_layout.u.mask {
            // common cases where FFmpeg channel order matches that expected by an AudioChannelLayoutTag
            case ChannelMasks.AV_CH_LAYOUT_MONO.rawValue:  // FC
                layoutTag = kAudioChannelLayoutTag_Mono
            case ChannelMasks.AV_CH_LAYOUT_STEREO.rawValue:  // FL+FR
                layoutTag = kAudioChannelLayoutTag_Stereo
            case ChannelMasks.AV_CH_LAYOUT_5POINT1.rawValue,  // FL+FR+FC+LFE+SL+SR
                ChannelMasks.AV_CH_LAYOUT_5POINT1_BACK.rawValue:
                layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
            case ChannelMasks.AV_CH_LAYOUT_7POINT1.rawValue,  // FL+FR+FC+LFE+BL+BR+SL+SR
                ChannelMasks.AV_CH_LAYOUT_7POINT1_WIDE.rawValue,
                ChannelMasks.AV_CH_LAYOUT_7POINT1_WIDE_BACK.rawValue:
                layoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
            default:
                // FFmpeg presents channels in order of AVChannel enum, which in general is not the same order
                // that various AudioChannelLayoutTags expect. So describe channels individually below.
                layoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            }
        } else if params.ch_layout.order == AV_CHANNEL_ORDER_CUSTOM {
            // TODO: layoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            logger.error("AudioTrackReader stream \(self.index) loadTrackInfo: unhandled custom channel layout")
        } else if params.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            // AVFoundation won't play with unknown layout, so make some assumptions
            logger.warning("AudioTrackReader stream \(self.index) loadTrackInfo: unspecified channel layout")
            switch params.ch_layout.nb_channels {
            case 1:
                layoutTag = kAudioChannelLayoutTag_Mono
            case 2:
                layoutTag = kAudioChannelLayoutTag_Stereo
            case 6:
                layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
            case 8:
                layoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
            default:
                logger.error(
                    "AudioTrackReader stream \(self.index) loadTrackInfo: can't guess layout for \(params.ch_layout.nb_channels) channels"
                )
            }
        }

        // This is messy because descriptions must be contained in a contiguous array after the other AudioChannelLayout fields.
        let layoutSize =
            layoutTag != kAudioChannelLayoutTag_UseChannelDescriptions
            ? MemoryLayout<AudioChannelLayout>.size
            : MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)! + Int(params.ch_layout.nb_channels)
                * MemoryLayout<AudioChannelDescription>.stride
        let layoutPtr = UnsafeMutableRawPointer.allocate(
            byteCount: layoutSize,
            alignment: MemoryLayout<AudioChannelLayout>.alignment
        )
        defer { layoutPtr.deallocate() }
        layoutPtr.initializeMemory(as: UInt8.self, to: 0)  // zero unused fields
        var layout = layoutPtr.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        layout.mChannelLayoutTag = layoutTag

        // populate descriptions
        if layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let descriptionPtr = layoutPtr.advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                .bindMemory(to: AudioChannelDescription.self, capacity: Int(params.ch_layout.nb_channels))
            var channel_number = 0
            var channel_mask: UInt64 = 1
            while true {
                if (params.ch_layout.u.mask & channel_mask) != 0 {
                    descriptionPtr.advanced(by: channel_number).pointee.mChannelLabel =
                        AudioTrackReader.channelLabels[params.ch_layout.u.mask & channel_mask]
                        ?? kAudioChannelLabel_Unknown
                    channel_number = channel_number + 1
                }
                if channel_mask & ChannelMasks.AV_CH_BINAURAL_RIGHT.rawValue != 0 { break }
                channel_mask = channel_mask << 1
            }
            layout.mNumberChannelDescriptions = UInt32(channel_number)
            assert(channel_number == Int(params.ch_layout.nb_channels))
        }

        // See definitions at https://developer.apple.com/documentation/CoreAudioTypes/AudioStreamBasicDescription#overview
        //   sample = a single value for a single channel
        //   frame = set of time-coincident samples for all channels in the stream e.g. 2 samples for a stereo channel
        // From CoreAudioBaseTypes.h:
        //   "In uncompressed audio, a Packet is one frame", "In compressed audio, a Packet is an indivisible chunk of compressed data"
        //   "In non-interleaved [=planar] audio, the per frame fields identify one channel".
        //
        // 3 cases:
        //   - Audio that CoreMedia doesn't understand - uncompressed=true, decoding=true
        //     * Get FFmpeg to decode, and supply the uncompressed LPCM data via AudioSampleCursor
        //   - Uncompressed audio that macOS understands - uncompressed=true, decoding=false
        //     * Supply the uncompressed data via AudioPassthruSampleCursor
        //   - Compressed audio that macOS understands - uncompressed=false, decoding=false
        //     * Supply the compressed data via AudioPassthruSampleCursor
        //
        let uncompressed = [kAudioFormatLinearPCM, kAudioFormatALaw, kAudioFormatULaw].contains(formatID)
        let lossless = [kAudioFormatAppleLossless, kAudioFormatFLAC].contains(formatID)
        let bigEndian = [
            AV_CODEC_ID_PCM_S16BE, AV_CODEC_ID_PCM_S24BE, AV_CODEC_ID_PCM_S32BE, AV_CODEC_ID_PCM_S64BE, AV_CODEC_ID_PCM_F32BE,
            AV_CODEC_ID_PCM_F64BE,
        ].contains(params.codec_id)
        let decoding = dec_ctx != nil
        let outFmt: AVSampleFormat = swr_ctx?.pointee.out_sample_fmt ?? dec_ctx?.pointee.sample_fmt ?? AVSampleFormat(params.format)
        let bytesPerSample = UInt32(
            decoding
                ? av_get_bytes_per_sample(outFmt)  // size of the decoded samples
                : av_get_bits_per_sample(params.codec_id) >> 3  // 0 for compressed formats, 1 for aLaw/uLaw, 1,2,3,4 or 8 for PCM
        )
        let validBits = UInt32(
            decoding
                ? (dec_ctx!.pointee.bits_per_raw_sample > 0 ? UInt32(dec_ctx!.pointee.bits_per_raw_sample) : bytesPerSample << 3)
                : (params.bits_per_raw_sample > 0 ? UInt32(params.bits_per_raw_sample) : bytesPerSample << 3)
        )
        if formatID == kAudioFormatLinearPCM && AudioTrackReader.formatFlags[outFmt] == nil {
            logger.error(
                "AudioTrackReader stream \(self.index) loadTrackInfo: Unhandled sample format \(av_get_sample_fmt_name(AVSampleFormat(params.format)) != nil ? String(cString:av_get_sample_fmt_name(AVSampleFormat(params.format))) : String(outFmt.rawValue), privacy: .public)"
            )
            return completionHandler(nil, MEError(.unsupportedFeature))
        }
        let flags =
            lossless
            ? AudioTrackReader.losslessFormatFlags[
                Int(params.bits_per_raw_sample > 0 ? params.bits_per_raw_sample : av_get_bytes_per_sample(outFmt) << 3)
            ] ?? 0
            : (formatID == kAudioFormatLinearPCM
                ? AudioTrackReader.formatFlags[outFmt]!
                    | (bytesPerSample << 3 == validBits ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsAlignedHigh)
                    | (bigEndian ? kAudioFormatFlagIsBigEndian : 0)
                : 0)
        let planar = (AudioTrackReader.formatFlags[outFmt]! & kAudioFormatFlagIsNonInterleaved) != 0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(params.sample_rate),
            mFormatID: formatID!,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerSample * UInt32(planar ? 1 : params.ch_layout.nb_channels),  // "To indicate variable packet size, set this field to 0"
            mFramesPerPacket: UInt32(uncompressed ? 1 : params.frame_size),  // "In uncompressed audio, a Packet is one frame"
            mBytesPerFrame: bytesPerSample * UInt32(planar ? 1 : params.ch_layout.nb_channels),  // "Set this field to 0 for compressed formats"
            mChannelsPerFrame: UInt32(params.ch_layout.nb_channels),
            mBitsPerChannel: uncompressed ? validBits : 0,  // "Set the number of bits to 0 for compressed formats"
            mReserved: 0
        )
        let codecName = CodecName.name(params: &params)
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: layoutSize,
            layout: &layout,
            magicCookieSize: params.extradata_size > 2 ? Int(params.extradata_size) : 0,
            magicCookie: params.extradata,
            extensions: codecName != nil
                ? [kCMFormatDescriptionExtension_FormatName as CFString: codecName! as CFString] as CFDictionary : nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else {
            let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            logger.error(
                "AudioTrackReader stream \(self.index) loadTrackInfo CMAudioFormatDescriptionCreate returned \(err, privacy:.public)"
            )
            return completionHandler(nil, err)
        }
        logger.debug(
            "AudioTrackReader stream \(self.index) loadTrackInfo enabled:\(self.isEnabled) format:\(String(describing: self.formatDescription!), privacy: .public)"
        )
        let trackInfo = METrackInfo(
            __mediaType: kCMMediaType_Audio,
            trackID: CMPersistentTrackID(index + 1),  // trackIDs can't be zero
            formatDescriptions: [formatDescription!]
        )
        trackInfo.isEnabled = isEnabled
        trackInfo.naturalTimescale = stream.pointee.time_base.den
        if let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0),
            let lvalue = String(validatingUTF8: entry.pointee.value)?.lowercased(),
            lvalue != "" && lvalue != "und" && lvalue != "unk"
        {
            trackInfo.extendedLanguageTag = Locale.canonicalLanguageIdentifier(from: lvalue)
        }

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
                "AudioTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public)"
            )
        }
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor =
                dec_ctx != nil
                ? try AudioSampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: presentationTimeStamp
                )
                : try AudioPassthruSampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: presentationTimeStamp
                )
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "AudioTrackReader stream \(self.index) generateSampleCursor atPresentationTimeStamp \(presentationTimeStamp, privacy: .public): \(error, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtFirstSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("AudioTrackReader stream \(self.index) generateSampleCursorAtFirstSampleInDecodeOrder")
        }
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor =
                dec_ctx != nil
                ? try AudioSampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: stream.pointee.start_time != AV_NOPTS_VALUE
                        ? CMTime(value: stream.pointee.start_time, timeBase: stream.pointee.time_base) : .zero
                )
                : try AudioPassthruSampleCursor(
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
                "AudioTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtFirstSampleInDecodeOrder: \(error, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

    func generateSampleCursorAtLastSampleInDecodeOrder(
        completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
    ) {
        if TRACE_SAMPLE_CURSOR {
            logger.debug("AudioTrackReader stream \(self.index) generateSampleCursorAtLastSampleInDecodeOrder")
        }
        guard let format = format else { return completionHandler(nil, MEError(.internalFailure)) }
        do {
            let cursor =
                dec_ctx != nil
                ? try AudioSampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: .positiveInfinity
                )
                : try AudioPassthruSampleCursor(
                    format: format,
                    track: self,
                    index: index,
                    atPresentationTimeStamp: .positiveInfinity
                )
            sampleCursors.add(cursor)
            return completionHandler(cursor, nil)
        } catch {
            logger.error(
                "AudioTrackReader stream \(self.index) generateSampleCursor generateSampleCursorAtLastSampleInDecodeOrder: \(error, privacy: .public)"
            )
            return completionHandler(nil, error)
        }
    }

}
