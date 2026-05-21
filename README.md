# WATweaks
A research-focused iOS tweak for WhatsApp, built around WAABProperties, runtime feature gates, native Developer/Dogfood surfaces, Liquid Glass, WA Plus/Aura flags, and Keychain diagnostics.\
`Version v1.1.0` | `Target app: WhatsApp iOS`

---

> [!NOTE]
> WATweaks is not a normal “end-user feature pack”. It is a runtime feature-flag browser and hook router for testing WhatsApp iOS gates exposed through Objective-C/Swift runtime surfaces.

---

# Installation

> [!IMPORTANT]
> Which type of device are you planning on installing this tweak on?
> - Jailbroken/TrollStore device -> build or install the generated `.deb`
> - Standard iOS device -> sideload a patched WhatsApp IPA using `cyan`, SideStore, Feather, or a similar sideloading flow

The package target is:

```text
com.darthplagueiswise.watweaks
```

The tweak filter targets:

```text
net.whatsapp.WhatsApp
```

# Features

Features marked with **\*** are the main focus of the current WATweaks refactor.

### Native settings entry **\***
- Injects a `WATweaks` row into WhatsApp Settings **\***
- Opens the WATweaks menu without touching WhatsApp’s table data source **\***
- Uses a UIKit `tableFooterView` strategy for safer insertion **\***
- Keeps the existing long-press activation path for Settings rows **\***
- Long-press supported trigger cells include:
  - Help / Ajuda
  - Developer
  - WATweaks

### Runtime menu **\***
- RyukGram-style root menu adapted for WhatsApp research **\***
- Searchable runtime browser
- Compact feature bundles first; raw technical surfaces moved under Advanced **\***
- Shows active override counts per bundle
- Runtime diagnostics page
- Reset overrides
- Reset WATweaks preferences
- Restart WhatsApp from the tweak menu

### Feature bundles **\***
WATweaks groups hookable runtime entries into user-facing bundles:

- General
- LiquidGlass
- WA Plus / Aura
- Status
- Channels
- Calls
- Messages
- AI / Meta AI
- Privacy & Username
- Premium & Business
- Settings Rows
- Developer / Dogfood / Internal

Each bundle scans only relevant class names, class-name fragments, selector tokens, and categories to reduce runtime noise.

### Advanced runtime browser **\***
Advanced mode exposes raw technical surfaces for debugging and research:

- WAABProperties
- WAContextMain
- Feature Gate Keepers
- WAAuraGating
- Settings Navigation
- Employee / Dogfood

### WAABProperties overrides **\***
- Hooks zero-argument BOOL getters exposed by `WAABProperties` **\***
- Supports `FOAWAABPropertiesImpl` and alternate ABProperties implementations **\***
- Hooks `boolForKey:defaultValue:` as a fallback path **\***
- Hooks `stringForKey:defaultValue:` for string-backed flag paths
- Stores WAAB overrides as plain strings:

```text
wagr.waab.<flag> = "on" | "off"
```

- Missing key means “use WhatsApp’s original value”
- Includes observer logging with a ring buffer
- Includes WAAB diagnostics:
  - installed state
  - direct BOOL hook count
  - boolForKey hook state
  - stringForKey hook state
  - active override count
  - observer state

### WAAB flag catalogs **\***
WATweaks ships curated WAAB catalogs under `resources/`:

```text
waab_selected_categories_bool_only_catalog.json.gz
waab_selected_categories_getter_validated_catalog.json.gz
```

The build process expands/copies those resources into:

```text
/Library/Application Support/WATweaks/
```

The included documentation report tracks selected getter categories and validation metadata.

### Runtime ObjC hook router **\***
- Installs hooks only when a specific entry is explicitly toggled **\***
- Uses `MSHookMessageEx`
- Supports instance methods
- Supports class methods
- Persists overrides with boolean-or-absent semantics
- Records observed original values
- Uses canonical override keys:

```text
wagr.override|objc|<Class>|<inst|class>|<selector>
```

Observed values are stored as:

```text
wagr.observed|objc|<Class>|<inst|class>|<selector>
```

### Native Developer menu gates **\***
Dedicated hook owner for WhatsApp’s native Developer menu gates.

Primary class:

