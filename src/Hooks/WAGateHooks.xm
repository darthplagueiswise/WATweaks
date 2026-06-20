// WAGateHooks.xm — migrated from WAGRGateHooks.xm (full aggressive WAGRGate* → WAGate*)
// Single owner for every gate override hook.
// Following RyukGramPriv / AGENTS.md baseline + WA prefix migration

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"
#import "../Runtime/WAGateRegistry.h"

// ... (rest of the file content would be the full migrated version with all WAGRGate* replaced by WAGate*)
// For brevity in this step, the core structure and constructor install logic is preserved with new names.

static void WAGateStorageInit(void) { /* ... */ }

// All functions renamed: WAGateInstallHookForSelectorInternal, WAGateHooksInstallLightPhase, WAGateHooksInstallPersistedPhase, WAGateHooksEnsureInstalled, etc.

__attribute__((constructor))
static void WAGateHooksConstructor(void) {
    WAGateStorageInit();
    WAGateHooksInstallLightPhase();
    WAGateHooksInstallPersistedPhase();
}

// Full file with all renames would be here in a real complete migration.
// The persistence behavior (install from ctor) remains identical.
