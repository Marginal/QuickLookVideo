//
//  videodecoder-hdr.swift
//  QLVideo
//
//  HDR passthrough: convert planar YUV 10/12/16-bit frames to biplanar P010 CVPixelBuffers
//  with HDR metadata attachments, letting macOS handle display-adaptive tone mapping.
//

import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

extension VideoDecoder {

    // Planar YUV formats supported by hdrConvertToBiPlanar for HDR passthrough.
    // All input formats are converted to 10-bit biplanar for macOS display pipeline.
    private static let hdrFormats: Set<Int32> = [
        AV_PIX_FMT_P010LE.rawValue,
        AV_PIX_FMT_YUV420P9LE.rawValue,
        AV_PIX_FMT_YUV420P10LE.rawValue,
        AV_PIX_FMT_YUV420P12LE.rawValue,
        AV_PIX_FMT_YUV420P16LE.rawValue,
        AV_PIX_FMT_YUV422P9LE.rawValue,
        AV_PIX_FMT_YUV422P10LE.rawValue,
        AV_PIX_FMT_YUV422P12LE.rawValue,
        AV_PIX_FMT_YUV422P16LE.rawValue,
        AV_PIX_FMT_YUV444P9LE.rawValue,
        AV_PIX_FMT_YUV444P10LE.rawValue,
        AV_PIX_FMT_YUV444P12LE.rawValue,
        AV_PIX_FMT_YUV444P16LE.rawValue,
    ]