```text
_TtC15WADebugMenuMain17DebugMenuProvider
```

Selectors:

```text
isDebugMenuAllowed
isDebugMenuShortcutEnabled
```

Behavior:

- Forces the native Developer menu gates when the relevant WATweaks toggles are enabled
- Uses deterministic class targets instead of broad startup scans **\***
- Retries installation after launch to handle late Swift runtime loading **\***

### Employee / Dogfood / Internal gates **\***
- Hooks the confirmed `WAServerProperties +isInternalUser` gate **\***
- Keeps forward-compatible trampolines for:
  - `isMetaEmployeeOrInternalTester`
  - `is_meta_employee_or_internal_tester`
  - `graphQLEmployeeC1Disabled`
- Removes the old runtime-wide broad scan approach **\***
- Uses deterministic candidate classes only **\***
- Exposes dogfood diagnostics from the menu

### WAContextMain gates **\***
- Narrows the context hook owner to the confirmed surface:
  - `isVerifiedChannelFeatureFlagEnabled`
- Removes dead/debug selectors previously attempted on `WAContextMain`
- Avoids competing with the dedicated native Developer menu hook owner

### Liquid Glass
- Enables Liquid Glass related UserDefaults overrides
- Supports method hooks around `WDSLiquidGlass`
- Main toggles include:
  - Liquid Glass master
  - UserDefaults override mode
  - Method hook mode
- Targets Liquid Glass flags such as:
  - `wa_lg_ios_liquid_glass_enabled`
  - `wa_lg_ios_liquid_glass_launched`
  - `wa_lg_ios_liquid_glass_m1`
  - `wa_lg_ios_liquid_glass_m_1_5`
  - `wa_lg_ios_liquid_glass_chat_top_bar_m2_enabled`
  - `wa_lg_ios_liquid_glass_enable_new_chatbar_ux`
  - `wa_lg_ios_liquid_glass_larger_composer`
  - `wa_lg_ios_liquid_glass_reduce_transparency`

### WA Plus / Aura simulation
- Applies grouped Aura / subscription / premium benefit flags
- Positive flag group includes themes, icons, stickers, pinned chats, ringtones, AI subscription, and benefit checks
- Negative flag group disables known kill-switch style gates
- Can attempt to open native Aura-related controllers when present:
  - `_TtC6WAAura23AppThemesViewController`
  - `_TtC6WAAura22AppIconsViewController`
  - `WACallRingtonePickerViewController`
  - `_TtC6WAAura30WACallRingtonePickerViewController`
- Includes Aura diagnostic output

### Keychain diagnostics
- Uses `fishhook` to observe Security.framework calls
- Hooks:
  - `SecItemAdd`
  - `SecItemCopyMatching`
  - `SecItemUpdate`
  - `SecItemDelete`
- Optional sideload compatibility behavior for access-group related queries
- Diagnostics include detected access group and patch state
- Main toggles:
  - `wa_sideload_keychain_rewrite_enabled`
  - `wa_keychain_observer_enabled`

### Sideload support
- Includes a SideStore-only sideload patch path
- Uses `modules/fishhook`
- Includes `build-fast.sh` for repackaging a sideloaded IPA using a previously built dylib
- Expects a decrypted WhatsApp IPA when using the sideload flow

### Diagnostics
WATweaks exposes diagnostics for:

- Runtime hook router
- Liquid Glass
- Dogfood / Employee gates
- Keychain access group state
- WAAB observer
- Native Developer menu hook state
- WATweaks Settings row attachment state

# Opening tweak settings

WATweaks can be opened from inside WhatsApp Settings.

Current activation paths:

1. Tap the injected **WATweaks** row in WhatsApp Settings.
2. Long-press supported Settings cells such as **Help**, **Ajuda**, **Developer**, or **WATweaks**.

> [!NOTE]
> The injected WATweaks row is implemented as a footer view to avoid modifying WhatsApp’s internal Settings data source.

# Building from source

### Prerequisites

