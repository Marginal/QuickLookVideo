//
//  CoverArtView.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 09/01/2025.
//

import Cocoa
import UniformTypeIdentifiers

enum VideoType { case unspecified, mkv, mp4, other, unreadable }
enum CoverType { case unspecified, png, jpeg, other, unreadable }

class CoverArtView: NSView {

    @IBOutlet weak var videoDropTarget: VideoDropTarget!
    @IBOutlet weak var videoStatus: NSTextField!
    @IBOutlet weak var coverDropTarget: CoverDropTarget!
    @IBOutlet weak var coverStatus: NSTextField!
    @IBOutlet weak var doItButton: NSButton!

    var videoFile: URL?
    var videoFileType: VideoType = .unspecified
    var videoFileHasCoverArt = false
    var videoFileStreams: [Int] = []
    var coverFile: URL?
    var coverFileType: CoverType = .unspecified

    @IBAction func dismiss(_ sender: NSButton) {
        reset()
        self.window?.close()
    }

    @IBAction func doIt(_ sender: NSButton) {
        var outfile: String
        //ffmpeg requires output file to have an extension that matches the container
        let outext =
            videoFileType == .mkv
            ? (videoFile!.pathExtension.caseInsensitiveCompare("webm") == .orderedSame ? "webm" : "mkv")
            : (videoFile!.pathExtension.caseInsensitiveCompare("m4v") == .orderedSame ? "m4v" : "mp4")

        var i = 2
        while true {
            outfile = "\(videoFile!.deletingPathExtension().path) \(i).\(outext)"
            if !FileManager.default.fileExists(atPath: outfile) {
                break
            }
            i += 1
        }

        let savePanel = NSSavePanel()
        if !videoFileHasCoverArt {
            savePanel.message = String(localized: "Add cover art", comment: "Cover art Save dialog")
        } else if coverFileType == .unspecified {
            savePanel.message = String(localized: "Remove cover art", comment: "Cover art Save dialog")
        } else {
            savePanel.message = String(localized: "Replace cover art", comment: "Cover art Save dialog")
        }
        savePanel.nameFieldStringValue =
            URL(fileURLWithPath: outfile).lastPathComponent
        savePanel.directoryURL = videoFile!.deletingLastPathComponent()
        if videoFileType == .mp4 {
            savePanel.allowedContentTypes =
                outext == "mp4" ? [.mpeg4Movie, .appleProtectedMPEG4Video] : [.appleProtectedMPEG4Video, .mpeg4Movie]
        } else if let mkv = UTType("org.matroska.mkv"),
            let webm = UTType("org.webmproject.webm")
        {
            savePanel.allowedContentTypes = outext == "mkv" ? [mkv, webm] : [webm, mkv]
        }

        savePanel.beginSheetModal(
            for: self.window!,
            completionHandler: {
                [self]
                (result: NSApplication.ModalResponse) in
                if result == .OK && savePanel.url != nil {
                    var outurl = savePanel.url!

                    // Sandboxing won't let ffmpeg overwrite a file directly, so make ffmpeg write to a temporary file. This also solves overwriting the input file.
                    var realouturl: URL?
                    if FileManager.default.fileExists(atPath: outurl.path) {
                        realouturl = outurl
                        outurl =
                            ((try? FileManager.default.url(
                                for: .itemReplacementDirectory,
                                in: .userDomainMask,
                                appropriateFor: savePanel.url,
                                create: true
                            ))
                            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)).appendingPathComponent(
                                outurl.lastPathComponent,
                                isDirectory: false
                            )
                    }

                    #if DEBUG
                        var args: [String] = [
                            "-loglevel", "info", "-i", videoFile!.path,
                        ]
                    #else
                        var args: [String] = [
                            "-loglevel", "error", "-i", videoFile!.path,
                        ]
                    #endif
                    let mappings = videoFileStreams.flatMap { ["-map", "0:\($0)"] }
                    // Following relies on ffmpeg adding the cover art as the last stream
                    if coverFileType == .unspecified {
                        args +=
                            mappings + [
                                "-c", "copy", "-copy_unknown", "-movflags", "+faststart", "-movflags", "use_metadata_tags",
                                outurl.path,
                            ]
                    } else if videoFileType == .mp4 {
                        // Can't use "-movflags use_metadata_tags" since this causes ffmpeg 7.1 to drop the attachment
                        args +=
                            ["-i", coverFile!.path] + mappings + [
                                "-map", "1", "-c", "copy", "-copy_unknown", "-movflags", "+faststart",
                                "-disposition:\(videoFileStreams.count)", "attached_pic", outurl.path,
                            ]
                    } else {
                        let coverext = coverFileType == .png ? "png" : "jpeg"
                        args +=
                            ["-attach", coverFile!.path] + mappings + [
                                "-c", "copy", "-copy_unknown", "-metadata:s:\(videoFileStreams.count)",
                                "mimetype=image/\(coverext)", "-metadata:s:\(videoFileStreams.count)",
                                "filename=cover.\(coverext)", outurl.path,
                            ]
                    }

                    do {
                        let _ = try helper(Bundle.main.path(forAuxiliaryExecutable: "ffmpeg")!, args: args)
                        if realouturl != nil {
                            FileManager.default.createFile(atPath: realouturl!.path, contents: try Data(contentsOf: outurl))
                            let _ = try? FileManager.default.removeItem(at: outurl)
                        }
                    } catch let error as NSError {
                        savePanel.orderOut(nil)
                        let _ = try? FileManager.default.removeItem(at: outurl)  // remove broken output file
                        let alert = NSAlert(error: error)
                        alert.alertStyle = .critical
                        alert.runModal()
                    }
                }
                self.window?.close()
                reset()
            }
        )
    }

    func reset() {
        if videoFile != nil && (NSApp.delegate as! AppDelegate).isSandboxed { videoFile!.stopAccessingSecurityScopedResource() }
        videoFile = nil
        videoFileType = .unspecified
        videoFileHasCoverArt = false
        if coverFile != nil && (NSApp.delegate as! AppDelegate).isSandboxed { coverFile!.stopAccessingSecurityScopedResource() }
        coverFile = nil
        coverFileType = .unspecified
        outcomes()
    }

    func outcomes() {
        switch videoFileType {
        case .unspecified:
            videoDropTarget.image = nil
            videoStatus.stringValue = String(localized: "Drop video file here", comment: "Prompt in cover art dialog")
        case .mkv, .mp4:
            // DropTarget image is already filled in
            videoStatus.stringValue = String(localized: "Drop video file here", comment: "Prompt in cover art dialog")
        case .other:
            videoDropTarget.image = NSImage(named: NSImage.cautionName)
            videoStatus.stringValue = String(
                localized: "File type does not support cover art",
                comment: "Error message in cover art dialog"
            )
        case .unreadable:
            videoDropTarget.image = NSImage(named: NSImage.cautionName)
            videoStatus.stringValue = String(localized: "Not a video file", comment: "Error message in cover art dialog")
        }

        switch coverFileType {
        case .unspecified:
            coverDropTarget.image = nil
            coverStatus.stringValue = String(
                localized: "Drop file to use as cover art here.\nLeave empty to remove existing cover art.",
                comment: "Prompt in cover art dialog"
            )
        case .png, .jpeg:
            // DropTarget image is filled in automatically
            coverStatus.stringValue = String(
                localized: "Drop file to use as cover art here.\nLeave empty to remove existing cover art.",
                comment: "Prompt in cover art dialog"
            )
        case .other:
            coverDropTarget.image = NSImage(named: NSImage.cautionName)
            coverStatus.stringValue = String(localized: "Not a JPEG or PNG file", comment: "Error message in cover art dialog")
        case .unreadable:
            coverDropTarget.image = NSImage(named: NSImage.cautionName)
            coverStatus.stringValue = String(localized: "Not an image file", comment: "Error message in cover art dialog")
        }

        if [.mkv, .mp4].contains(videoFileType)
            && [.png, .jpeg].contains(coverFileType)
        {
            if videoFileHasCoverArt {
                doItButton.title = String(localized: "Replace", comment: "Submit button in cover art dialog")
            } else {
                doItButton.title = String(localized: "Add", comment: "Submit button in cover art dialog")
            }
            doItButton.isEnabled = true
        } else if [.mkv, .mp4].contains(videoFileType) && videoFileHasCoverArt
            && coverFileType == .unspecified
        {
            doItButton.title = String(localized: "Remove", comment: "Submit button in cover art dialog")
            doItButton.isEnabled = true
        } else {
            doItButton.title = String(localized: "Add", comment: "Submit button in cover art dialog")
            doItButton.isEnabled = false
        }
    }
}

