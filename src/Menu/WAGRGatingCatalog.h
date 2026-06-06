// WAGRGatingCatalog.h
// ─────────────────────────────────────────────────────────────────────────────
// The catalog is the single source of truth for every gate the WATweaks UI
// can toggle. It is intentionally a *data* file — adding a new gate to the
// menu is a one-line entry in WAGRGatingCatalog.m, not a new view controller.
//
// Each entry binds a (Class, Selector) pair to a human-friendly label, a
// short description of what the gate controls, and an area tag that groups
// related gates together in the UI.
//
// The runtime side reads the override state from NSUserDefaults using the
// existing WAGRObjCHookRouter override key format:
//
//   wagr.override|objc|<ClassName>|<inst|class>|<selector>
//
// so the catalog requires no new persistence code — it reuses the storage
// the router already knows about. When the user flips a switch in the
// area menu, we write to that key; the router's startup pass picks it up.
// ─────────────────────────────────────────────────────────────────────────────

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Areas ───────────────────────────────────────────────────────────────────
// Each area gets its own dedicated screen in the menu. Adding a new area is
// a matter of appending an enum value and a title string in WAGRGatingArea
// + WAGRGatingAreaTitle below, then populating entries with that area tag.
typedef NS_ENUM(NSInteger, WAGRGatingArea) {
    WAGRGatingAreaAura = 0,           // WAAura / subscription / premium gates
    WAGRGatingAreaLiquidGlass,        // LiquidGlass / WDS visual experiments
    WAGRGatingAreaEvolveAbout,        // Evolve/About Me, contact card, profile bubble gates
    WAGRGatingAreaContactsHub,        // Contacts hub, favorites, recently-online/presence gates
    WAGRGatingAreaPayments,           // Payments / PIX / UPI / Meta Pay gates
    WAGRGatingAreaLinkedDevices,      // Linked-device / primary / companion gates
    WAGRGatingAreaGroups,             // Group AB properties / group history gates
    WAGRGatingAreaHiddenRows,         // is*Hidden / shouldHide* across UI
    WAGRGatingAreaChat,               // Chat-screen specific gates
    WAGRGatingAreaCall,               // Call/voice/video gates
    WAGRGatingAreaSettingsRows,       // Hidden rows in Settings VC
    WAGRGatingAreaDeveloper,          // Internal/developer/dogfood gates
    WAGRGatingAreaAI,                 // Meta AI / AI subscription gates
    WAGRGatingAreaPrivacy,            // Privacy / username / passkey gates
    WAGRGatingAreaFOA,                // Family-of-apps / Meta app utility gates
    WAGRGatingAreaBiz,                // WABiz / business / catalog / merchant gates
    WAGRGatingAreaCount,
};

NSString *WAGRGatingAreaTitle(WAGRGatingArea area);
NSString *WAGRGatingAreaIconName(WAGRGatingArea area);
NSString *WAGRGatingAreaSubtitle(WAGRGatingArea area);

// ── Entry ───────────────────────────────────────────────────────────────────
// One catalog entry describes a single toggleable gate.
//
// `inverted` is for "is*Disabled" / "should*Hide" style selectors where
// the user-friendly toggle ("show this UI element") maps to the gate
// returning NO. When inverted=YES, the UI toggle ON forces the gate to NO;
// when inverted=NO, the UI toggle ON forces the gate to YES.
@interface WAGRGatingEntry : NSObject

@property(nonatomic, copy, readonly)   NSString *className;
@property(nonatomic, copy, readonly)   NSString *selectorName;
@property(nonatomic, assign, readonly) BOOL isClassMethod;
@property(nonatomic, copy, readonly)   NSString *title;
@property(nonatomic, copy, readonly)   NSString *desc;
@property(nonatomic, assign, readonly) WAGRGatingArea area;
@property(nonatomic, assign, readonly) BOOL inverted;
// Optional pre-flight check: a class name that, if not present at runtime,
// the entry is suppressed from the UI. Use this for entries that target
// Swift classes that may not be loaded on every build. nil = always show.
@property(nonatomic, copy, readonly, nullable) NSString *availabilityClass;

+ (instancetype)entryWithClass:(NSString *)cls
                      selector:(NSString *)sel
                 isClassMethod:(BOOL)isClassMethod
                         title:(NSString *)title
                          desc:(NSString *)desc
                          area:(WAGRGatingArea)area
                      inverted:(BOOL)inverted
             availabilityClass:(nullable NSString *)availabilityClass;
@end

// ── Catalog accessor ────────────────────────────────────────────────────────
@interface WAGRGatingCatalog : NSObject

// Returns all entries for the given area, with entries whose availabilityClass
// is set but not present in the runtime filtered out.
+ (NSArray<WAGRGatingEntry *> *)entriesForArea:(WAGRGatingArea)area;

// Returns the total count of entries across all areas. Useful for the root
// menu where we display "Aura — 12 gates" etc.
+ (NSUInteger)countForArea:(WAGRGatingArea)area;

@end

// ── Pref key formatter (mirrors WAGRObjCHookRouter's key format) ────────────
// The catalog and the router both use this exact format so a toggle change
// from the menu and a programmatic override from the router are reading
// and writing the same NSUserDefaults key.
NSString *WAGROverrideKeyFor(NSString *className, NSString *selectorName, BOOL isClassMethod);

NS_ASSUME_NONNULL_END
