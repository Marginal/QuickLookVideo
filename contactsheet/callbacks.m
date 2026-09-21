//
//  callbacks.m
//  QLVideo
//
//  Created by Jonathan Harris on 02/12/2025.
//
//  Stuff we can't do in Swift for various reasons
//

#include "callbacks.h"

#define TRACE_FILEIO (DEBUG && 0)

static os_log_t logger;

//
// FFmpeg log callback. Difficult (impossible?) to do this in Swift because of varargs in callback
//

void av_log_callback(void *avcl, int level, const char *fmt, va_list vl) {
    static int print_prefix = 1;
    static int indent = 0; // we can be called with just spaces to do indentation. Remember if that's happened.
    char *line = NULL;

    if (level > av_log_get_level())
        return;

    if (!logger)
        logger = os_log_create("uk.org.marginal.qlvideo", "contactsheet");

    int line_size = av_log_format_line2(avcl, level, fmt, vl, NULL, 0, &print_prefix);
    if (line_size <= 0 || !(line = malloc(line_size + indent + 1)))
        return; // Can't log!
    else if (indent) {
        memset(line, ' ', indent);
    }
    if (av_log_format_line2(avcl, level, fmt, vl, line + indent, line_size + indent + 1, &print_prefix) > 0) {
        if (strspn(line + indent, " ") == line_size) {
            indent += line_size;
        } else {
            indent = 0;
            switch (level) {
            case AV_LOG_PANIC:
                os_log_fault(logger, "%{public}s", line);
                break;

            case AV_LOG_FATAL:
                os_log_error(logger, "%{public}s", line);
                break;

            default:
                os_log_debug(logger, "%{public}s", line);
            }
        }
    }
    free(line);
}

void setup_av_log_callback(void) { av_log_set_callback(av_log_callback); }
