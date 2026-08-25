#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#import "../Runtime/WAGRSurface.h"
#import "../Runtime/WAGRRuntimeValueStore.h"

#include <string.h>

/*
 * Generic runtime entries are class+selector metadata.  Static metadata alone
 * cannot produce an instance-method value: an actual live receiver is required.
 *
 * The old browser tried to solve that by walking arbitrary ivars and crashed.
 * The crash guard correctly removed that unsafe graph walk, but the consequence
 * was many honest "receiver indisponível" rows (e.g. dependency accessors such
 * as -abProperties on manager/controller instances).
 *
 * This layer uses a safer model: install a tiny ABI-checked pass-through probe
 * only for visible zero-argument instance getters.  When WhatsApp naturally
 * calls that getter, the probe records the real `self` weakly and returns the
 * original value unchanged.  Subsequent browser reads invoke the getter on that
 * exact live instance.  No alloc/init guesses and no arbitrary ivar traversal.
 */

@interface WAGRReceiverProbe : NSObject
@property(nonatomic, copy) NSString *uid;
@property(nonatomic, copy) NSString *className;
@property(nonatomic, assign) SEL selector;
@property(nonatomic, assign) IMP original;
@property(nonatomic, assign) char typeCode;
@end
@implementation WAGRReceiverProbe
@end

static NSMutableDictionary<NSString *, WAGRReceiverProbe *> *gWAGRReceiverProbes;
static NSMapTable<NSString *, id> *gWAGRReceiverByUID;
static NSMapTable<NSString *, id> *gWAGRReceiverByClass;
static NSObject *gWAGRReceiverLock;
static id (*gWAGRReceiverFallback)(id, SEL, WAGREntry *) = NULL;
static NSString *(*gWAGRCurrentFallback)(id, SEL, WAGREntry *, id *) = NULL;

static void WAGRReceiverEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWAGRReceiverProbes = [NSMutableDictionary dictionary];
        gWAGRReceiverByUID = [NSMapTable strongToWeakObjectsMapTable];
        gWAGRReceiverByClass = [NSMapTable strongToWeakObjectsMapTable];
        gWAGRReceiverLock = [NSObject new];
    });
}

static NSString *WAGRReceiverUID(NSString *className, NSString *selectorName) {
    if (!className.length || !selectorName.length) return @"";
    return [NSString stringWithFormat:@"%@|instance|%@", className, selectorName];
}

static const char *WAGRReceiverSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRReceiverSupportedType(char type) {
    return strchr("BcCsSiIlLqQfd@", type) != NULL;
}

static BOOL WAGRReceiverStructuralSelector(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    if (!lower.length) return YES;
    if ([lower hasPrefix:@"init"] || [lower hasPrefix:@"dealloc"] ||
        [lower hasPrefix:@"copy"] || [lower hasPrefix:@"mutablecopy"]) return YES;
    static NSSet<NSString *> *blocked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = [NSSet setWithArray:@[
            @"retain", @"release", @"autorelease", @"retaincount", @"class",
            @"superclass", @"self", @"zone", @"hash", @"description",
            @"debugdescription", @"methodsignatureforselector", @"forwardinvocation:"
        ]];
    });
    return [blocked containsObject:lower];
}

static UIViewController *WAGRReceiverFindVisibleBrowser(UIViewController *controller) {
    if (!controller) return nil;
    if ([NSStringFromClass([controller class]) isEqualToString:@"WAGRSurfaceBrowserVC"] &&
        controller.viewIfLoaded.window) return controller;
    if (controller.presentedViewController) {
        UIViewController *found = WAGRReceiverFindVisibleBrowser(controller.presentedViewController);
        if (found) return found;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        UIViewController *found = WAGRReceiverFindVisibleBrowser(((UINavigationController *)controller).topViewController);
        if (found) return found;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *found = WAGRReceiverFindVisibleBrowser(((UITabBarController *)controller).selectedViewController);
        if (found) return found;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = WAGRReceiverFindVisibleBrowser(child);
        if (found) return found;
    }
    return nil;
}

