#import "WAGRMobileConfigNativeEngine.h"
#import "WAGRMobileConfigBridge.h"
#import "WAGRLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

static NSString * const kWAGRMCNativeErrorDomain = @"WATweaks.MobileConfigNativeEngine";

static const char *WAGRMCNativeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL WAGRMCNativeMethodReturnsVoid(Method method) {
    if (!method) return NO;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    return WAGRMCNativeSkipQualifiers(raw)[0] == 'v';
}

static BOOL WAGRMCNativeMethodIsVoidNoArg(Method method) {
    return method && method_getNumberOfArguments(method) == 2 &&
           WAGRMCNativeMethodReturnsVoid(method);
}

static NSString *WAGRMCNativeEncoding(id manager, NSString *selectorName) {
    if (!manager || !selectorName.length) return @"";
    Method method = class_getInstanceMethod([manager class], NSSelectorFromString(selectorName));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"";
}

static BOOL WAGRMCNativeInvokeVoidNoArg(id manager, NSString *selectorName) {
    if (!manager || !selectorName.length) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([manager class], selector);
    if (!WAGRMCNativeMethodIsVoidNoArg(method)) return NO;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(manager, selector);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSString *WAGRMCNativeStablePrefix(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !key.length) return nil;
    NSString *prefix = [[key componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return nil;
    NSCharacterSet *bad = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    return [prefix rangeOfCharacterFromSet:bad].location == NSNotFound ? prefix : nil;
}

static NSInteger WAGRMCNativeRowIndex(NSString *row) {
    if (![row isKindOfClass:NSString.class]) return NSNotFound;
    NSString *prefix = [[row componentsSeparatedByString:@":"] firstObject];
    if (!prefix.length) return NSNotFound;
    NSCharacterSet *bad = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    if ([prefix rangeOfCharacterFromSet:bad].location != NSNotFound) return NSNotFound;
    return prefix.integerValue;
}

static NSDictionary *WAGRMCNativeMergeDocuments(NSDictionary *existing,
                                                 NSDictionary *incoming) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    if ([existing isKindOfClass:NSDictionary.class]) [merged addEntriesFromDictionary:existing];

    [incoming enumerateKeysAndObjectsUsingBlock:^(NSString *newKey, id newRowsObject, __unused BOOL *stop) {
        if ([newKey isEqualToString:@"_qe_overrides_"]) {
            if ([newRowsObject isKindOfClass:NSArray.class]) merged[newKey] = newRowsObject;
            return;
        }
        if (![newRowsObject isKindOfClass:NSArray.class]) return;
        NSString *stable = WAGRMCNativeStablePrefix(newKey);
        if (!stable.length) return;

        NSString *oldKey = nil;
        for (NSString *candidate in merged.allKeys) {
            if ([[WAGRMCNativeStablePrefix(candidate) ?: @""] isEqualToString:stable]) {
                oldKey = candidate;
                break;
            }
        }

        NSString *targetKey = newKey;
        if ([newKey hasSuffix:@":"] && oldKey.length && ![oldKey hasSuffix:@":"]) {
            targetKey = oldKey;
        }

        NSMutableDictionary<NSNumber *, NSString *> *rowsByIndex = [NSMutableDictionary dictionary];
        NSArray *oldRows = oldKey.length && [merged[oldKey] isKindOfClass:NSArray.class]
            ? merged[oldKey] : @[];
        for (NSString *row in oldRows) {
            NSInteger index = WAGRMCNativeRowIndex(row);
            if (index != NSNotFound) rowsByIndex[@(index)] = row;
        }
        for (NSString *row in (NSArray *)newRowsObject) {
            NSInteger index = WAGRMCNativeRowIndex(row);
            if (index != NSNotFound) rowsByIndex[@(index)] = row;
        }

        NSArray<NSNumber *> *indices = [rowsByIndex.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *rows = [NSMutableArray arrayWithCapacity:indices.count];
        for (NSNumber *index in indices) {
            NSString *row = rowsByIndex[index];
            if (row) [rows addObject:row];
        }
        if (oldKey.length && ![oldKey isEqualToString:targetKey]) [merged removeObjectForKey:oldKey];
        merged[targetKey] = rows;
    }];
    if (!merged[@"_qe_overrides_"]) merged[@"_qe_overrides_"] = @[];
    return merged;
}

static NSError *WAGRMCNativeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kWAGRMCNativeErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"MobileConfig native engine error"}];
}

BOOL WAGRMobileConfigNativeInvalidate(id userContext, NSString **outDiagnostic) {
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    if (!manager) {
        if (outDiagnostic) *outDiagnostic = @"UserSession manager unresolved; no invalidation was sent.";
        return NO;
    }

    NSMutableArray<NSString *> *invoked = [NSMutableArray array];
    if (WAGRMCNativeInvokeVoidNoArg(manager, @"invalidateCachedLatestContext")) {
        [invoked addObject:@"invalidateCachedLatestContext"];
    }
    if (WAGRMCNativeInvokeVoidNoArg(manager, @"forceInvalidate")) {
        [invoked addObject:@"forceInvalidate"];
    }

    NSString *diagnostic = [NSString stringWithFormat:
        @"manager=%@; invoked=%@; setOverrides ABI=%@",
        NSStringFromClass([manager class]) ?: @"?",
        invoked.count ? [invoked componentsJoinedByString:@", "] : @"none",
        WAGRMCNativeEncoding(manager, @"setOverrides:").length
            ? WAGRMCNativeEncoding(manager, @"setOverrides:") : @"missing"];
    if (outDiagnostic) *outDiagnostic = diagnostic;
    WAGRLogAppendF(@"[MobileConfig][NativeEngine] %@", diagnostic);
    return invoked.count > 0;
}

