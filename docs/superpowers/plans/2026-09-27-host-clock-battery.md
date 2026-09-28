# Host synchronization implementation plan

Goal: implement the approved independent host clock and battery settings.
Architecture: Apple shell samples host state; a thread-safe core ABI queues it;
the emulation worker changes battery inputs and the identified guest calendar.
Tech stack: SwiftUI, UIKit/IOKit, C++, MAME, Python regression harnesses.

- [x] Identify and probe the guest calendar conversion/setter in the retail ROM.
- [x] Add a main-battery percentage override in the MAME driver and a queued core
  ABI with external-power override; verify with a headless battery regression.
- [x] Add host observation and persistent settings in DataRoverShell, sampling on
  launch/resume and periodically while active. Treat unknown battery as unavailable.
- [x] Integrate clock synchronization using verified guest calendar state, with
  ROM guards and launch/restore/resume coverage.
- [x] Build both Apple targets, run focused tests and existing checkpoint regression.
- [x] Review changes, document behavior and limitations, commit and push both forks.