// https://www.appcoda.com/nspasteboard-macos/
class VideoDropTarget: NSImageView {

    weak var parent: CoverArtView!

    override func awakeFromNib() {
        parent = (window?.contentView as! CoverArtView)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let items = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
            ), items.first != nil, let url = items.first as? NSURL
        else {
            parent.videoFileType = .unreadable
            parent.outcomes()
            return false
        }

        parent.videoFile = url as URL
        if (NSApp.delegate as! AppDelegate).isSandboxed { _ = parent.videoFile!.startAccessingSecurityScopedResource() }
        var fmt_ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&fmt_ctx, parent.videoFile!.path, nil, nil) == 0,
            avformat_find_stream_info(fmt_ctx, nil) == 0
        else {
            avformat_close_input(&fmt_ctx)
            parent.videoFileType = .unreadable
            parent.outcomes()
            return true
        }

        if strcmp(fmt_ctx!.pointee.iformat.pointee.name, "mov,mp4,m4a,3gp,3g2,mj2") == 0 {
            parent.videoFileType = .mp4
            if let brand = av_dict_get(fmt_ctx!.pointee.metadata, "major_brand", nil, 0) {
                // ffmpeg doesn't allow cover art in .MOV files
                if strcmp(brand.pointee.value, "qt  ") == 0 || strcmp(brand.pointee.value, "3g") == 0 {
                    parent.videoFileType = .other
                }
            }
        } else if strcmp(fmt_ctx!.pointee.iformat.pointee.name, "matroska,webm") == 0 {
            parent.videoFileType = .mkv
        } else {
            parent.videoFileType = .other
        }

        // Which streams we want to keep
        parent.videoFileStreams = []
        for idx in 0..<Int(fmt_ctx!.pointee.nb_streams) {
            let stream = fmt_ctx!.pointee.streams[idx]!.pointee
            let fourcc = stream.codecpar.pointee.codec_tag
            if fourcc == 0x736d_7264 || fourcc == 0x696d_7264 || fourcc == 0x5741_5243 {
                // ffmpeg can't copy encryped streams "drms" & "drmi", or Canon CRAW
                parent.videoFileType = .other
                break
            } else if (stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO)
                && stream.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS)
                    != AV_DISPOSITION_ATTACHED_PIC
            {
                // Video streams including timed thumbnails, but not cover art
                parent.videoFileStreams.append(idx)
            } else if stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
                || stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
                || stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT
            {
                // Audio, subtitles and attachments, but not opaque data (AVMEDIA_TYPE_DATA) which fmmpeg typically can't copy
                parent.videoFileStreams.append(idx)
            }
        }

        parent.videoFileHasCoverArt = false
        if [.mkv, .mp4].contains(parent.videoFileType) {
            // Find the best cover art stream.
            var artStream = -1
            var artPriority = 0
            for i in 0..<Int(fmt_ctx!.pointee.nb_streams) {
                guard let stream = fmt_ctx!.pointee.streams[i]?.pointee else { continue }
                let params = stream.codecpar.pointee
                if (params.codec_id == AV_CODEC_ID_PNG || params.codec_id == AV_CODEC_ID_MJPEG)
                    // Depending on codec and ffmpeg version cover art may be represented as attachment or as additional video stream(s)
                    && (params.codec_type == AVMEDIA_TYPE_ATTACHMENT
                        || (params.codec_type == AVMEDIA_TYPE_VIDEO
                            && ((stream.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS))
                                == AV_DISPOSITION_ATTACHED_PIC)))
                {
                    // MKVs can contain multiple cover art - see https://www.matroska.org/technical/attachments.html
                    let nameDict = av_dict_get(stream.metadata, "filename", nil, 0)
                    let filename = nameDict != nil ? String(cString: nameDict!.pointee.value) : ""
                    var priority = 1
                    if filename.lowercased().hasPrefix("cover.") {
                        priority = 4
                    } else if filename.lowercased().hasPrefix("cover_land.") {
                        priority = 3
                    } else if filename.lowercased().hasPrefix("cover_small.") {
                        priority = 2
                    }
                    if artPriority < priority  // Prefer first if multiple with same priority
                    {
                        artPriority = priority
                        artStream = i
                    }
                }
            }
            if artStream >= 0 {
                parent.videoFileHasCoverArt = true
                let stream = fmt_ctx!.pointee.streams[artStream]!.pointee
                let params = stream.codecpar.pointee
                if stream.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
                    parent.videoDropTarget.image = NSImage(
                        data: Data(bytes: stream.attached_pic.data, count: Int(stream.attached_pic.size))
                    )
                } else {  // attachment stream
                    parent.videoDropTarget.image = NSImage(data: Data(bytes: params.extradata, count: Int(params.extradata_size)))
                }
            } else {
                parent.videoDropTarget.image = NSWorkspace.shared.icon(forFile: parent.videoFile!.path)
            }
        }

        avformat_close_input(&fmt_ctx)
        parent.outcomes()
        return true
    }
}

class CoverDropTarget: NSImageView {

    weak var parent: CoverArtView!

    override func awakeFromNib() {
        parent = (window?.contentView as! CoverArtView)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let items = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
            ), items.first != nil, let url = items.first as? NSURL
        else {
            parent.coverFileType = .unreadable
            parent.outcomes()
            return false
        }

        parent.coverFile = url as URL
        if (NSApp.delegate as! AppDelegate).isSandboxed { _ = parent.coverFile!.startAccessingSecurityScopedResource() }
        if let json = try? helper(
            Bundle.main.path(forAuxiliaryExecutable: "ffprobe")!,
            args: ["-loglevel", "quiet", "-of", "json=c=1", "-show_streams", parent.coverFile!.path]
        ),
            let dictionary = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: []) as? [String: Any],
            let streams = dictionary["streams"] as? [[String: Any]]
        {
            if streams.count == 1 && ["png", "mjpeg"].contains(streams[0]["codec_name"] as? String) {
                parent.coverFileType = streams[0]["codec_name"] as! String == "png" ? .png : .jpeg
            } else {
                parent.coverFileType = .other
            }
        } else {
            parent.coverFileType = .unreadable
        }
        parent.outcomes()
        return true
    }
}
