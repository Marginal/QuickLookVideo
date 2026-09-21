//
//  callbacks.h
//  QLVideo
//

#ifndef callbacks_h
#define callbacks_h

#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

void setup_av_log_callback(void);

#ifdef __cplusplus
}
#endif

#endif // !callbacks_h