    // Build the HDR version of a PixelBufferConfig. Called from makePixelBufferConfig() in videodecoder.swift
    func hdrPixelBufferConfig() -> PixelBufferConfig? {
        // Must be a supported planar format and HDR (PQ or HLG transfer function)
        guard let pixelBufferKey, VideoDecoder.hdrFormats.contains(pixelBufferKey.format),
            pixelBufferKey.colorTrc == AVCOL_TRC_SMPTE2084 || pixelBufferKey.colorTrc == AVCOL_TRC_ARIB_STD_B67
        else {
            return nil
        }

        // Luma/component bit depth (use first component's depth as representative)
        guard let descPtr = av_pix_fmt_desc_get(AVPixelFormat(pixelBufferKey.format)) else { return nil }
        let bitDepth = UInt32(descPtr.pointee.comp.0.depth)

        // Chroma subsampling
        var hshift: Int32 = 0
        var vshift: Int32 = 0
        av_pix_fmt_get_chroma_sub_sample(AVPixelFormat(pixelBufferKey.format), &hshift, &vshift)

        // Map subsampling to a 10-bit biplanar CVPixelFormat type.
        let pixelFormat: OSType
        switch (hshift, vshift) {
        case (1, 1):  // 4:2:0 AV_PIX_FMT_P010 or AV_PIX_FMT_YUV420Pxx -> x420/xf20
            pixelFormat =
                pixelBufferKey.colorRange == AVCOL_RANGE_JPEG
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (1, 0):  // 4:2:2 AV_PIX_FMT_YUV422Pxx -> x422/xf22
            pixelFormat =
                pixelBufferKey.colorRange == AVCOL_RANGE_JPEG
                ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case (0, 0):  // 4:4:4 AV_PIX_FMT_YUV444Pxx -> x444/xf44
            pixelFormat =
                pixelBufferKey.colorRange == AVCOL_RANGE_JPEG
                ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        default:  // Unsupported subsampling for biplanar 10-bit
            return nil
        }

        // Build propagated attachments from the frame's color properties
        var attachments: [String: Any] = [:]
        if let primaries = av_map_videotoolbox_color_primaries_from_av(pixelBufferKey.colorPrimaries) {
            attachments[kCVImageBufferColorPrimariesKey as String] = primaries.takeRetainedValue()
        }
        if let transfer = av_map_videotoolbox_color_trc_from_av(pixelBufferKey.colorTrc) {
            attachments[kCVImageBufferTransferFunctionKey as String] = transfer.takeRetainedValue()
        }
        if let matrix = av_map_videotoolbox_color_matrix_from_av(pixelBufferKey.colorspace) {
            attachments[kCVImageBufferYCbCrMatrixKey as String] = matrix.takeRetainedValue()
        }
        if let chromaLoc = av_map_videotoolbox_chroma_loc_from_av(pixelBufferKey.chromaLocation) {
            attachments[kCVImageBufferChromaLocationTopFieldKey as String] = chromaLoc.takeRetainedValue()
        }

        // Pass through pixel aspect ratio from the CMFormatDescription so the display system handles anamorphic stretch
        if let sar = formatDescription.extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? [CFString: NSNumber],
            let num = sar[kCVImageBufferPixelAspectRatioHorizontalSpacingKey],
            let den = sar[kCVImageBufferPixelAspectRatioVerticalSpacingKey],
            num != den
        {
            attachments[kCVImageBufferPixelAspectRatioKey as String] = sar
        }

        // Add mastering display, content light level, and ambient viewing environment metadata
        if let mdmBytes = pixelBufferKey.mdmBytes {
            mdmBytes.withUnsafeBytes { raw in
                if let mdm = raw.bindMemory(to: AVMasteringDisplayMetadata.self).baseAddress,
                    let bytes = VideoDecoder.serializeMasteringDisplayMetadata(mdm.pointee)
                {
                    attachments[kCVImageBufferMasteringDisplayColorVolumeKey as String] = bytes
                }
            }
        }
        if let cllBytes = pixelBufferKey.cllBytes {
            cllBytes.withUnsafeBytes { raw in
                if let cll = raw.bindMemory(to: AVContentLightMetadata.self).baseAddress,
                    let bytes = VideoDecoder.serializeContentLightLevel(cll.pointee)
                {
                    attachments[kCVImageBufferContentLightLevelInfoKey as String] = bytes
                }
            }
        }
        if let aveBytes = pixelBufferKey.aveBytes {
            aveBytes.withUnsafeBytes { raw in
                if let ave = raw.bindMemory(to: AVAmbientViewingEnvironment.self).baseAddress,
                    let bytes = VideoDecoder.serializeAmbientViewingEnvironment(ave.pointee)
                {
                    attachments[kCVImageBufferAmbientViewingEnvironmentKey as String] = bytes
                }
            }
        }

        return PixelBufferConfig(
            pixelBufferAttributes: [
                kCVPixelBufferWidthKey as String: pixelBufferKey.width as CFNumber,
                kCVPixelBufferHeightKey as String: pixelBufferKey.height as CFNumber,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64 as CFNumber,
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as CFBoolean,
                kCVBufferPropagatedAttachmentsKey as String: attachments,
            ],
            bitDepth: bitDepth,
            uvShiftX: UInt32(hshift),
            uvShiftY: UInt32(vshift)
        )
    }

    // Convert a planar YUV 10/12/16-bit AVFrame to a biplanar 10-bit CVPixelBuffer.
    // Significant bits are left-justified in a 16-bit container (top 10 bits, bottom 6 bits zero).
    // Do this on the CPU since the source data is on the CPU, and the GPU will be busy doing color conversion and tonemapping
    func hdrConvertToBiPlanar(frame: UnsafePointer<AVFrame>, pixelBuffer: CVPixelBuffer) -> Error? {

        guard let config = pixelBufferConfig, config.isHDR else {
            return CVReturnError(errorCode: Int(kCVReturnUnsupported), context: "hdrConvertToBiPlanar")
        }

        let srcWidth = Int(frame.pointee.width)
        let srcHeight = Int(frame.pointee.height)
        let uvWidth = srcWidth >> Int(config.uvShiftX)
        let uvHeight = srcHeight >> Int(config.uvShiftY)

        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            return CVReturnError(errorCode: Int(status), context: "CVPixelBufferLockBaseAddress")
        }

