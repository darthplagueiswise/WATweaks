#pragma once
#import <Foundation/Foundation.h>
#import "../WAGramPrefix.h"

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
+ (NSArray<WAGRSurfaceSpec *> *)allSurfaces;
@end

#ifdef __cplusplus
extern "C" {
#endif
NSString *WAGRCategoryForSelector(NSString *selectorName);
NSString *WAGRCleanDisplayName(NSString *name);
#ifdef __cplusplus
}
#endif

@interface WAGRScanner : NSObject
+ (NSArray<WAGREntry *> *)scanSurface:(WAGRSurfaceSpec *)spec;
@end
