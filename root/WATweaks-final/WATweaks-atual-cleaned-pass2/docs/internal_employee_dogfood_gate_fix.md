# Internal / Employee / Dogfood gate fix

Root cause found from logs and binary check:

- `WAContextMain` does not implement `isInternalUser`, `isEmployee`, or `isMetaEmployeeOrInternalTester` on this build, so PreFlight showing `responds=NO` is expected and cannot be fixed by hooking that object.
- The only confirmed ObjC owner of `+isInternalUser` is `WAServerProperties` in `SharedModules(14)`.
- The native Developer / Private Experimentation flow mainly reads WAAB/private experimentation keys such as `private_abprop_for_dev_only`, `private_experimentation_should_sync`, `waios_mc_debug_ui_enabled`, `whatsbroken_enabled`, and `dogfooding_nudge_settings_entrypoint_enabled`.
- The previous Internal master only enabled selector-style overrides. It did not set those WAAB keys, so the app still behaved as non-internal for the Private Experimentation path.

This patch makes the Internal master write the verified WAAB/private experimentation keys and bootstraps them again before opening Private Experimentation. It also defers the manager fetch until `viewDidAppear:` to avoid double early calls before UIKit has presented the controller.
