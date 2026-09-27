# FFmpeg backports

`ffmpeg-notchlc-alpha.patch` backports Joss Gray's (dev-joss) NotchLC alpha
decoder fix from [FFmpeg PR #23791](https://www.mail-archive.com/ffmpeg-devel@ffmpeg.org/msg189842.html).
The pinned FFmpeg 9.0.2 revision does not include it.

The patch reads the alpha payload separately for each interpolated 4x4 block,
advances its interpolation index for every pixel, and corrects the signed
interpolation arithmetic and scaling. Without it, partially transparent pixels
can decode incorrectly, including values outside the 12-bit alpha range.

`scripts/buildffmpeg` applies the patch before building either architecture.
Repeated builds accept an already applied patch. This intentionally leaves
`ffmpeg/libavcodec/notchlc.c` modified within the submodule; do not commit a new
submodule revision for this local modification. An incompatible dependency
update fails the build so that the backport is reviewed rather than skipped.
Remove the patch and its build hook once the pinned FFmpeg includes the fix.
