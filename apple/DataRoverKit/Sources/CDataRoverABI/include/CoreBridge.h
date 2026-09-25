// CoreBridge.h — nullability-annotated redeclaration of the libdatarover C
// ABI, exposed as the `CDataRoverABI` Swift module.
//
// Fork source of truth: <mame>/src/libdatarover/datarover_core.h (ABI names
// verbatim here). No target includes the fork header (it has
// no MAME header search paths); symbols resolve at link time from
// libDataRoverCore.a, which the app targets link.
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

typedef struct datarover_create_options {
    uint32_t struct_size;
    int32_t network_enabled;
    int32_t audio_output_enabled;
} datarover_create_options;

const uint8_t * _Nullable datarover_framebuffer_bytes(void * _Nullable machine);
size_t datarover_framebuffer_size(void);
void * _Nullable datarover_create(const char * _Nullable nvram_dir,
                                  const char * _Nullable cfg_dir,
                                  const char * _Nullable rom_path);
void * _Nullable datarover_create_with_options(const char * _Nullable nvram_dir,
                                                const char * _Nullable cfg_dir,
                                                const char * _Nullable rom_path,
                                                const datarover_create_options * _Nullable options);
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
// Nonblocking pull of mono signed PCM frames at 48 kHz.
size_t datarover_audio_read(void * _Nullable machine, int16_t * _Nullable samples,
                            size_t frame_capacity);
void datarover_audio_clear(void * _Nullable machine);
// 0: disabled, 1: provider initialized, -1: requested provider unavailable.
int datarover_network_status(void * _Nullable machine);

NS_ASSUME_NONNULL_END
