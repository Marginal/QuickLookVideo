//
//  hevctests.swift
//  QLVideo
//

import Foundation
import Testing

@testable import QLVideo_Formats

struct HEVCDecoderTests {
    private final class BundleMarker: NSObject {}

    private struct Picture: Equatable {
        let timestamp: Int64
        let checksum: UInt32
    }

    @Test("HEVC low-delay decoding preserves pictures and timestamps", arguments: [8, 10])
    func lowDelay(bitDepth: Int) throws {
        let file = try #require(
            Bundle(for: BundleMarker.self).url(forResource: "hev1-\(bitDepth)-bit", withExtension: "mp4", subdirectory: "fixtures")
        )
        let reordered = try decode(file, bitDepth: bitDepth, lowDelay: false)
        let immediate = try decode(file, bitDepth: bitDepth, lowDelay: true)
        try #require(reordered.count == 48)
        #expect(immediate.map(\.timestamp) != reordered.map(\.timestamp))
        #expect(immediate.sorted { $0.timestamp < $1.timestamp } == reordered)

        // A thumbnail seek may decode reference frames while asking for just one picture.
        let preroll = try decode(file, bitDepth: bitDepth, lowDelay: true, discardFirst: true)
        #expect(preroll == Array(immediate.dropFirst()))
    }

    private func decode(_ file: URL, bitDepth: Int, lowDelay: Bool, discardFirst: Bool = false) throws -> [Picture] {
        var input: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&input, file.path, nil, nil) == 0)
        defer { avformat_close_input(&input) }
        try #require(avformat_find_stream_info(input, nil) == 0)
        let index = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        try #require(index >= 0)
        let stream = try #require(input?.pointee.streams[Int(index)])
        let parameters = try #require(stream.pointee.codecpar)
        #expect(parameters.pointee.codec_tag == 0x3176_6568)  // 'hev1' in FFmpeg byte order
        if bitDepth == 10 {
            #expect(parameters.pointee.extradata_size == 23)  // hvcC without parameter-set arrays
        }

        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_HEVC))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let decoder = try #require(context)
        try #require(avcodec_parameters_to_context(decoder, parameters) == 0)
        decoder.pointee.thread_type = FF_THREAD_SLICE
        decoder.pointee.thread_count = 2
        if lowDelay {
            decoder.pointee.flags |= AV_CODEC_FLAG_LOW_DELAY
        }
        try #require(avcodec_open2(decoder, codec, nil) == 0)

        var allocatedPacket = av_packet_alloc()
        defer { av_packet_free(&allocatedPacket) }
        let packet = try #require(allocatedPacket)
        var allocatedFrame = av_frame_alloc()
        defer { av_frame_free(&allocatedFrame) }
        let frame = try #require(allocatedFrame)
        var pictures: [Picture] = []
        var packetCount = 0

        func receive() throws {
            while true {
                let status = avcodec_receive_frame(decoder, frame)
                if status == AVERROR_EAGAIN || status == AVERROR_EOF {
                    return
                }
                try #require(status == 0)
                let picture = frame.pointee
                let pixelFormat = bitDepth == 10 ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P
                try #require(picture.format == pixelFormat.rawValue)
                let planes = [picture.data.0, picture.data.1, picture.data.2]
                let strides = [picture.linesize.0, picture.linesize.1, picture.linesize.2]
                var checksum: UInt32 = 1
                for plane in planes.indices {
                    let base = try #require(planes[plane])
                    let subsampling = plane == 0 ? 1 : 2
                    let height = Int(picture.height) / subsampling
                    let rowBytes = Int(picture.width) / subsampling * (bitDepth == 10 ? 2 : 1)
                    for row in 0..<height {
                        checksum = av_adler32_update(checksum, base + row * Int(strides[plane]), rowBytes)
                    }
                }
                pictures.append(Picture(timestamp: picture.pts, checksum: checksum))
                av_frame_unref(frame)
            }
        }

        while av_read_frame(input, packet) == 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == index else { continue }
            let discard = discardFirst && packetCount == 0
            packetCount += 1
            if discard {
                packet.pointee.flags |= AV_PKT_FLAG_DISCARD
            }
            let before = pictures.count
            try #require(avcodec_send_packet(decoder, packet) == 0)
            try receive()
            if lowDelay {
                try #require(pictures.count == before + (discard ? 0 : 1))
                if !discard {
                    #expect(pictures.last?.timestamp == packet.pointee.pts)
                }
            }
        }
        try #require(avcodec_send_packet(decoder, nil) == 0)
        try receive()
        #expect(pictures.count == packetCount - (discardFirst ? 1 : 0))
        return pictures
    }
}
