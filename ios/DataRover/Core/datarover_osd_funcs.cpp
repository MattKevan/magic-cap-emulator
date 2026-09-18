// datarover_osd_funcs.cpp — iOS OSD free-function providers.
//
// The core links the SDL OSD nowhere (src/osd/sdl3/* excluded from
// file-list.txt), but two OSD-layer free functions are referenced by generic
// code in the lib and must exist at link time:
//   - osd_setup_osd_specific_emu_options (miscmenu.o, ui.o)
//   - osd_set_aggressive_input_focus (luaengine.o)
//   - osd_video_config video_config (osdwindow.o reads .numscreens)
// The SDL breeze for these is trivial (sdlopts.cpp adds SDL option tables we
// don't have; window.cpp toggles SDL grab state we don't have), so the iOS
// providers are minimal: register the base OSD options, ignore focus grabs,
// and default to a single screen (the SwiftUI shell owns the real surface).
#include "emu.h"
#include "emuopts.h"
#include "modules/lib/osdobj_common.h"
#include "modules/osdwindow.h"

void osd_setup_osd_specific_emu_options(emu_options &opts)
{
	opts.add_entries(osd_options::s_option_entries);
}

void osd_set_aggressive_input_focus(bool aggressive_focus)
{
	(void)aggressive_focus;
}

osd_video_config video_config;
