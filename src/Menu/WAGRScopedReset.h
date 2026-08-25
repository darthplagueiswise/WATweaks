#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Presents the destructive reset sheet with independent WATweaks scopes.
/// Runtime-value overrides are classified from their exact persisted
/// class/selector/meta tuple and the currently loaded Mach-O image.
void WAGRPresentScopedReset(UIViewController *presenter);

NS_ASSUME_NONNULL_END
