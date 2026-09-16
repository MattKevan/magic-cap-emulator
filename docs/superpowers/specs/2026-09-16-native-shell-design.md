# DataRover native app shell — design

Scope: fork-localized shell patch on the `custom` branch + bundle-side
packaging in this repo. Delivers: DataRover branding everywhere, native
mac menubar, Alt-release pointer capture with a custom stylus cursor.
No emulation behavior changes; regressions untouched (headless).

## Approach

Option A: small `#ifdef`-guarded patch set in the fork's SDL3 OSD path
plus repo-side icon/plist. Single process, real native menus, full
control of title/cursor/grab.

Rejected: (B) zero-fork Swift wrapper driving the binary as a child —
title stays MAME-branded, no grab/cursor control, two Dock processes.
(C) SDL-minimal de-brand (product rename + Lua entries) — no native
menubar, violates chosen scope.

## Branding and title

- New `SUBTARGET=datarover` ifdef: window title `"DataRover 840"`
  (+ view name), never the `MAME <ver>` string (`osdwindow.cpp:38`
  format, `mame.cpp:14` APPNAME are the patch points; title is
  create-time only, no setter exists).
- Build-time product override to `DataRover` (plist `product`,
  `verinfo.py:122` forces `MAME` today) so menubar, Dock and bundle
  identity lose the MAME name.
- Driver-scoped suppression of the `IMPERFECT_TIMING` warning screen
  (`datarover.cpp:4916` flag fires it; `-skip_gameinfo` only kills
  gameinfo) so boot goes straight to Magic Cap.
- Scoped so no other MAME system is affected.

## Native menubar

New ObjC++ module on the SDL3 path building
`DataRover / File / View / Window`:

- File: Reset machine (`⌘R`), Fresh boot — wipe NVRAM, Quit (`⌘Q`).
- View: LCD / Serial / Both (`⌘1/2/3`), integer zoom 1x–3x (`⌘0`
  cycles or `⌘=`/`⌘-`), Fullscreen (`⌘F`).
- Window: MAME UI (Tab menu) toggle, Close (`⌘W`).
- DataRover menu: About DataRover, Settings if any, standard Services/Hide.

Every item wires to existing OSD calls. No new emulation behavior.
MAME Tab menu left intact underneath.

## Pointer capture and cursor

- Auto-capture stays (the pen needs it): hover grabs while `-lightgun`
  is set (`osdsdl.cpp:465`, `sdl3/window.cpp:131/271`).
- Holding Left Alt releases the pointer so it can leave the window.
- Custom stylus/crosshair cursor replaces the hidden system cursor
  over the LCD. User asked: "can we change the pointer" — yes, this.
- Retina mapping keeps the existing `SDL_VIDEO_HIGHDPI_DISABLED=1`
  fix; lightgun absolute path unchanged.

## Packaging (this repo)

- App icon: stylized top-hat mark (`.icns` or `Assets.car`).
- `Info.plist` display name `DataRover` (already `CFBundleName`,
  confirm display string).
- ROM wizard unchanged; launcher flags unchanged.
- Doc note: fork `custom` branch carries the shell patch; rebuild
  (`SUBTARGET=datarover`) to pick up UI changes.

## Verification

- Double-click boot: menubar, Dock and window title read DataRover;
  zero MAME strings on screen.
- Each menu item exercised once (reset, fresh boot, views, zoom,
  fullscreen, Tab toggle).
- Alt-release + custom cursor checked at 1x/2x.
- Existing regression suite stays green.
