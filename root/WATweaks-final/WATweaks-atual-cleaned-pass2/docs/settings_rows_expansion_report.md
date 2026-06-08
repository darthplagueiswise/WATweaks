# Settings Rows expansion report

Analyzed `WhatsApp(4)` and `SharedModules(8)` with `strings` focused on `SettingsView_*`, payments, Aura/ringtones, companion/primary/linked-device gates.

## Confirmed native Settings identifiers

`SettingsView_PaymentsCell`, `SettingsView_SubscriptionsCell`, `SettingsView_DeveloperCell`, `SettingsView_WebClientCell`, `SettingsView_WAFFLEHomeCell`, `SettingsView_VibesBookmark`, `SettingsView_MetaHorizonBookmark`, `SettingsView_MetaAIAppBookmark`, `SettingsView_ThreadsBookmark`, `SettingsView_IGBookmark`, `SettingsView_FBBookmark`.

## Confirmed builder selectors near WASettingsViewController

`addPaymentsRowToSection:`, `createPaymentRowIfNeeded:`, `showBRConsumerPaymentsHome`, `addSubscriptionsRowToSection:`, `checkSubscriptionsEligibilityAndInsertRowIfNeeded`, `insertSubscriptionsRow`, `removeSubscriptionsRow`, `isSubscriptionsRowPresentInTable`.

## Added groups

- Payments / PIX / UPI: `br_consumer_payments_home_enabled`, `payments_home_revamp_*`, `payment_settings_*`, `br_payments_pix_*`, `enable_payment_passkey`.
- Aura / Ringtones: `aura_ringtones_*`, `wa_plus_custom_ringtones`, `meta_subs_benefit_wa_ringtones_upsell`, inverted `no_premium_ringtones_available`.
- Linked-device / primary-device support: `ios_linked_devices_empty_states_ui_refresh_enabled`, `linked_devices_send_link_cta_ios`, `companion_support_enabled`, `native_contacts_primary_allows_mutations_from_companions`, `primary_lists_support`, `primary_favorites_sync_support`, `username_enabled_on_companion`, `enable_status_on_companion`.

## Runtime behavior

Catalog toggles still use `WAGRSetOverride()` / `WAGRClearOverride()`. When an anchor Settings-row flag is toggled, WATweaks now also applies related flags for that group so one switch enables the likely chain instead of one isolated WAAB getter.

Native row insertion remains lazy: no constructor, no launch-time Settings work, no table footer.
