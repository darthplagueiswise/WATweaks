#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@class WAGRABPropEntry;

@interface WAGRABPropsBrowserVC : UITableViewController <UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic, strong, readonly, nullable) id userContext;
@property(nonatomic, strong, readonly, nullable) id explicitABProperties;

- (instancetype)initWithUserContext:(id _Nullable)userContext;
- (instancetype)initWithUserContext:(id _Nullable)userContext
                        abProperties:(id _Nullable)abProperties;

/// Subclass hooks used by the compatibility reconstruction of WhatsApp's
/// removed WADebugABPropertiesTableViewController.
- (NSString *)wagrInitialABPropertiesTitle;
- (NSString *)wagrABPropertiesTitleForEntryCount:(NSUInteger)entryCount;
- (BOOL)wagrUsesNativeABPropertiesWriter;
- (BOOL)wagrAllowsRuntimeABPropertiesFallback;
- (BOOL)wagrScopesToExplicitABProperties;
- (BOOL)wagrShowsABTFetchControl;
- (BOOL)wagrShowsDiagnosticFooter;
- (BOOL)wagrIncludesRuntimeEntry:(WAGRABPropEntry *)entry;
- (NSString *)wagrDisplayTitleForEntry:(WAGRABPropEntry *)entry;
- (BOOL)wagrUsesThreeStateControls;
- (void)scanNow;
- (BOOL)wagrHasActiveOperation;
@end

NS_ASSUME_NONNULL_END
