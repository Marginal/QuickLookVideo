//
//  colormapping.swift
//  QLVideo
//
//  Maps between FFmpeg's AVColor* and CoreMedia's kCMFormatDescription*/kCVImageBuffer*
//  kCMFormatDescription* values are #defined as being the same as kCVImageBuffer* so we can use them interchangeably
//
// TODO: Should add field order for interlaced video, but it's confusing - https://ffmpeg.org/pipermail/ffmpeg-devel/2024-April/326213.html
//

import CoreMedia

class FFmpegToCM {

    static let colorRange: [AVColorRange: CFBoolean] = [
        AVCOL_RANGE_MPEG: kCFBooleanFalse,
        AVCOL_RANGE_JPEG: kCFBooleanTrue,
    ]

    // see av_map_videotoolbox_color_primaries_from_av()
    static let primaries: [AVColorPrimaries: CFString] = [
        AVCOL_PRI_BT709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        AVCOL_PRI_BT470M: kCMFormatDescriptionColorPrimaries_SMPTE_C,
        AVCOL_PRI_BT470BG: kCMFormatDescriptionColorPrimaries_EBU_3213,
        AVCOL_PRI_SMPTE170M: kCVImageBufferColorPrimaries_SMPTE_C,
        AVCOL_PRI_SMPTE240M: kCVImageBufferColorPrimaries_SMPTE_C,
        AVCOL_PRI_FILM: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,  // Using BT.709 as fallback
        AVCOL_PRI_BT2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
        AVCOL_PRI_SMPTE428: kCMFormatDescriptionColorPrimaries_SMPTE_C,  // Using SMPTE C as fallback
        AVCOL_PRI_SMPTE431: kCMFormatDescriptionColorPrimaries_DCI_P3,
        AVCOL_PRI_SMPTE432: kCMFormatDescriptionColorPrimaries_P3_D65,
        AVCOL_PRI_JEDEC_P22: kCMFormatDescriptionColorPrimaries_P22,
    ]

    static let transfer: [AVColorTransferCharacteristic: CFString] = [
        AVCOL_TRC_BT709: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        AVCOL_TRC_GAMMA22: kCVImageBufferTransferFunction_UseGamma,
        AVCOL_TRC_GAMMA28: kCVImageBufferTransferFunction_UseGamma,
        AVCOL_TRC_SMPTE170M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
        AVCOL_TRC_SMPTE240M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
        AVCOL_TRC_LINEAR: kCMFormatDescriptionTransferFunction_Linear,
        // AVCOL_TRC_LOG
        // AVCOL_TRC_LOG_SQRT
        AVCOL_TRC_IEC61966_2_4: kCMFormatDescriptionTransferFunction_sRGB,  // closest available
        // AVCOL_TRC_BT1361_ECG
        AVCOL_TRC_IEC61966_2_1: kCMFormatDescriptionTransferFunction_sRGB,
        AVCOL_TRC_BT2020_10: kCMFormatDescriptionTransferFunction_ITU_R_2020,
        AVCOL_TRC_BT2020_12: kCMFormatDescriptionTransferFunction_ITU_R_2020,
        AVCOL_TRC_SMPTE2084: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
        AVCOL_TRC_SMPTE428: kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1,
        AVCOL_TRC_ARIB_STD_B67: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
    ]

    static let matrix: [AVColorSpace: CFString] = [
        // AVCOL_SPC_RGB // n/a
        AVCOL_SPC_BT709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        AVCOL_SPC_FCC: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,  // close enough
        AVCOL_SPC_BT470BG: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE170M: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
        AVCOL_SPC_SMPTE240M: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995,
        // AVCOL_SPC_YCGCO
        AVCOL_SPC_BT2020_NCL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        AVCOL_SPC_BT2020_CL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            // AVCOL_SPC_SMPTE2085
            // AVCOL_SPC_CHROMA_DERIVED_NCL
            // AVCOL_SPC_CHROMA_DERIVED_CL
            // AVCOL_SPC_ICTCP
            // AVCOL_SPC_IPT_C2
            // AVCOL_SPC_YCGCO_RE
            // AVCOL_SPC_YCGCO_RO
    ]

