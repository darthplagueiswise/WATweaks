# WATweaks runtime validation against current WhatsApp binaries

Validated with `lief` and `capstone` inside the sandbox against the uploaded current binaries:

- `/mnt/data/WhatsApp(16)`
- `/mnt/data/SharedModules(20)`

## WhatsApp executable

- LIEF parsed Mach-O: `CPU_TYPE.ARM64`; sections inspected: `__text, __objc_methname, __cstring`.
- Relevant string/selector presence:
  - `WAABProperties`: 648
  - `FOAWAABPropertiesImpl`: 0
  - `boolForKey:defaultValue:`: 2
  - `stringForKey:defaultValue:`: 2
  - `integerForKey:defaultValue:`: 2
  - `doubleForKey:defaultValue:`: 1
  - `WAAuraGating`: 145
  - `WDSLiquidGlass`: 2
  - `isM0Enabled`: 3
  - `isM1Enabled`: 3
  - `isInternalUser`: 3
  - `isDebugMenuAllowed`: 1
  - `isDebugMenuShortcutEnabled`: 1
  - `aura_enabled`: 1
  - `aura_subscription_simulation_enabled`: 0
  - `ios_liquid_glass_enabled`: 0
  - `ios_liquid_glass_launched`: 0

- Capstone disassembly sample from `__text`:

```asm
0x100008000: sub sp, sp, #0x40
0x100008004: stp x20, x19, [sp, #0x20]
0x100008008: stp x29, x30, [sp, #0x30]
0x10000800c: add x29, sp, #0x30
0x100008010: str xzr, [sp, #0x18]
0x100008014: adrp x0, #0x108019000
0x100008018: add x0, x0, #0xe78
0x10000801c: ldr x8, [x0]
```

## SharedModules.framework

- LIEF parsed Mach-O: `CPU_TYPE.ARM64`; sections inspected: `__text, __objc_methname, __cstring`.
- Relevant string/selector presence:
  - `WAABProperties`: 234
  - `FOAWAABPropertiesImpl`: 3
  - `boolForKey:defaultValue:`: 4
  - `stringForKey:defaultValue:`: 4
  - `integerForKey:defaultValue:`: 4
  - `doubleForKey:defaultValue:`: 4
  - `WAAuraGating`: 10
  - `WDSLiquidGlass`: 2
  - `isM0Enabled`: 1
  - `isM1Enabled`: 1
  - `isInternalUser`: 2
  - `isDebugMenuAllowed`: 0
  - `isDebugMenuShortcutEnabled`: 0
  - `aura_enabled`: 1
  - `aura_subscription_simulation_enabled`: 1
  - `ios_liquid_glass_enabled`: 1
  - `ios_liquid_glass_launched`: 1

- Capstone disassembly sample from `__text`:

```asm
0x4000: stp x22, x21, [sp, #-0x30]!
0x4004: stp x20, x19, [sp, #0x10]
0x4008: stp x29, x30, [sp, #0x20]
0x400c: add x29, sp, #0x20
0x4010: mov x19, x1
0x4014: adrp x8, #0x3ef7000
0x4018: ldr x8, [x8, #0x1b8]
0x401c: cbnz x8, #0x4034
```

## Source changes tied to validation

- Runtime surfaces are now image-backed: `exec` filters classes whose `class_getImageName()` is the main `WhatsApp.app/WhatsApp` image; `sharedmodules` filters `SharedModules.framework/SharedModules`.
- Runtime rows are only no-argument Objective-C methods/properties returning `BOOL`/`char`; this matches what `MSHookMessageEx` trampolines can safely force.
- WAAB central hooks target `boolForKey:defaultValue:`, `stringForKey:defaultValue:`, `integerForKey:defaultValue:` and `doubleForKey:defaultValue:`; all four are present in SharedModules and the BOOL/string/integer variants also appear in the executable.
- Developer-menu UI mutation hooks are disabled; the tweak entrypoint is Settings long-press only.
- Launch is hook-safe: constructors no longer install Gate/WAAB/Aura/Dogfood/Developer hooks. The user installs hooks explicitly via toggles or the Apply button.
