# Security

RediWM's security decisions aim to keep authentication, privileged operations
and sandboxed applications behind explicit boundaries. This describes the
intended security model; it is not an independent security audit. Contributor
rules live in [AGENTS.md](AGENTS.md), and validation is described in
[TESTING.md](TESTING.md).

- **Desktop trust.** The compositor and shell share a process and run as the
  logged-in user. Ordinary unsandboxed Wayland clients can access powerful
  protocols, including capture, clipboard management and virtual input.
  Installing or running a desktop app therefore carries trust; RediWM is not
  a general sandbox for same-user processes. X11 clients retain Xwayland's
  shared X server trust model.
- **Sandbox access is explicit.** Clients connected through
  `wp_security_context_v1` cannot access privileged globals unless
  `[[sandbox_allow]]` grants the relevant group. Guessing a hidden global's
  name does not bypass the restriction. Nested security contexts are refused.
  See [the global filter](src/global_filter.zig).
- **Failure must preserve the lock.** A lock client's death leaves the session
  locked. When `rediwm-session` restarts a compositor that crashed while
  locked, it restores the lock before the backend starts. Lock-before-sleep
  holds a delay inhibitor until the lock covers the outputs. Virtual input
  cannot operate lock or authentication UI; logind's `Unlock` signal is
  deliberately ignored. See [session locking](src/session/lock.zig).
- **Capture and automation have gates.** Screen capture is refused during
  locking and polkit authentication. IPC refuses all requests while locked;
  synthetic input and pixel reads additionally require the startup-only
  `[ipc] automation` opt-in. Its socket lives in a private directory with
  owner-only permissions. Sandboxed IPC callers require an explicit `ipc`
  allowance, plus `automation` for those commands; caller identification
  fails closed. See [IPC admission](src/ipc/server.zig) and
  [request checks](src/ipc/handlers.zig).
- **Privilege stays outside the desktop.** The login greeter runs unprivileged
  with desktop services disabled; `rediwm-dm` and its PAM workers decide
  authentication. Account changes go through a root-owned helper under
  polkit authorization. Helper requests are untrusted, operations are
  validated, and passwords never travel in command arguments. Authentication
  secrets use locked memory that is wiped after use.
- **Browsing must not execute a file's instructions.** Files disables Git
  hooks, external helpers and transports, and refuses repository configurations
  naming filter or Git LFS commands. Desktop launchers must pass the launch
  trust check; otherwise they remain plain files until explicitly allowed.
  The PDF viewer refuses to parse documents unless its required sandbox is
  established. See [Git handling](src/files/git.zig),
  [launcher trust](src/desktop/watcher.zig) and [PDF startup](src/pdf/main.zig).

Report suspected vulnerabilities through this repository's GitHub issues for
now. Include the affected revision, impact and minimal reproduction steps.
Issues are public: leave out passwords, tokens and private user data.
