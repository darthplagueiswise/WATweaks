#import "WAGRABPropsNativeOverrideEngine.h"

// Compatibility translation unit retained because it is part of the existing
// Theos source list. The tracked-intent registry now has a single owner in
// WAGRABPropsNativeOverrideEngine.m, alongside the read/sync/export operations
// that consume it. Keeping duplicate mutator implementations here would create
// duplicate linker symbols and, more importantly, split ownership of the same
// watweak_native_abprops_override_registry_v3 store.
