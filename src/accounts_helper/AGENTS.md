# rediwm-accounts-helper

Root-owned, run under `pkexec`; the compositor never runs as root.

* Stdin JSON and `PKEXEC_UID` are untrusted: validate every operation.
* Pass argv arrays to absolute system tools; never accept passwords in argv.
* The authorization-only request changes no system state.
* Helper, polkit policy and client (`src/accounts`) stay out of greeter mode.
