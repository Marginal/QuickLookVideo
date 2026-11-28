//
//  videotrackreaderdv.swift
//  QLVideo
//
//  Return a Dolby Vision configuration atom, synthesizing from frame side data if necessary
//

import Foundation

extension VideoTrackReader {

    func DolbyVisionConfig() -> UnsafePointer<AVDOVIDecoderConfigurationRecord>? {
        // Determine whether this is actually Dolby Vision within HEVC or AV1
        let params = stream.pointee.codecpar!
        if let sideData = av_packet_side_data_get(
            params.pointee.coded_side_data,
            params.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        ),
           sideData.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        {
            return UnsafeRawPointer(sideData.pointee.data).assumingMemoryBound(
                to: AVDOVIDecoderConfigurationRecord.self
            )
        }
        return nil
    }

    /* Attempts to sythensize the Dolby Vision configuration record from metadata in the first few frames
           have not been successful enough to pursuade VideoToolbox to decode the content.

    // Dolby Vision uses full color range, otherwise give up
    if params.pointee.color_range != AVCOL_RANGE_JPEG { return nil }

    // Look for Dolby Vision RPU or metadata in the first few frames. Fail silently.
    guard let codec = avcodec_find_decoder(params.pointee.codec_id) else { return nil }
    dec_ctx = avcodec_alloc_context3(codec)
    if dec_ctx == nil { return nil }
    if avcodec_parameters_to_context(dec_ctx, params) < 0 { return nil }
    if avcodec_open2(dec_ctx, codec, nil) < 0 { return nil }

    var packet = av_packet_alloc()
    defer { av_packet_free(&packet) }
    var frame = av_frame_alloc()
    defer { av_frame_free(&frame) }

    while av_read_frame(format.fmt_ctx, packet) == 0 {
        defer { av_packet_unref(packet) }
        if packet!.pointee.stream_index != index { continue }
        if avcodec_send_packet(dec_ctx, packet) < 0 { break }
        while avcodec_receive_frame(dec_ctx, frame) == 0 {
            defer { av_frame_unref(frame) }
            guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA) else { continue }
            let metadata = UnsafeRawPointer(sideData.pointee.data).assumingMemoryBound(to: AVDOVIMetadata.self).pointee
            let rpuDataHeader = UnsafeRawPointer(sideData.pointee.data.advanced(by: metadata.header_offset))
                .assumingMemoryBound(to: AVDOVIRpuDataHeader.self).pointee

            // Profile guess taken from ff_dovi_guess_profile_hevc()
            let profile: UInt8 = {
                if params.pointee.codec_id == AV_CODEC_ID_AV1 {
                    return 10
                } else if rpuDataHeader.vdr_rpu_profile == 0 {
                    return 5
                } else if rpuDataHeader.el_spatial_resampling_filter_flag == 1
                    && rpuDataHeader.disable_residual_flag == 0
                {
                    return rpuDataHeader.vdr_bit_depth == 12 ? 7 : 4
                } else {
                    return 8
                }
            }()

            let dovi = AVDOVIDecoderConfigurationRecord(
                dv_version_major: 1,
                dv_version_minor: 0,
                dv_profile: profile,
                dv_level: 0, // unknown
                rpu_present_flag: 1,
                el_present_flag: (profile == 4 || profile == 7) ? 1 : 0,  // Profile 5 is single-layer (no EL)
                bl_present_flag: 1,
                dv_bl_signal_compatibility_id: 0,
                dv_md_compression: 0
            )
            return DolbyVisionAtom(dovi: dovi)
        }
    }

    // Rewind for normal demuxing
    avformat_seek_file(format.fmt_ctx, -1, Int64.min, 0, Int64.max, 0)
    avformat_flush(format.fmt_ctx)
     */

    func DolbyVisionAtom(dovi: AVDOVIDecoderConfigurationRecord) -> (CFString, CFData) {
        let bytes: [UInt8] =
            [
                dovi.dv_version_major,
                dovi.dv_version_minor,
                (dovi.dv_profile << 1) | (dovi.dv_level >> 7),
                (dovi.dv_level << 3) | (dovi.rpu_present_flag << 2) | (dovi.el_present_flag << 1)
                    | dovi.bl_present_flag,
                (dovi.dv_bl_signal_compatibility_id << 4) | (dovi.dv_md_compression << 2),
            ] + Array(repeating: 0, count: 19)
        return (
            (dovi.dv_profile > 10 ? "dvcC" : (dovi.dv_profile > 7 ? "dvvC" : "dvcC")) as CFString,
            CFDataCreate(kCFAllocatorDefault, bytes, CFIndex(bytes.count))
        )
    }

}
