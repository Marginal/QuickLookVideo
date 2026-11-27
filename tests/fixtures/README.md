Both MP4 fixtures are two-second FFmpeg `testsrc2` clips at 160 × 96 and 24 fps. They use libx265
with 12-frame closed GOPs and up to three B-frames.

The 8-bit fixture stores its parameter sets in `hvcC`. The 10-bit fixture repeats parameter
sets in the stream at each keyframe and has an `hvcC` record with zero parameter-set arrays.
