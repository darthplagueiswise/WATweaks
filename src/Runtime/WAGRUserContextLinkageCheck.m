#import "WAGRUserContextLinkage.h"

// Link-time guard: this translation unit intentionally references the public
// C linkage symbol exported by WAGRDebugMenuLauncher.xm. If an ObjC++/Logos
// consumer accidentally redeclares WAGRCurrentUserContext without extern "C",
// that consumer will fail independently, while this file guarantees the
// canonical symbol itself remains present in every dogfood2 build.
__attribute__((used))
static id (*const kWAGRCurrentUserContextLinkageCheck)(void) = WAGRCurrentUserContext;
