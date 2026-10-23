#pragma once
#import "WAGRABPropsBrowserVC.h"
#include "../Runtime/WAGRConfigControlCatalog.h"

@interface WAGRConfigControlsVC : WAGRABPropsBrowserVC
- (instancetype)initWithUserContext:(id)context group:(WAGRConfigControlGroup)group;
@end
