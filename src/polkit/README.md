# Native polkit agent

Stages 2–7 implement registration, identity selection, the helper conversation
and the compositor-owned authentication dialog, queue, retries, configuration
and IPC lifecycle events. `Agent.conversation.opened`
borrows the validated action/message while the dialog copies its display data;
helper events then drive the prompt. Only the noninstalled test runner supplies
automatic fixture responses.

`Agent.create` owns a dedicated system-bus connection attached to the caller's
Wayland event loop. It runs only with a login identity verified by `rediwm-session`, or
an explicit `REDIWM_FORCE_POLKIT=1`. Nested/headless instances otherwise do
nothing, even if they inherited the host's `XDG_SESSION_ID`. Environment storage
(used for the locale) must outlive the agent. The compositor owns the agent and
destroys it before its notification manager and event loop.

After Hello, the agent subscribes to the bus driver's `NameOwnerChanged` before
looking up polkit's owner. Production copies the supervisor's verified
`REDIWM_LOGIN_SESSION`; forced isolated fixtures can supply `XDG_SESSION_ID`.
When neither is supplied, it asks logind for `GetSessionByPID(getpid())`, then reads that session's `Id`
property. An object path is not a session id. Locale precedence is nonempty
`LC_ALL`, `LC_MESSAGES`, `LANG`, then `C`.

Registration uses a `unix-session` subject and a STRING agent path. There is
no RequestName call: polkit associates registration with our unique bus name.
An initially absent daemon is activated through `StartServiceByName`.
Ownership changes invalidate registration and cause a new registration with
the new unique owner; stale registration replies cannot validate a replacement
daemon. Only that current unique owner can invoke our exported methods.
Incoming bodies are validated by the D-Bus codec and exact method signatures;
cookies, details and responses are never logged.

Registration/session-lookup failures are nonfatal and notify the compositor's
observer, which reports degraded authentication. An existing agent is never
displaced. There is no polling or retry loop on refusal. Full system-bus
reconnection remains later work. Losing the authority or bus cancels any active
conversation and every queued request immediately, releasing all deferred replies.

`destroy` runs outside dispatch. If registered, it queues Unregister and tries
one nonblocking flush without dispatching unrelated compositor callbacks during
teardown. This is best effort under backpressure; closing the bus connection
also removes the registration, including one whose reply was still pending.
Connection destruction completes pending callbacks while the agent is still
alive; they ignore results once `closing` is set.

`zig build test-polkit` uses the production module in a small, noninstalled
runner and independent PyGObject polkit/logind services on a fresh private bus.
It uses no credentials and never registers with the live desktop's polkit.
The visual draft in `assets/mockups/polkit-dialog.html` remains a separate
design artifact; `dialog.zig` is the working native surface.

## Conversation ownership

`identity.zig` parses the bounded identity list and prefers our actual uid
(including primary/supplementary group membership), then a resolvable explicit
user, then a resolvable group member. `native.c` is an NSS/process/memory ABI
shim; it does not call PAM. Display names/usernames are copied into fixed
account storage and never derived from `$USER`.

`helper.zig` connects to `/run/polkit/agent-helper.socket` from the registering
process. `REDIWM_POLKIT_HELPER_SOCKET` overrides that path for fixtures. Custom
paths disable the spawn fallback, so a missing fixture never opens the host's
privileged helper. With the default path, ENOENT/ECONNREFUSED may fall back to a
known root-owned, non-group/world-writable setuid helper. Spawned children use
a socketpair and are killed through a pidfd on cancellation and reaped by the event loop;
ordinary teardown never joins a child on the Wayland thread. The older-distro
setuid path has not been exercised against a real setuid installation here.

