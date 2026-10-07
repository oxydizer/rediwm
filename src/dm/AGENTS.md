# rediwm-dm

Runs as root. The greeter (`rediwm --greeter`) is untrusted input.

* The daemon never blocks; workers own one PAM handle each.
* Signal masks survive exec: clear them. `setuid` clears `PR_SET_PDEATHSIG`.
* Never format JSON with `{s}`.
* Only the daemon and workers are root. Don't sandbox `rediwm-dm.service`:
  user sessions inherit it.
* `--test`, `--confdir`, `--data-dir` and `--marker` are refused as root.
