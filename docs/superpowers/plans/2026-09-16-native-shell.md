# DataRover native shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Patch the fork's SDL3 OSD so the DataRover app boots with DataRover branding, a native mac menubar, and Alt-release pointer capture.

**Architecture:** Four small fork-localized patches (title, menubar, pointer, warning suppression) all guarded to `datarover*` systems or the `datarover` subtarget build, plus repo-side icon/plist work. Each patch is independently testable via rebuild + boot.

**Tech Stack:** C++ (MAME OSD), ObjC++ (Cocoa menubar), SDL3 API, bash packaging.

**Spec:** `docs/superpowers/specs/2026-09-16-native-shell-design.md`

## Global Constraints

- All fork changes scoped to `datarover*` systems or the `datarover` SUBTARGET build; no other MAME system affected.
- ROM never bundled; pinned SHA-256 `94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b`.
- Runtime flags unchanged from `tools/start_manual.sh` (`-view LCD -lightgun -lightgun_device lightgun -nokeepaspect -ui_active`, `SDL_VIDEO_HIGHDPI_DISABLED=1`).
- Staged binary remains `Contents/MacOS/datarover-bin` (case-insensitive APFS ruling).
- Ad-hoc sign only; no Developer ID, notarization, DMG.
- Regressions untouched; verification is interactive (display required), not automated tests.

---

### Task 1: Window title override for datarover systems

**Files:**
- Modify: `/Users/mattkevan/Dev/mame/src/osd/modules/osdwindow.cpp:38-50` (title format)
- Test: rebuild + boot, read window title

**Interfaces:**
- Consumes: `machine.system().name`, `machine.system().type.fullname()` (already in scope)
- Produces: title string `"DataRover 840"` (+ view/screen suffix) for `datarover*` systems; all other systems byte-identical behavior

- [ ] **Step 1: Read the exact current code**

Read `/Users/mattkevan/Dev/mame/src/osd/modules/osdwindow.cpp:22-52`. Confirm the `m_title(util::string_format(...))` initializer and the `machine.system().name` accessor.

- [ ] **Step 2: Add the datarover branch**

```cpp
m_title(
        (strncmp(machine.system().name, "datarover", 9) == 0)
            ? util::string_format(
                (video_config.numscreens > 1)
                    ? "DataRover 840 screen %1$d - %2$s"
                    : "DataRover 840 - %2$s",
                index,
                machine.system().type.fullname())
            : util::string_format(
            (video_config.numscreens > 1)
                ? "%3$s [%4$s] screen %5$d - %1$s %2$s (%6$s%7$sP%8$d)"
                : "%3$s [%4$s] - %1$s %2$s (%6$s%7$sP%8$d)",
            emulator_info::get_appname(),
            emulator_info::get_bare_build_version(),
            machine.system().type.fullname(),
            machine.system().name,
            index,
            (sizeof(int) == sizeof(void *)) ? "I" : "",
            (sizeof(long) == sizeof(void *)) ? "L" : (sizeof(long long) == sizeof(void *)) ? "LL" : "",
            sizeof(void *) * 8))
```

Add `#include <cstring>` if `strncmp` is not already available via existing includes. Keep the non-datarover branch byte-identical.

- [ ] **Step 3: Rebuild the driver**

```bash
cd /Users/mattkevan/Dev/mame
PATH="/usr/lib/ccache:$PATH" make SUBTARGET=datarover SOURCES=src/mame/skeleton/datarover.cpp REGENIE=1 NO_USE_PORTAUDIO=1 -j"$(sysctl -n hw.ncpu)"
```

Expected: build exits 0.

- [ ] **Step 4: Verify the title on a display**

Re-stage (`MAME_DIR=/Users/mattkevan/Dev/mame tools/build_mac_app.sh` from the repo) and double-click boot. Window title reads `DataRover 840 - ...`, no `MAME` string.

- [ ] **Step 5: Commit in the fork**

```bash
cd /Users/mattkevan/Dev/mame
git add src/osd/modules/osdwindow.cpp
git commit -m "datarover: override OSD window title with DataRover branding"
```

---

### Task 2: Native mac menubar (DataRover / File / View / Window)

**Files:**
- Create: `/Users/mattkevan/Dev/mame/src/osd/sdl3/datarover_menu.mm` (ObjC++, Cocoa menubar)
- Modify: SDL3 OSD makefile file list to compile the `.mm` on macOS (find the existing sdl3 file list; follow its pattern)
- Test: rebuild + boot, menubar appears with working items