    static let location: [AVChromaLocation: CFString] = [
        AVCHROMA_LOC_LEFT: kCMFormatDescriptionChromaLocation_Left,
        AVCHROMA_LOC_CENTER: kCMFormatDescriptionChromaLocation_Center,
        AVCHROMA_LOC_TOP: kCMFormatDescriptionChromaLocation_Top,
        AVCHROMA_LOC_BOTTOM: kCMFormatDescriptionChromaLocation_Bottom,
        AVCHROMA_LOC_TOPLEFT: kCMFormatDescriptionChromaLocation_TopLeft,
        AVCHROMA_LOC_BOTTOMLEFT: kCMFormatDescriptionChromaLocation_BottomLeft,
    ]
}

class CMToFFmpeg {

    static let colorRange: [CFBoolean: AVColorRange] = [
        kCFBooleanFalse: AVCOL_RANGE_MPEG,
        kCFBooleanTrue: AVCOL_RANGE_JPEG,
    ]

    static let primaries: [CFString: AVColorPrimaries] = [
        kCMFormatDescriptionColorPrimaries_ITU_R_709_2: AVCOL_PRI_BT709,
        kCMFormatDescriptionColorPrimaries_EBU_3213: AVCOL_PRI_BT470BG,
        kCMFormatDescriptionColorPrimaries_SMPTE_C: AVCOL_PRI_SMPTE240M,
        kCMFormatDescriptionColorPrimaries_DCI_P3: AVCOL_PRI_SMPTE431,
        kCMFormatDescriptionColorPrimaries_P3_D65: AVCOL_PRI_SMPTE432,
        kCMFormatDescriptionColorPrimaries_ITU_R_2020: AVCOL_PRI_BT2020,
        kCMFormatDescriptionColorPrimaries_P22: AVCOL_PRI_JEDEC_P22,
    ]

    static let transfer: [CFString: AVColorTransferCharacteristic] = [
        kCMFormatDescriptionTransferFunction_ITU_R_709_2: AVCOL_TRC_BT709,
        kCMFormatDescriptionTransferFunction_SMPTE_240M_1995: AVCOL_TRC_SMPTE240M,
        kCMFormatDescriptionTransferFunction_UseGamma: AVCOL_TRC_GAMMA22,
        kCMFormatDescriptionTransferFunction_ITU_R_2020: AVCOL_TRC_BT2020_10,
        kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1: AVCOL_TRC_SMPTE428,
        kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ: AVCOL_TRC_SMPTE2084,
        kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG: AVCOL_TRC_ARIB_STD_B67,
        kCMFormatDescriptionTransferFunction_Linear: AVCOL_TRC_LINEAR,
        kCMFormatDescriptionTransferFunction_sRGB: AVCOL_TRC_IEC61966_2_1,
    ]

    static let matrix: [CFString: AVColorSpace] = [
        kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2: AVCOL_SPC_BT709,
        kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4: AVCOL_SPC_SMPTE170M,
        kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995: AVCOL_SPC_SMPTE240M,
        kCMFormatDescriptionYCbCrMatrix_ITU_R_2020: AVCOL_SPC_BT2020_NCL,
    ]

    static let location: [CFString: AVChromaLocation] = [
        kCMFormatDescriptionChromaLocation_Left: AVCHROMA_LOC_LEFT,
        kCMFormatDescriptionChromaLocation_Center: AVCHROMA_LOC_CENTER,
        kCMFormatDescriptionChromaLocation_TopLeft: AVCHROMA_LOC_TOPLEFT,
        kCMFormatDescriptionChromaLocation_Top: AVCHROMA_LOC_TOP,
        kCMFormatDescriptionChromaLocation_BottomLeft: AVCHROMA_LOC_BOTTOMLEFT,
        kCMFormatDescriptionChromaLocation_Bottom: AVCHROMA_LOC_BOTTOM,
            // kCMFormatDescriptionChromaLocation_DV420 // "Cr and Cb samples are alternately co-sited with the left luma samples of the same field"
    ]
}
