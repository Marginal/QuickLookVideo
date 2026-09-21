//
//  AppDelegate.swift
//  QLVideo
//
// AppDelegate for hosting the entrypoint invoked from the Services menu
//

import Cocoa
import Foundation
import OSLog
import SwiftUI

// Constants
let kMinimumDuration: Double = 5  // Don't bother seeking clips shorter than this [s].
let kDefaultSnapshotCount = 12
let kMinimumPeriod: Double = 60  // Don't create snapshots spaced more closely than this [s].
let kThumbnailWidth: CGFloat = 160
let kSidebarFrameWidth: CGFloat = kThumbnailWidth + 32
let kSidebarWidth: CGFloat = kSidebarFrameWidth + 8

let logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "contactsheet")

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var windowControllers: [URL: NSWindowController] = [:]
    private var terminateTimer: Timer?
    private let formatter: DateComponentsFormatter

    // Dummy to create localization in .strings file
    // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html
    let serviceMenuTitle = String(
        localized: "View Contact Sheet",
        table: "ServicesMenu",
        comment: "Entry in Finder's Services menu. Use the same term for \"Contact Sheet\" as used in the Preview app's View menu."
    )

    override init() {
        // Send FFmpeg logs to system log
        #if DEBUG
            logger.debug("AppDelegate init")
            av_log_set_level(AV_LOG_DEBUG | AV_LOG_SKIP_REPEATED)
        #else
            av_log_set_level(AV_LOG_WARNING | AV_LOG_SKIP_REPEATED)
        #endif
        setup_av_log_callback()

        formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        super.init()
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            logger.debug("AppDelegate applicationDidFinishLaunching")
        #endif
    }

    // Service entry point
    @objc
    func showContactSheet(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard
            let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true as NSNumber]) as? [URL],
            let url = urls.first
        else {
            error.pointee = "No file URL provided"  // Shouldn't get here
            logger.error("showContactSheet with no url")
            return
        }
        #if DEBUG
            logger.debug("showContactSheet for \(url.path, privacy: .public)")
        #endif

        // Already have a window open for this url?
        if let windowController = windowControllers[url] {
            windowController.showWindow(nil)
            NSApplication.shared.activate()
            return
        }

        var fmt_ctx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&fmt_ctx, url.path, nil, nil)
        guard ret == 0 else {
            return showFFmpegAlert(errorCode: ret, context: "avformat_open_input", url: url)
        }

        // Read ahead if necessary to populate info like codec parameters that otherwise might not be available
        fmt_ctx!.pointee.max_analyze_duration = Int64(5 * AV_TIME_BASE)  // 5s
        fmt_ctx!.pointee.probesize = 10 * 1024 * 1024  // 10MB
        ret = avformat_find_stream_info(fmt_ctx, nil)
        guard ret == 0 else {
            avformat_close_input(&fmt_ctx)
            return showFFmpegAlert(errorCode: ret, context: "avformat_find_stream_info", url: url)
        }

        // Open best video stream
        var decoder: UnsafePointer<AVCodec>?
        let bestVideo = Int(av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0))
        if bestVideo < 0 {
            avformat_close_input(&fmt_ctx)

        }
        let stream = fmt_ctx!.pointee.streams[bestVideo]!
        guard let snapshotter = SnapShotter(fmt_ctx: fmt_ctx!, stream: stream) else {
            // Shouldn't happen since we checked that the stream is decodable above
            avformat_close_input(&fmt_ctx)
            return showFFmpegAlert(errorCode: AVERROR_UNKNOWN, context: "SnapShotter", url: url)
        }

        // Find best audio stream
        let bestAudio = Int(av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
        let channels = bestAudio < 0 ? 0 : fmt_ctx!.pointee.streams[bestAudio]!.pointee.codecpar.pointee.ch_layout.nb_channels
        let channelstring: String = {
            switch channels
            {
            case 0: return "🔇"
            case 1: return String(localized: "mono", table: "ServicesMenu", comment: "Contact sheet titlebar: video has mono audio")
            case 2:
                return String(localized: "stereo", table: "ServicesMenu", comment: "Contact sheet titlebar: video has stereo audio")
            case 6: return "5.1"
            case 7: return "6.1"
            case 8: return "7.1"
            default: return "\(channels)🔉"  // Quadraphonic, LCRS or something else
            }
        }()

        let title: String = {
            if let tag = av_dict_get(fmt_ctx!.pointee.metadata, "title", nil, 0) {
                return String(cString: tag.pointee.value)
            } else {
                return url.lastPathComponent
            }
        }()

        let view = ContactSheetView(snapshotter: snapshotter).allowedDynamicRange(.high)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.representedURL = url
        if snapshotter.duration <= 0 {
            window.title = "\(title) \(snapshotter.dstWidth)×\(snapshotter.dstHeight) \(channelstring)"
        } else {
            window.title =
                "\(title) \(snapshotter.dstWidth)×\(snapshotter.dstHeight) \(channelstring) \(formatter.string(from:TimeInterval(snapshotter.duration)) ?? "")"

        }

        // Determine whether we have more than one sidebar image (including cover art) so should display the sidebar
        var imageCount: Int =
            snapshotter.stream.pointee.disposition == (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS)
            ? Int(snapshotter.stream.pointee.nb_frames)
            : Int((snapshotter.duration / kMinimumPeriod).rounded(.down)) - 1
        if imageCount <= 1 {
            for i in 0..<Int(fmt_ctx!.pointee.nb_streams) {
                guard let stream = fmt_ctx!.pointee.streams[i], let params = stream.pointee.codecpar else { continue }
                if (params.pointee.codec_id == AV_CODEC_ID_PNG || params.pointee.codec_id == AV_CODEC_ID_MJPEG)
                    // Depending on codec and ffmpeg version cover art may be represented as attachment or as additional video stream(s)
                    && (params.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT
                        || (params.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                            && ((stream.pointee.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS))
                                == AV_DISPOSITION_ATTACHED_PIC))) {
                    imageCount = 2
                    break
                }
            }
        }
        let sidebarWidth = imageCount > 1 ? kSidebarWidth : 0
        let scale: Double = {
            if snapshotter.dstWidth <= 400 {
                return 0.5  // Double size for small clips otherwise looks ridiculous
            } else if let screenSize = NSScreen.main?.visibleFrame {
                let scaleW: Double = (Double(snapshotter.dstWidth) / (screenSize.width + sidebarWidth)).rounded(.up)
                let scaleH: Double = (Double(snapshotter.dstHeight) / screenSize.height).rounded(.up)
                return max(scaleW, scaleH)
            } else {
                return 1
            }
        }()
        #if DEBUG
            logger.debug("setting initial scale to \(1/scale)")
        #endif
        window.setContentSize(
            NSSize(width: Double(snapshotter.dstWidth) / scale + sidebarWidth, height: Double(snapshotter.dstHeight) / scale)
        )

        // Cancel any pending termination
        terminateTimer?.invalidate()
        terminateTimer = nil

        let windowController = NSWindowController(window: window)
        windowController.window?.delegate = self
        windowControllers[url] = windowController
        windowController.showWindow(nil)
        NSApplication.shared.activate()
    }

    func windowWillClose(_ notification: Notification) {
        #if DEBUG
            logger.debug(
                "windowWillClose for \((notification.object as? NSWindow)?.representedURL?.path ?? "unknown", privacy: .public)"
            )
        #endif
        guard let window = notification.object as? NSWindow,
            let url = window.representedURL
        else { return }
        windowControllers.removeValue(forKey: url)

        // Hang around for a minute after closing the last view
        if windowControllers.isEmpty {
            terminateTimer?.invalidate()
            terminateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        }
    }

    func showFFmpegAlert(errorCode: Int32, context: String, url: URL) {
        NSApplication.shared.activate()
        var buffer = [Int8](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        av_strerror(errorCode, &buffer, buffer.count)
        logger.error("\(context, privacy: .public): \(String(cString: buffer), privacy: .public) (\(errorCode))")
        // Package as a NSError so we don't have to translate
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: errorCode == -EPERM || errorCode == -EACCES ? NSFileReadNoPermissionError : NSFileReadUnknownError,
            userInfo: [
                NSURLErrorKey: url,
                NSLocalizedRecoverySuggestionErrorKey: String(cString: buffer),  // displayed as informativeText
            ]
        )
        NSAlert(error: error).runModal()
    }
}
