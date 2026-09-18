// flac_config_prefix.h — forces the RIGHT config.h for FLAC TUs.
//
// MAME's src/emu/config.h shadows <config.h> whenever -Isrc/emu precedes the
// FLAC include dir (always, since per-file -I append after target -Is).
// Absolute path: immune to include order entirely. Then undefines
// HAVE_CONFIG_H so the TU's own `#include <config.h>` is skipped.
#pragma once
#include "/Users/mattkevan/Dev/mame/3rdparty/flac/src/libFLAC/include/config.h"
#undef HAVE_CONFIG_H
