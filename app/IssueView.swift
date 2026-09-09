//
//  IssueView.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 01/12/2022.
//

import AVFoundation
import Cocoa
import OSLog
import QuickLookThumbnailing

class IssueView: NSView {

    @IBOutlet weak var dropTarget: IssueDropTarget!
    @IBOutlet weak var advice: NSTextField!
    @IBOutlet weak var sendButton: NSButton!

    var videoFile: URL?
    var thumbnailStatus: String?
    var playableStatus: String?

    override func awakeFromNib() {
        // Reformat list items in advice
        let style = NSMutableParagraphStyle()
        style.headIndent = NSAttributedString(string: " • ", attributes: [.font: advice.font!]).size().width
        advice.attributedStringValue = NSAttributedString(
            string: advice.stringValue.replacingOccurrences(of: "\n- ", with: "\n • "),
            attributes: [
                .font: advice.font!,
                .paragraphStyle: style,
            ]
        )
    }

    @IBAction func dismessReport(sender: NSButton) {
        reset()
        let delegate = NSApp.delegate as! AppDelegate
        delegate.mainWindow.endSheet(self.window!)
    }

    @IBAction func sendReport(sender: NSButton) {
        sendButton.isEnabled = false
        let version = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        let macOS = ProcessInfo().operatingSystemVersionString
        let machine = sysCtl("hw.machine")
        var hardware = "\(sysCtl("hw.model")), \(sysCtl("machdep.cpu.brand_string")),"
        if machine == "arm64" {
            hardware = hardware + " neon=\(sysCtl("hw.optional.neon"))"
        } else if machine == "x86_64" {
            hardware = hardware + " avx2=\(sysCtl("hw.optional.avx2_0")) avx512f=\(sysCtl("hw.optional.avx512f"))"
        }
        var report =
            "*Your description of the problem here!*\n\n\n---\nQuickLook Video \(version)\nmacOS: \(macOS)\nHardware: \(hardware)\n"
        report.append("Previewer: \(pluginstatus(id: "com.apple.uk.org.marginal.qlvideo.previewer") ?? "Not found")\n")
        report.append("Thumbnailer: \(pluginstatus(id: "com.apple.uk.org.marginal.qlvideo.thumbnailer") ?? "Not found")\n")
        report.append("Media Formats: \(pluginstatus(id: "uk.org.marginal.qlvideo.formatreader") ?? "Not found")\n")
        report.append("Media Codecs: \(pluginstatus(id: "uk.org.marginal.qlvideo.videodecoder") ?? "Not found")\n")

        var filereport = "\n\(videoFile!.path):\n"
        if let type = try? videoFile?.resourceValues(forKeys: [.contentTypeKey]).contentType {
            filereport.append(
                "ContentType: '\(type.identifier)', subtype of 'public.audio'=\(type.isSubtype(of: UTType.audio) ? "yes" : "no"), subtype of 'public.movie'=\(type.isSubtype(of: UTType.movie) ? "yes" : "no")\n"
            )
        } else {
            filereport.append("ContentType: Unknown\n")
        }
        filereport.append("Playable: \(playableStatus ?? "Unknown")\n")
        filereport.append("Thumbnail: \(thumbnailStatus ?? "Unknown")\n")
        do {
            try filereport.append(
                "Spotlight: \(helper("/usr/bin/mdimport", args: ["-n", "-d1"] + [videoFile!.path]).replacingOccurrences(of: "\n", with: " "))\n"
            )
        } catch {
            filereport.append("Spotlight: \(error)\n")
        }

        do {
            try filereport.append(
                "```json\n\(helper(Bundle.main.path(forAuxiliaryExecutable: "ffprobe")!, args: ["-loglevel", "error", "-print_format", "json", "-show_entries", "stream=codec_type,codec_name,profile,codec_tag_string,sample_fmt,channel_layout,language,width,height,display_aspect_ratio,pix_fmt,color_range,color_primaries,color_trc,color_space,extradata_size:stream_disposition=default,attached_pic,timed_thumbnails:stream_side_data:chapter=start_time,end_time:format=format_name,duration,size,bit_rate,probe_score"] + [videoFile!.path]).replacingOccurrences(of: "\n\n", with: "\n").replacingOccurrences(of: "    ", with: "  "))```\n"
            )
        } catch {
            filereport.append("ffprobe: \(error)\n")
        }
        filereport = filereport.replacingOccurrences(
            of: videoFile!.path,
            with: "*file*.\(videoFile!.pathExtension)"
        )
        report.append("\(filereport)\n")

        // https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-an-issue#creating-an-issue-from-a-url-query
        var url: URL
        if let encoded = report.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url = URL(string: "https://github.com/Marginal/QLVideo/issues/new?body=".appending(encoded))!
        } else {
            url = URL(string: "https://github.com/Marginal/QLVideo/issues/new")!
        }
        NSWorkspace.shared.open(url)

        reset()
        let delegate = NSApp.delegate as! AppDelegate
        delegate.mainWindow.endSheet(self.window!)

        if let crashZip = lookForCrashes() {
            delegate.showCrashReport(filePath: crashZip)
        }
    }

    func reset() {
        videoFile = nil
        thumbnailStatus = nil
        playableStatus = nil
        dropTarget.image = nil
        sendButton.isEnabled = false
    }
}