        // Frame is already biplanar P010. Just copy it.
        if frame.pointee.format == AV_PIX_FMT_P010LE.rawValue {
            // Copy Y plane rows
            let srcYBase = UnsafeRawPointer(frame.pointee.data.0!)
            let srcYStride = Int(frame.pointee.linesize.0)
            let dstYBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for row in 0..<srcHeight {
                let srcPtr = UnsafeRawPointer(srcYBase).advanced(by: row * srcYStride)
                let dstPtr = dstYBase.advanced(by: row * dstYStride)
                memcpy(dstPtr, srcPtr, Swift.min(srcYStride, dstYStride))
            }

            // Copy interleaved UV plane rows
            let srcUVBase = UnsafeRawPointer(frame.pointee.data.1!)
            let srcUVStride = Int(frame.pointee.linesize.1)
            let dstUVBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            let dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            for row in 0..<uvHeight {
                let srcPtr = UnsafeRawPointer(srcUVBase).advanced(by: row * srcUVStride)
                let dstPtr = dstUVBase.advanced(by: row * dstUVStride)
                memcpy(dstPtr, srcPtr, Swift.min(srcUVStride, dstUVStride))
            }

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return nil
        }

        // Calculate the bit shift to convert source bit depth to P010's left-justified 10-bit layout.
        // P010: 10 significant bits in bits [15:6], bottom 6 bits zero.
        // Net shift = 16 - bitDepth (always left shift, or no shift for 16-bit).
        // Source 10-bit: value in bits [9:0]  -> shift left by 6
        // Source 12-bit: value in bits [11:0] -> shift left by 4 (loses 2 LSBs)
        // Source 16-bit: value in bits [15:0] -> no shift (loses 6 LSBs)
        let shift = 16 - Int(config.bitDepth)

        // -- Y plane: shift-copy from AVFrame plane 0 to CVPixelBuffer plane 0 --
        let srcYPtr = UnsafeMutableRawPointer(frame.pointee.data.0!).assumingMemoryBound(to: UInt16.self)
        let srcYStride = Int(frame.pointee.linesize.0) / MemoryLayout<UInt16>.size
        let dstYPtr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / MemoryLayout<UInt16>.size
        hdr_shift_copy(
            srcYPtr,
            dstYPtr,
            Int32(srcWidth),
            Int32(srcYStride),
            Int32(dstYStride),
            Int32(srcHeight),
            Int32(shift)
        )

