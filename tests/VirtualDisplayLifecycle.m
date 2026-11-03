#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "DisplayBridge.h"

static BOOL online(CGDirectDisplayID identifier) {
    CGDirectDisplayID identifiers[32]; uint32_t count = 0;
    NSCAssert(CGGetOnlineDisplayList(32, identifiers, &count) == kCGErrorSuccess, @"Cannot enumerate displays");
    for (uint32_t index = 0; index < count; index++) if (identifiers[index] == identifier) return YES;
    return NO;
}

int main(void) {
    @autoreleasepool {
        RemoteDisplay *display = [RemoteDisplay new];
        NSError *error = nil;
        NSCAssert([display removeWithError:&error], @"Removing an absent display must be idempotent");
        for (int cycle = 0; cycle < 2; cycle++) {
            CGDirectDisplayID identifier;
            @autoreleasepool {
                NSCAssert([display createWithWidth:960 height:600 error:&error], @"Create failed: %@", error);
                identifier = display.displayID;
                NSCAssert(identifier != 0 && online(identifier), @"Owned virtual display must be online");
                NSCAssert([display removeWithError:&error], @"Remove failed: %@", error);
                NSCAssert(display.displayID == 0, @"Ownership must be cleared after release");
            }
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
            while (online(identifier) && deadline.timeIntervalSinceNow > 0) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            NSCAssert(!online(identifier), @"Removed display is still online");
            NSCAssert([display removeWithError:&error], @"Repeated removal must be safe");
        }
        puts("Virtual display create/remove lifecycle passed (two cycles).");
    }
    return 0;
}
