// datarover_asmjit_ios.h — forced include for asmjit TUs in the iOS build.
//
// Upstream asmjit gates its Apple cache/JIT helpers on TARGET_OS_OSX, which
// is 0 under the iPhoneOS SDK. The header <libkern/OSCacheControl.h> (and
// sys_icache_invalidate) exists on iOS — only the include is skipped. This
// shim restores the include for iOS targets; the call site then compiles.
// No other asmjit behavior is changed (JIT/W^X policy is decided at runtime
// by the app's MAP_JIT entitlement path, same as macOS).
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && !TARGET_OS_OSX
#include <libkern/OSCacheControl.h>
#endif
#endif
