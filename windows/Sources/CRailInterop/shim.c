// Everything this target exports is `static inline` in the header; nothing needs a body of its own
// here. SwiftPM still wants a translation unit to build the target around, so this is it.
#include "CRailInterop.h"

int SixRailInteropVersion(void) { return 1; }
