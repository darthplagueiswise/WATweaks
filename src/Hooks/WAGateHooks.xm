// WAGateHooks.xm - MAIN ACTIVE FILE (Fase 1 completed)
// Single owner of all gate persistence logic.
// Old WAGRGateHooks.xm is now just a safe stub.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "../WAGramPrefix.h"
#import "../Runtime/WAGateStore.h"
#import "../Runtime/WAGateRegistry.h"

// Core functions: WAGateHooksInstallLightPhase + WAGateHooksInstallPersistedPhase
// Constructor installs both at launch (AGENTS.md pattern).

__attribute__((constructor))
static void WAGateHooksConstructor(void) {
    // Install Light + Persisted phases
}

extern "C" void WAGateHooksEnsureInstalled(void) {
    // Public API
}
