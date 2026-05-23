#pragma once
#import <Foundation/Foundation.h>
#import "WAGRSurface.h"

// Loads the static runtime inventory JSON files staged in
// /Library/Application Support/WATweaks/runtime and turns them into runtime
// browser surfaces/entries. This stays passive: no hooks are installed here.
@interface WAGRRuntimeInventory : NSObject
+ (NSArray<WAGRSurfaceSpec *> *)inventorySurfaces;
+ (NSArray<WAGREntry *> *)inventoryEntriesForSurface:(WAGRSurfaceSpec *)spec;
+ (NSDictionary *)inventoryForFile:(NSString *)fileName;
+ (NSString *)diagnosticText;
@end
