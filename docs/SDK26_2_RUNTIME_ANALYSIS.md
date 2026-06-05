# WATweaks SDK 26.2 runtime refresh

Inputs analyzed:

- WhatsApp(14): Mach-O arm64 executable, SDK 26.2, minOS 15.1.
- SharedModules(18): Mach-O arm64 dylib, SDK 26.2, minOS 15.1.

Confirmed SDK 26.2 surfaces:

- `FOAWAABPropertiesImpl` is in SharedModules and exposes `boolForKey:defaultValue:`, `stringForKey:defaultValue:`, `integerForKey:defaultValue:` and `doubleForKey:defaultValue:`. The old hook was incomplete because it only covered bool/string.
- `WAAuraGating` is in SharedModules and has ObjC-visible BOOL instance methods: `isEnabled`, `isUserEligible`, `isSettingsRowEnabled`, `isKillSwitchActive`, `isAppearanceSettingsEnabled`, `isAppIconsEnabled`, `isAppThemesEnabled`, `isRingtonesEnabled`, `isEnhancedListsEnabled`, `isStickersEnabled`, and benefit methods.
- Aura has an official simulation flag: `aura_subscription_simulation_enabled`. The patch treats Aura as a simulation/experiment surface, not as a credential bypass.
- `WDSLiquidGlass` is in SharedModules and exposes class methods for M0/M1/M1.5/M2/top bar/native swipe/unify navigation/fixes. The patch hooks the class methods and also writes the corresponding `ios_liquid_glass_*` WAAB flags through `WAGRGateStore`.
- Runtime catalogs generated from the submitted binaries:
  - WhatsApp Exec runtime entries: 10680
  - SharedModules runtime entries: 13158
  - WAAB candidate feature flags: 12191

Design:

- No global class scan in constructor.
- Constructor phase installs fixed, known hot-path hooks only.
- Runtime browsers are scoped by Mach-O image using `class_getImageName`: one for WhatsApp exec and one for SharedModules.
- WAAB overrides use the existing single source of truth, `WAGRGateStore`, so bool/string/integer/double lookups resolve consistently.
- Visual theme removes the old flat black/opaque feel and uses system material blur/transparent grouped UI. No gradients.

## Liquid Glass UI correction

The WATweaks menu chrome must not simulate Liquid Glass with legacy `UIBlurEffect`/material styles. The SDK 26.2 patch now uses the iOS 26 UIKit glass classes dynamically:

- `UIGlassEffect` for custom menu and cell glass surfaces.
- `UIGlassContainerEffect` for the controller-level glass container where available.
- Native iOS 26 navigation/toolbar chrome is left alone so UIKit can render Liquid Glass itself.
- Older iOS versions receive only neutral translucent fallback colors, not fake blur.
