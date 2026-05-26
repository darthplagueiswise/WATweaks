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

    // Known WhatsApp/Meta prefixes and families seen in WAAB / MC / debug paths.
    if ([s hasPrefix:@"waios_"] || [s hasPrefix:@"waio_"] || [s containsString:@"_waios_"] || [s containsString:@"_waio_"]) return @"WAiOS";
    if ([s hasPrefix:@"wamo_"] || [s containsString:@"_wamo_"]) return @"WAMO";
    if ([s hasPrefix:@"xfamg_"] || [s containsString:@"_xfamg_"]) return @"XFAMG";
    if ([s hasPrefix:@"xwa_"] || [s containsString:@"_xwa_"]) return @"XWA";
    if ([s hasPrefix:@"waab_"] || [s containsString:@"waabproperties"] || [s containsString:@"abproperties"]) return @"WAAB";
    if ([s hasPrefix:@"foa_"] || [s hasPrefix:@"foa"] || [s containsString:@"foawaab"]) return @"FOA";
    if ([s hasPrefix:@"wds_"] || [s containsString:@"liquid_glass"] || [s containsString:@"liquidglass"]) return @"WDS / LiquidGlass";

    if ([s containsString:@"graphql"] || [s containsString:@"graph_ql"] || [s hasPrefix:@"gql_"]) return @"GraphQL";
    if ([s containsString:@"mobile_config"] || [s containsString:@"mobileconfig"] || [s containsString:@"mcbased"] || [s hasPrefix:@"mc_"] || [s hasPrefix:@"fbmc_"]) return @"MobileConfig";
    if ([s hasPrefix:@"private_"] || [s containsString:@"private_experiment"] || [s containsString:@"privateab"] || [s containsString:@"debugpropoverride"]) return @"Private Experimentation";

    if (WAGRContainsAny(s, @[@"employee", @"dogfood", @"dogfooding", @"internal", @"tester", @"developer", @"debugmenu"])) return @"Internal / Dogfood";
    if (WAGRContainsAny(s, @[@"aura", @"subscription", @"premium", @"benefit", @"watsapp_plus", @"wa_plus"])) return @"WA Plus / Aura";
    if (WAGRContainsAny(s, @[@"metaai", @"meta_ai", @"ai_", @"llama", @"imagine", @"hatch", @"bot", @"incognito"])) return @"AI / Meta AI";
    if (WAGRContainsAny(s, @[@"settings", @"setting", @"menu", @"row", @"cell", @"entrypoint", @"entry_point"])) return @"Settings / UI";
    if (WAGRContainsAny(s, @[@"business", @"biz", @"smb", @"commerce", @"paid", @"payments", @"payment"])) return @"Business / Payments";
    if (WAGRContainsAny(s, @[@"privacy", @"username", @"passkey", @"security", @"defense", @"block", @"contact"])) return @"Privacy / Identity";
    if (WAGRContainsAny(s, @[@"call", @"voip", @"voice", @"audio", @"video"] )) return @"Calls / Media";
    if (WAGRContainsAny(s, @[@"message", @"chat", @"composer", @"thread", @"poll", @"direct"] )) return @"Messaging";
    if (WAGRContainsAny(s, @[@"status", @"story", @"sticker", @"channel", @"newsletter", @"broadcast"] )) return @"Status / Channels";

    NSString *tok = WAGRFirstToken(s);
    if (!tok.length || [tok isEqualToString:@"is"] || [tok isEqualToString:@"has"] || [tok isEqualToString:@"can"] || [tok isEqualToString:@"should"]) return @"Other";
    return tok.uppercaseString;
}

NSString *WAGRRuntimeSubcategoryForName(NSString *name) {
    NSString *s = name.lowercaseString ?: @"";
    if (!s.length) return @"General";

    // Negative gates first, so dangerous toggles are visually separated.
    if (WAGRContainsAny(s, @[@"kill_switch", @"killswitch", @"kill-switch", @"kill switch", @"disable_all", @"global_disable"])) return @"Negative · Kill Switch";
    if (WAGRContainsAny(s, @[@"disabled", @"disable", @"disable_", @"_disable", @"serverpropsdisable", @"experimental_disabled"])) return @"Negative · Disabled";
    if (WAGRContainsAny(s, @[@"hidden", @"hide", @"suppress", @"remove_row", @"remove_menu", @"not_show", @"dont_show", @"do_not_show"])) return @"Negative · Hide / Suppress";
    if (WAGRContainsAny(s, @[@"block", @"blocked", @"deny", @"denied", @"disallow", @"blacklist", @"black_list", @"ban_"])) return @"Negative · Block / Deny";

    if (WAGRContainsAny(s, @[@"employee", @"dogfood", @"dogfooding", @"internal", @"tester", @"developer", @"dev_only", @"debugmenu", @"debug_menu"])) return @"Internal · Employee / Dogfood";
    if (WAGRContainsAny(s, @[@"debug", @"diagnostic", @"logging", @"log_", @"trace", @"whatsbroken", @"override"])) return @"Debug / Overrides";
    if (WAGRContainsAny(s, @[@"eligible", @"eligibility", @"allowed", @"is_allowed", @"can_", @"should_show", @"entrypoint", @"entry_point"])) return @"Eligibility / Entrypoint";
    if (WAGRContainsAny(s, @[@"enabled", @"enable", @"is_enabled", @"feature_enabled", @"master"])) return @"Positive · Enabled";
    if (WAGRContainsAny(s, @[@"experiment", @"abprop", @"ab_prop", @"bucket", @"sync", @"rollout", @"treatment", @"variant"])) return @"Experiment / Sync";
    if (WAGRContainsAny(s, @[@"fetch", @"cache", @"network", @"request", @"graphql", @"query", @"server"])) return @"Network / Fetch";
    if (WAGRContainsAny(s, @[@"ui", @"view", @"screen", @"row", @"cell", @"section", @"menu", @"button"])) return @"UI / Surface";

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
