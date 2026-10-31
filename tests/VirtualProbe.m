#import <AppKit/AppKit.h>
#import "../NativeBridge/include/DisplayBridge.h"
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        RemoteDisplay *display = [RemoteDisplay new];
        NSError *error = nil;
        if (![display createWithWidth:1440 height:900 error:&error]) {
            fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        CGDirectDisplayID id = display.displayID;
        CGRect bounds = CGDisplayBounds(id);
        printf("{\"displayID\":%u,\"online\":%s,\"width\":%.0f,\"height\":%.0f}\n",id,CGDisplayIsOnline(id)?"true":"false",bounds.size.width,bounds.size.height);
        return CGDisplayIsOnline(id) && bounds.size.width == 1440 && bounds.size.height == 900 ? 0 : 1;
    }
}
