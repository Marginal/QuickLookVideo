//
//  videodecoder-zscale.swift
//
//  Format conversion using zscale filter, including for formats that require HDR tonemapping.
//

import CoreMedia
import CoreVideo
import Foundation
import MediaExtension

// See https://www.ffmpeg.org/doxygen/trunk/filtering_video_8c-example.html

extension VideoDecoder {

    // Convert the decoded frame to GBRP float or 8bit depending on whether it's HDR or SDR, return the new frame
    func zscaleConvertToGBRP(frame: inout UnsafeMutablePointer<AVFrame>, pixelBuffer: inout CVPixelBuffer) -> Error? {

        // frame color fields should already be patched by fixupColors() in decodeFrame

        if filterGraph == nil {
            let error = zscaleSetup(frame: &frame.pointee, pixelBuffer: &pixelBuffer)
            guard error == nil else { return error! }
        }

        /* push the decoded frame into the filtergraph */
        var ret = av_buffersrc_add_frame(src_ctx, frame)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "av_buffersrc_add_frame") }

        /* pull filtered frames from the filtergraph */
        var outFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        ret = av_buffersink_get_frame(sink_ctx, outFrame)
        guard ret == 0 else {
            av_frame_free(&outFrame)
            return AVERROR(errorCode: ret, context: "av_buffersink_get_frame")
        }
        var old: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&old)
        frame = outFrame!

        return nil
    }

    private func zscaleSetup(frame: inout AVFrame, pixelBuffer: inout CVPixelBuffer) -> Error? {

        let filterDesc = makeFilterChain(frame: &frame, pixelBuffer: &pixelBuffer)

        let bufferSrc = avfilter_get_by_name("buffer")
        let bufferSink = avfilter_get_by_name("buffersink")

        filterGraph = avfilter_graph_alloc()!

        /* buffer video source: the decoded frames from the decoder will be inserted here. */
        let srcArgs =
            "video_size=\(frame.width)x\(frame.height):pix_fmt=\(frame.format):colorspace=\(String(cString: av_color_space_name(frame.colorspace))):range=\(frame.color_range == AVCOL_RANGE_JPEG ? "pc" : "tv"):time_base=1/1000"  // time_base is required but irrelevant
        let alpha: Bool = {
            if let desc = av_pix_fmt_desc_get(AVPixelFormat(frame.format)) {
                return (desc.pointee.flags & UInt64(AV_PIX_FMT_FLAG_ALPHA)) != 0
            } else {
                return false
            }
        }()
        let sinkArgs = "pixel_formats=\(alpha ? AV_PIX_FMT_GBRAP.rawValue : AV_PIX_FMT_GBRP.rawValue)"  // should use AV_PIX_FMT_GBRPF32LE for HDR to match tonemap output, but vImage conversion broken
        logger.log(
            "VideDecoder using filter with input \"\(srcArgs, privacy: .public)\", filter \"\(filterDesc, privacy: .public)\", output \"\(sinkArgs, privacy: .public)\""
        )

        var ret = avfilter_graph_create_filter(&src_ctx, bufferSrc, "in", srcArgs, nil, filterGraph)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_create_filter") }

        /* buffer video sink: to terminate the filter chain. */
        ret = avfilter_graph_create_filter(&sink_ctx, bufferSink, "out", sinkArgs, nil, filterGraph)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_create_filter") }

        /*
         * Set the endpoints for the filter graph. The filter_graph will
         * be linked to the graph described by filters_descr.
         */

        /*
         * The buffer source output must be connected to the input pad of
         * the first filter described by filters_descr; since the first
         * filter input label is not specified, it is set to "in" by
         * default.
         */
        var outputs = avfilter_inout_alloc()
        outputs!.pointee.name = strdup("in")
        outputs!.pointee.filter_ctx = src_ctx
        outputs!.pointee.pad_idx = 0
        outputs!.pointee.next = nil

        /*
         * The buffer sink input must be connected to the output pad of
         * the last filter described by filters_descr; since the last
         * filter output label is not specified, it is set to "out" by
         * default.
         */
        var inputs = avfilter_inout_alloc()
        inputs!.pointee.name = strdup("out")
        inputs!.pointee.filter_ctx = sink_ctx
        inputs!.pointee.pad_idx = 0
        inputs!.pointee.next = nil

        ret = avfilter_graph_parse_ptr(filterGraph, filterDesc.cString(using: .utf8), &inputs, &outputs, nil)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_parse_ptr") }

        ret = avfilter_graph_config(filterGraph, nil)
        guard ret == 0 else { return AVERROR(errorCode: ret, context: "avfilter_graph_config") }

        return nil
    }

    private func makeFilterChain(frame: inout AVFrame, pixelBuffer: inout CVPixelBuffer) -> String {

        let pin = String(cString: av_color_primaries_name(frame.color_primaries))
        let tin = String(cString: av_color_transfer_name(frame.color_trc))
        let min = String(cString: av_color_space_name(frame.colorspace))

        // pixelBuffer.width != frame.width for anamorphic
        let out_w = CVPixelBufferGetWidth(pixelBuffer)

        if frame.color_trc == AVCOL_TRC_SMPTE2084 || frame.color_trc == AVCOL_TRC_ARIB_STD_B67 {
            // HDR content
            return """
                zscale=w=\(out_w):h=\(frame.height):f=lanczos:pin=\(pin):tin=\(tin):min=\(min):primaries=709:transfer=linear:matrix=709:npl=100,
                tonemap=hable
                """
        } else {
            // SDR content - SD or HD
            return
                "zscale=w=\(out_w):h=\(frame.height):f=lanczos:pin=\(pin):tin=\(tin):min=\(min):primaries=709:transfer=709:matrix=709"
        }
    }
}