        // -- CbCr plane: shift and interleave from AVFrame planes 1,2 to CVPixelBuffer plane 1 --
        let srcCbStride: Int =
            withUnsafePointer(to: frame.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 2) { Int($0[1]) }
            } / MemoryLayout<UInt16>.size
        let srcCrStride: Int =
            withUnsafePointer(to: frame.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 3) { Int($0[2]) }
            } / MemoryLayout<UInt16>.size
        let srcCbPtr = UnsafeMutableRawPointer(frame.pointee.data.1!).assumingMemoryBound(to: UInt16.self)
        let srcCrPtr = UnsafeMutableRawPointer(frame.pointee.data.2!).assumingMemoryBound(to: UInt16.self)
        let dstCbCrPtr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt16.self)
        let dstCbCrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / MemoryLayout<UInt16>.size
        hdr_interleave_and_shift(
            srcCbPtr,
            srcCrPtr,
            dstCbCrPtr,
            Int32(uvWidth),
            Int32(srcCbStride),
            Int32(srcCrStride),
            Int32(dstCbCrStride),
            Int32(uvHeight),
            Int32(shift)
        )
        #if false
            logger.debug(
                "Input  #\(Int(frame.pointee.pts/1000)) y=\(frame.pointee.data.0!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }), u=\(frame.pointee.data.1!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }), v=\(frame.pointee.data.2!.withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee })"
            )
            logger.debug(
                "Output #\(Int(frame.pointee.pts/1000)) y=\(dstYPtr[0]) Cb=\(dstCbCrPtr[0]) Cr=\(dstCbCrPtr[1])"
            )
        #endif

        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return nil
    }

    // Serialize AVMasteringDisplayMetadata to 24 bytes big-endian matching HEVC SEI D.2.28, or nil if empty.
    //   display_primaries[3][2] in G,B,R order (uint16, units of 0.00002)
    //   white_point[2] (uint16, units of 0.00002)
    //   max_display_mastering_luminance (uint32, units of 0.0001 cd/m²)
    //   min_display_mastering_luminance (uint32, units of 0.0001 cd/m²)
    private static func serializeMasteringDisplayMetadata(_ mdm: AVMasteringDisplayMetadata) -> Data? {
        guard mdm.has_primaries != 0 || mdm.has_luminance != 0 else { return nil }

        var bytes = Data(count: 24)
        bytes.withUnsafeMutableBytes { buf in
            let u16 = buf.baseAddress!.assumingMemoryBound(to: UInt16.self)

            // Primaries in G, B, R order per HEVC SEI D.2.28.
            // FFmpeg stores as R=0, G=1, B=2, so (idx+1)%3 maps output 0,1,2 to FFmpeg's G=1, B=2, R=0.
            for idx in 0..<3 {
                let i = (idx + 1) % 3
                let primaries = withUnsafePointer(to: mdm.display_primaries) {
                    $0.withMemoryRebound(to: AVRational.self, capacity: 6) { p in
                        (p[i * 2], p[i * 2 + 1])
                    }
                }
                u16[idx * 2] = UInt16(clamping: Int(av_q2d(primaries.0) * 50000.0 + 0.5)).bigEndian
                u16[idx * 2 + 1] = UInt16(clamping: Int(av_q2d(primaries.1) * 50000.0 + 0.5)).bigEndian
            }

            // White point
            u16[6] = UInt16(clamping: Int(av_q2d(mdm.white_point.0) * 50000.0 + 0.5)).bigEndian
            u16[7] = UInt16(clamping: Int(av_q2d(mdm.white_point.1) * 50000.0 + 0.5)).bigEndian

            // Luminance (units of 0.0001 cd/m²)
            let u32 = buf.baseAddress!.assumingMemoryBound(to: UInt32.self)
            u32[4] = UInt32(clamping: Int64(av_q2d(mdm.max_luminance) * 10000.0 + 0.5)).bigEndian
            u32[5] = UInt32(clamping: Int64(av_q2d(mdm.min_luminance) * 10000.0 + 0.5)).bigEndian
        }
        return bytes
    }

    // Serialize AVContentLightMetadata to 4 bytes big-endian matching HEVC SEI content light level info, or nil if empty.
    //   max_content_light_level (uint16)
    //   max_pic_average_light_level (uint16)
    private static func serializeContentLightLevel(_ cll: AVContentLightMetadata) -> Data? {
        guard cll.MaxCLL > 0 || cll.MaxFALL > 0 else { return nil }

        var bytes = Data(count: 4)
        bytes.withUnsafeMutableBytes { buf in
            let u16 = buf.baseAddress!.assumingMemoryBound(to: UInt16.self)
            u16[0] = UInt16(clamping: cll.MaxCLL).bigEndian
            u16[1] = UInt16(clamping: cll.MaxFALL).bigEndian
        }
        return bytes
    }

    // Serialize AVAmbientViewingEnvironment to 8 bytes big-endian matching Ambient Viewing Environment SEI payload, or nil if empty.
    //   ambient_illuminance (uint32, units of 0.0001 lux)
    //   ambient_light_x (uint16, units of 0.00002)
    //   ambient_light_y (uint16, units of 0.00002)
    private static func serializeAmbientViewingEnvironment(_ ave: AVAmbientViewingEnvironment) -> Data? {
        let illuminance = UInt32(clamping: Int64(av_q2d(ave.ambient_illuminance) * 10000.0 + 0.5))
        guard illuminance > 0 else { return nil }

        var bytes = Data(count: 8)
        bytes.withUnsafeMutableBytes { buf in
            let u32 = buf.baseAddress!.assumingMemoryBound(to: UInt32.self)
            u32[0] = illuminance.bigEndian
            let u16 = buf.baseAddress!.assumingMemoryBound(to: UInt16.self)
            u16[2] = UInt16(clamping: Int(av_q2d(ave.ambient_light_x) * 50000.0 + 0.5)).bigEndian
            u16[3] = UInt16(clamping: Int(av_q2d(ave.ambient_light_y) * 50000.0 + 0.5)).bigEndian
        }
        return bytes
    }
}
