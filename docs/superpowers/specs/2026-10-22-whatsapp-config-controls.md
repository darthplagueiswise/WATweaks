# WhatsApp configuration controls

The user requested updating existing toggles and adding working controls for the
WhatsApp configuration mechanisms established in the IPA investigation. Facebook
attachments remain excluded. This extends existing editors, not a new remote
configuration protocol.

Target: WhatsApp 26.40.10 (1086609742), arm64, minimum iOS 15. Exact selectors and
types must exist in the supplied IPA and be revalidated at runtime. Unsupported
builds/absent getters must not produce usable toggles.

Provide curated groups for MC session/WWW/rollout, MC diagnostics, dogfood and
internal tools, ABProps scheduling and transport diagnostics. Boolean controls
use Native / OFF / ON; Native removes an override, while OFF persists false.
Numeric controls use the existing typed editor. Each group permits explicit
choice of local getter override or verified StartupConfigs override. Never fall
back between these backends silently. Reject a non-default mutation while the
same parameter has a tracked override in the other backend; permit removal.

Reuse the common runtime store and existing StartupConfigs writer. Report
rejected, saved/pending and installed separately. Unknown native values are not
false. Account identity/eligibility remains read-only, consistent with the
existing account-state contract; diagnostics do not grant server eligibility.

Expose native fetch visibly in the MC screen rather than inside the export
sheet; keep fetch/download one-shot actions. Display actual artifact existence
and retain native response/account correlation. Preserve browsing all runtime
families and image inspection. Fix stale ABT-only wording and the reset flow:
clear tracked native overrides before forgetting their registry, preserve keys
needed to retry failed removals, and report failure without silently exiting.

Validation: portable control-state/catalog tests, integration guards on existing
editors, all host checks, independent whole-change review and macOS/Theos CI.
No host check or successful build is a live-device/server claim.
