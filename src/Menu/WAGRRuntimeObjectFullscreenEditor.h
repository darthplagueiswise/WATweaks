#pragma once
#import <UIKit/UIKit.h>

BOOL WAGRPresentRuntimeFullObjectEditor(UIViewController *presenter,
    NSString *className, NSString *selectorName, BOOL meta, NSString *typeCode,
    id raw, dispatch_block_t completion);
