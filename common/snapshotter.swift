//
//  snapshotter.swift
//
// Some format/codec combinations return EAGAIN from av_receive_frame() on the first frame, which results
// in no thumbnails.
// Some media just happens to have a black frame at the snapshot time.
// Generate pseudo artwork for the thumbnail to handle both cases.
// Assumes that streams are enabled/disabled as they would be when a thumbnail request is made

import Accelerate
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@preconcurrency  // we want this to be able to run off the main thread
class SnapShotter {

    nonisolated(unsafe) let stream: UnsafeMutablePointer<AVStream>
    nonisolated(unsafe) var fmt_ctx: UnsafeMutablePointer<AVFormatContext>?
    nonisolated(unsafe) var dec_ctx: UnsafeMutablePointer<AVCodecContext>?
    nonisolated(unsafe) let sws_ctx: UnsafeMutablePointer<SwsContext>?
    let srcWidth: Int32
    let srcHeight: Int32
    let dstWidth: Int32
    let dstHeight: Int32
    let isHDR: Bool
    let duration: Double

    init?(fmt_ctx: UnsafeMutablePointer<AVFormatContext>, stream: UnsafeMutablePointer<AVStream>) {
        self.fmt_ctx = fmt_ctx
        self.stream = stream

        // Set up decode context
        let params = stream.pointee.codecpar!
        guard let codec = avcodec_find_decoder(params.pointee.codec_id) else { return nil }
        dec_ctx = avcodec_alloc_context3(codec)
        if dec_ctx == nil { return nil }
        var ret = avcodec_parameters_to_context(dec_ctx, stream.pointee.codecpar!)
        if ret < 0 { return nil }

        if params.pointee.codec_id != AV_CODEC_ID_AV1 {  // dav1d effectively only supports frame slicing, and with a delay
            dec_ctx!.pointee.thread_type = FF_THREAD_SLICE  // since (hopefully) we're only decoding one frame
            var len = MemoryLayout.size(ofValue: dec_ctx!.pointee.thread_count)
            // Get number of *performance* cores /usr/include/sys/sysctl.h
            if sysctlbyname("hw.perflevel0.logicalcpu", &dec_ctx!.pointee.thread_count, &len, nil, 0) != 0 {
                dec_ctx!.pointee.thread_count = 0  // auto
            }
        }
        ret = avcodec_open2(dec_ctx, codec, nil)
        if ret < 0 { return nil }

        // Set up for conversion

        // Logic abbrevated from fixupColors()
        isHDR =
            dec_ctx!.pointee.color_trc == AVCOL_TRC_SMPTE2084 || dec_ctx!.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67
            || av_packet_side_data_get(
                params.pointee.coded_side_data,
                params.pointee.nb_coded_side_data,
                AV_PKT_DATA_MASTERING_DISPLAY_METADATA
            ) != nil
            || av_packet_side_data_get(
                params.pointee.coded_side_data,
                params.pointee.nb_coded_side_data,
                AV_PKT_DATA_CONTENT_LIGHT_LEVEL
            ) != nil
            || av_packet_side_data_get(
                params.pointee.coded_side_data,
                params.pointee.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF
            ) != nil

        srcWidth = dec_ctx!.pointee.width
        srcHeight = dec_ctx!.pointee.height
        let sar = av_guess_sample_aspect_ratio(fmt_ctx, &stream.pointee, nil)
        if sar.num != 0 && (sar.num != 1 || sar.den != 1) {
            dstWidth = Int32(av_rescale_rnd(Int64(srcWidth), Int64(sar.num), Int64(sar.den), AV_ROUND_NEAR_INF))
        } else {
            dstWidth = srcWidth
        }
        dstHeight = srcHeight

        sws_ctx = sws_getContext(
            srcWidth,
            srcHeight,
            dec_ctx!.pointee.pix_fmt,
            dstWidth,
            dstHeight,
            isHDR ? AV_PIX_FMT_X2RGB10LE : AV_PIX_FMT_BGRA,
            Int32(SWS_BICUBIC.rawValue | SWS_FULL_CHR_H_INT.rawValue),
            nil,
            nil,
            nil
        )
        guard sws_ctx != nil else {
            avcodec_free_context(&dec_ctx)
            dec_ctx = nil
            return nil
        }
        duration =
            fmt_ctx.pointee.duration > 0
            ? Double(fmt_ctx.pointee.duration) / Double(AV_TIME_BASE)
            : Double(stream.pointee.duration) * av_q2d(stream.pointee.time_base)
    }

