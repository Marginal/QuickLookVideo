//
//  callbacks.m
//  QLVideo
//
//  Created by Jonathan Harris on 02/12/2025.
//
//  Stuff we can't do in Swift for various reasons
//

#include "callbacks.h"
#import "QLVideo_Formats-Swift.h"

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
        logger = os_log_create("uk.org.marginal.qlvideo", "formatreader");

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

            case AV_LOG_ERROR:
                os_log(logger, "%{public}s", line);
                break;

            default:
                os_log_debug(logger, "%{public}s", line);
            }
        }
    }
    free(line);
}

void setup_av_log_callback(void) { av_log_set_callback(av_log_callback); }

//
// AVIOContext callbacks
//

int MEByteSource_read_packet(void *opaque, uint8_t *buf, int buf_size) {
    FormatReader *formatReader = (__bridge FormatReader *)opaque;
    size_t bytesRead = 0;
    NSError *error = nil;

    if (!logger)
        logger = os_log_create("uk.org.marginal.qlvideo", "formatreader");
#if TRACE_FILEIO
    os_log_debug(logger, "MEByteSource read_packet offset %lld, %p %d bytes", formatReader.avio_filepos, buf, buf_size);
#endif

    if (formatReader.avio_filepos == formatReader.byteSource.fileLength) {
#if TRACE_FILEIO
        os_log_debug(logger, "MEByteSource read_packet EOF");
#endif
        return AVERROR_EOF;
    }

    // Read into the provided buffer. readDataOfLength is marked as NS_SWIFT_UNAVAILABLE and I can't
    // find other ways of doing this in Swift without copying the data, so we're doing it in ObjC
    if ([formatReader.byteSource readDataOfLength:buf_size
                                       fromOffset:formatReader.avio_filepos
                                    toDestination:buf
                                        bytesRead:&bytesRead
                                            error:&error]) {
        formatReader.avio_filepos += bytesRead;
        return (int)bytesRead;
    }

    switch (error.code) {
    case MEErrorEndOfStream:
#if TRACE_FILEIO
        os_log_debug(logger, "MEByteSource read_packet EOF");
#endif
        return AVERROR_EOF;
    default:
        os_log_error(logger, "MEByteSource read_packet error %zd %{public}@", error.code, error.localizedDescription);
        return AVERROR_UNKNOWN;
    }
}

int64_t MEByteSource_seek(void *opaque, int64_t offset, int whence) {
    // MEByteSource doesn't doesn't support seek. Implement a file position/cursor manually.
    FormatReader *formatReader = (__bridge FormatReader *)opaque;

    if (!logger)
        logger = os_log_create("uk.org.marginal.qlvideo", "formatreader");

    switch (whence) {
    case AVSEEK_SIZE:
#if TRACE_FILEIO
        os_log_debug(logger, "MEByteSource seek AVSEEK_SIZE=%lld", formatReader.byteSource.fileLength);
#endif
        return formatReader.byteSource.fileLength;
    case SEEK_SET:
#if TRACE_FILEIO
        os_log_debug(logger, "MMByteSource seek SEEK_SET to %lld", offset);
#endif
        formatReader.avio_filepos = offset;
        return formatReader.avio_filepos;
    case SEEK_CUR:
#if TRACE_FILEIO
        os_log_debug(logger, "MEByteSource seek SEEK_CUR %+lld to %lld", offset, formatReader.avio_filepos + offset);
#endif
        formatReader.avio_filepos += offset;
        return formatReader.avio_filepos;
    case SEEK_END:
#if TRACE_FILEIO
        os_log_debug(logger, "MEByteSource seek SEEK_END %+lld to %lld", offset, formatReader.byteSource.fileLength + offset);
#endif
        formatReader.avio_filepos = formatReader.byteSource.fileLength + offset;
        return formatReader.avio_filepos;
    default:
        os_log_error(logger, "MEByteSource seek invalid whence=%d", whence);
        [NSException raise:NSInvalidArgumentException format:@"MEByteSource seek unsupported whence=%d", whence];
        return AVERROR_BUG;
    }
}