BOOL WAGRMobileConfigNativeWriteOverrideDocument(NSDictionary<NSString *, id> *document,
                                                  id userContext,
                                                  BOOL mergeExisting,
                                                  NSError **outError,
                                                  NSString **outDiagnostic) {
    if (![document isKindOfClass:NSDictionary.class]) {
        if (outError) *outError = WAGRMCNativeError(1, @"Override document is not a dictionary.");
        return NO;
    }

    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    if (!manager) {
        if (outError) *outError = WAGRMCNativeError(2,
            @"FBMobileConfigUserSessionContextManager was not resolved. Refusing sessionless/default fallback.");
        return NO;
    }

    NSString *path = WAGRMobileConfigOverridesPath(userContext);
    if (!path.length) {
        if (outError) *outError = WAGRMCNativeError(3,
            @"The live UserSession manager did not provide getOverridesTablePath.");
        return NO;
    }

    NSError *error = nil;
    NSDictionary *existing = @{};
    NSData *oldData = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (oldData.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:oldData options:0 error:&error];
        if (![parsed isKindOfClass:NSDictionary.class]) {
            if (outError) *outError = error ?: WAGRMCNativeError(4,
                @"Existing mc_overrides.json is not a dictionary JSON document.");
            return NO;
        }
        existing = parsed;
    }

    NSDictionary *finalDocument = mergeExisting
        ? WAGRMCNativeMergeDocuments(existing, document)
        : document;
    if (![NSJSONSerialization isValidJSONObject:finalDocument]) {
        if (outError) *outError = WAGRMCNativeError(5, @"Merged override document is not JSON serializable.");
        return NO;
    }

    NSJSONWritingOptions options = NSJSONWritingPrettyPrinted;
    if (@available(iOS 11.0, *)) options |= NSJSONWritingSortedKeys;
    NSData *data = [NSJSONSerialization dataWithJSONObject:finalDocument options:options error:&error];
    if (!data.length) {
        if (outError) *outError = error ?: WAGRMCNativeError(6, @"Failed to serialize mc_overrides JSON.");
        return NO;
    }

    NSString *directory = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        if (outError) *outError = error;
        return NO;
    }

    if (oldData.length) {
        NSString *backup = [path stringByAppendingString:@".watweaks.bak"];
        [oldData writeToFile:backup options:NSDataWritingAtomic error:nil];
    }
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        if (outError) *outError = error;
        return NO;
    }

    NSString *invalidateDiagnostic = nil;
    BOOL invalidated = WAGRMobileConfigNativeInvalidate(userContext, &invalidateDiagnostic);
    NSString *diagnostic = [NSString stringWithFormat:
        @"wrote=%@; bytes=%lu; manager=%@; nativeInvalidate=%@; %@",
        path, (unsigned long)data.length,
        NSStringFromClass([manager class]) ?: @"?",
        invalidated ? @"YES" : @"NO",
        invalidateDiagnostic ?: @""];
    if (outDiagnostic) *outDiagnostic = diagnostic;
    WAGRLogAppendF(@"[MobileConfig][NativeEngine] %@", diagnostic);
    return YES;
}

NSDictionary<NSString *, id> *WAGRMobileConfigNativeEngineDiagnosticDocument(id userContext) {
    id manager = WAGRMobileConfigUserSessionContextManager(userContext);
    NSString *setOverridesEncoding = WAGRMCNativeEncoding(manager, @"setOverrides:");
    BOOL sharedPtrABI = [setOverridesEncoding containsString:@"shared_ptr"] ||
                        [setOverridesEncoding containsString:@"FBMobileConfigOverridesTable"];
    return @{
        @"user_session_resolved" : @(manager != nil),
        @"manager_class" : manager ? (NSStringFromClass([manager class]) ?: @"?") : @"nil",
        @"overrides_path" : WAGRMobileConfigOverridesPath(userContext) ?: (id)NSNull.null,
        @"get_overrides_path_encoding" : WAGRMCNativeEncoding(manager, @"getOverridesTablePath"),
        @"overrides_getter_encoding" : WAGRMCNativeEncoding(manager, @"overrides"),
        @"set_overrides_encoding" : setOverridesEncoding ?: @"",
        @"set_overrides_is_cpp_shared_ptr_abi" : @(sharedPtrABI),
        @"direct_set_overrides_call_enabled" : @NO,
        @"invalidate_cached_latest_context_encoding" : WAGRMCNativeEncoding(manager, @"invalidateCachedLatestContext"),
        @"force_invalidate_encoding" : WAGRMCNativeEncoding(manager, @"forceInvalidate"),
        @"force_refresh_config_encoding" : WAGRMCNativeEncoding(manager, @"forceRefreshOfConfig:"),
        @"policy" : @"Write native mc_overrides table at UserSession path; request ABI-safe invalidation. Never objc_msgSend setOverrides: as an object because its current ABI is std::shared_ptr<FBMobileConfigOverridesTable>.",
    };
}

NSString *WAGRMobileConfigNativeEngineDiagnosticText(id userContext) {
    NSDictionary *document = WAGRMobileConfigNativeEngineDiagnosticDocument(userContext);
    NSData *data = [NSJSONSerialization dataWithJSONObject:document
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                       : [document description];
}
