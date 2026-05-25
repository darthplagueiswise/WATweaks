#import "WAGRLog.h"
#import <stdarg.h>

static NSMutableArray<NSString *> *gWAGRLogLines = nil;
static NSObject *gWAGRLogLock = nil;
static NSDateFormatter *gWAGRLogFormatter = nil;
static const NSUInteger kWAGRMaxLogLines = 600;

static void WAGRLogEnsure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRLogLines = [NSMutableArray arrayWithCapacity:kWAGRMaxLogLines];
        gWAGRLogLock = [NSObject new];
        gWAGRLogFormatter = [NSDateFormatter new];
        gWAGRLogFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        gWAGRLogFormatter.dateFormat = @"HH:mm:ss.SSS";
    });
}

void WAGRLogAppend(NSString *message) {
    if (!message.length) return;
    WAGRLogEnsure();
    NSString *ts = [gWAGRLogFormatter stringFromDate:[NSDate date]] ?: @"--:--:--.---";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", ts, message];
    NSLog(@"[WATweaks] %@", message);
    @synchronized (gWAGRLogLock) {
        [gWAGRLogLines addObject:line];
        while (gWAGRLogLines.count > kWAGRMaxLogLines) [gWAGRLogLines removeObjectAtIndex:0];
    }
}

void WAGRLogAppendF(NSString *format, ...) {
    if (!format.length) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    WAGRLogAppend(msg);
}

NSString *WAGRLogSnapshot(void) {
    WAGRLogEnsure();
    @synchronized (gWAGRLogLock) {
        if (!gWAGRLogLines.count) return @"(sem logs WATweaks nesta sessão)";
        return [gWAGRLogLines componentsJoinedByString:@"\n"];
    }
}

void WAGRLogClear(void) {
    WAGRLogEnsure();
    @synchronized (gWAGRLogLock) { [gWAGRLogLines removeAllObjects]; }
    NSLog(@"[WATweaks] log buffer cleared");
}
