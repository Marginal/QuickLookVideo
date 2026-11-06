QuickLook Video [![Download on the Mac App Store](https://github.com/Marginal/QLVideo/raw/master/img/appstore.svg)](https://apps.apple.com/us/app/quicklook-video/id6759566961?pt=1451928&ct=GitHub&mt=8)
===============

Thumbnails in Finder, Quick Look previews, and metadata in Spotlight and Finder's Get Info window
for most types of audio and video files.

QuickLook, AVFoundation and Spotlight understand a limited number of media files - mostly only MPEG
audio and video codecs within ISO file formats. This app adds support for wide range of other codecs
and "non-native" media file types, including:

* File formats: Matroska `.mka`, `.mkv`, WebM `.webm`, Windows Media `.wma`, `.wmv`,
  Ogg Video `.ogm`, `.ogv`, AVI `.avi`, QuickTime `.mov`, Flash Video `.flv`, `.f4v`,
  Real Media `.ra`, `.rm`, `.rv`, SMPTE `.gxf`, `.mxf`.
* Audio codecs: Vorbis, Windows Media Audio, WavPak, ATRAC, etc.
* Video codecs: VP6, VP8, VP9, AV1, HEVC/H.265, VVC/H.266, Dolby Vision, Theora, DXV, HAP, Sorenson,
  Cinepak, AIC, Flash, Real Video, DivX, Intel Indeo, QuickTime animation, etc.

How does it work?
-----------------
The app contains a Spotlight extension that adds support for non-native file formats, and two Media
Extensions that add support to AVFoundation for non-native file formats and video codecs.

(Long-time Mac users may remember [Perian](https://www.perian.org) which performed a similar
function with the QuickTime framework before QuickTime was replaced by AVFoundation).

Installation and Usage
----------------------
See [Getting Started](https://github.com/Marginal/QLVideo/wiki/Getting-Started).

Troubleshooting
---------------
See the [troubleshooting guide](https://github.com/Marginal/QLVideo/wiki/Troubleshooting) if you have any problems.

<img src="img/finder.jpeg" alt="Finder" width="517"/> &nbsp; <img src="img/info.jpeg" alt="Finder Info" width="271"/>
<img src="img/preview.jpeg" alt="QuickLook preview" width="879"/>

License
-------
Copyright © 2014-2026 Jonathan Harris.

Licensed under the [GNU Public License (GPL)](http://www.gnu.org/licenses/gpl-2.0.html) version 2 or later.