- Xcode + Command Line Tools
- [Theos](https://theos.dev/docs/installation)
- iPhoneOS 16.2 SDK installed under Theos
- `ldid`
- `dpkg`
- GNU `make`
- `cyan` only for sideload IPA packaging
- A decrypted WhatsApp IPA only for sideload builds

### Clone

```sh
git clone git@github.com:darthplagueiswise/WATweaks.git
cd WATweaks
```

### Build rootless package

```sh
chmod +x build.sh
./build.sh
```

Or directly:

```sh
make package FINALPACKAGE=1
```

### Fast dylib dev build

```sh
chmod +x build-dev.sh
./build-dev.sh
```

### Sideload repackaging

First build the dylib, then place a decrypted WhatsApp IPA under `packages/`.

```sh
./build.sh dylib
./build-fast.sh sidestore
```

# GitHub Actions

The workflow is:

```text
.github/workflows/build-watweaks.yml
```

It builds on macOS, installs dependencies, configures Theos, downloads/restores the iPhoneOS 16.2 SDK, updates the package version from the run number, builds the package, and uploads the `.deb`.

Generated package naming:

```text
WATweaks_<branch>_<base_version>_#<run_number>.deb
```

Example:

```text
WATweaks_main_1.1.0_#12.deb
```

# Project layout

```text
WATweaks/
├── .github/workflows/build-watweaks.yml
├── Makefile
├── control
├── WATweaks.plist
├── build.sh
├── build-dev.sh
├── build-fast.sh
├── modules/
│   ├── fishhook/
│   └── SideloadPatch/
├── resources/
│   ├── waab_selected_categories_bool_only_catalog.json.gz
│   └── waab_selected_categories_getter_validated_catalog.json.gz
├── docs/
│   └── waab_selected_categories_getter_validation_report.md
├── scripts/
│   ├── wagr_validate_sources.py
│   └── sync-dev2-build-assets.sh
└── src/
    ├── Tweak.x
    ├── WAGramPrefix.h
    ├── WAPrefix.h
    ├── WAUtils.*
    ├── WAKeychainPatch.*
    ├── Hooks/
    ├── Menu/
    └── Runtime/
```

# Runtime storage

### WAAB flags

```text
wagr.waab.<flag> = "on" | "off"
```

### Runtime ObjC overrides

```text
wagr.override|objc|<Class>|<inst|class>|<selector> = BOOL
```

### Observed runtime values

```text
wagr.observed|objc|<Class>|<inst|class>|<selector> = BOOL
```

### Important master toggles

```text
wa_employee_master
wa_abprops_observer_enabled
wa_liquid_glass_enabled
wa_sideload_keychain_rewrite_enabled
wa_keychain_observer_enabled
wagr_debug_mode_enabled
wagr_internal_master_enabled
wagr_native_debug_menu_enabled
```

# Validation

Run the project sanity checker:

```sh
python3 scripts/wagr_validate_sources.py
```

The script checks the core project layout, expected source files, tweak plist, router files, and required activation tokens.

# Design notes

- `src/Tweak.x` owns the long-press activation path and table hook.
- Native Developer menu hooks live in `src/Hooks/WAGRNativeDevMenuHooks.xm`.
- Dogfood/Internal hooks live in `src/Hooks/WAGREmployeeHooks.xm`.
- WAAB hooks live in `src/Hooks/WAABPropsObserver.xm`.
- The runtime browser only installs selected overrides.
- Broad startup scans are avoided for the Developer/Dogfood refactor.
- Overrides use `YES`, `NO`, or absent/no override semantics.
- The Settings row avoids WhatsApp data-source mutation.

# Known issues

- WATweaks is a research/debugging tool, so some flags may do nothing until the original WhatsApp code path is reached.
- Some Swift-only or `objc_direct` paths may not appear in the Objective-C runtime browser.
- WAAB flags that are never read by the running app session may not produce visible changes immediately.
- Some native WhatsApp screens may require a restart or a fresh navigation path after toggling a gate.
- The injected Settings row currently uses a footer-style insertion rather than a true WhatsApp-owned Settings cell.

# Credits

- [fishhook](https://github.com/facebook/fishhook) — symbol rebinding used for Keychain observation
- [Theos](https://theos.dev/) — iOS tweak build system
- [RyukGram](https://github.com/faroukbmiled/RyukGram) — menu/build workflow inspiration
- Radan / [@euoradan](https://github.com/euoradan) — WATweaks research, architecture, testing, and feature-flag mapping
