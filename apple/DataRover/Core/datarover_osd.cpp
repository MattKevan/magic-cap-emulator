// datarover_osd.cpp — iOS headless OSD stub (DataRoverCore static lib).
//
// The core TU (src/libdatarover/datarover_core.cpp) already ships its own
// core_headless_osd satisfying osd_interface with null audio/input sinks.
// This file intentionally stays EMPTY of symbols: it exists so the Xcode
// target has at least one iOS-owned source for target membership, signing,
// and future iOS-specific OSD glue (e.g. Main-Thread dispatch notes).
//
// Do NOT instantiate another osd_interface here: the manager singleton path
// (mame_machine_manager::instance + create_ui) requires exactly one OSD,
// owned by datarover_core.cpp.
