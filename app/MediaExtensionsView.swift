//
//  MediaExtensionsView.swift
//  QLVideo
//

import Cocoa

final class MediaExtensionsView: NSView {

    @IBAction func ok(sender: NSButton) {
        let delegate = NSApp.delegate as! AppDelegate
        delegate.mainWindow.endSheet(self.window!)
    }

    @IBAction func openPrefs(sender: NSButton) {
        // Found in /System/Library/ExtensionKit/Extensions/LoginItems.appex/Contents/MacOS/LoginItems
        let url = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.mediaextension.formatreader"
        NSWorkspace.shared.open(URL(string: url)!)
        let delegate = NSApp.delegate as! AppDelegate
        delegate.mainWindow.endSheet(self.window!)
    }
}
