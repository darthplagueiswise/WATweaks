// WADefaults.h
// Baseline following RyukGramPriv / AGENTS.md
// All tweak preferences that should be backed up/exported must be registered here.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the master dictionary of all registered defaults.
/// Used for backup, export, and first-run initialization.
NSDictionary<NSString *, id> * WADefaultsDictionary(void);

/// Convenience: get a registered default value (falls back to NSUserDefaults if not present).
id WAGetDefault(NSString *key);

NS_ASSUME_NONNULL_END