    deinit {
        sws_freeContext(sws_ctx)
        avcodec_free_context(&dec_ctx)
    }

    nonisolated func generateSnapshot(snapshotTime: Double) -> CGImage? {

        assert(snapshotTime <= 1)
        let timed_thumbnails = snapshotTime < 0

        // Decoded image
        var dstStride = (4 * dstWidth + 63) & ~63
        let dstByteCount = Int(dstHeight * dstStride)
        guard let dstData = CFDataCreateMutable(kCFAllocatorDefault, dstByteCount) else { return nil }
        CFDataSetLength(dstData, dstByteCount)  // ensure its allocated
        var dstPlane0: UnsafeMutablePointer<UInt8>? = CFDataGetMutableBytePtr(dstData)

        var pkt = av_packet_alloc()
        guard pkt != nil else { return nil }
        defer { av_packet_free(&pkt) }
        var frame = av_frame_alloc()
        guard frame != nil else { return nil }
        defer { av_frame_free(&frame) }

        for lumaThreshold in [0.125, 0.0625] {  // Try to get a decently bright image, or at least not a terrible one
            // Seek to snapshot time
            if timed_thumbnails {
                // Just take frames as they come
            } else if stream.pointee.duration != AV_NOPTS_VALUE {
                guard
                    avformat_seek_file(
                        fmt_ctx!,
                        stream.pointee.index,
                        Int64.min,
                        Int64((Double(stream.pointee.duration) * snapshotTime).rounded()),
                        Int64.max,
                        0
                    ) >= 0
                else { return nil }
            } else {
                guard
                    avformat_seek_file(
                        fmt_ctx!,
                        -1,
                        Int64.min,
                        Int64((Double(fmt_ctx!.pointee.duration) * snapshotTime).rounded()),
                        Int64.max,
                        0
                    ) >= 0
                else { return nil }
            }
            avcodec_flush_buffers(dec_ctx)

            // demux
            var loopCount = 30  // Give up after this many video frames
            while loopCount > 0 && av_read_frame(fmt_ctx, pkt) >= 0 {
                if pkt!.pointee.stream_index != stream.pointee.index {
                    av_packet_unref(pkt)
                    continue
                }
                loopCount -= 1

                // decode
                guard avcodec_send_packet(dec_ctx, pkt) >= 0 else { continue }  // Can get invalid data after a seek with some older formats. Keep going.
                av_packet_unref(pkt)
                repeat {
                    let ret = avcodec_receive_frame(dec_ctx, frame)
                    if ret == AVERROR_EAGAIN { break }
                    guard ret >= 0 else { return nil }

                    // Convert using native size - macOS will resize to the desired size before caching the result
                    let outHeight = withUnsafePointer(to: &frame!.pointee.linesize) { srcLinesizeTuple in
                        srcLinesizeTuple.withMemoryRebound(to: Int32.self, capacity: Int(AV_NUM_DATA_POINTERS)) {
                            srcLinesizePtr in
                            sws_scale(
                                sws_ctx,
                                UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(frame!.pointee.extended_data)),
                                srcLinesizePtr,
                                0,
                                srcHeight,
                                &dstPlane0,
                                &dstStride
                            )
                        }
                    }
                    guard outHeight > 0 else { return nil }

                    if !timed_thumbnails {
                        // Calculate brightness of centre half of the image
                        let roiX = Int(dstWidth) / 4
                        let roiY = Int(dstHeight) / 4
                        let roiW = max(1, Int(dstWidth) / 2)
                        let roiH = max(1, Int(dstHeight) / 2)

                        // Accumulate R/G/B ignoring alpha
                        var sumR: UInt64 = 0
                        var sumG: UInt64 = 0
                        var sumB: UInt64 = 0
                        if isHDR {
                            dstPlane0?.withMemoryRebound(to: UInt32.self, capacity: dstByteCount / 4) { base in
                                for y in 0..<roiH {
                                    let row = base.advanced(by: (roiY + y) * Int(dstStride) / 4 + roiX)
                                    for x in 0..<Int(roiW) {
                                        let value = row[x]
                                        sumR &+= UInt64((value >> 20) & 0x3FF)
                                        sumG &+= UInt64((value >> 10) & 0x3FF)
                                        sumB &+= UInt64(value & 0x3FF)
                                    }
                                }
                            }
                        } else {
                            for y in 0..<roiH {
                                let rowStart = dstPlane0!.advanced(by: (roiY + y) * Int(dstStride) + roiX * 4)
                                var p = UnsafePointer<UInt8>(rowStart)
                                for _ in 0..<roiW {
                                    sumB &+= UInt64(p[0])
                                    sumG &+= UInt64(p[1])
                                    sumR &+= UInt64(p[2])
                                    p = p.advanced(by: 4)
                                }
                            }
                        }
                        // Average channels and calulate Luma in range 0..1
                        let count = Double(roiW * roiH)
                        let avgR = Double(sumR) / count
                        let avgG = Double(sumG) / count
                        let avgB = Double(sumB) / count
                        let luma =
                            isHDR
                            ? (0.2627 * avgR + 0.6780 * avgG + 0.0593 * avgB) / 1024.0  // BT.2020
                            : (0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB) / 256.0  // BT.709
                        if luma < lumaThreshold || luma >= 1 - lumaThreshold { continue }  // too dark or bright
                    }

                    // wangle into a CGImage
                    let colorSpace: CGColorSpace
                    let bitmapInfo: CGBitmapInfo
                    var headroom = 0.0
                    if isHDR {
                        colorSpace = CGColorSpace(
                            name: dec_ctx!.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67
                                ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_2100_PQ
                        )!
                        bitmapInfo = CGBitmapInfo(
                            alpha: .noneSkipFirst,
                            component: .integer,
                            byteOrder: .order32Little,
                            pixelFormat: .RGB101010
                        )
                        if let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL) {
                            let MaxCLL = sideData.pointee.data.withMemoryRebound(
                                to: AVContentLightMetadata.self,
                                capacity: 1,
                                { return $0.pointee.MaxCLL }
                            )
                            headroom = Double(MaxCLL) / 100.0
                        } else if let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA) {
                            let max_luminance = sideData.pointee.data.withMemoryRebound(
                                to: AVMasteringDisplayMetadata.self,
                                capacity: 1,
                                { return $0.pointee.has_luminance > 0 ? av_q2d($0.pointee.max_luminance) : 0.0 }
                            )
                            headroom = max_luminance / 100.0
                        }
                    } else {
                        colorSpace = CGColorSpaceCreateDeviceRGB()
                        guard let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame!.pointee.format)) else { return nil }
                        if desc.pointee.flags & UInt64(AV_PIX_FMT_FLAG_ALPHA) == 0 {
                            bitmapInfo = CGBitmapInfo(alpha: .noneSkipFirst, component: .integer, byteOrder: .order32Little)
                        } else if frame!.pointee.alpha_mode == AVALPHA_MODE_PREMULTIPLIED {
                            bitmapInfo = CGBitmapInfo(alpha: .premultipliedFirst, component: .integer, byteOrder: .order32Little)
                        } else {
                            bitmapInfo = CGBitmapInfo(alpha: .first, component: .integer, byteOrder: .order32Little)
                        }
                    }
                    guard
                        let provider = CGDataProvider(data: dstData),
                        let image = headroom > 0
                            ? CGImage(
                                headroom: Float(headroom),
                                width: Int(dstWidth),
                                height: Int(dstHeight),
                                bitsPerComponent: isHDR ? 10 : 8,
                                bitsPerPixel: 32,
                                bytesPerRow: Int(dstStride),
                                space: colorSpace,
                                bitmapInfo: bitmapInfo,
                                provider: provider,
                                decode: nil,
                                shouldInterpolate: false,
                                intent: .defaultIntent
                            )
                            : CGImage(
                                width: Int(dstWidth),
                                height: Int(dstHeight),
                                bitsPerComponent: isHDR ? 10 : 8,
                                bitsPerPixel: 32,
                                bytesPerRow: Int(dstStride),
                                space: colorSpace,
                                bitmapInfo: bitmapInfo,
                                provider: provider,
                                decode: nil,
                                shouldInterpolate: false,
                                intent: .defaultIntent
                            )
                    else { return nil }
                    return image
                } while true
            }
        }
        return nil
    }

}
