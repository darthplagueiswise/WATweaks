#import "WAGRABPropsStorageAudit.h"

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const kWAGRABAuditSuite = @"group.net.whatsapp.WhatsApp.shared";

static BOOL WAGRABAuditDecimal(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return NO;
    return [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

static NSDictionary *WAGRABAuditDecodeDictionary(id raw) {
    if ([raw isKindOfClass:NSDictionary.class]) return raw;
    if (![raw isKindOfClass:NSData.class]) return nil;
    id object = [NSPropertyListSerialization propertyListWithData:(NSData *)raw
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSDictionary *WAGRABAuditBestPayload(NSDictionary *domain) {
    NSString *bestKey = nil;
    NSDictionary *best = nil;
    NSUInteger bestCount = 0;
    for (id keyObject in domain ?: @{}) {
        if (![keyObject isKindOfClass:NSString.class]) continue;
        NSString *key = keyObject;
        NSString *lower = key.lowercaseString;
        if (![lower hasPrefix:@"gabp."] || ![lower hasSuffix:@"p"] || [lower containsString:@"none"]) continue;
        NSDictionary *decoded = WAGRABAuditDecodeDictionary(domain[key]);
        if (!decoded.count) continue;
        NSUInteger count = 0;
        for (id propKey in decoded) {
            NSString *candidate = [propKey isKindOfClass:NSString.class] ? propKey : [propKey description];
            if (WAGRABAuditDecimal(candidate)) count++;
        }
        if (count > bestCount) {
            bestCount = count;
            bestKey = key;
            best = decoded;
        }
    }
    return @{
        @"payload_key": bestKey ?: @"",
        @"numeric_count": @(bestCount),
        @"payload": best ?: @{},
    };
}

static NSDictionary *WAGRABAuditCFDomain(CFStringRef host) {
    CFStringRef appID = (__bridge CFStringRef)kWAGRABAuditSuite;
    CFArrayRef copiedKeys = CFPreferencesCopyKeyList(appID,
                                                      kCFPreferencesCurrentUser,
                                                      host);
    NSArray *keys = CFBridgingRelease(copiedKeys);
    NSMutableDictionary *domain = [NSMutableDictionary dictionary];
    for (id keyObject in keys ?: @[]) {
        if (![keyObject isKindOfClass:NSString.class]) continue;
        NSString *key = keyObject;
        CFPropertyListRef copied = CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                          appID,
                                                          kCFPreferencesCurrentUser,
                                                          host);
        if (!copied) continue;
        id value = CFBridgingRelease(copied);
        if (value) domain[key] = value;
    }
    return domain;
}

static NSDictionary *WAGRABAuditReadPlist(NSURL *url) {
    if (!url) return @{};
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length) return @{};
    id object = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static NSDictionary *WAGRABAuditFileInfo(NSURL *url) {
    if (!url) return @{};
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil] ?: @{};
    return @{
        @"path": url.path ?: @"",
        @"exists": @([NSFileManager.defaultManager fileExistsAtPath:url.path]),
        @"size": attributes[NSFileSize] ?: @0,
        @"mtime": [attributes[NSFileModificationDate] description] ?: @"",
    };
}

static NSArray<NSDictionary *> *WAGRABAuditByHostFiles(NSURL *preferencesURL) {
    if (!preferencesURL) return @[];
    NSURL *byHostURL = [preferencesURL URLByAppendingPathComponent:@"ByHost" isDirectory:YES];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:byHostURL
                                                          includingPropertiesForKeys:nil
                                                                             options:0
                                                                               error:nil] ?: @[];
    NSMutableArray *results = [NSMutableArray array];
    NSString *prefix = [kWAGRABAuditSuite stringByAppendingString:@"."];
    for (NSURL *url in files) {
        NSString *name = url.lastPathComponent ?: @"";
        if (![name hasPrefix:prefix] || ![name hasSuffix:@".plist"]) continue;
        NSDictionary *domain = WAGRABAuditReadPlist(url);
        NSDictionary *payload = WAGRABAuditBestPayload(domain);
        NSMutableDictionary *row = [WAGRABAuditFileInfo(url) mutableCopy];
        row[@"payload_key"] = payload[@"payload_key"] ?: @"";
        row[@"numeric_count"] = payload[@"numeric_count"] ?: @0;
        [results addObject:row];
    }
    [results sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [[left[@"path"] description] localizedCaseInsensitiveCompare:[right[@"path"] description]];
    }];
    return results;
}

static NSDictionary *WAGRABAuditSource(NSString *name, NSDictionary *domain) {
    NSDictionary *payload = WAGRABAuditBestPayload(domain ?: @{});
    return @{
        @"name": name ?: @"",
        @"domain_key_count": @((domain ?: @{}).count),
        @"payload_key": payload[@"payload_key"] ?: @"",
        @"numeric_count": payload[@"numeric_count"] ?: @0,
    };
}

