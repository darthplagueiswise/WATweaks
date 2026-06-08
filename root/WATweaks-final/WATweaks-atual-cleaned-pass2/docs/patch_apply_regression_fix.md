# Patch apply regression fix

Root cause: the strict startup zip removed timed retries and also removed most dyld add-image retries. Several hook owners only attempted installation once in their constructor. In WhatsApp/SharedModules many target classes are registered later, so constructor-only attempts missed them and the toggles appeared to write state without any live hook installed.

Fix:
- keep constructor hook batches;
- add dyld add-image callbacks that retry only targeted hook installers;
- no dispatch_after retry cascade;
- no runtime scan in constructors;
- no NSUserDefaults migration/wipe in constructors;
- restore SettingsRows ensure before injecting into WASettingsViewController;
- keep WAGRGateIsSet/Get hot path as direct objectForKey on canonical key.
