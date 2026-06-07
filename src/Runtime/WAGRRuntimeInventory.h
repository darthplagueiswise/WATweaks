#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WAGRRuntimeInventory : NSObject
+ (NSDictionary *)manifest;
+ (NSDictionary *)inventoryNamed:(NSString *)name;
+ (NSArray<NSString *> *)availableInventoryNames;
+ (NSString *)diagnosticText;
@end

#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *WAGRRuntimeInventoryManifest(void);
NSDictionary *WAGRRuntimeInventoryNamed(NSString *name);
NSString *WAGRRuntimeInventoryDiagnosticText(void);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