static void WAGRReceiverRefreshVisibleRows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            UIViewController *browser = WAGRReceiverFindVisibleBrowser(window.rootViewController);
            if (![browser isKindOfClass:UITableViewController.class]) continue;
            UITableView *table = ((UITableViewController *)browser).tableView;
            NSArray<NSIndexPath *> *visible = table.indexPathsForVisibleRows ?: @[];
            if (visible.count) {
                [table reloadRowsAtIndexPaths:visible withRowAnimation:UITableViewRowAnimationNone];
            }
            break;
        }
    });
}

static void WAGRReceiverObserve(WAGRReceiverProbe *probe, id receiver) {
    if (!probe || !receiver) return;
    BOOL changed = NO;
    WAGRReceiverEnsureState();
    @synchronized (gWAGRReceiverLock) {
        id old = [gWAGRReceiverByUID objectForKey:probe.uid];
        if (old != receiver) changed = YES;
        [gWAGRReceiverByUID setObject:receiver forKey:probe.uid];
        if (probe.className.length) [gWAGRReceiverByClass setObject:receiver forKey:probe.className];
    }
    if (changed) WAGRReceiverRefreshVisibleRows();
}

static IMP WAGRReceiverReplacement(WAGRReceiverProbe *probe) {
    switch (probe.typeCode) {
        case 'B': return imp_implementationWithBlock(^BOOL(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((BOOL (*)(id, SEL))probe.original)(receiver, probe.selector) : NO;
        });
        case 'c': return imp_implementationWithBlock(^signed char(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((signed char (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'C': return imp_implementationWithBlock(^unsigned char(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((unsigned char (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 's': return imp_implementationWithBlock(^short(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((short (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'S': return imp_implementationWithBlock(^unsigned short(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((unsigned short (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'i': return imp_implementationWithBlock(^int(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((int (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'I': return imp_implementationWithBlock(^unsigned int(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((unsigned int (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'l': return imp_implementationWithBlock(^long(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((long (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'L': return imp_implementationWithBlock(^unsigned long(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((unsigned long (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'q': return imp_implementationWithBlock(^long long(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((long long (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'Q': return imp_implementationWithBlock(^unsigned long long(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((unsigned long long (*)(id, SEL))probe.original)(receiver, probe.selector) : 0;
        });
        case 'f': return imp_implementationWithBlock(^float(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((float (*)(id, SEL))probe.original)(receiver, probe.selector) : 0.0f;
        });
        case 'd': return imp_implementationWithBlock(^double(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((double (*)(id, SEL))probe.original)(receiver, probe.selector) : 0.0;
        });
        case '@': return imp_implementationWithBlock(^id(id receiver) {
            WAGRReceiverObserve(probe, receiver);
            return probe.original ? ((id (*)(id, SEL))probe.original)(receiver, probe.selector) : nil;
        });
        default: return NULL;
    }
}

static void WAGRReceiverInstallProbe(WAGREntry *entry) {
    if (!entry || entry.isClassMethod || !entry.className.length || !entry.selectorName.length ||
        WAGRReceiverStructuralSelector(entry.selectorName)) return;

    NSString *uid = WAGRReceiverUID(entry.className, entry.selectorName);
    if (!uid.length) return;
    WAGRReceiverEnsureState();
    @synchronized (gWAGRReceiverLock) {
        if (gWAGRReceiverProbes[uid]) return;
    }

    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return;

    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    char type = WAGRReceiverSkipQualifiers(raw)[0];
    if (!WAGRReceiverSupportedType(type)) return;

    WAGRReceiverProbe *probe = [WAGRReceiverProbe new];
    probe.uid = uid;
    probe.className = entry.className;
    probe.selector = selector;
    probe.typeCode = type;
    IMP replacement = WAGRReceiverReplacement(probe);
    if (!replacement) return;

    IMP original = NULL;
    MSHookMessageEx(cls, selector, replacement, &original);
    if (!original || original == replacement) return;
    probe.original = original;
    @synchronized (gWAGRReceiverLock) {
        gWAGRReceiverProbes[uid] = probe;
    }
}

static id WAGRReceiverObservedForEntry(WAGREntry *entry) {
    if (!entry || entry.isClassMethod) return nil;
    WAGRReceiverEnsureState();
    NSString *uid = WAGRReceiverUID(entry.className, entry.selectorName);
    @synchronized (gWAGRReceiverLock) {
        id receiver = uid.length ? [gWAGRReceiverByUID objectForKey:uid] : nil;
        if (!receiver && entry.className.length) {
            receiver = [gWAGRReceiverByClass objectForKey:entry.className];
        }
        Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
        SEL selector = NSSelectorFromString(entry.selectorName);
        if (receiver && cls && [receiver isKindOfClass:cls] && [receiver respondsToSelector:selector]) {
            return receiver;
        }
    }
    return nil;
}

static id WAGRReceiverForEntry(id self, SEL _cmd, WAGREntry *entry) {
    if (!entry || entry.isClassMethod) {
        return gWAGRReceiverFallback ? gWAGRReceiverFallback(self, _cmd, entry) : nil;
    }

    id observed = WAGRReceiverObservedForEntry(entry);
    if (observed) return observed;

    id existing = gWAGRReceiverFallback ? gWAGRReceiverFallback(self, _cmd, entry) : nil;
    if (existing) return existing;

    // No legitimate live receiver is known yet.  Arm a pass-through observer for
    // this visible getter; the next natural WhatsApp call provides the real self.
    WAGRReceiverInstallProbe(entry);
    return nil;
}

static NSString *WAGRCurrentForEntry(id self, SEL _cmd, WAGREntry *entry, id *raw) {
    NSString *value = gWAGRCurrentFallback ? gWAGRCurrentFallback(self, _cmd, entry, raw) : @"?";
    if (!entry.isClassMethod && [value isEqualToString:@"receiver indisponível"]) {
        return @"aguardando instância viva · probe pass-through instalado";
    }
    return value;
}

static void WAGRInstallLiveReceiverObservation(void) {
    Class cls = NSClassFromString(@"WAGRSurfaceBrowserVC");
    if (!cls) return;

    SEL receiverSel = NSSelectorFromString(@"receiverForEntry:");
    Method receiverMethod = class_getInstanceMethod(cls, receiverSel);
    if (receiverMethod && method_getImplementation(receiverMethod) != (IMP)WAGRReceiverForEntry) {
        gWAGRReceiverFallback = (id (*)(id, SEL, WAGREntry *))method_getImplementation(receiverMethod);
        method_setImplementation(receiverMethod, (IMP)WAGRReceiverForEntry);
    }

    SEL currentSel = NSSelectorFromString(@"currentForEntry:raw:");
    Method currentMethod = class_getInstanceMethod(cls, currentSel);
    if (currentMethod && method_getImplementation(currentMethod) != (IMP)WAGRCurrentForEntry) {
        gWAGRCurrentFallback = (NSString *(*)(id, SEL, WAGREntry *, id *))method_getImplementation(currentMethod);
        method_setImplementation(currentMethod, (IMP)WAGRCurrentForEntry);
    }
}

__attribute__((constructor))
static void WAGRRuntimeLiveReceiverObservationCtor(void) {
    @autoreleasepool {
        WAGRReceiverEnsureState();
        dispatch_async(dispatch_get_main_queue(), ^{
            // CrashGuard is the authoritative safe resolver at 1.10 s; install
            // this observer after it so fallback remains conservative.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.42 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                WAGRInstallLiveReceiverObservation();
            });
        });
    }
}