NSDictionary<NSString *, id> *WAGRABPropsStorageAudit(void) {
    // Deliberately do NOT call -synchronize or CFPreferencesAppSynchronize here.
    // The purpose is to observe divergence before any explicit flush/reload can
    // destroy the evidence.
    NSUserDefaults *suiteDefaults = [[NSUserDefaults alloc] initWithSuiteName:kWAGRABAuditSuite];
    NSDictionary *defaultsDomain = nil;
    @try { defaultsDomain = suiteDefaults.dictionaryRepresentation ?: @{}; }
    @catch (__unused NSException *exception) { defaultsDomain = @{}; }

    NSDictionary *anyHostDomain = WAGRABAuditCFDomain(kCFPreferencesAnyHost);
    NSDictionary *currentHostDomain = WAGRABAuditCFDomain(kCFPreferencesCurrentHost);

    NSURL *groupURL = [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:kWAGRABAuditSuite];
    NSURL *preferencesURL = groupURL
        ? [groupURL URLByAppendingPathComponent:@"Library/Preferences" isDirectory:YES]
        : nil;
    NSURL *directURL = preferencesURL
        ? [preferencesURL URLByAppendingPathComponent:[kWAGRABAuditSuite stringByAppendingString:@".plist"]]
        : nil;
    NSDictionary *directDomain = WAGRABAuditReadPlist(directURL);

    NSDictionary *defaultsSource = WAGRABAuditSource(@"NSUserDefaults suite", defaultsDomain);
    NSDictionary *anyHostSource = WAGRABAuditSource(@"CFPreferences AnyHost", anyHostDomain);
    NSDictionary *currentHostSource = WAGRABAuditSource(@"CFPreferences CurrentHost", currentHostDomain);
    NSDictionary *directSource = WAGRABAuditSource(@"Physical AppGroup plist", directDomain);

    NSUInteger liveCount = MAX([defaultsSource[@"numeric_count"] unsignedIntegerValue],
                               [anyHostSource[@"numeric_count"] unsignedIntegerValue]);
    NSUInteger diskCount = [directSource[@"numeric_count"] unsignedIntegerValue];
    BOOL diverged = liveCount != diskCount;

    return @{
        @"suite": kWAGRABAuditSuite,
        @"app_group_path": groupURL.path ?: @"",
        @"live_count": @(liveCount),
        @"physical_plist_count": @(diskCount),
        @"live_vs_physical_diverged": @(diverged),
        @"sources": @[defaultsSource, anyHostSource, currentHostSource, directSource],
        @"physical_plist": WAGRABAuditFileInfo(directURL),
        @"by_host_files": WAGRABAuditByHostFiles(preferencesURL),
        @"note": @"Read-only audit. No synchronize/write was performed before measurement."
    };
}

static NSString *WAGRABAuditCompactKey(NSString *key) {
    if (!key.length) return @"—";
    NSRange at = [key rangeOfString:@"@"]; 
    if (at.location == NSNotFound) return key;
    NSRange prefix = [key rangeOfString:@"gabp.o"];
    if (prefix.location == NSNotFound || at.location <= NSMaxRange(prefix)) return key;
    return [NSString stringWithFormat:@"%@<account>%@",
        [key substringToIndex:NSMaxRange(prefix)],
        [key substringFromIndex:at.location]];
}

NSString *WAGRABPropsStorageAuditText(void) {
    NSDictionary *audit = WAGRABPropsStorageAudit();
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"ABProps Storage Audit\nSuite: %@\nAppGroup: %@\n\n",
        audit[@"suite"] ?: @"?",
        [audit[@"app_group_path"] length] ? audit[@"app_group_path"] : @"<containerURL indisponível>"];

    for (NSDictionary *source in audit[@"sources"] ?: @[]) {
        [text appendFormat:@"%@\n  gabp: %@\n  count: %@\n  domain keys: %@\n",
            source[@"name"] ?: @"?",
            WAGRABAuditCompactKey(source[@"payload_key"] ?: @""),
            source[@"numeric_count"] ?: @0,
            source[@"domain_key_count"] ?: @0];
    }

    NSDictionary *file = audit[@"physical_plist"] ?: @{};
    [text appendFormat:@"\nPhysical plist\n  path: %@\n  exists: %@\n  size: %@\n  mtime: %@\n",
        [file[@"path"] length] ? file[@"path"] : @"<unresolved>",
        [file[@"exists"] boolValue] ? @"YES" : @"NO",
        file[@"size"] ?: @0,
        [file[@"mtime"] length] ? file[@"mtime"] : @"—"];

    NSArray *byHost = audit[@"by_host_files"] ?: @[];
    if (byHost.count) {
        [text appendString:@"\nByHost candidates\n"];
        for (NSDictionary *row in byHost) {
            [text appendFormat:@"  %@\n    count: %@ · size: %@ · mtime: %@\n",
                row[@"path"] ?: @"?", row[@"numeric_count"] ?: @0,
                row[@"size"] ?: @0, row[@"mtime"] ?: @"—"];
        }
    }

    BOOL diverged = [audit[@"live_vs_physical_diverged"] boolValue];
    [text appendFormat:@"\nVerdict: %@\n",
        diverged
            ? @"CFPreferences/NSUserDefaults and the physical plist expose different ABProp counts."
            : @"Live preference APIs and the physical plist expose the same ABProp count."];
    [text appendString:@"Measurement is read-only; no synchronize/write ran before this comparison."];
    return text;
}
