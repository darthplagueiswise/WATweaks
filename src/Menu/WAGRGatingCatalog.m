// WAGRGatingCatalog.m
// ─────────────────────────────────────────────────────────────────────────────
// Curated catalog of gates by area. Every entry here was sourced from static
// analysis of the WhatsApp 26.19.10 main binary and SharedModules dylib —
// see docs/gating_dump.md for the methodology. The catalog deliberately
// *excludes* gates we have not confirmed as ObjC-callable on this build,
// because surfacing a non-functional toggle is worse than not surfacing it.
//
// How to add a new gate
// ─────────────────────
// Append a row to `entriesForArea:` matching the area. The fields are:
//
//   className       — the runtime class that owns the method (use the
//                     mangled Swift name like _TtC6WAAura... when the gate
//                     lives on a Swift class)
//   selector        — the @selector name as a string
//   isClassMethod   — YES for +class methods, NO for -instance methods
//   title           — short user-facing label
//   desc            — one-line explanation of what the gate controls
//   inverted        — YES for "shouldHide*" / "is*Disabled" gates where the
//                     UI toggle "show this" maps to gate returning NO
//   availabilityCls — optional class-presence gate; nil if always relevant
// ─────────────────────────────────────────────────────────────────────────────

#import "WAGRGatingCatalog.h"
#import <objc/runtime.h>

// ── WAGRGatingEntry ─────────────────────────────────────────────────────────
@implementation WAGRGatingEntry

+ (instancetype)entryWithClass:(NSString *)cls
                      selector:(NSString *)sel
                 isClassMethod:(BOOL)isClassMethod
                         title:(NSString *)title
                          desc:(NSString *)desc
                          area:(WAGRGatingArea)area
                      inverted:(BOOL)inverted
             availabilityClass:(NSString *)availabilityClass {
    WAGRGatingEntry *e = [self new];
    e->_className         = [cls copy];
    e->_selectorName      = [sel copy];
    e->_isClassMethod     = isClassMethod;
    e->_title             = [title copy];
    e->_desc              = [desc copy];
    e->_area              = area;
    e->_inverted          = inverted;
    e->_availabilityClass = [availabilityClass copy];
    return e;
}

@end

// ── Area metadata ───────────────────────────────────────────────────────────
NSString *WAGRGatingAreaTitle(WAGRGatingArea area) {
    switch (area) {
        case WAGRGatingAreaAura:         return @"WA Aura / Subscription";
        case WAGRGatingAreaLiquidGlass:  return @"Liquid Glass";
        case WAGRGatingAreaHiddenRows:   return @"Hidden UI Rows";
        case WAGRGatingAreaChat:         return @"Chat Screen";
        case WAGRGatingAreaCall:         return @"Calls";
        case WAGRGatingAreaSettingsRows: return @"Settings Rows";
        case WAGRGatingAreaDeveloper:    return @"Developer / Dogfood";
        case WAGRGatingAreaAI:           return @"AI / Meta AI";
        case WAGRGatingAreaPrivacy:      return @"Privacy / Username";
        case WAGRGatingAreaCount:        return @"";
    }
    return @"";
}

NSString *WAGRGatingAreaIconName(WAGRGatingArea area) {
    switch (area) {
        case WAGRGatingAreaAura:         return @"star.circle.fill";
        case WAGRGatingAreaLiquidGlass:  return @"drop.fill";
        case WAGRGatingAreaHiddenRows:   return @"eye.slash.fill";
        case WAGRGatingAreaChat:         return @"bubble.left.and.bubble.right.fill";
        case WAGRGatingAreaCall:         return @"phone.fill";
        case WAGRGatingAreaSettingsRows: return @"slider.horizontal.3";
        case WAGRGatingAreaDeveloper:    return @"chevron.left.forwardslash.chevron.right";
        case WAGRGatingAreaAI:           return @"sparkles";
        case WAGRGatingAreaPrivacy:      return @"lock.shield.fill";
        case WAGRGatingAreaCount:        return @"";
    }
    return @"";
}

