The closed-GOP MP4 fixtures are two-second FFmpeg `testsrc2` clips at 160 × 96 and 24 fps. They
use libx265 with 12-frame GOPs and up to three B-frames.

The 8-bit fixture stores its parameter sets in `hvcC`. The 10-bit fixture repeats parameter
sets in the stream at each keyframe and has an `hvcC` record with zero parameter-set arrays.

`hev1-10-bit-open-gop.mp4` is a two-second 320 × 180 Main 10 clip at 24 fps with in-band parameter
sets. Its first clean random-access picture is frame 12. Leading frames 10 and 11 are decoded after
frame 12 but need reference pictures preceding it. Starting at frame 12 suppresses only these two
pictures. When decoding from the start, all 48 frames are available.
