#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
@interface RemoteDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly) NSArray<NSNumber *> *disabledDisplays;
- (BOOL)createWithWidth:(unsigned int)width height:(unsigned int)height error:(NSError **)error;
- (BOOL)disablePhysicalDisplays:(NSError **)error;
- (BOOL)restorePhysicalDisplays:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
