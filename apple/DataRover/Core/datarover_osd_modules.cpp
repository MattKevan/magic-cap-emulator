// datarover_osd_modules.cpp — iOS OSD module-ID providers.
//
// register_options() (osdobj_common.cpp, unmodified) references module IDs
// whose real providers were excluded from file-list.txt: SDL-coupled
// providers (guarded by OSD_SDL, never defined on iOS) and GUI debugger
// backends (Qt/GUI). Each unavailable ID is defined here as a
// MODULE_NOT_SUPPORTED provider: probe() false, init -1. If the core ever
// selected one, module selection would skip it exactly as on desktop builds
// where the backend didn't compile in. The iOS core always runs headless
// (core_headless_osd), so these are link-time satisfiers only.
// IDs covered: DEBUG_WINDOWS/QT/IMGUI/GDBSTUB (debugger GUI backends),
// FONT_SDL (SDL_ttf; FONT_SDL3's real TU compiles but only defines
// FONT_SDL3), RENDERER_BGFX (drawbgfx excluded: needs SDL window.h).
#include "emu.h"
#include "modules/debugger/debug_module.h"
#include "modules/font/font_module.h"
#include "modules/osdmodule.h"
#include "modules/render/render_module.h"
#include "osdcore.h"

namespace osd {
namespace {

class ios_stub_font : public osd_module, public font_module
{
public:
	ios_stub_font()
		: osd_module(OSD_FONT_PROVIDER, "sdl")
		, font_module()
	{
	}
	int init(osd_interface &osd, const osd_options &options) override
	{
		(void)osd;
		(void)options;
		return 0;
	}
	osd_font::ptr font_alloc() override { return nullptr; }
	bool get_font_families(std::string const &font_path, std::vector<std::pair<std::string, std::string>> &result) override
	{
		(void)font_path;
		(void)result;
		return false;
	}
};

class ios_stub_render : public osd_module, public render_module
{
public:
	ios_stub_render()
		: osd_module(OSD_RENDERER_PROVIDER, "bgfx")
		, render_module()
	{
	}
	int init(osd_interface &osd, const osd_options &options) override
	{
		(void)osd;
		(void)options;
		return 0;
	}
	void exit() override { }
	std::unique_ptr<osd_renderer> create(osd_window &window) override
	{
		(void)window;
		return nullptr;
	}

protected:
	unsigned flags() const override { return 0; }
};

MODULE_NOT_SUPPORTED(debug_windows, OSD_DEBUG_PROVIDER, "windows")
MODULE_NOT_SUPPORTED(debug_qt, OSD_DEBUG_PROVIDER, "qt")
MODULE_NOT_SUPPORTED(debug_imgui, OSD_DEBUG_PROVIDER, "imgui")
MODULE_NOT_SUPPORTED(debug_gdbstub, OSD_DEBUG_PROVIDER, "gdbstub")

} // anonymous namespace
} // namespace osd

MODULE_DEFINITION(DEBUG_WINDOWS, osd::debug_windows)
MODULE_DEFINITION(DEBUG_QT, osd::debug_qt)
MODULE_DEFINITION(DEBUG_IMGUI, osd::debug_imgui)
MODULE_DEFINITION(DEBUG_GDBSTUB, osd::debug_gdbstub)
MODULE_DEFINITION(FONT_SDL, osd::ios_stub_font)
MODULE_DEFINITION(RENDERER_BGFX, osd::ios_stub_render)
