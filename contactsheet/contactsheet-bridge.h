//
//  contactsheet-bridge.h
//  QLVideo
//

#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/ambient_viewing_environment.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/hdr_dynamic_metadata.h>
#include <libavutil/hdr_dynamic_vivid_metadata.h>
#include <libswscale/swscale.h>

// FFmpeg internals
#include <libavutil/pixdesc.h>

// this project
#include "callbacks.h"
