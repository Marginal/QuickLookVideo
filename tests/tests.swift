//
//  dealloc.swift
//  QLVideo
//

import Foundation
import MediaExtension
import Testing

@testable import QLVideo_Formats

struct FormatReaderTests {

    @Test("FormatReader deinit", .bug("https://github.com/Marginal/QuickLookVideo/issues/214")) func testdeinit()
        async throws
    {
        let env = ProcessInfo.processInfo.environment
        let testdirName = try #require(env["TESTDIR"])  // Must be set in the XCTest plan
        let testdir = URL(filePath: testdirName)
        try #require(testdir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false)
        let files = try FileManager.default.contentsOfDirectory(
            at: testdir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        )

        let factory = FormatReaderFactory()

        try await Task.detached(priority: .medium) {
            for _ in 0..<10 {
                for file in files {
                    guard let byteSource = MockByteSource(file: file),
                        let formatReader = try? await factory.formatReader(with: byteSource),
                        (try? await formatReader.fileInfo()) != nil,  // must call this before any other MEFormatReader functions
                        let trackReaders = try? await formatReader.trackReaders()
                    else {
                        continue  // not interested in non-media files or, for this test, in media files we can't open
                    }

                    // Find the video track and extract the packet at thumbnail time
                    for trackReader in trackReaders {
                        if let trackInfo = try? await trackReader.trackInfo(), trackInfo.mediaType == kCMMediaType_Video {
                            print(byteSource.fileName)
                            do {
                                let sampleCursor = try await trackReader.sampleCursor(atPresentationTimeStamp: QLThumbnailTime)
                                try await _ = sampleCursor.loadSampleBufferContainingSamples!(to: nil)
                            } catch {
                                // for this test we're not interested in media files we can't demux
                            }
                            break
                        }
                    }
                }
            }

            // Check all FormatReaders have deinitted
            try await Task.sleep(for: .seconds(1))  // Allow any underway av_read_frame() or av_bsf_receive_packet() to finish
            try #require(factory.formatReaders.allObjects.count == 0)  // NSHashTable.count can be != 0 even though no real objects remain
        }.value
    }
}
