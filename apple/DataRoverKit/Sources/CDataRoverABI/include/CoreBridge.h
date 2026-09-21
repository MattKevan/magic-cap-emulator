// CoreBridge.h — Swift bridging header: nullability-annotated redeclaration
// of the 9-function libdatarover C ABI.
//
// Fork source of truth: <mame>/src/libdatarover/datarover_core.h (ABI names
// verbatim here). The app target never includes the fork header (no MAME
// header search paths on this target); symbols resolve at link time from
// libDataRoverCore.a.
//
// Nullability mirrors the header contract: the framebuffer pointer may be
// NULL (pre-boot / non-RAM-backed mapping — null-check before blit) and
// create returns NULL on boot failure.
// NOTE: no #pragma once — the module imports this as its umbrella header, and
// it is included once per translation unit (shim.m).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define DATAROVER_FB_WIDTH 480
#define DATAROVER_FB_HEIGHT 320
#define DATAROVER_FB_SIZE (480 * 320 / 4)

const uint8_t * _Nullable datarover_framebuffer_bytes(void * _Nullable machine);
size_t datarover_framebuffer_size(void);
void * _Nullable datarover_create(const char * _Nullable nvram_dir,
                                  const char * _Nullable cfg_dir,
                                  const char * _Nullable rom_path);
void datarover_destroy(void * _Nullable machine);
void datarover_pen_down(void * _Nullable machine, int x, int y);
void datarover_pen_move(void * _Nullable machine, int x, int y);
void datarover_pen_up(void * _Nullable machine);
int datarover_install_package(void * _Nullable machine,
                              const uint8_t * _Nullable data, size_t len);
int datarover_install_package_named(void * _Nullable machine,
                                    const uint8_t * _Nullable data, size_t len,
                                    const char * _Nullable filename_utf8);
// 0-100 while an install runs on the calling thread, -1 when none is in flight.
int datarover_install_progress(void * _Nullable machine);


// Thread-safe controls; changes are applied by the emulation worker.
void datarover_set_option(void * _Nullable machine, int side, int pressed);
void datarover_set_paused(void * _Nullable machine, int paused);
void datarover_request_save(void * _Nullable machine);
// 0: not saved, 1: pending, 2: saved, -1: failed.
int datarover_save_status(void * _Nullable machine);
uint64_t datarover_frame_revision(void * _Nullable machine);
void datarover_restart(void * _Nullable machine);

NS_ASSUME_NONNULL_END