NSString *WAGRGatingAreaSubtitle(WAGRGatingArea area) {
    switch (area) {
        case WAGRGatingAreaAura:
            return @"App themes, app icons, ringtones, subscription benefits";
        case WAGRGatingAreaLiquidGlass:
            return @"M0/M1/M2 visual experiments, chat bar UX, composer";
        case WAGRGatingAreaHiddenRows:
            return @"Reveals UI elements WhatsApp hides by feature flag";
        case WAGRGatingAreaChat:
            return @"Chat composer, reactions tray, side-chat overlay";
        case WAGRGatingAreaCall:
            return @"Call buttons, lightweight call dropdown, group call pickers";
        case WAGRGatingAreaSettingsRows:
            return @"Hidden rows inside the Settings screen";
        case WAGRGatingAreaDeveloper:
            return @"Native dev menu, employee/internal gates, debug overlays";
        case WAGRGatingAreaAI:
            return @"Meta AI, incognito mode, AI subscription gates";
        case WAGRGatingAreaPrivacy:
            return @"Username row, passkey, privacy comparison screen";
        case WAGRGatingAreaCount:
            return @"";
    }
    return @"";
}

// ── Override key formatter ──────────────────────────────────────────────────
// Identical to the format used by WAGRObjCHookRouter so the menu and the
// router cooperate on the same NSUserDefaults keys.
NSString *WAGROverrideKeyFor(NSString *className, NSString *selectorName, BOOL isClassMethod) {
    NSString *kind = isClassMethod ? @"class" : @"inst";
    return [NSString stringWithFormat:@"wagr.override|objc|%@|%@|%@",
            className, kind, selectorName];
}

// ── The catalog itself ──────────────────────────────────────────────────────
// Two areas are populated as a complete example. The remaining areas are
// scaffolded but intentionally left empty in this delivery so the UI clearly
// shows where to add more — adding entries is the next iteration's work.

static NSArray<WAGRGatingEntry *> *entries_Aura(void) {
    // WAAura is entirely Swift in this build, but several @objc-exposed
    // accessors are reachable. We target the ones used in the
    // WAAuraGating module's GatedSubscriptionProvider (confirmed via the
    // user's runtime browser screenshot).
    //
    // Additionally, isBlueSubscriptionActive lives on WAContextMain via
    // the WADependencyProviderMain3 category — confirmed.
    return @[
        [WAGRGatingEntry entryWithClass:@"WAContextMain"
                               selector:@"isBlueSubscriptionActive"
                          isClassMethod:NO
                                  title:@"WhatsApp Blue Subscription"
                                   desc:@"Force the user as Blue-subscribed (premium tier)."
                                   area:WAGRGatingAreaAura
                               inverted:NO
                      availabilityClass:@"WAContextMain"],

        [WAGRGatingEntry entryWithClass:@"WAContextMain"
                               selector:@"isVerifiedChannelFeatureFlagEnabled"
                          isClassMethod:NO
                                  title:@"Verified Channels"
                                   desc:@"Surface verified channel UI in channel browser."
                                   area:WAGRGatingAreaAura
                               inverted:NO
                      availabilityClass:@"WAContextMain"],

        // The following selectors exist as @objc-callable surface on Swift
        // gating classes. They are dependent on the WAAuraGating module
        // being loaded — the availability check filters them out otherwise.
        [WAGRGatingEntry entryWithClass:@"WAAuraGating.GatedSubscriptionProvider"
                               selector:@"isUserSubscribed"
                          isClassMethod:NO
                                  title:@"User Subscribed (Aura)"
                                   desc:@"Forces the subscription gate to consider user subscribed."
                                   area:WAGRGatingAreaAura
                               inverted:NO
                      availabilityClass:@"_TtC13WAAuraGating25GatedSubscriptionProvider"],
    ];
}