**Interfaces:**
- Consumes: `running_machine &` for reset/schedule_exit, OSD window list for view/fullscreen toggles; menu actions call the same entry points the Tab menu rows call
- Produces: `datarover_install_menu()` called once from SDL3 init on macOS; no-op on other platforms

- [ ] **Step 1: Find the SDL3 OSD file list and init hook**

Locate the makefile/scripts fragment listing `src/osd/sdl3/*.cpp` (search for `window.cpp` under `src/osd/sdl3` in `scripts/`). Note how platform-conditional files (e.g. mac-only) are declared. Also locate SDL3 OSD init (`sdl_osd_interface` init / `sdlwindow_init` in `src/osd/sdl3/`) as the call site.

- [ ] **Step 2: Write the menubar module**

```objc
// datarover_menu.mm - native mac menubar for the DataRover build.
#import <Cocoa/Cocoa.h>

void datarover_install_menu(void)
{
    NSMenu *menubar = [[NSMenu new] autorelease];
    // DataRover menu: About, Quit (Cmd+Q via terminate:)
    // File menu: Reset Machine (Cmd+R), Fresh Boot, Close (Cmd+W)
    // View menu: LCD / Serial / Both (Cmd+1/2/3), Zoom 1x-3x (Cmd+0 cycles), Fullscreen (Cmd+F)
    // Window menu: Toggle MAME UI, Minimize
    // Each action posts to the running machine via existing OSD entry points.
    [NSApp setMainMenu:menubar];
}
```

Fill each menu with `NSMenuItem` + key equivalents per the spec. Wire actions to the same machine calls the Tab menu rows use (reset → `machine.schedule_hard_reset()`, quit → `machine.schedule_exit()`; view/fullscreen via OSD window options). Guard the whole file with `#if defined(SDLMAME_MACOSX)` so non-mac builds are unaffected.

- [ ] **Step 3: Register in the build and call from init**

Add the `.mm` to the SDL3 file list with the mac-only pattern found in Step 1. Call `datarover_install_menu()` from SDL3 OSD init on macOS only.

- [ ] **Step 4: Rebuild and verify**

Rebuild as in Task 1. Boot: menubar reads DataRover/File/View/Window; exercise Reset, each view, zoom, fullscreen, Tab toggle once each.

- [ ] **Step 5: Commit in the fork**

```bash
cd /Users/mattkevan/Dev/mame
git add src/osd/sdl3/datarover_menu.mm <makefile-fragment>
git commit -m "datarover: add native mac menubar"
```

---

### Task 3: Alt-release pointer capture + stylus cursor

**Files:**
- Modify: `/Users/mattkevan/Dev/mame/src/osd/sdl3/window.cpp:270-302` (`update_cursor_state`)
- Modify: `/Users/mattkevan/Dev/mame/src/osd/sdl3/osdsdl.cpp` (track Left Alt state from `SDL_EVENT_KEY_DOWN/UP` with `SDL_SCANCODE_LALT`, following the existing LCTRL/LShift pattern at lines 532-575)
- Test: rebuild + boot, hold/release behavior + cursor shape

**Interfaces:**
- Consumes: `should_hide_mouse()` (unchanged), SDL scancode events
- Produces: capture released + system pointer shown while Left Alt held; custom stylus cursor otherwise

- [ ] **Step 1: Add Alt tracking beside the modifier block**

In `osdsdl.cpp`, extend the `SDL_EVENT_KEY_DOWN`/`KEY_UP` handlers (lines 526-575 pattern) with `SDL_SCANCODE_LALT` setting/clearing a new `m_alt_held` member (declare beside `m_mouse_over_window` at line 182). Follow the exact `m_modifier_keys` bit pattern or a dedicated bool — one mechanism only.

- [ ] **Step 2: Gate capture on Alt in update_cursor_state**

```cpp
bool alt_released = downcast<sdl_osd_interface&>(machine().osd()).alt_held();
if ((!fullscreen() && !should_hide_mouse) || alt_released)
{
    show_pointer();
    release_pointer();
}
else
{
    hide_pointer();
    capture_pointer();
}
```

When `alt_released`, the pointer is visible and free to leave the window. On release of Alt, next frame re-captures per existing logic.

- [ ] **Step 3: Install the stylus cursor**

Replace the `SDL_SetCursor(nullptr)` force-update at `window.cpp:299` for the datarover path: build a small crosshair/stylus `SDL_Cursor` once (static, `SDL_CreateCursor` with a 16x16 crosshair bitmap) and `SDL_SetCursor()` to it when hiding the system pointer. Keep the non-datarover path untouched.

- [ ] **Step 4: Rebuild and verify at 1x/2x**

