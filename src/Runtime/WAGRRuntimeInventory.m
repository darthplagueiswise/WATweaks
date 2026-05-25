#import "WAGRRuntimeInventory.h"
#import <UIKit/UIKit.h>

static NSString *WAGRInventoryBasePath(void) {
    NSArray<NSString *> *candidates = @[
        @"/Library/Application Support/WATweaks/runtime",
        [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"WATweaksRuntime"],
        [[NSBundle mainBundle] bundlePath]
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return p;
    }
    return candidates.firstObject;
}

static NSDictionary *WAGRLoadJSONAtPath(NSString *path) {
    if (!path.length) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}

@implementation WAGRRuntimeInventory
+ (NSDictionary *)manifest {
    return WAGRLoadJSONAtPath([WAGRInventoryBasePath() stringByAppendingPathComponent:@"wagr_runtime_inventory_manifest.json"]);
}
+ (NSDictionary *)inventoryNamed:(NSString *)name {
    if (!name.length) return @{};
    NSString *safe = [[name lastPathComponent] stringByDeletingPathExtension];
    if (!safe.length) return @{};
    return WAGRLoadJSONAtPath([WAGRInventoryBasePath() stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"json"]]);
}
+ (NSArray<NSString *> *)availableInventoryNames {
    NSDictionary *m = [self manifest];
    NSArray *groups = [m[@"groups"] isKindOfClass:NSArray.class] ? m[@"groups"] : @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *g in groups) {
        NSString *gid = [g[@"id"] isKindOfClass:NSString.class] ? g[@"id"] : nil;
        if (gid.length) [names addObject:gid];
    }
    return names;
}
+ (NSString *)diagnosticText {
    NSDictionary *m = [self manifest];
    NSArray *groups = [m[@"groups"] isKindOfClass:NSArray.class] ? m[@"groups"] : @[];
    NSMutableString *s = [NSMutableString stringWithFormat:@"base=%@\ngroups=%lu", WAGRInventoryBasePath(), (unsigned long)groups.count];
    for (NSDictionary *g in groups) {
        [s appendFormat:@"\n%@ classes=%@ selectors=%@", g[@"id"] ?: @"?", g[@"classes_total"] ?: @0, g[@"selectors_total"] ?: @0];
    }
    return s;
}
@end

NSDictionary *WAGRRuntimeInventoryManifest(void) { return [WAGRRuntimeInventory manifest]; }
NSDictionary *WAGRRuntimeInventoryNamed(NSString *name) { return [WAGRRuntimeInventory inventoryNamed:name]; }
NSString *WAGRRuntimeInventoryDiagnosticText(void) { return [WAGRRuntimeInventory diagnosticText]; }