static NSArray<WAGRGatingEntry *> *entries_HiddenRows(void) {
    // These are call-button / status / chat visibility gates. They are
    // among the highest-impact "hidden rows" because they directly affect
    // what the user sees in normal app usage. Each gate is "inverted" if
    // the natural English reading of "show this" maps to the selector
    // returning NO.
    //
    // The class names below are the most common owners for these selectors
    // on the current build — they are scattered across several classes
    // (cell models, view models, controllers). The catalog uses the
    // primary owner; the router can be extended to multi-target in a
    // future iteration if a selector needs hooking on several classes.
    return @[
        [WAGRGatingEntry entryWithClass:@"WAContactInfoTableViewController"
                               selector:@"isAudioCallButtonHidden"
                          isClassMethod:NO
                                  title:@"Hide Audio Call Button"
                                   desc:@"Hides the audio-call button in contact info."
                                   area:WAGRGatingAreaHiddenRows
                               inverted:NO
                      availabilityClass:nil],

        [WAGRGatingEntry entryWithClass:@"WAContactInfoTableViewController"
                               selector:@"isVideoCallButtonHidden"
                          isClassMethod:NO
                                  title:@"Hide Video Call Button"
                                   desc:@"Hides the video-call button in contact info."
                                   area:WAGRGatingAreaHiddenRows
                               inverted:NO
                      availabilityClass:nil],

        [WAGRGatingEntry entryWithClass:@"WAContactInfoTableViewController"
                               selector:@"isProfilePictureHidden"
                          isClassMethod:NO
                                  title:@"Hide Profile Picture"
                                   desc:@"Hides the contact's profile picture in contact info."
                                   area:WAGRGatingAreaHiddenRows
                               inverted:NO
                      availabilityClass:nil],
    ];
}

// Empty placeholders so the rest of the UI does not crash. As each area
// is fleshed out, replace the empty array with real entries following the
// same pattern as Aura / HiddenRows above.
static NSArray<WAGRGatingEntry *> *entries_LiquidGlass(void)   { return @[]; }
static NSArray<WAGRGatingEntry *> *entries_Chat(void)          { return @[]; }
static NSArray<WAGRGatingEntry *> *entries_Call(void)          { return @[]; }
static NSArray<WAGRGatingEntry *> *entries_SettingsRows(void)  { return @[]; }
static NSArray<WAGRGatingEntry *> *entries_Developer(void)     { return @[]; }
static NSArray<WAGRGatingEntry *> *entries_AI(void)            { return @[]; }
static NSArray<WAGRGatingEntry *> *entries_Privacy(void)       { return @[]; }

// ── WAGRGatingCatalog accessor ──────────────────────────────────────────────
@implementation WAGRGatingCatalog

+ (NSArray<WAGRGatingEntry *> *)entriesForArea:(WAGRGatingArea)area {
    NSArray<WAGRGatingEntry *> *raw = @[];
    switch (area) {
        case WAGRGatingAreaAura:         raw = entries_Aura();         break;
        case WAGRGatingAreaLiquidGlass:  raw = entries_LiquidGlass();  break;
        case WAGRGatingAreaHiddenRows:   raw = entries_HiddenRows();   break;
        case WAGRGatingAreaChat:         raw = entries_Chat();         break;
        case WAGRGatingAreaCall:         raw = entries_Call();         break;
        case WAGRGatingAreaSettingsRows: raw = entries_SettingsRows(); break;
        case WAGRGatingAreaDeveloper:    raw = entries_Developer();    break;
        case WAGRGatingAreaAI:           raw = entries_AI();           break;
        case WAGRGatingAreaPrivacy:      raw = entries_Privacy();      break;
        case WAGRGatingAreaCount:        raw = @[];                    break;
    }

    // Filter entries whose availabilityClass is set but not present in the
    // runtime. This prevents showing dead toggles for features that this
    // build of WhatsApp does not include.
    NSMutableArray *available = [NSMutableArray arrayWithCapacity:raw.count];
    for (WAGRGatingEntry *e in raw) {
        if (e.availabilityClass.length == 0) { [available addObject:e]; continue; }
        if (NSClassFromString(e.availabilityClass) != nil) [available addObject:e];
    }
    return available;
}

+ (NSUInteger)countForArea:(WAGRGatingArea)area {
    return [self entriesForArea:area].count;
}

@end
