// flac_config_prefix.h — forces the RIGHT config.h for FLAC TUs.
//
// MAME's src/emu/config.h shadows <config.h> whenever -Isrc/emu precedes the
// FLAC include dir (always, since per-file -I append after target -Is).
// A quoted relative include is resolved against THIS file's directory before
// any -I search, so it is immune to include order and needs no per-machine
// substitution. Then undefines HAVE_CONFIG_H so the TU's own
// `#include <config.h>` is skipped.
//
// The depth matches the MAME_DIR default in project.yml
// ($(SRCROOT)/../../../mame, i.e. a `mame` sibling of the repo root).
#pragma once
#include "../../../../mame/3rdparty/flac/src/libFLAC/include/config.h"
#undef HAVE_CONFIG_H
