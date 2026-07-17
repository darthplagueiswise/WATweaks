#import "WAGRRuntimeClassifier.h"
#import "WAGRSurface.h"

// Compatibility facade for older callers. The previous implementation owned a
// long list of product-specific keywords that became stale on every WhatsApp
// build. All names now come from the same live tokeniser used by the runtime
// scanners; there is no separately maintained category table here.

NSString *WAGRRuntimePrefixForName(NSString *name) {
    return WAGRLiveRuntimeFamilyForSelector(name, nil);
}

NSString *WAGRRuntimeSubcategoryForName(NSString *name) {
    return WAGRLiveRuntimeSubcategoryForEntry(name, nil, nil);
}

NSString *WAGRRuntimeSectionForName(NSString *name) {
    return WAGRLiveRuntimeSubcategoryForEntry(name, nil, nil);
}

NSString *WAGRRuntimeSectionForSelector(NSString *selectorName, NSString *className) {
    return WAGRLiveRuntimeSubcategoryForEntry(selectorName, className, nil);
}
