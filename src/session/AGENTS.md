# Lock internals

Cross-cutting lock rules (greeter, crash handling, IPC refusal, client
ext-session-lock) are in the root `AGENTS.md`.

* `Lock.covered()` releases the lock-before-sleep inhibitor; the builtin lock
  also sets `Output.lock_commit_pending`.

* **The lock never polls.** Its one timer redraws the clock at the next minute
  boundary; the PAM worker (`auth.c`) signals an eventfd that `Lock.authReady`
  watches only while an attempt runs. Don't add a periodic tick (a 100 ms one
  cost ~10 wakeups/s for as long as the session stayed locked).
* **Lock volume/brightness** (`lock_controls.zig`): sliders at the bottom
  centre of the built-in lock, the pointer/touch way to what the hardware keys
  already do behind it. Never in the greeter (no audio, no external tools) and
  hidden under an ext-session-lock client's surface. They are their own small
  raster (`View.controls_node`), so a drag never re-rasters the clock, avatar
  and field. A row exists only while its backend reports
  (`Lock.controlsChanged` from the audio wake and the brightness helper's
  result); a drag shows its own value until release. Events only, no timer.
