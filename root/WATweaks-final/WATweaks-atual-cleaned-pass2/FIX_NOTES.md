# WATweaks-atual fixed package

This package uses the working menu activation architecture as the base while keeping the current runtime gate files.

Applied cleanup:
- Restored the WASettingsViewController WATweaks navigation-bar button.
- Re-enabled the idempotent native settings row hook owner instead of the disabled shim.
- Routed both Settings button and long-press fallback to the same WAGRSurfaceListVC menu.
- Removed the duplicate WAGRMainSettingsVC menu source so the build has one root menu owner.
- Kept long-press Help/Developer/WATweaks fallback and global two-finger double-tap fallback from the working base.
- Kept the current gate/persistence implementation through WAGRGateStore and WAGRRuntimeCompat.

Validation performed:
- Zip integrity check on both input archives.
- Static source comparison between current and working base.
- Static duplicate entrypoint cleanup.
- Syntax-level symbol presence check for the restored startup/Settings hook externs.

Note: I could not run a full Theos/iOS build in this sandbox because the iOS toolchain is not installed here.
