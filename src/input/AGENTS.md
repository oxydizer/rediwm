# Input

* **Text input/IME** (`text_input.zig`): `syncFocus` is the only enter path.
  IM grabs replace client delivery only (bindings, hardware keys and
  shell/lock UI win); an IM's own virtual keyboard bypasses its grab.
  Lock/auth reject virtual input. IPC `GetTextInput` never returns text.
* **Layouts:** layout-zero fallback is for binding lookup only; text uses the
  active XKB state.
* **Shell key repeat:** one `shell_repeat` per keyboard; a new shell target
  needs a `ShellTarget` case, a freeable panel calls `forgetShellTarget`.
  Return, Escape, Tab and modifier chords never repeat.
* **Pointer constraints** (`pointer_constraints.zig`): every client motion
  path calls `clientMotion` then `sync`. Active only with pointer and keyboard
  focus; new compositor input modes go in `motionReachesClient` or
  `candidate`. `sendDeactivated` destroys oneshots synchronously: clear
  `active` first.
* **Shortcuts inhibit** gates only the switcher, screenshot shortcuts and
  final dispatch; hardware keys, VT switching and open panels still win.
* **Drag dodge** (`drag_dodge.zig`) slides a file manager aside through
  `Toplevel.setDodge`, a presentation-only offset added in
  `applyVisualTransform`. Never fold it into `x`/`y`/`move_x` (it would grow
  the canvas, reach IPC and saved layouts, and outlive the drag). Anything
  that stops showing a window must `clearDodge` it (`detachInput` does).
* **Touch/tablet** use their own protocol only when
  `directInputReachesClients()`; otherwise they emulate the pointer (send your
  own `pointerNotifyFrame`). Touchscreens map to `output_name` or the built-in
  panel.
* **Lid:** a closed lid hides built-in panels only while another display is
  on; undocked, logind owns the lid.