The helper owns its event sources and a separate mlocked, MADV_DONTDUMP mapping
for the fixed response buffer. Responses are limited to 510 bytes (plus newline
and NUL for the helper's `fgets(512)`), reject newline/CR/NUL, and are copied only
after validation. The consumer must clear its own input storage after responding.
Sent portions are explicitly zeroed, and cancel/EOF/error/success clear all
remaining response bytes. Failure to lock memory fails the conversation closed.
Opening and queued writes have five-second deadlines; waiting for a human or
PAM response has no artificial timeout. Reads and writes do bounded work per
event; split/coalesced lines, escaped text and HUP with final data are supported.

Helper callbacks borrow text until return. They may respond or cancel, but
must not destroy the helper/agent or recursively dispatch. The agent retains
a completed helper until the next request or destruction so its callback
cannot free its own stack's owner. BeginAuthentication stays deferred until a
terminal result; only helper SUCCESS sends a successful method return (the
helper has already reported the result to polkitd). The active cookie selects
cancellation for both active and queued requests. Each waiting request owns its
cookie, account, action and message. The FIFO allows 16 waiting requests plus
one active request; duplicate cookies, excess requests and oversized descriptions
are rejected before retention. Cancellation of one cookie does not affect others.

A helper FAILURE starts a fresh helper with the same cookie, up to three total
attempts. EOF, malformed helper data and connection/spawn failures are terminal,
not password retries. A one-shot event-loop timer advances retries and the queue
outside helper callbacks, so no callback frees its own helper. Final failure,
success and cancellation consume a request exactly once and advance to the next.
Authority replacement, bus loss and shutdown discard the entire queue. Teardown
keeps request storage alive until bus disconnect callbacks have completed.

The noninstalled terminal driver (`zig build run-polkit-test-agent -- --terminal`)
reads directly into locked memory, hides terminal input and restores settings on
normal completion or SIGINT/SIGTERM. Its isolated tests use fixture credentials.
The user confirmed real native polkit authentication on the development machine
on 2026-10-02; other distro/helper combinations still need qualification.

## Native dialog

The dialog uses the UI renderer and `ui/widgets/secret_input.zig`, a dedicated
fixed-storage editor rather than the ordinary heap-owned text input. Its 510-byte
storage lives in a separate mlocked, MADV_DONTDUMP mapping. Editing scrubs deleted
bytes; submission and every terminal path wipe the field. Both masked and echo-on
rendering use uncached shaping, horizontal scrolling and sensitive panel buffers
that are scrubbed instead of pooled. There is no password reveal control, clipboard
copy/cut/paste, IME, or widget-tree exposure for responses.

Tab/Shift+Tab navigate input, Cancel, Authenticate and action id. Enter submits,
Escape cancels, arrows/Home/End move within the response, and Ctrl+U clears it.
Selecting the action id and pressing Ctrl+C copies only that public identifier.
The identity is resolved through NSS and the lock icon comes from `icons/lock.svg`.
Helper info/errors remain visible across the following prompt. The UI displays
Attempt N of 3 and clears the field before each retry.

The panel and dimming scrim are on the compositor's trusted lock layer, above
normal shell/client overlays. Keyboard, pointer, gestures, client focus changes,
virtual-keyboard and IME routes are gated while it is open. IPC mutations and
synthetic input and screenshots return `AuthenticationActive`; read-only status
remains available. Status includes only dialog state/geometry, never input.
Consumed key/button releases remain swallowed after closing, and keyboard focus
returns to the current live toplevel without forwarding held authentication keys.

Locking closes the helper, hides the dialog and wipes entered response bytes,
while retaining the active request ahead of the FIFO. Requests arriving while
locked are queued. Successful unlock restarts that conversation at the same
attempt number; a failed unlock leaves it suspended. Cancelling a hidden request
removes it permanently. No helper is started while suspended. Session deactivation
outside a lock cancels all requests; deactivation while locked preserves the
suspension. Removing the visible dialog's output cancels the active request.
Opening the dialog disconnects active capture clients before presentation. New
capture sessions and queued/new screenshots are refused while it is visible,
including for echo-on prompts. Automated checks use fixture responses; real
password-prompt success was separately confirmed by the user during the October
2026 desktop review.

`zig build test-polkit-ui` runs the real compositor and an independent authority/
helper on a private bus/headless output. A test-only LD_PRELOAD fixture supplies
native wlroots keyboard/pointer devices via a private FIFO; no production input
bypass exists. Real Wayland application/IME peers verify input isolation and
virtual-keyboard rejection. See [TESTING.md](../../TESTING.md) for renderer
and scale controls.

## Configuration and reload

```toml
[polkit]
enable = true
helper_socket = "/run/polkit/agent-helper.socket"
```

These are the defaults. The socket must be an absolute path shorter than 108
bytes with no NUL. Unknown keys and invalid values reject the config.
`REDIWM_POLKIT_HELPER_SOCKET` remains an explicit test override with precedence
over the configured path. Only the default socket permits the setuid-helper
fallback; custom sockets fail closed.

Reload applies the helper path to newly accepted requests. Every accepted
request owns its path, including while queued, suspended or retrying. Disabling
rejects new requests, lets accepted requests finish, then unregisters when idle.
Enabling registers again. Startup with `enable = false` does not create an
agent or connect to the system bus; `REDIWM_FORCE_POLKIT` does not override this.
Enabling still respects the normal login/nested activation policy.

## IPC lifecycle

`get_shell_state` and shell details include nullable `polkit_dialog` state
(waiting, prompt or failed) and geometry. No response, cookie, identity or request
metadata is exposed by that field.

Subscribe with `event_stream` and
`{"events":["polkit_prompt_opened","polkit_prompt_closed"]}`.
Wire events are `PolkitPromptOpened` and `PolkitPromptClosed`, each containing
only `seq` and `time_ms`. Retries replace the panel and emit close/open pairs.
Locking emits a metadata-free close to existing subscribers; unlock emits open
when the retained request resumes. The close event is allowed through the usual
lock-time broadcast suppression so subscribers can discard the old panel.

Real login-session authentication with the installed helper was confirmed by the
user on this machine; it remains a manual acceptance check for other setups.
Capture exclusion is covered by the private-bus dialog test:
an active protocol capture is disconnected, a new capture cannot obtain a frame,
and screenshots are refused before and after response entry.
