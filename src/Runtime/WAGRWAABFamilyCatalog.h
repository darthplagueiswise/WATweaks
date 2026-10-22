#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves the Objective-C category/family recorded in the supplied IPA.
/// When no build metadata exists, returns a visibly marked heuristic fallback.
FOUNDATION_EXPORT NSString *WAGRWAABFamilyForSelector(NSString *selectorName,
                                                       NSString *_Nullable sourceImage,
                                                       NSString *fallback,
                                                       BOOL *_Nullable cataloged);
FOUNDATION_EXPORT NSString *WAGRWAABFamilyCatalogDiagnosticText(void);

NS_ASSUME_NONNULL_END