// https://www.appcoda.com/nspasteboard-macos/
class IssueDropTarget: NSImageView {

    weak var parent: IssueView!

    override func awakeFromNib() {
        parent = (window?.contentView as! IssueView)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let items = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) {
            parent.reset()
            for item in items {
                if let url = item as? NSURL {
                    parent.videoFile = url as URL
                    break
                }
            }

            // Generate thumbnail and probe playability, which may provoke a plugin crash that we can report
            if let url = parent.videoFile {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: 128, height: 128),
                    scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                    representationTypes: .thumbnail  // ask for thumbnail only, not icon or all
                )
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
                    DispatchQueue.main.async {
                        if let error {
                            self.parent.thumbnailStatus = String(describing: error)
                            self.image = NSWorkspace.shared.icon(forFile: url.path)
                        } else if let image = thumbnail?.nsImage {
                            self.parent.thumbnailStatus = "Yes"
                            self.image = image
                        } else {
                            self.parent.thumbnailStatus = "No"
                            self.image = NSWorkspace.shared.icon(forFile: url.path)
                        }
                    }
                }

                let asset = AVURLAsset(url: url)
                Task {
                    do {
                        let playable = try await asset.load(.isPlayable)
                        if let ext = asset.mediaExtensionProperties {
                            self.parent.playableStatus = "With extension '\(ext.extensionName)'"
                        } else if playable {
                            self.parent.playableStatus = "Yes"
                        } else {
                            self.parent.playableStatus = "No"
                        }
                    } catch {
                        self.parent.playableStatus = "Failed \(error.localizedDescription)"
                    }
                    parent.sendButton.isEnabled = true
                    parent.sendButton.setAccessibilityFocused(true)
                }
                return true
            }
        }
        return false
    }
}

func pluginstatus(id: String) -> String? {
    do {
        let status = try helper("/usr/bin/pluginkit", args: ["-Ami", id])
        if let match = status.firstMatch(of: #/(.)\s+([a-z\.]+)\(([0-9\.]+)\)/#) {
            switch match.output.1 {
            case "!": return "\(match.output.3) debug"
            case "+": return "\(match.output.3) enabled"
            case "-": return "\(match.output.3) disabled"
            case "=": return "\(match.output.3) superseded"
            case " ": return "\(match.output.3)"  // Default - user has not explicitly enabled or disabled
            default: return "\(match.output.3) unknown"
            }
        }
        return nil
    } catch {
        return nil
    }
}

// Look in ~/Library/Logs/DiagnosticReports for recent crash reports involving our plugins/extensions and, if found,
// zip them up and return the zip file path so the user can attach them to the issue.
func lookForCrashes() -> URL? {
    let logger = (NSApp.delegate as! AppDelegate).logger
    let fm = FileManager.default
    let crashDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    let appVersion = Bundle.main.infoDictionary!["CFBundleVersion"] as! String
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime, .withFractionalSeconds]

    guard
        let entries = try? fm.contentsOfDirectory(
            at: crashDir,
            includingPropertiesForKeys: [],
            options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants, .skipsHiddenFiles]
        )
    else {
        return nil
    }

    var latest: [String: (date: Date, url: URL)] = [:]  // bundleId: (date of crash, url of report)

    for url in entries {
        guard url.pathExtension.lowercased() == "ips",
            let text = try? String(contentsOf: url, encoding: .utf8),
            let split = text.range(of: "}\n{")
        else { continue }

        let firstJSON = String(text[...split.lowerBound])
        let secondJSON = String(text[text.index(before: split.upperBound)...])

        guard let firstData = firstJSON.data(using: .utf8),
            let secondData = secondJSON.data(using: .utf8),
            let firstObj = try? JSONSerialization.jsonObject(with: firstData) as? [String: Any],
            let secondObj = try? JSONSerialization.jsonObject(with: secondData) as? [String: Any],
            let timestamp = firstObj["timestamp"] as? String,
            let crashDate = isoFormatter.date(from: timestamp),
            let usedImages = secondObj["usedImages"] as? [[String: Any]]
        else { continue }

        for image in usedImages {
            guard let bundleId = image["CFBundleIdentifier"] as? String,
                bundleId.contains("uk.org.marginal.qlvideo"),
                let bundleVersion = image["CFBundleVersion"] as? String,
                bundleVersion == appVersion
            else { continue }
            // One of our plugins/extensions was potentially implicated in this crash
            if let current = latest[bundleId] {
                if crashDate > current.date { latest[bundleId] = (crashDate, url) }
            } else {
                latest[bundleId] = (crashDate, url)
            }
            break
        }
    }

    let filesToZip = latest.values.map { $0.url }
    guard !filesToZip.isEmpty else { return nil }

    let stamp = { () -> String in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yy-MM-dd HH.mm.ss"
        return df.string(from: Date())
    }()
    let zipURL = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop")
        .appendingPathComponent("QLVideo Crashes \(stamp).zip")
    do {
        try? fm.removeItem(at: zipURL)
        try helper("/usr/bin/zip", args: ["-j", zipURL.path] + filesToZip.map { $0.path })
    } catch {
        logger.error("zip failed: \(String(describing: error))")
        return nil
    }
    return zipURL
}
