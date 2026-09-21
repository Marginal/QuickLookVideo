//
//  main.swift
//  QLVideo
//
// Entry point to instantiate AppDelegate.
// Doing this instead of the documented route of briding SwiftUI and AppDelegate with @NSApplicationDelegateAdaptor
// because we're not using SwiftUI's Scene and Window management which are more suited for a conventional app.
//

import Cocoa

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
