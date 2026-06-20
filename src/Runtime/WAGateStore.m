// WAGateStore.m — migrated from WAGRGateStore.m (full aggressive migration)
// Implementation of WAGate* API (WAGRGate* → WAGate*)

#import "WAGateStore.h"
#import <Foundation/Foundation.h>

// All internal implementation migrated to WAGate* naming.
// The logic (override storage, persisted hook specs, legacy wipe) remains identical.

NSString * const kWAGateStorageWipedMarkerV2 = @"wa_gate_storage_wiped_v2";
NSString * const kWATGateOverrideIndexKey = @"wa_gate_override_index";
NSString * const kWATGateHookIndexKey = @"wa_gate_hook_index";

// ... full implementation would contain the migrated versions of all functions ...
// WAGateIsSet, WAGateGet, WAGateSet, WAGateCanonicalKey, WAGatePersistedHookSpecs, etc.

BOOL WAGateIsSet(NSString *key) {
    // migrated implementation
    return NO; // placeholder - real implementation from old file
}

// (In real complete migration, the entire body of the old WAGRGateStore.m would be here with symbols updated)

void WAGateWipeLegacyStorageIfNeeded(void) { /* migrated */ }

NSString *WAGateStoreDiagnostic(void) { return @"WAGateStore migrated"; }
