#import "WAGRRuntimeClassifier.h"

static BOOL WAGRContainsAny(NSString *s, NSArray<NSString *> *needles) {
    if (!s.length) return NO;
    for (NSString *n in needles) {
        if (n.length && [s rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *WAGRFirstToken(NSString *name) {
    NSString *s = name.lowercaseString ?: @"";
    if (!s.length) return @"other";
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@"_-. /:"];
    NSArray<NSString *> *parts = [s componentsSeparatedByCharactersInSet:sep];
    for (NSString *p in parts) if (p.length) return p;
    return s;
}

NSString *WAGRRuntimePrefixForName(NSString *name) {
    NSString *s = name.lowercaseString ?: @"";
    if (!s.length) return @"Other";

    // High-signal WhatsApp/Meta prefixes. Keep this prefix-driven so WAAB keys
    // do not collapse into the owner class bucket (WAABProperties/FOAWAABPropertiesImpl).
    if ([s hasPrefix:@"waios_"] || [s hasPrefix:@"waio_"] ||
        [s containsString:@"_waios_"] || [s containsString:@"_waio_"] ||
        [s hasPrefix:@"maios_"] || [s containsString:@"_maios_"]) return @"WAiOS";
    if ([s hasPrefix:@"wamo_"] || [s containsString:@"_wamo_"]) return @"WAMO";
    if ([s hasPrefix:@"xfamg_"] || [s containsString:@"_xfamg_"]) return @"XFAMG";
    if ([s hasPrefix:@"xwa_"] || [s containsString:@"_xwa"]) return @"XWA";
    if ([s hasPrefix:@"xma_"] || [s containsString:@"_xma_"]) return @"XMA";
    if ([s hasPrefix:@"waab_"] || [s containsString:@"waabproperties"] || [s containsString:@"abproperties"]) return @"WAAB";
    if ([s hasPrefix:@"foa_"] || [s hasPrefix:@"foa"] || [s containsString:@"foawaab"]) return @"FOA";
    if ([s hasPrefix:@"wds_"] || [s containsString:@"liquid_glass"] || [s containsString:@"liquidglass"]) return @"WDS / LiquidGlass";
    if ([s hasPrefix:@"ctwa_"] || [s containsString:@"_ctwa_"]) return @"CTWA";
    if ([s hasPrefix:@"br_"] || [s containsString:@"br_consumer_payments"]) return @"BR / Payments";
    if ([s hasPrefix:@"wa_bookmarks_"] || [s containsString:@"bookmarks_hs_"]) return @"FOA / Bookmarks";

    if ([s containsString:@"graphql"] || [s containsString:@"graph_ql"] || [s hasPrefix:@"gql_"]) return @"GraphQL";
    if ([s containsString:@"mobile_config"] || [s containsString:@"mobileconfig"] || [s containsString:@"mcbased"] || [s hasPrefix:@"mc_"] || [s hasPrefix:@"fbmc_"]) return @"MobileConfig";
    if ([s hasPrefix:@"private_"] || [s containsString:@"private_experiment"] || [s containsString:@"privateab"] || [s containsString:@"debugpropoverride"]) return @"Private Experimentation";

    if (WAGRContainsAny(s, @[@"employee", @"dogfood", @"dogfooding", @"internal", @"tester", @"developer", @"debugmenu", @"debug_menu", @"whitehat", @"white_hat"])) return @"Internal / Dogfood";
    if (WAGRContainsAny(s, @[@"aura", @"subscription", @"premium", @"benefit", @"watsapp_plus", @"whatsapp_plus", @"wa_plus"])) return @"WA Plus / Aura";
    if (WAGRContainsAny(s, @[@"asteria", @"ai_home", @"metaai", @"meta_ai", @"ai_", @"llama", @"imagine", @"hatch", @"bot", @"incognito", @"genai", @"gen_ai", @"persona", @"assistant"])) return @"AI / Meta AI";
    if (WAGRContainsAny(s, @[@"settings", @"setting", @"menu", @"row", @"cell", @"entrypoint", @"entry_point", @"nux", @"tooltip", @"banner"])) return @"Settings / UI";
    if (WAGRContainsAny(s, @[@"business", @"biz", @"smb", @"commerce", @"catalog", @"merchant", @"paid", @"payments", @"payment", @"upi", @"pix"])) return @"Business / Payments";
    if (WAGRContainsAny(s, @[@"privacy", @"username", @"passkey", @"security", @"defense", @"block", @"contact", @"presence", @"about", @"last_seen", @"lastseen"])) return @"Privacy / Identity";
    if (WAGRContainsAny(s, @[@"call", @"voip", @"voice", @"audio", @"video", @"media", @"camera", @"composer"] )) return @"Calls / Media";
    if (WAGRContainsAny(s, @[@"message", @"msg", @"chat", @"thread", @"poll", @"direct", @"group", @"community"] )) return @"Messaging";
    if (WAGRContainsAny(s, @[@"status", @"story", @"stories", @"sticker", @"channel", @"newsletter", @"broadcast", @"updates_tab"] )) return @"Status / Channels";
    if (WAGRContainsAny(s, @[@"interop", @"companion", @"md_", @"multi_device", @"linked_device", @"accounts", @"account_switcher"])) return @"Account / Companion";

    NSString *tok = WAGRFirstToken(s);
    if (!tok.length || [tok isEqualToString:@"is"] || [tok isEqualToString:@"has"] || [tok isEqualToString:@"can"] || [tok isEqualToString:@"should"]) return @"Other";
    return tok.uppercaseString;
}

NSString *WAGRRuntimeSubcategoryForName(NSString *name) {
    NSString *s = name.lowercaseString ?: @"";
    if (!s.length) return @"General";

    // Negative gates first. This intentionally puts risky knobs at the top of
    // each prefix group: disabled/hide/killswitch/block are the usual reason a
    // visible row exists but does not open or a feature silently disappears.
    if (WAGRContainsAny(s, @[@"kill_switch", @"killswitch", @"kill-switch", @"kill switch", @"disable_all", @"global_disable", @"hard_disable", @"emergencyrollback", @"emergency_rollback"])) return @"Negative · Kill Switch";
    if (WAGRContainsAny(s, @[@"disabled", @"disable", @"disable_", @"_disable", @"serverpropsdisable", @"experimental_disabled", @"off_switch"])) return @"Negative · Disabled";
    if (WAGRContainsAny(s, @[@"hidden", @"hide", @"suppress", @"remove_row", @"remove_menu", @"not_show", @"dont_show", @"do_not_show", @"hide_row", @"hide_cell"])) return @"Negative · Hide / Suppress";
    if (WAGRContainsAny(s, @[@"block", @"blocked", @"deny", @"denied", @"disallow", @"blacklist", @"black_list", @"ban_"])) return @"Negative · Block / Deny";

    if (WAGRContainsAny(s, @[@"employee", @"dogfood", @"dogfooding", @"internal", @"tester", @"developer", @"dev_only", @"debugmenu", @"debug_menu", @"whitehat", @"white_hat"])) return @"Internal · Employee / Dogfood";
    if (WAGRContainsAny(s, @[@"debug", @"diagnostic", @"logging", @"log_", @"trace", @"whatsbroken", @"override", @"qa", @"test_data"])) return @"Debug / Overrides";
    if (WAGRContainsAny(s, @[@"eligible", @"eligibility", @"allowed", @"is_allowed", @"can_", @"should_show", @"entrypoint", @"entry_point", @"visible", @"availability"])) return @"Eligibility / Entrypoint";
    if (WAGRContainsAny(s, @[@"enabled", @"enable", @"is_enabled", @"feature_enabled", @"master", @"launched", @"launch"])) return @"Positive · Enabled";
    if (WAGRContainsAny(s, @[@"experiment", @"abprop", @"ab_prop", @"bucket", @"sync", @"rollout", @"treatment", @"variant", @"arm_", @"cohort"])) return @"Experiment / Sync";
    if (WAGRContainsAny(s, @[@"fetch", @"cache", @"network", @"request", @"graphql", @"query", @"server", @"prefetch", @"lazyinit", @"shadow"])) return @"Network / Fetch";
    if (WAGRContainsAny(s, @[@"ui", @"view", @"screen", @"row", @"cell", @"section", @"menu", @"button", @"tab", @"navbar", @"topbar", @"bottombar"])) return @"UI / Surface";

    return @"General";
}

NSString *WAGRRuntimeSectionForName(NSString *name) {
    NSString *prefix = WAGRRuntimePrefixForName(name) ?: @"Other";
    NSString *sub = WAGRRuntimeSubcategoryForName(name) ?: @"General";
    return [NSString stringWithFormat:@"%@ — %@", prefix, sub];
}

NSString *WAGRRuntimeSectionForSelector(NSString *selectorName, NSString *className) {
    // Prefix should be driven by the flag/selector itself, not by broad owner
    // classes such as WAABProperties, otherwise every WAAB flag collapses into
    // a single bucket and prefix triage becomes useless.
    NSString *name = selectorName.length ? selectorName : (className ?: @"");
    NSString *hay = [NSString stringWithFormat:@"%@ %@", selectorName ?: @"", className ?: @""];
    NSString *prefix = WAGRRuntimePrefixForName(name) ?: @"Other";
    NSString *sub = WAGRRuntimeSubcategoryForName(hay) ?: @"General";
    return [NSString stringWithFormat:@"%@ — %@", prefix, sub];
}
