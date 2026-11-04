//
//  MockByteSource.m
//  QLVideo
//

#import "MockByteSource.h"
#import "MediaExtension/MEError.h"

@implementation MockByteSource {
    NSURL *_fileURL;
    NSFileHandle *_fileHandle;
}

- (nullable instancetype)initWithFile:(NSURL *)fileURL {
    self = [super init];
    if (self) {
        _fileURL = [fileURL copy];
        _fileHandle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:nil];
        if (!_fileHandle) {
            return nil; // not a regular file
        }
    }
    return self;
}

- (void)dealloc {
    [_fileHandle closeFile];
}

- (NSString *)fileName {
    return _fileURL.lastPathComponent;
}

- (UTType *)contentType {
    NSString *typeString;
    if (![_fileURL getResourceValue:&typeString forKey:NSURLTypeIdentifierKey error:nil]) {
        return NULL;
    }
    return [UTType typeWithIdentifier:typeString];
}

- (int64_t)fileLength {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_fileURL.path error:nil];
    return [attributes[NSFileSize] unsignedLongLongValue];
}

- (BOOL)readDataOfLength:(size_t)length
              fromOffset:(int64_t)offset
           toDestination:(void *)dest
               bytesRead:(size_t *)bytesReadOut
                   error:(NSError *__autoreleasing _Nullable *_Nullable)error {
    *bytesReadOut = pread(_fileHandle.fileDescriptor, dest, length, (off_t)offset);
    if (*bytesReadOut == 0) {
        *error = [NSError errorWithDomain:MediaExtensionErrorDomain code:MEErrorEndOfStream userInfo:nil];
        return NO;
    } else if (*bytesReadOut < 0) {
        *bytesReadOut = 0;
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    } else {
        return YES;
    }
}

@end
