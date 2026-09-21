//
//  AppDelegate.swift
//  QuickLook Video
//
//  Created by Jonathan Harris on 15/11/2022.
//

import AVFoundation
import Cocoa
import MediaToolbox
import OSLog
import QuickLookThumbnailing
import Security
import VideoToolbox

// Settings
let kSettingsLastSpotlight = "LastSpotlight"  // Last version ran - for upgrade check
let kSettingsLastQuickLook = "LastQuickLook"  // Last version ran - for upgrade check
let kSettingsSnapshotCount = "SnapshotCount"  // Max number of snapshots generated in Preview mode.
let kSettingsSnapshotTime = "SnapshotPercentage"  // Seek offset for thumbnails and single Previews [s].
let kSettingsSnapshotAlways = "SnapshotAlways"  // Whether to generate static snapshot(s) even if playable Preview is available.

// Setting defaults
let kDefaultSnapshotTime = 0.25  // CoreMedia generator appears to use 10s.

// Last time the extensions changed enough that we should automatically reset spotlight or thumbnails
let kResetSpotlight = 3.09  // metadata schema fix
let kResetQuickLook = 3.11  // Cover art fix and thumbnail improvements

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet var mainWindow: NSWindow!
    @IBOutlet var reportIssue: NSMenuItem!

    @IBOutlet var versionLabel: NSTextField!
    @IBOutlet var copyrightNote: NSTextField!

    var snapshotTime = NSSlider()
    var snapshotTimeValue = NSTextField()

    @IBOutlet var regenerateNote: NSTextField!
    @IBOutlet var reindexingNote: NSTextField!

    // Dialogs
    @IBOutlet var issueWindow: NSWindow!
    @IBOutlet var crashReportWindow: NSWindow!
    @IBOutlet var coverArtWindow: NSWindow!
    @IBOutlet var mediaExtensionsWindow: NSWindow!

    var defaults: UserDefaults?
    var logger = Logger(subsystem: "uk.org.marginal.qlvideo", category: "app")

    lazy var isSandboxed: Bool = {
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == noErr,
            SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == noErr,
            let info = info as? [CFString: Any],
            let entitlements = info[kSecCodeInfoEntitlementsDict] as? [CFString: Any]
        else { return false }
        return entitlements["com.apple.security.app-sandbox" as CFString] as? Bool ?? false
    }()

    // View is loaded but not yet displayed - read settings
    func applicationDidFinishLaunching(_ aNotification: Notification) {

        let myBundle = Bundle.main
        let version: String = myBundle.infoDictionary!["CFBundleShortVersionString"] as! String
        versionLabel.stringValue = "Version \(version)"
        copyrightNote.stringValue = myBundle.infoDictionary!["NSHumanReadableCopyright"] as! String
        regenerateNote.isHidden = true
        reindexingNote.isHidden = true

        // Allow loading of MediExtensions for Issue View and sanity check
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()

        // Ensure our Services helper app has been seen. Should be redundant but just in case
        // https://developer.apple.com/documentation/BundleResources/placing-content-in-a-bundle
        LSRegisterURL(
            myBundle.bundleURL.appending(
                components: "Contents",
                "Helpers",
                "QLVideo Contact Sheet.app",
                directoryHint: .isDirectory
            ) as CFURL,
            false
        )

        // Set up help
        if isSandboxed {
            NSHelpManager.shared.registerBooks(in: myBundle)  // should be redundant but just in case
        } else {
            NSApplication.shared.helpMenu = NSMenu(title: "Unused")  // Remove the searchable Help entry
        }

        let suiteName: String = myBundle.infoDictionary!["ApplicationGroup"] as! String
        defaults = UserDefaults(suiteName: suiteName)
        if let defaults {
            if defaults.double(forKey: kSettingsSnapshotTime) <= 0 {
                snapshotTime.doubleValue = kDefaultSnapshotTime
            } else {
                snapshotTime.doubleValue = defaults.double(forKey: kSettingsSnapshotTime)
            }
        } else {
            snapshotTime.doubleValue = kDefaultSnapshotTime
            logger.error("Can't access defaults for \(suiteName, privacy: .public)")
        }
        snapshotTimeValue.stringValue = "\(Int(snapshotTime.doubleValue * 100)) %"

        // Check if unsupported hardware and don't do further setup if so
        if sysCtl("hw.machine") == "x86_64" && sysCtl("hw.optional.avx2_0") != "yes" {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(
                localized: "QuickLook Video requires a late-2013 Mac or newer, with AVX2 and VideoToolbox support",
                comment: "Error message in app"
            )
            alert.informativeText = String.localizedStringWithFormat(
                String(localized: "Please use release %@ of QuickLook Video", comment: "Advice in app"),
                "1.x"
            )
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // If we don't have base-level VideoToolbox support (e.g. under emulation) then our videodecoder won't get loaded,
        // so nothing will work
        if !VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(
                localized: "QuickLook Video 3.x requires GPU support for VideoToolbox, which isn't available on this machine",
                comment: "Error message in app"
            )
            alert.informativeText = String.localizedStringWithFormat(
                String(localized: "Please use release %@ of QuickLook Video", comment: "Advice in app"),
                "2.x"
            )
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        maybeResetCache(version)
        maybeResetSpotlight(version)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK:- UI actions

    // snapshotTime slider changed - round to int, update text field, and update defaults
    @IBAction func snapshotTimeChanged(sender: NSSlider) {
        let value = snapshotTime.doubleValue
        snapshotTime.doubleValue = (value * 100).rounded() / 100
        snapshotTimeValue.stringValue = "\(Int(snapshotTime.doubleValue * 100)) %"
        defaults?.set(value, forKey: kSettingsSnapshotTime)
    }

    @IBAction func regenerateThumbnails(sender: NSButton) {
        defaults?.synchronize()
        regenerateNote.isHidden = true
        if resetCache() {
            do { try helper("/usr/bin/killall", args: ["AudiovisualThumbnailExtension"]) } catch {}
            do { try helper("/usr/bin/killall", args: ["-kill", "-m", "QLVideo (Formats|Codecs)"]) } catch {}
            do {
                try helper("/usr/bin/killall", args: ["Finder"])
            } catch {
                // Managed to tell QuickLook to regenerate cache, but couldn't restart Finder - Sandboxed?
                regenerateNote.isHidden = false
            }
        }

        // No way to tell directly whether MediaExtensions are enabled.
        // So check playability of a file that requires a formatreader.
        guard let url = Bundle.main.url(forResource: "test-vp8-vorbis-webvtt", withExtension: "webm") else { return }
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let playable = try await asset.load(.isPlayable)
                if !playable {
                    logger.error("Test file not playable: formatreader not available")
                    mainWindow.beginSheet(mediaExtensionsWindow, completionHandler: nil)
                    return
                }
            } catch {
                logger.error("Test file not playable \(error.localizedDescription, privacy: .public)")
                mainWindow.beginSheet(mediaExtensionsWindow, completionHandler: nil)
                return
            }
            // Check whether thumbnailable, which requires videodecoder too
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 128, height: 128),
                scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                representationTypes: .thumbnail  // ask for thumbnail only, not icon or all
            )
            do {
                _ = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } catch {
                logger.error("Test file not thumbnailable: \(error.localizedDescription, privacy: .public)")
                mainWindow.beginSheet(mediaExtensionsWindow, completionHandler: nil)
            }
        }
    }

    @IBAction func showHelp(sender: NSMenuItem) {
        if isSandboxed {
            NSApplication.shared.showHelp(sender)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/Marginal/QLVideo/wiki")!)
        }
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        if isSandboxed {
            NSApplication.shared.showHelp(alert)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/Marginal/QLVideo/wiki")!)
        }
        return true
    }

    @IBAction func reportIssue(sender: NSMenuItem) {
        mainWindow.beginSheet(issueWindow, completionHandler: nil)
    }

    func showCrashReport(filePath: URL) {
        if let view = crashReportWindow.contentView as? CrashReportView {
            view.configure(url: filePath)
            mainWindow.beginSheet(crashReportWindow, completionHandler: nil)
        }
    }

    @IBAction func coverArt(sender: NSMenuItem) {
        coverArtWindow.makeKeyAndOrderFront(self)
    }

    // MARK:- plugin management

    // Reset the QuickLook cache if previous app version was too old
    func maybeResetCache(_ currentVersion: String) {
        regenerateNote.isHidden = true
        if let defaults {
            let oldVersion = defaults.double(forKey: kSettingsLastQuickLook)  // will be zero if not set
            if oldVersion < kResetQuickLook {
                if resetCache() {
                    defaults.set(currentVersion, forKey: kSettingsLastQuickLook)
                    regenerateNote.isHidden = false
                }
            } else {
                defaults.set(currentVersion, forKey: kSettingsLastQuickLook)
            }
        }
    }

    // Reindex Spotlight metadata if previous app version was too old
    func maybeResetSpotlight(_ currentVersion: String) {
        reindexingNote.isHidden = true
        if let defaults {
            let oldVersion = defaults.double(forKey: kSettingsLastSpotlight)  // will be zero if not set
            if oldVersion < kResetSpotlight {
                // Spotlight can be slow to notice new importers. Nothing we can do about that so poll.
                let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [self] timer in
                    let mdimporter = "\(Bundle.main.bundlePath)/Contents/Library/Spotlight/"
                    do {
                        let listing = try helper("/usr/bin/mdimport", args: ["-L"])
                        if listing.contains(mdimporter) {
                            timer.invalidate()
                            if resetSpotlight() {
                                defaults.set(currentVersion, forKey: kSettingsLastSpotlight)
                                reindexingNote.isHidden = false
                            }
                        }
                    } catch {
                        timer.invalidate()
                    }
                }
                timer.fire()
            } else {
                defaults.set(currentVersion, forKey: kSettingsLastSpotlight)
            }
        }
    }
}

