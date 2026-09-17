# PCLink Install Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** File → Install Package… transfers a user-picked `.pkg` into the running DataRover app over PCLink.

**Architecture:** Extract the wire codec + transfer loop from `tools/pclink_regression.py` into a standalone `tools/pclink_send.py` that attaches to a live machine's `-rs2321 pty` PTY. Fork menubar gains the picker item calling it. No Lua automation; user drives the guest to the Storeroom computer by hand.

**Tech Stack:** Python 3 (stdlib: termios, select, struct, zlib), ObjC++ (`NSOpenPanel`), bash launcher.

**Spec:** `docs/superpowers/specs/2026-09-17-connectivity-design.md` (Phase 1 + Device buttons sections)

## Global Constraints

- User drives the guest to the Storeroom computer by hand; no Lua automation in the bundle.
- ROM never bundled; packages live in `~/Library/Application Support/DataRover/packages/`.
- Pointer-release remaps Left Alt → Right Alt (spec Device section); Left Alt stays the Option button.
- Device menu: Power (`⌘P`, keeps `End`), Option Button (hold-able or toggle).
- Fork changes scoped to `datarover*`/macOS; regressions untouched.
- Ad-hoc sign only.

---

### Task 1: Standalone pclink_send.py transfer agent

**Files:**
- Create: `tools/pclink_send.py`
- Test: `python3 tools/pclink_send.py --help` + existing unit tests still pass

**Interfaces:**
- Consumes: `tools/pclink_regression.py` codec functions (copied, not imported — the regression file is a harness, not a library)
- Produces: `pclink_send.py --pty PATH --package FILE` CLI consumed by Task 2

- [ ] **Step 1: Read the codec source**

Read `tools/pclink_regression.py:36-45` (tags + `PC_LINK_MAGIC`), `:210-320` (`escape_payload`, `unescape_payload`, `encode_crc_stream`, `decode_crc_stream`, `encode_packet`, `decode_packet`, `package_metadata`), `:857-912` (`read_available`, `drain`, `write_all`, `configure_raw_pty`).

- [ ] **Step 2: Write the agent**

```python
#!/usr/bin/env python3
"""Send one .pkg to a live DataRover over its PCLink RS-232 PTY.

Usage: pclink_send.py --pty /dev/ttysXXX --package foo.pkg [--timeout 180]
The guest must already sit at the Storeroom computer (manual navigation).
Protocol: ChMa magic + Cnct/Cntd handshake, SPkg metadata, CRC package
stream, Ping/Pong barrier, GBye close (see docs/pclink.md).
"""
import argparse, os, select, struct, sys, termios, time, zlib
from pathlib import Path

PC_LINK_MAGIC = b"ChMa"
CONNECT_TAG = b"Cnct"
CONNECTED_TAG = b"Cntd"
SEND_PACKAGE_TAG = b"SPkg"
GOODBYE_TAG = b"GBye"
PING_TAG = b"Ping"
PONG_TAG = b"Pong"
ESCAPE_BYTES = frozenset((0x0E, 0x0F, 0x10))
```

Copy the codec functions verbatim from the regression file (escape/unescape, crc encode/decode, packet encode/decode, package_metadata). Then the transfer:

```python
def main(argv=None):
    args = parse_args(argv)
    package = Path(args.package)
    fd = os.open(args.pty, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    configure_raw_pty(fd)
    # 1. wait for ChMa + Cnct (deadline args.timeout)
    # 2. write CONNECTED twice (Magic Cap requires both)
    # 3. write SPkg metadata + CRC package stream
    # 4. write Ping; wait for Pong in trailing wire
    # 5. write GBye; close; return 0
    # Any timeout/protocol error: print to stderr, return 1
```

Follow the regression loop at `pclink_regression.py:1297-1390` minus the Lua/navigation/process-management parts (no MAME spawn, no snapshots, no modem). Print `INSTALL OK` on success.

- [ ] **Step 3: Smoke-test argument handling**

```bash
python3 tools/pclink_send.py --help
python3 tools/pclink_send.py --pty /dev/null --package does-not-exist.pkg; echo "exit=$?"
```

Expected: help prints; missing package exits nonzero with a clear error.

- [ ] **Step 4: Run existing unit tests**

```bash
python3 -m unittest discover -s tests 2>&1 | tail -3
```

Expected: same 451/455 baseline (4 pre-existing environmental errors: ImageMagick + slirp header). No new failures.

- [ ] **Step 5: Commit**

```bash
git add tools/pclink_send.py
git commit -m "Add standalone PCLink package sender"
```

---

### Task 2: Fork menubar — Install Package item + Device menu + Right-Alt remap

**Files:**
- Modify: `/Users/mattkevan/Dev/mame/src/osd/sdl3/datarover_menu.mm` (File menu + new Device menu)
- Modify: `/Users/mattkevan/Dev/mame/src/osd/sdl3/osdsdl.cpp` + `osdsdl.h` (LALT → RALT tracking)
- Test: rebuild + validate (live transfer is Task 3)

