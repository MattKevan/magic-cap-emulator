# iOS device shell

The landscape shell follows Figma frame 572:788 and uses its exported logo and
Option artwork. Hold either Option control while touching the guest screen;
both controls feed the same emulated hardware input, with independent releases.
The logo opens Save state, Restart, and Load package.

The core runs at real-time speed with MAME throttling and sleeping enabled.
The Metal view checks for changed frames at 30 Hz, and stops its display link
while paused. Opening the menu or leaving the app pauses the emulation worker.
Actual device heat still needs a sustained physical-device check.

A complete MAME checkpoint is atomically replaced on background/menu entry,
manual save, clean shutdown and every 60 seconds while running. iOS background
saving uses a bounded background task. Relaunch restores the checkpoint;
invalid saves fall back to booting from NVRAM. Force termination before a save
finishes can lose changes since the previous checkpoint. Saves are tied to the
current core's state format; NVRAM fallback may contain older data.

Package import currently stores the selected file in Documents/packages and
explicitly reports that it is not installed. The desktop installer relies on a
PTY serial transport unavailable in the iOS sandbox; an in-process transport
is needed for actual guest installation.

## Clock investigation

Dino's RTC is a 40-bit counter at 32,768 Hz, not an absolute Unix timestamp.
The existing driver stores host time alongside RTC NVRAM and can advance the
counter by elapsed host time on a warm boot. Full checkpoint restore currently
restores the counter as saved, so time spent paused is not added. Setting the
Magic Cap calendar to the iPhone date requires identifying the guest calendar
base/setting interface; directly writing Unix seconds into the RTC is wrong.
Absolute phone-clock synchronization is not implemented in this change.

## Validation

Headless controls regression covers pause CPU usage, paused frame stability,
checkpoint creation, restart, reload, corrupt saves and shutdown while paused.
The iPhone 16 / iOS 18.5 simulator was used for visual comparison and logo-menu
save/restart checks. Backgrounding, termination and relaunch also restored
the same Magic Cap screen. iPad / iOS 27 simulator orientation needs further validation:
its captured surface appeared portrait and clipped. Guest-visible Option chords
and sustained device temperature require a physical-device check.
