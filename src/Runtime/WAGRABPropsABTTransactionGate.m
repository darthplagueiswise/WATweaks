#import "WAGRABPropsABTTransactionGate.h"
#import "WAGRLog.h"

static NSObject *gGateLock;
static NSString *gGateChannel;
static NSString *gGateToken;
static NSTimeInterval gGateStartedTime;
static NSString *gGateChildChannel;
static NSString *gGateChildToken;
static NSTimeInterval gGateChildStartedTime;
static BOOL gGateReleaseOwnerWhenIdle;

static void EnsureGate(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gGateLock = [NSObject new]; });
}

BOOL WAGRABPropsABTTransactionAcquire(NSString *channel,
                                      NSString *token,
                                      NSString **diagnostic) {
    EnsureGate();
    if (!channel.length || !token.length) {
        if (diagnostic) *diagnostic = @"ABT transaction gate requires channel and token";
        return NO;
    }
    NSString *busy = nil;
    @synchronized (gGateLock) {
        if (gGateToken.length) {
            busy = [NSString stringWithFormat:@"ABT transaction already active: channel=%@ token=%@",
                    gGateChannel ?: @"?", gGateToken];
        } else {
            gGateChannel = [channel copy];
            gGateToken = [token copy];
            gGateStartedTime = NSDate.date.timeIntervalSince1970;
            gGateReleaseOwnerWhenIdle = NO;
        }
    }
    if (busy) {
        if (diagnostic) *diagnostic = busy;
        return NO;
    }
    WAGRLogAppendF(@"[ABProps][ABTGate] acquired channel=%@ token=%@", channel, token);
    return YES;
}

BOOL WAGRABPropsABTTransactionAcquireWithin(NSString *channel,
                                            NSString *token,
                                            NSString *ownerToken,
                                            NSString **diagnostic) {
    EnsureGate();
    if (!channel.length || !token.length || !ownerToken.length) {
        if (diagnostic) *diagnostic = @"ABT child transaction requires channel, token and owner token";
        return NO;
    }
    NSString *failure = nil;
    @synchronized (gGateLock) {
        if (![gGateToken isEqualToString:ownerToken]) {
            failure = [NSString stringWithFormat:
                @"ABT transaction owner mismatch: requested=%@ active=%@",
                ownerToken, gGateToken ?: @"none"];
        } else if (gGateReleaseOwnerWhenIdle) {
            failure = [NSString stringWithFormat:
                @"ABT transaction owner is quarantined pending release: %@",
                ownerToken];
        } else if (gGateChildToken.length) {
            failure = [NSString stringWithFormat:
                @"ABT child transaction already active: channel=%@ token=%@",
                gGateChildChannel ?: @"?", gGateChildToken];
        } else {
            gGateChildChannel = [channel copy];
            gGateChildToken = [token copy];
            gGateChildStartedTime = NSDate.date.timeIntervalSince1970;
        }
    }
    if (failure) {
        if (diagnostic) *diagnostic = failure;
        return NO;
    }
    WAGRLogAppendF(@"[ABProps][ABTGate] acquired child channel=%@ token=%@ owner=%@",
                   channel, token, ownerToken);
    return YES;
}

void WAGRABPropsABTTransactionRelease(NSString *token) {
    EnsureGate();
    NSString *channel = nil;
    NSString *kind = nil;
    NSString *deferredOwnerChannel = nil;
    NSString *deferredOwnerToken = nil;
    BOOL released = NO;
    @synchronized (gGateLock) {
        if (token.length && [gGateChildToken isEqualToString:token]) {
            channel = [gGateChildChannel copy];
            gGateChildChannel = nil;
            gGateChildToken = nil;
            gGateChildStartedTime = 0;
            kind = @"child";
            released = YES;
            if (gGateReleaseOwnerWhenIdle && gGateToken.length) {
                deferredOwnerChannel = [gGateChannel copy];
                deferredOwnerToken = [gGateToken copy];
                gGateChannel = nil;
                gGateToken = nil;
                gGateStartedTime = 0;
                gGateReleaseOwnerWhenIdle = NO;
            }
        } else if (token.length && [gGateToken isEqualToString:token] &&
                   !gGateChildToken.length) {
            channel = [gGateChannel copy];
            gGateChannel = nil;
            gGateToken = nil;
            gGateStartedTime = 0;
            gGateReleaseOwnerWhenIdle = NO;
            kind = @"owner";
            released = YES;
        }
    }
    if (released) {
        WAGRLogAppendF(@"[ABProps][ABTGate] released %@ channel=%@ token=%@",
                       kind ?: @"?", channel ?: @"?", token);
    }
    if (deferredOwnerToken.length) {
        WAGRLogAppendF(@"[ABProps][ABTGate] released deferred owner channel=%@ token=%@",
                       deferredOwnerChannel ?: @"?", deferredOwnerToken);
    }
}

void WAGRABPropsABTTransactionReleaseWhenIdle(NSString *ownerToken) {
    EnsureGate();
    NSString *channel = nil;
    BOOL released = NO, deferred = NO;
    @synchronized (gGateLock) {
        if (![gGateToken isEqualToString:ownerToken]) return;
        if (gGateChildToken.length) {
            gGateReleaseOwnerWhenIdle = YES;
            deferred = YES;
        } else {
            channel = [gGateChannel copy];
            gGateChannel = nil;
            gGateToken = nil;
            gGateStartedTime = 0;
            gGateReleaseOwnerWhenIdle = NO;
            released = YES;
        }
    }
    if (released) {
        WAGRLogAppendF(@"[ABProps][ABTGate] released idle owner channel=%@ token=%@",
                       channel ?: @"?", ownerToken ?: @"?");
    } else if (deferred) {
        WAGRLogAppendF(@"[ABProps][ABTGate] owner release deferred until child completion token=%@",
                       ownerToken ?: @"?");
    }
}

NSDictionary<NSString *, id> *WAGRABPropsABTTransactionGateDocument(void) {
    EnsureGate();
    @synchronized (gGateLock) {
        return @{
            @"busy": @(gGateToken.length > 0),
            @"channel": gGateChannel ?: @"",
            @"token": gGateToken ?: @"",
            @"started_time": @(gGateStartedTime),
            @"child_busy": @(gGateChildToken.length > 0),
            @"child_channel": gGateChildChannel ?: @"",
            @"child_token": gGateChildToken ?: @"",
            @"child_started_time": @(gGateChildStartedTime),
            @"owner_release_when_idle": @(gGateReleaseOwnerWhenIdle)
        };
    }
}