**Interfaces:**
- Consumes: `pclink_send.py` path (bundled or referenced — report which you chose and why)
- Produces: working menu items verified live in Task 3

- [ ] **Step 1: Re-read the current menu file**

Read `/Users/mattkevan/Dev/mame/src/osd/sdl3/datarover_menu.mm` fully. Note the `menu_entry` helper, `install_submenu` pattern, and the existing File menu (Reset/Fresh/Close).

- [ ] **Step 2: Add Install Package item**

```objc
- (void)installPackage:(id)sender
{
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowedFileTypes:@[@"pkg"]];
    [panel setDirectoryURL:[NSURL fileURLWithPath:
        [@"~/Library/Application Support/DataRover/packages/" stringByExpandingTildeInPath]]];
    if ([panel runModal] != NSModalResponseOK)
        return;
    // resolve the live -rs2321 pty path and spawn tools/pclink_send.py
    // --pty <path> --package <picked file>; report exit status via
    // machine().ui().popup_time on failure, silent on success
}
```

PTY discovery: the running machine was launched with `-rs2321 pty`; MAME announces `:rs2321:pty PTY: <path>` on stdout at startup. Since the menu handler cannot read launcher stdout, resolve via the OSD RS-232 device: find the `rs232` device `pty` path through `machine().root_device()` serial interface, or accept the PTY path from a `DATAROVER_PCLINK_PTY` env var written by the launcher at startup (simpler — launcher captures it from binary stdout and exports it). Choose one, document the choice in the report. File menu placement, no shortcut (or `⌘I` — check for collisions first).

- [ ] **Step 3: Add Device menu + remap release to Right Alt**

```objc
NSMenu *deviceMenu = [[[NSMenu alloc] initWithTitle:@"Device"] autorelease];
[deviceMenu addItem:menu_entry(@"Power", @"p", @selector(pressPower:))];
[deviceMenu addItem:menu_entry(@"Option Button", @"", @selector(pressOption:))];
install_submenu(bar, @"Device", deviceMenu);
```

Power wires to the `POWER_BUTTON` ioport (`datarover.cpp:4681`, `power_changed` handler); Option Button to `OPTION_BUTTON` (`datarover.cpp:4655`). Both are `IPT_OTHER` ports — drive them via `machine().input()` port-write or the same path the `End`/`LAlt` key bindings use (read how `PORT_CODE(KEYCODE_END)` reaches `power_changed` and reuse that injection point; report the mechanism). In `osdsdl.cpp`/`osdsdl.h`: change `SDL_SCANCODE_LALT` tracking to `SDL_SCANCODE_RALT` for `m_alt_held` (Left Alt stays the Option button key). Keep `End` working for Power.

- [ ] **Step 4: Rebuild + validate**

```bash
cd /Users/mattkevan/Dev/mame
make SUBTARGET=datarover SOURCES=src/mame/skeleton/datarover.cpp REGENIE=1 NO_USE_PORTAUDIO=1 -j"$(sysctl -n hw.ncpu)"
./datarover -validate datarover840
```

Expected: both exit 0.

- [ ] **Step 5: Commit in the fork**

```bash
cd /Users/mattkevan/Dev/mame
git add src/osd/sdl3/datarover_menu.mm src/osd/sdl3/osdsdl.cpp src/osd/sdl3/osdsdl.h
git commit -m "datarover: install package item, device menu, right-alt release"
```

---

### Task 3: Live install verification on the running app

**Files:**
- Modify: none
- Test: the app on a display (throwaway runs; no test files kept)

**Interfaces:**
- Consumes: staged bundle with Task 2 binary + `pclink_send.py`
- Produces: verified install path; nothing downstream

- [ ] **Step 1: Stage and boot**

```bash
MAME_DIR=/Users/mattkevan/Dev/mame tools/build_mac_app.sh
open build/DataRover.app
```

Navigate the guest to the Storeroom computer by hand.

- [ ] **Step 2: Install the DvorakKeyboard package**

File → Install Package… → select `$MAGIC_CAP_ASSETS/packages/DvorakKeyboard.pkg` (fetch via `tools/fetch_assets.sh packages` if missing).

Expected: `DvorakKeyboard` object appears in built-in storage (21K object per `docs/pclink.md` acceptance).

- [ ] **Step 3: Reject path**

Pick a non-package file (or cancel the panel).

Expected: clean cancel / clear error, guest undisturbed, no boot.

- [ ] **Step 4: Buttons**

Device → Power suspends (screen blanks to retained RAM) and wakes on second press; Option Button held during card insert triggers the erase/setup flow (or at minimum registers in the guest — report observed behavior).

- [ ] **Step 5: Record results, commit nothing**

Report per-step PASS/FAIL with evidence. Failures file against Task 1 or 2 — do not paper over here.
