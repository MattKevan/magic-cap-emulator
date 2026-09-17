# libdatarover Shared Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the DataRover driver into a portable `libdatarover` core with a C ABI, proven by an SDL shim that keeps today's app working unchanged.

**Architecture:** Stage 1 only (core extraction behind the ABI with the SDL frontend still working — the spec's safety net). New `src/libdatarover/` subtree in the fork holding the ABI + framebuffer tap + input injection; the existing driver file moves behind it without behavior change. Mac SwiftUI shell (stage 2) and iOS shell (stage 3) are separate follow-up plans, not this one.

**Tech Stack:** C++ (driver extraction), C ABI header, CMake/Xcode static lib, Python for verification.

**Spec:** `docs/superpowers/specs/2026-09-17-shared-core-design.md` (Core ABI + Staging §1 only)

## Global Constraints

- No emulation behavior changes; existing regression suite stays green throughout.
- ROM stays user-supplied; paths (NVRAM/cfg/packages) injected by the frontend.
- SDL frontend keeps working unchanged — pixel-compare vs the pre-extraction binary is the acceptance.
- Ad-hoc sign only; fork work on `custom`, repo work on `main`.

---

### Task 1: Core ABI header + framebuffer tap

**Files:**
- Create: `/Users/mattkevan/Dev/mame/src/libdatarover/datarover_core.h` (C ABI)
- Create: `/Users/mattkevan/Dev/mame/src/libdatarover/datarover_core.cpp` (framebuffer tap)
- Test: compile check + framebuffer byte-compare script

**Interfaces:**
- Consumes: `datarover_state` internals (`src/mame/skeleton/datarover.cpp`, 4919 lines; LCD framebuffer at `FRAME_BYTES = 480*320/4`, line 1564)
- Produces: `datarover_framebuffer_bytes()` + `datarover_framebuffer_size()` consumed by Task 3's compare script

- [ ] **Step 1: Read the framebuffer source**

Read `datarover.cpp:1560-1600` (FRAME_BYTES, frame layout) and find the LCD screen device tag + how scanout reads the buffer (grep `FRAME_BYTES` uses).

- [ ] **Step 2: Write the ABI header**

```c
// datarover_core.h — portable C ABI for libdatarover.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define DATAROVER_FB_WIDTH 480
#define DATAROVER_FB_HEIGHT 320
#define DATAROVER_FB_SIZE (480 * 320 / 4)  // 2bpp, matches FRAME_BYTES

// Framebuffer access (valid after machine boot; pointer owned by core).
const uint8_t *datarover_framebuffer_bytes(void *machine);
size_t datarover_framebuffer_size(void);
// Lifecycle + input + package + paths land in Task 2; declared here:
void *datarover_create(const char *nvram_dir, const char *cfg_dir, const char *rom_path);
void datarover_destroy(void *machine);
void datarover_pen_down(void *machine, int x, int y);
void datarover_pen_move(void *machine, int x, int y);
void datarover_pen_up(void *machine);
int datarover_install_package(void *machine, const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
```

Task 1 implements only the two framebuffer functions (stub the rest returning NULL/0 with a `// Task 2` comment — the single exception to no-placeholders, explicitly tracked).

- [ ] **Step 3: Implement the framebuffer tap**

`datarover_core.cpp` includes the driver header path and resolves the LCD buffer from the `running_machine *` via the screen device tag found in Step 1. Return pointer + `DATAROVER_FB_SIZE`.

- [ ] **Step 4: Compile-check standalone**

```bash
cd /Users/mattkevan/Dev/mame
clang++ -std=c++17 -fsyntax-only src/libdatarover/datarover_core.cpp -Isrc -Isrc/emu -Isrc/lib -Isrc/osd
```

Expected: exit 0 (or report the exact missing-include errors — do not fix the build system in this task).

- [ ] **Step 5: Commit in the fork**

```bash
cd /Users/mattkevan/Dev/mame
git add src/libdatarover/
git commit -m "datarover: sketch core ABI header with framebuffer tap"
```

---

### Task 2: Lifecycle, input, package injection behind the ABI

**Files:**
- Modify: `/Users/mattkevan/Dev/mame/src/libdatarover/datarover_core.cpp` (implement stubs)
- Test: headless lifecycle smoke via a tiny C driver (create → boot frames → destroy)

**Interfaces:**
- Consumes: Task 1 header; `mame_machine_manager::execute()` run loop (`src/frontend/mame/mame.cpp:235`); ioport injection (`POWER_BUTTON`/`OPTION_BUTTON` pattern from pulsePort work); `pclink_send` wire codec logic
- Produces: full working ABI consumed by Task 3's shim

- [ ] **Step 1: Implement lifecycle**

`datarover_create`: build `emu_options` + `sdl_osd_interface`-free minimal OSD (or reuse the existing OSD with `-video none`), set `nvram_directory`/`cfg_directory`/`rompath` from args, select the `datarover840` driver, boot the machine on a worker thread (the `execute()` loop blocks — thread it, report the threading choice). `datarover_destroy`: schedule exit + join + free.

- [ ] **Step 2: Implement pen input**

`pen_down/move/up`: map 480×320 guest coords onto the `TOUCH_X`/`TOUCH_Y`/`TOUCH_BUTTON` ioports (`datarover.cpp:4672-4679`, `IPT_LIGHTGUN_X/Y`, `GUNCODE` bindings) via the same `ioport_field::set_value` injection used by pulsePort. Clamp to [0,479]/[0,319].

- [ ] **Step 3: Implement package install**

`datarover_install_package`: feed the byte buffer through the PCLink encode path (`encode_packet(SPkg)`, CRC stream — port the Python codec from `tools/pclink_send.py` to C++ or shell to a bundled helper; report which) into the guest's UART-A/RS-232 endpoint in-process. Success = guest Storeroom object appears (verified in Task 4).

- [ ] **Step 4: Headless smoke test**

Write `/tmp/core_smoke.c` (throwaway, not committed): create with temp dirs, run 600 emulated frames, call pen_down/up once, destroy, exit 0. Compile against the core sources directly (no build-system changes yet).

```bash
clang /tmp/core_smoke.c src/libdatarover/datarover_core.cpp -o /tmp/core_smoke && /tmp/core_smoke; echo "exit=$?"
```

Expected: exit 0. Report hangs/crashes verbatim — do not paper over.

- [ ] **Step 5: Commit in the fork**

```bash
cd /Users/mattkevan/Dev/mame
git add src/libdatarover/
git commit -m "datarover: implement core lifecycle, pen, and package injection"
```

---

### Task 3: SDL shim + pixel-compare parity gate

**Files:**
- Create: `/Users/mattkevan/Dev/mame/src/libdatarover/sdl_shim.cpp` (boots the core, presents via existing SDL OSD)
- Create: `tools/core_parity.py` (repo; boots pre-extraction binary vs shim, compares framebuffers)
- Test: parity script passes

**Interfaces:**
- Consumes: Task 2 ABI; pre-extraction `datarover` binary as reference
- Produces: parity proof; nothing downstream (stages 2/3 are separate plans)

- [ ] **Step 1: Write the SDL shim**

`sdl_shim.cpp`: `main()` parsing the same flags as the launcher (`-rompath/-cfg/-nvram`), calling `datarover_create`, running the existing SDL OSD event loop against the core machine, `datarover_destroy` on exit. Minimal glue — reuse, don't rewrite, the OSD boot path.

- [ ] **Step 2: Write the parity script**

`tools/core_parity.py`: boots reference `./datarover` and the shim with identical ROM/NVRAM/cfg (temp dirs, `-video none` + framebuffer dump via the ABI for the shim side; for the reference side use the existing `desk_regression.py` snapshot path), compares the 480×320 buffers byte-for-byte, prints `PARITY OK` or the first differing offset.

- [ ] **Step 3: Run the gate**

```bash
python3 tools/core_parity.py; echo "exit=$?"
python3 -m unittest discover -s tests 2>&1 | tail -3
```

Expected: `PARITY OK`; suite at 451/455 baseline (4 pre-existing environmental errors). Any pixel diff or new suite failure = real finding, fix or report BLOCKED with the diff.

- [ ] **Step 4: Commit both sides**

```bash
cd /Users/mattkevan/Dev/magic-cap-emulator
git add tools/core_parity.py
git commit -m "Add libdatarover parity gate"
cd /Users/mattkevan/Dev/mame
git add src/libdatarover/sdl_shim.cpp
git commit -m "datarover: add SDL shim over the core ABI"
```

---

### Task 4: End-to-end core verification (headless-provable)

**Files:**
- Modify: none
- Test: the core via shim + ABI (throwaway runs; no test files kept)

**Interfaces:**
- Consumes: Task 3 shim + parity proof
- Produces: stage-1 sign-off; stages 2/3 planned separately

- [ ] **Step 1: Pen round-trip**

Drive `pen_down/move/up` through the ABI (extend `/tmp/core_smoke.c` or a Python ctypes harness — report which) at the three calibration points; confirm the guest leaves the welcome screen (framebuffer changes vs boot frame).

- [ ] **Step 2: Package install through the ABI**

`datarover_install_package` with `DvorakKeyboard.pkg` bytes; confirm the Storeroom object appears (framebuffer/Lua inspection — report the observation method).

- [ ] **Step 3: EtherLink HTTP render**

Configure the core machine with the 3C589 + slirp/UDP peer path (same flags as `etherlink_regression.py`); confirm the `EtherLink III works` render. Headless via framebuffer compare against the retained acceptance screenshot.

- [ ] **Step 4: Record results, commit nothing**

Per-step PASS/FAIL/BLOCKED with evidence. UI-visible behavior (Metal blit, toolbar) belongs to stage 2/3 plans — not here.
