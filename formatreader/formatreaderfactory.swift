//
//  formatreaderfactory.swift
//  QLVideo
//
//  Created by Jonathan Harris on 17/11/2025.
//

import Dispatch
import Foundation
import MediaExtension
import OSLog

extension MEByteSource: @retroactive ByteSource {}  // Conform to our ByteSource protocol to allow for unit testing

let logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "formatreader")

class FormatReaderFactory: NSObject, MEFormatReaderExtension {

    private var infoSignal: DispatchSourceSignal?
    var formatReaders = NSHashTable<FormatReader>.weakObjects()  // for dumpState() and unit testing

    required override init() {
        super.init()
        // Send FFmpeg logs to system log
        #if DEBUG
            logger.debug("FormatReaderFactory init")
            av_log_set_level(AV_LOG_DEBUG | AV_LOG_SKIP_REPEATED)
        #else
            av_log_set_level(AV_LOG_WARNING | AV_LOG_SKIP_REPEATED)
        #endif
        setup_av_log_callback()

        // Dump state to log on receipt of SIGINFO
        // See https://blog.smittytone.net/2021/07/19/tackle-async-signal-safety-in-swift/
        signal(SIGINFO, SIG_IGN)  // should be default behaviour, but lets be sure
        infoSignal = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .global(qos: .background))
        infoSignal?.setEventHandler { [self] in
            _ = infoSignal?.data  // Indicate that we're handling the signal. Is this necessary?
            dumpState()
        }
        infoSignal?.resume()
    }

    func formatReader(with primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws
        -> any MEFormatReader
    {
        #if DEBUG
            let identifier: String = primaryByteSource.contentType?.identifier ?? "unknown"
            logger.debug(
                "FormatReaderFactory formatReader \(primaryByteSource.fileName, privacy:.public) \(identifier, privacy:.public) \(ProcessInfo().operatingSystemVersionString, privacy:.public)"
            )
        #endif  // DEBUG
        let reader = FormatReader(byteSource: primaryByteSource)
        formatReaders.add(reader)
        return reader
    }

    // For unit testing
    func formatReader(with mockByteSource: MockByteSource) throws -> any MEFormatReader {
        #if DEBUG
            let identifier: String = mockByteSource.contentType?.identifier ?? "unknown"
            logger.debug(
                "FormatReaderFactory formatReader \(mockByteSource.fileName, privacy:.public) \(identifier, privacy:.public) \(ProcessInfo().operatingSystemVersionString, privacy:.public)"
            )
        #endif  // DEBUG
        let reader = FormatReader(byteSource: mockByteSource)
        formatReaders.add(reader)
        return reader
    }

    func dumpState() {
        logger.info("FormatReader open files:")
        var limits = rlimit()
        let maxfd: Int32 = getrlimit(RLIMIT_NOFILE, &limits) == 0 && limits.rlim_cur != Int64.max ? Int32(limits.rlim_cur) : 2560
        var path: [Int8] = Array(repeating: 0, count: Int(MAXPATHLEN))
        for fd: Int32 in 3..<maxfd {
            let ret = fcntl(fd, F_GETPATH, &path)
            if ret >= 0 {
                logger.info("  FD \(fd)\t\(String(cString: path), privacy:.public)")
            }
        }
        logger.info("FormatReader state:")
        for formatReader in formatReaders.allObjects {
            logger.info("FormatReader for \(formatReader.byteSource.fileName, privacy: .public)")
            logger.info("  PacketDemuxer \(formatReader.demuxer?.status() ?? "absent", privacy: .public)")
            for trackReader in formatReader.readers.allObjects {
                logger.info(
                    "  \(String(describing: type(of: trackReader)), privacy: .public) for stream #\(trackReader.index) \(trackReader.formatDescription!.mediaSubType, privacy: .public) \(formatReader.demuxer?.status(stream: trackReader.index) ?? "absent", privacy: .public)"
                )
                for sampleCursor in trackReader.sampleCursors.allObjects {
                    logger.info("    \(sampleCursor.debugDescription, privacy: .public)")
                }
            }
        }
    }
}
