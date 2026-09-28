# Host clock and battery synchronization

The user approved two independent settings in the shared Apple shell: sync the
Magic Cap calendar to host local date/time on launch and resume, and periodically
mirror host main battery percentage and external power. Keep backup battery
healthy. Settings persist and can be changed without restarting. Default both
on; unavailable battery information falls back to emulated inputs, never zero.

Host observations are queued through the C ABI and applied only on the emulation
worker after checkpoint restore. Battery overrides must bypass synthetic charging.
Clock integration must identify the guest calendar base or setter, validate the
supported ROM and avoid altering elapsed-time device/scheduler timers. Unsupported
clock integration must report its status instead of writing guessed addresses.

Verification covers battery endpoints, partial charge, AC changes, disabling,
unknown readings, calendar conversion and launch/pause/resume/restore behavior.
Build the macOS and iOS targets and preserve existing checkpoint regression.
