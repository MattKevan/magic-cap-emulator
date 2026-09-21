// The ABI lives in the app's linked static library, not in this package.
// This translation unit exists so SwiftPM produces an importable module
// from include/CoreBridge.h; it deliberately defines nothing.
//
// It is Objective-C (.m), not C: CoreBridge.h imports Foundation for its
// NS_ASSUME_NONNULL nullability macros, and clang refuses the Foundation /
// ObjectiveC modules in plain C mode ("module 'ObjectiveC.NSObject'
// requires feature 'objc'").
#include "CoreBridge.h"
