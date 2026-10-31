#import "DisplayBridge.h"
#import <dlfcn.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, retain) NSString *name;
@property(nonatomic, retain) dispatch_queue_t queue;
@property(nonatomic) unsigned int vendorID, productID, serialNum, maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, retain) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

typedef CGError (*ConfigureEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);

@implementation RemoteDisplay {
    CGVirtualDisplay *_display;
    NSMutableArray<NSNumber *> *_disabled;
}
- (instancetype)init {
    if ((self = [super init])) _disabled = [NSMutableArray new];
    return self;
}
- (CGDirectDisplayID)displayID { return _display ? _display.displayID : 0; }
- (NSArray<NSNumber *> *)disabledDisplays { return [_disabled copy]; }
- (BOOL)fail:(NSError **)error message:(NSString *)message {
    if (error) *error = [NSError errorWithDomain:@"MacWebRemote.Display" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
- (BOOL)createWithWidth:(unsigned int)width height:(unsigned int)height error:(NSError **)error {
    if (_display) return YES;
    if (!NSClassFromString(@"CGVirtualDisplay")) return [self fail:error message:@"macOS does not provide CGVirtualDisplay."];
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.name = @"MacWeb Remote";
    descriptor.queue = dispatch_get_main_queue();
    descriptor.vendorID = 0x4d57;
    descriptor.productID = 1;
    descriptor.serialNum = 20261031;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 110, height * 25.4 / 110);
    CGVirtualDisplay *candidate = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60]];
    if (!candidate || ![candidate applySettings:settings]) return [self fail:error message:@"Could not create the virtual display."];
    _display = candidate;
    return YES;
}
- (ConfigureEnabled)configureFunction {
    return (ConfigureEnabled)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
}
- (BOOL)disablePhysicalDisplays:(NSError **)error {
    if (!_display || !CGDisplayIsOnline(_display.displayID)) return [self fail:error message:@"The virtual display must be active before turning off physical displays."];
    if (_disabled.count) return YES;
    ConfigureEnabled configure = [self configureFunction];
    if (!configure) return [self fail:error message:@"This macOS version does not support disabling displays."];
    CGDirectDisplayID displays[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count)) return [self fail:error message:@"Could not enumerate displays."];
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config)) return [self fail:error message:@"Could not begin display configuration."];
    NSMutableArray *pending = [NSMutableArray new];
    for (uint32_t i=0; i<count; i++) {
        if (displays[i] == _display.displayID) continue;
        if (configure(config, displays[i], false)) {
            CGCancelDisplayConfiguration(config);
            return [self fail:error message:@"The system rejected disabling a display."];
        }
        [pending addObject:@(displays[i])];
    }
    // App-scoped changes are reverted by WindowServer if this process exits.
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly)) return [self fail:error message:@"Could not apply display changes."];
    [_disabled addObjectsFromArray:pending];
    return YES;
}
- (BOOL)restorePhysicalDisplays:(NSError **)error {
    if (!_disabled.count) return YES;
    ConfigureEnabled configure = [self configureFunction];
    if (!configure) return [self fail:error message:@"Display restoration is unavailable."];
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config)) return [self fail:error message:@"Could not begin display restoration."];
    for (NSNumber *display in _disabled) {
        if (configure(config, display.unsignedIntValue, true)) {
            CGCancelDisplayConfiguration(config);
            return [self fail:error message:@"Could not restore a display; its identity is retained for retry."];
        }
    }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly)) return [self fail:error message:@"The system rejected restoring displays."];
    [_disabled removeAllObjects];
    return YES;
}
@end
