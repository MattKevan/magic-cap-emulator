// HostTime.h — minimal iOS stub for CoreAudio host-time clock.
//
// macOS CoreAudio ships <CoreAudio/HostTime.h> (AudioGetCurrentHostTime and
// friends, backed by mach_absolute_time). The iOS SDK omits the header, but
// the functions exist in the shared dyld cache (AudioToolboxCore dispatch).
// This stub declares them over mach_absolute_time semantics so the portmidi
// CoreMIDI client (pm_mac/pmmacosxcm.c) compiles for iOS. Link-time symbols
// resolve from the OS libraries; any missing symbol is reported verbatim in
// the Task 1 error catalog.
#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <mach/mach_time.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline UInt64 AudioGetCurrentHostTime(void)
{
	return mach_absolute_time();
}

static inline double AudioGetHostClockFrequency(void)
{
	static mach_timebase_info_data_t s_timebase = { 0, 0 };
	if (s_timebase.denom == 0)
		mach_timebase_info(&s_timebase);
	return 1e9 * (double)s_timebase.denom / (double)s_timebase.numer;
}

static inline UInt64 AudioConvertHostTimeToNanos(UInt64 hostTime)
{
	static mach_timebase_info_data_t s_timebase = { 0, 0 };
	if (s_timebase.denom == 0)
		mach_timebase_info(&s_timebase);
	return hostTime * s_timebase.numer / s_timebase.denom;
}

static inline UInt64 AudioConvertNanosToHostTime(UInt64 nanos)
{
	static mach_timebase_info_data_t s_timebase = { 0, 0 };
	if (s_timebase.denom == 0)
		mach_timebase_info(&s_timebase);
	return nanos * s_timebase.denom / s_timebase.numer;
}

// Carbon Endian helpers (Endianness.h, absent on iOS): little-endian is native.
static inline int32_t EndianS32_BtoN(int32_t v) { return v; }

#ifdef __cplusplus
}
#endif
