//
//  MockByteSource.h
//  QLVideo
//
// MEByteSource's init() is NS_UNAVAILABLE so we can't provide an alternative mocking implementation or superclass for
// unit testing of FormatReader.
// Instead, create a protocol that both MEByteSource and our alternative mocking class conform to, so we can swap between
// implementations in FormatReader.

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ByteSource <NSObject>

@property(nonatomic, readonly) NSString *fileName;
@property(nonatomic, readonly, nullable) UTType *contentType;
@property(nonatomic, readonly) int64_t fileLength;

- (BOOL)readDataOfLength:(size_t)length
              fromOffset:(int64_t)offset
           toDestination:(void *)dest
               bytesRead:(size_t *)bytesReadOut
                   error:(NSError *__autoreleasing _Nullable *_Nullable)error;

@end

@interface MockByteSource : NSObject <ByteSource>

- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithFile:(NSURL *)file NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
