Building
========

Prerequisites
-------
* Requires Xcode with macOS 15 SDK or later.
* Before building, update submodules with `git submodule update --init --recursive`.
* ffmpeg and its dependencies require "Meson", "Ninja", "pkg-config" and the "NASM" assembler to build. You can obtain them
  through [Homebrew](https://brew.sh) via `brew install meson ninja pkg-config nasm`. The built executables and libraries
  won't depend on Homebrew.

Products
-------
The Xcode project `QLVideo.xcodeproj` builds the following Products:

* QuickLook Video.app - App that hosts plugins and extensions, and registers the
  [Uniform Type Identifiers](http://developer.apple.com/library/mac/documentation/General/Conceptual/DevPedia-CocoaCore/UniformTypeIdentifier.html)
  of the media types that the plugins understand.
* mdimporter - Spotlight plugin that provides metadata.
* formatreader - Media extension that provides support for non-native file types and audio codecs.
* videodecoder - Media extension that provides support for non-native video codecs.
* contactsheet - Service that provides previews of video files as a series of snapshots.
* simpleplayer - Helper app for debugging the mdimporter plugin and the formatreader and videodecoder extensions.
  Plays files using AVFoundation. Not included in the main app.
* benchmark - Simple executable for benchmarking. Not included in the app.
* ffmpeg - The [FFmpeg](http://ffmpeg.org/) libraries. The app and its extensions depend on these.
  Also builds a standalone version of the `ffprobe` executable for bug reporting.
* dav1d - Support for the [AV1](https://en.wikipedia.org/wiki/AV1) codec. ffmpeg depends on this.
* zimg - Support for format and HDR colour conversion. ffmpeg depends on this.

Debugging
---------
All executables produce output in the system log. Use the filter `subsystem:uk.org.marginal.qlvideo` in the
Console app, or `sudo log stream --style compact --debug --predicate 's=uk.org.marginal.qlvideo'` in
the Terminal.

In addition, you can dump a summary of the extensions' internal state to the system log with
`killall -info "QLVideo Formats"` or `killall -info "QLVideo Codecs"`. 

To debug in Xcode, first build the "Quicklook Video" target once. Then switch targets depending on what you wish to debug:
* mdimporter - You can test the import with `mdimport -t -d3 /path/to/testfile`.
  The `mdimport` executable is not debuggable - to debug GetMetadataForFile() edit the "Run" scheme:
  - Executable: simpleplayer.app
  - Debug executable: ✔
  Choose a testfile in the simpleplayer application.
* formatreader and videodecoder - Edit the "Run" scheme for the "formatreader" target as follows:
  - Executable: simpleplayer.app
  - Debug executable: ✔
  Choose a testfile in the simpleplayer application.
* contactsheet - Edit the "Run" scheme:
  - Executable: navigate to "QLVideo Contact Sheet.app" in "QuickLook Video.app/Contents/Helpers/"
  - Debug executable: ✔
  Select a video file in Finder and choose "View Contact Sheet" from Finder's Services menu.
