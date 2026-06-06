#import "WAGRSettingsBackup.h"
#import "../Runtime/WAGRRuntimeInventory.h"
#import "../WAGramPrefix.h"
#import <CoreFoundation/CoreFoundation.h>

extern NSUInteger WAGRReinstallPersistedHooks(void);
extern void WAGRLGPrefsDidChange(void);
extern void WAGRWAABEnsureHooksInstalled(void);
extern void WAGRAuraEnsureHooksInstalled(void);
extern void WAGRSettingsRowsNativeEnsureHooksInstalled(void);
extern void WAGRAccountEligibilityEnsureHooksInstalled(void);

static BOOL WAGRBackupOwnsKey(NSString *key) {
    return WAGRIsManagedPreferenceKey(key);
}

static id WAGRJSONSafeObject(id obj) {
    if (!obj || obj == (id)kCFNull) return [NSNull null];
    if ([obj isKindOfClass:NSString.class] || [obj isKindOfClass:NSNumber.class] || [obj isKindOfClass:NSNull.class]) return obj;
    if ([obj isKindOfClass:NSArray.class]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id v in (NSArray *)obj) [a addObject:WAGRJSONSafeObject(v) ?: [NSNull null]];
        return a;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            if ([k isKindOfClass:NSString.class]) d[k] = WAGRJSONSafeObject(v) ?: [NSNull null];
        }];
        return d;
    }
    return [obj description] ?: @"";
}

static NSDictionary *WAGRBackupPayload(void) {
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation ?: @{};
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    for (NSString *key in all) {
        if (!WAGRBackupOwnsKey(key)) continue;
        id safe = WAGRJSONSafeObject(all[key]);
        if (safe) prefs[key] = safe;
    }
    NSDictionary *manifest = WAGRRuntimeInventoryManifest() ?: @{};
    return @{
        @"schema_version": @1,
        @"bundle": @"WATweaks",
        @"created_at_unix": @((long long)NSDate.date.timeIntervalSince1970),
        @"mode": @"mirror_nsuserdefaults_preferences",
        @"runtime_inventory_groups": [manifest[@"groups"] isKindOfClass:NSArray.class] ? manifest[@"groups"] : @[],
        @"preferences": prefs
    };
}

static UIViewController *WAGRBackupTopVC(void) {
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
            if (win.isKeyWindow && win.rootViewController) { root = win.rootViewController; break; }
        }
        if (root) break;
    }
    if (!root) root = UIApplication.sharedApplication.keyWindow.rootViewController;
    UIViewController *p = root;
    while (p.presentedViewController) p = p.presentedViewController;
    if ([p isKindOfClass:UINavigationController.class]) p = ((UINavigationController *)p).visibleViewController ?: p;
    if ([p isKindOfClass:UITabBarController.class]) p = ((UITabBarController *)p).selectedViewController ?: p;
    return p;
}

static void WAGRBackupAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title ?: @"WATweaks"
                                                                   message:message ?: @""
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [WAGRBackupTopVC() presentViewController:a animated:YES completion:nil];
    });
}

@interface WAGRSettingsBackup () <UIDocumentPickerDelegate>
@end

@implementation WAGRSettingsBackup

+ (instancetype)shared {
    static WAGRSettingsBackup *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

+ (void)presentExport {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:WAGRBackupPayload()
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&err];
    if (!data.length || err) { WAGRBackupAlert(@"Export falhou", err.localizedDescription ?: @"JSON vazio"); return; }

    NSString *name = [NSString stringWithFormat:@"WATweaks-backup-%lld.json", (long long)NSDate.date.timeIntervalSince1970];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
        WAGRBackupAlert(@"Export falhou", err.localizedDescription ?: @"Não consegui gravar o arquivo temporário.");
        return;
    }
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    [WAGRBackupTopVC() presentViewController:vc animated:YES completion:nil];
}

+ (void)presentImport {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.json", @"public.text"] inMode:UIDocumentPickerModeImport];
    picker.delegate = [WAGRSettingsBackup shared];
    picker.allowsMultipleSelection = NO;
    [WAGRBackupTopVC() presentViewController:picker animated:YES completion:nil];
}

+ (void)presentReset {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset WATweaks"
                                                               message:@"Remove todas as preferências/overrides gerenciados pelo WATweaks do NSUserDefaults."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused id _) {
        NSUInteger n = WAGRClearAllManagedPreferences();
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        WAGRBackupAlert(@"Reset", [NSString stringWithFormat:@"%lu chaves removidas.", (unsigned long)n]);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [WAGRBackupTopVC() presentViewController:a animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length) { WAGRBackupAlert(@"Import falhou", @"Arquivo vazio ou inacessível."); return; }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:NSDictionary.class]) { WAGRBackupAlert(@"Import falhou", err.localizedDescription ?: @"JSON inválido."); return; }
    NSDictionary *root = (NSDictionary *)obj;
    NSDictionary *prefs = [root[@"preferences"] isKindOfClass:NSDictionary.class] ? root[@"preferences"] : root;
    if (![prefs isKindOfClass:NSDictionary.class]) { WAGRBackupAlert(@"Import falhou", @"Não encontrei o dicionário preferences."); return; }

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableSet<NSString *> *imported = [NSMutableSet set];
    for (NSString *k in prefs) if (WAGRBackupOwnsKey(k)) [imported addObject:k];

    NSUInteger removed = 0, applied = 0;
    for (NSString *k in ud.dictionaryRepresentation.allKeys) {
        if (WAGRBackupOwnsKey(k) && ![imported containsObject:k]) { [ud removeObjectForKey:k]; removed++; }
    }
    for (NSString *k in imported) {
        id v = prefs[k];
        if (!v || v == (id)kCFNull) [ud removeObjectForKey:k];
        else [ud setObject:v forKey:k];
        applied++;
    }
    [ud synchronize];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);

    WAGRWAABEnsureHooksInstalled();
    WAGRAuraEnsureHooksInstalled();
    WAGRSettingsRowsNativeEnsureHooksInstalled();
    WAGRAccountEligibilityEnsureHooksInstalled();
    WAGRLGPrefsDidChange();
    NSUInteger hooks = WAGRReinstallPersistedHooks();

    WAGRBackupAlert(@"Import aplicado", [NSString stringWithFormat:@"%lu chaves aplicadas\n%lu chaves removidas\n%lu hooks reinstalados", (unsigned long)applied, (unsigned long)removed, (unsigned long)hooks]);
}
@end

NSString *WAGRSettingsBackupDiagnosticText(void) {
    NSUInteger n = 0;
    for (NSString *k in NSUserDefaults.standardUserDefaults.dictionaryRepresentation.allKeys) if (WAGRBackupOwnsKey(k)) n++;
    return [NSString stringWithFormat:@"owned preference keys=%lu\ninventory=%@", (unsigned long)n, WAGRRuntimeInventoryDiagnosticText() ?: @"n/a"];
}
