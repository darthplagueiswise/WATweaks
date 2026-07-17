#pragma once
#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"

NS_ASSUME_NONNULL_BEGIN

@interface WAGREntry : NSObject
@property(nonatomic, copy) NSString *surfaceID;
@property(nonatomic, copy) NSString *className;
@property(nonatomic, assign) BOOL isClassMethod;
@property(nonatomic, assign) BOOL isProperty;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, copy) NSString *returnType;
@property(nonatomic, copy) NSString *typeCode;
@property(nonatomic, copy) NSString *typeName;
@property(nonatomic, copy) NSString *overrideKey;

// Rebuilt from the loaded Objective-C runtime on every explicit scan.
@property(nonatomic, copy) NSString *imagePath;
@property(nonatomic, copy) NSString *imageName;
@property(nonatomic, copy) NSString *runtimeFamily;
@property(nonatomic, copy) NSString *runtimeSubcategory;
@end

@interface WAGRSurfaceSpec : NSObject
@property(nonatomic, copy) NSString *surfaceID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *icon;
@property(nonatomic, strong) NSArray<NSString *> *classNames;
@property(nonatomic, strong) NSArray<NSString *> *classNameFragments;
@property(nonatomic, strong) NSArray<NSString *> *selectorTokens;
@property(nonatomic, strong) NSArray<NSString *> *categoryAllowList;
@property(nonatomic, assign) BOOL scanInstanceMethods;
@property(nonatomic, assign) BOOL scanClassMethods;
@property(nonatomic, assign) BOOL scanProperties;
@property(nonatomic, assign) BOOL advancedOnly;

// Dynamic filters. An exact image path identifies a loaded Mach-O. A family
// is generated from the live selector/class names, never from a static list.
@property(nonatomic, copy, nullable) NSString *runtimeImagePath;
@property(nonatomic, copy, nullable) NSString *runtimeFamilyKey;
@property(nonatomic, assign) BOOL runtimeGenerated;
@property(nonatomic, assign) NSUInteger runtimeClassCount;
@property(nonatomic, assign) NSUInteger runtimeEntryCount;

// Compatibility entry point used by the raw runtime list. It now returns a
// fresh image-backed snapshot instead of a hard-coded surface array.
+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces;
@end

#ifdef __cplusplus
extern "C" {
#endif
NSString *WAGRCategoryForSelector(NSString *selectorName);
NSString *WAGRCleanDisplayName(NSString *name);
NSString *WAGRLiveRuntimeImageNameForPath(NSString * _Nullable imagePath);
NSString *WAGRLiveRuntimeFamilyForSelector(NSString * _Nullable selectorName,
                                            NSString * _Nullable className);
NSString *WAGRLiveRuntimeSubcategoryForEntry(NSString * _Nullable selectorName,
                                              NSString * _Nullable className,
                                              NSString * _Nullable imagePath);
#ifdef __cplusplus
}
#endif

@interface WAGRScanner : NSObject
+ (NSArray<WAGREntry *> *)scanSurface:(WAGRSurfaceSpec *)spec;
+ (NSArray<WAGRSurfaceSpec *> *)runtimeImageSurfaces;
+ (NSArray<WAGRSurfaceSpec *> *)runtimeFamilySurfaces;
@end

NS_ASSUME_NONNULL_END
