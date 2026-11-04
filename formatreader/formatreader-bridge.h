//
//  formatreader-bridge.h
//  QLVideo
//

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavutil/avutil.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/hdr_dynamic_metadata.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

// FFmpeg internals
#include <libavutil/pixdesc.h>
#include <libswresample/swresample_internal.h> // for SwrContext

// this project
#include "callbacks.h"
#import "MockByteSource.h"
