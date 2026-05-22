//
//  libFLEX.x
//  Thin export shim used by FLEXing-style integrations.
//

#import "libFLEX.h"
#import "FLEXWindow.h"
#import "FLEXManager.h"

id FLXGetManager(void) {
    return [FLEXManager sharedManager];
}

SEL FLXRevealSEL(void) {
    return @selector(showExplorer);
}

Class FLXWindowClass(void) {
    return [FLEXWindow class];
}