// MARK:- Helper functions

func resetCache() -> Bool {
    do {
        try helper("/usr/bin/qlmanage", args: ["-r", "cache"])
        return true
    } catch {
        return false
    }
}

func resetSpotlight() -> Bool {
    let mdimporter = "\(Bundle.main.bundlePath)/Contents/Library/Spotlight/QLVideo Metadata.mdimporter"
    do {
        try helper("/usr/bin/mdimport", args: ["-r", mdimporter])
        return true
    } catch {
        return false
    }
}

func sysCtl(_ name: String) -> String {
    var size = 0
    if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 {
        return "???"
    }
    var value = [CChar](repeating: 0, count: size)
    if sysctlbyname(name, &value, &size, nil, 0) != 0 {
        return "???"
    }

    // sysctl can return a int32, uint64 or chars. TODO: handle uint
    if size == 4 && value[0] == 1 {
        return "yes"
    } else if size == 4 && value[0] == 0 {
        return "no"
    } else {
        return String(cString: value)
    }
}

@discardableResult
func helper(_ exe: String, args: [String]) throws -> String {
    let task = Process()
    do {
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
    } catch {
        throw NSError(domain: "uk.org.marginal.qlvideo", code: -1, userInfo: [NSLocalizedFailureReasonErrorKey: "\(error)"])
    }

    let stdout = String(data: (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: (task.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if task.terminationStatus != 0 {
        throw NSError(
            domain: "uk.org.marginal.qlvideo",
            code: Int(task.terminationStatus),
            userInfo: [NSLocalizedFailureReasonErrorKey: stderr]
        )
    }

    return stdout + stderr
}
