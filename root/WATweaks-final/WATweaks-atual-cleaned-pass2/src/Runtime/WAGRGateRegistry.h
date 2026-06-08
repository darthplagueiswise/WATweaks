// WAGRGateRegistry.h — declarative description of the gate provider tree.
// ─────────────────────────────────────────────────────────────────────────────
// What this file owns
// ───────────────────
// The runtime gates UI is driven by a small, hand-curated registry of
// "providers". A provider is one row in the root menu — a logical category
// of related gates (e.g. LiquidGlass, Aura, MobileConfig). Each provider
// declares:
//
//   • A stable id (used internally; never persisted as part of a key)
//   • A user-facing title, subtitle and SF Symbol
//   • A list of concrete or fragment class names to scan at runtime
//   • A list of "featured" flags — the ones we know matter to the user.
//     These are surfaced at the top of the category screen. Everything
//     else discovered at runtime is reachable via the "Runtime Avançado"
//     button on the same screen.
//
// Why featured vs. runtime
// ────────────────────────
// The user reported that wanting to flip "LiquidGlass M1.5 off but keep
// LiquidGlass on" is impossible in a master-only UI. Featured flags answer
// the "show me the dial I'm looking for" case; the runtime browser answers
// the "let me poke any specific sub-flag" case. Both write the same
// schema-v2 key, so a flip in one screen is reflected immediately in the
// other.
//
// Adding/removing providers
// ─────────────────────────
// Append a WAGRGateProviderMake(...) row in WAGRGateRegistry.m's
// +allProviders. The runtime UI rebuilds from that list at view-load time —
// no other file touch needed.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Featured flag descriptor ─────────────────────────────────────────────────
// One row on the category screen. `selectorName` is the schema-v2 storage
// key (same name the runtime hook trampoline reads). `inverted` is YES for
// gates whose user-friendly meaning ("show this UI element") maps to the
// underlying gate returning NO. The toggle is written exactly as displayed;
// inversion is purely a presentation hint we propagate to the hook layer.
@interface WAGRGateFeaturedFlag : NSObject
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *detail;
@property(nonatomic, assign) BOOL inverted;
+ (instancetype)flagWithName:(NSString *)selectorName
                       title:(NSString *)title
                      detail:(nullable NSString *)detail
                    inverted:(BOOL)inverted;
@end

// ── Provider (category) ──────────────────────────────────────────────────────
@interface WAGRGateProvider : NSObject
@property(nonatomic, copy) NSString *providerID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *icon;

/// Concrete class names. Each name is checked via NSClassFromString at scan
/// time; absent classes are silently skipped (Swift may not be loaded yet).
@property(nonatomic, copy) NSArray<NSString *> *concreteClassNames;

/// Substring fragments. The runtime scanner enumerates objc_copyClassList
/// and matches each fragment case-insensitively. Avoid overly generic
/// fragments — they slow the scan and produce noise.
@property(nonatomic, copy) NSArray<NSString *> *classNameFragments;

/// Optional selector substring whitelist. If non-empty, the runtime browser
/// only surfaces selectors whose name contains any of these substrings
/// (case-insensitive). Empty = no filter.
@property(nonatomic, copy) NSArray<NSString *> *selectorTokens;

/// Featured flags displayed at the top of the category screen.
@property(nonatomic, copy) NSArray<WAGRGateFeaturedFlag *> *featured;

/// Scan options.
@property(nonatomic, assign) BOOL scanInstanceMethods;
@property(nonatomic, assign) BOOL scanClassMethods;
@property(nonatomic, assign) BOOL scanProperties;
@end

@interface WAGRGateRegistry : NSObject
/// Ordered list of providers shown in the runtime gates menu.
+ (NSArray<WAGRGateProvider *> *)allProviders;
/// Lookup by id; nil if not found.
+ (nullable WAGRGateProvider *)providerWithID:(NSString *)providerID;
@end

NS_ASSUME_NONNULL_END