Rebuild. Boot: pointer captured over LCD with stylus cursor; holding Left Alt frees it (can reach menubar); releasing Alt re-captures. Check at two zoom levels.

- [ ] **Step 5: Commit in the fork**

```bash
cd /Users/mattkevan/Dev/mame
git add src/osd/sdl3/window.cpp src/osd/sdl3/osdsdl.cpp
git commit -m "datarover: alt-release pointer capture with stylus cursor"
```

---

### Task 4: Suppress the imperfect-timing warning for datarover

**Files:**
- Modify: `/Users/mattkevan/Dev/mame/src/frontend/mame/ui/ui.cpp:754-758` (state 1 warnings gate)
- Test: rebuild + boot, straight to Magic Cap

**Interfaces:**
- Consumes: `machine().system().name`
- Produces: no warning screen for `datarover*` systems; all other systems unchanged

- [ ] **Step 1: Read the warnings gate**

Read `ui.cpp:754-830`. Confirm `machine_info().has_warnings()` drives the yellow screen and the datarover `MACHINE_IMPERFECT_TIMING` flag (`datarover.cpp:4916`) is what fires it.

- [ ] **Step 2: Add the driver-scoped bypass**

```cpp
if (show_warnings)
{
    // DataRover: imperfect timing is a known constant; skip straight to the system.
    bool is_datarover = strncmp(machine().system().name, "datarover", 9) == 0;
    bool need_warning = !is_datarover && machine_info().has_warnings();
```

Leave the rest of the state machine untouched. (`-skip_gameinfo` already handles state 0.)

- [ ] **Step 3: Rebuild and verify**

Rebuild. Boot: no yellow warning screen, straight to the Magic Cap splash/calibration.

- [ ] **Step 4: Commit in the fork**

```bash
cd /Users/mattkevan/Dev/mame
git add src/frontend/mame/ui/ui.cpp
git commit -m "datarover: skip imperfect-timing warning screen"
```

---

### Task 5: Repo packaging — icon, plist display name, docs

**Files:**
- Create: `packaging/macos/DataRover.icns` (stylized top-hat mark)
- Modify: `packaging/macos/Info.plist` (confirm `CFBundleDisplayName` = DataRover)
- Modify: `tools/build_mac_app.sh` (copy `.icns` into `Contents/Resources`, set `CFBundleIconFile` if needed)
- Modify: `docs/mame-bringup.md` (one line: fork `custom` carries the shell patch; rebuild to pick up UI changes)
- Test: staged bundle shows icon + DataRover name

**Interfaces:**
- Consumes: fork binary from Tasks 1-4
- Produces: finished branded bundle

- [ ] **Step 1: Create the icon**

Draw a minimal top-hat mark at 1024x1024, export `.icns` (via `iconutil` from a `.iconset`). Save to `packaging/macos/DataRover.icns`.

- [ ] **Step 2: Wire the icon into the bundle**

Update `tools/build_mac_app.sh` to copy the `.icns` to `Contents/Resources/` and ensure `Info.plist` names it via `CFBundleIconFile`. Re-stage and confirm the Finder icon + display name.

- [ ] **Step 3: Document the fork dependency**

Append to `docs/mame-bringup.md` near the build section: the `custom` branch carries the DataRover shell patch (title/menubar/pointer/warning); rebuild with `SUBTARGET=datarover` to pick up UI changes.

- [ ] **Step 4: Commit in this repo**

```bash
git add packaging/macos/DataRover.icns packaging/macos/Info.plist tools/build_mac_app.sh docs/mame-bringup.md
git commit -m "Brand DataRover.app bundle with icon and display name"
```

---

### Task 6: End-to-end shell verification

**Files:**
- Modify: none
- Test: the bundle on a display (throwaway runs; no test files kept)

**Interfaces:**
- Consumes: branded bundle from Task 5
- Produces: verified native shell; nothing downstream

- [ ] **Step 1: Branding sweep**

Double-click boot. Confirm menubar, Dock and window title read DataRover; screenshot and grep for `MAME` strings on screen (expect zero).

- [ ] **Step 2: Menu exercise**

Trigger each item once: Reset (`⌘R`), Fresh boot, views (`⌘1/2/3`), zoom, fullscreen (`⌘F`), Tab toggle, Close (`⌘W`).

- [ ] **Step 3: Pointer exercise**

Confirm capture + stylus cursor over LCD at 1x/2x; hold Left Alt, move out to the menubar; release, confirm re-capture.

- [ ] **Step 4: Regression suite green**

```bash
python3 -m unittest discover -s tests
```

Plus one headless boot regression (e.g. `tools/desk_regression.py`) to prove the fork patches did not disturb emulation. Record results; commit nothing.
