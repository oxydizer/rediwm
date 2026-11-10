# Keys & Certificates plan

Status: SSH implementation, 2026-11-10, on `feat/settings-ssh-keys`.
D1, D4 and D8 follow the recommendations below for the initial SSH page.
Agent integration, certificates, whole-home discovery, vault operations and
trust stores remain later phases; their decisions are still open.

The initial page inventories regular, owned files directly in `~/.ssh` by
content, groups copies by public fingerprint, and shows encryption, weak-key,
permission, missing-public and mismatched-public badges. It supports details,
copy public key, Ed25519 generation, passphrase/comment/label changes,
recreating a missing `.pub`, permissions and confirmed Trash of a selected
location plus its matching public companion. Users links to the page; global
search reaches it without starting its helper.

Supported metadata: OpenSSH private keys (including encrypted headers),
Ed25519/RSA/DSA/NIST ECDSA public keys, and unencrypted RSA PKCS#1/PKCS#8 PEM.
Encrypted legacy PEM, SSH certificates, security-key formats, PuTTY and other
certificate/container formats are skipped with an explanation for now. No
agent or host/reference inventory is implied by the SSH view. Trash confirms
the selected path and fingerprint and warns about references; enumerating
those references belongs to Phase 2.

The helper has bounded reads/replies, memory/CPU limits, no core dumps and a
read-only scanner sandbox (seccomp on Linux, preopened read capabilities and
Capsicum on FreeBSD). OpenSSH operations run on staged files; passphrase and
comment changes verify identity and unchanged source bytes before publishing.
The FreeBSD path has been cross-compiled; runtime qualification is still needed.
Passphrases use locked buffers and an inherited pipe to a private askpass mode,
with no external askpass IPC. Scan results refresh explicitly; no idle watches.

Generated fixtures cover the SSH portion of Phase 0 and the initial page:
fingerprint comparisons with OpenSSH, duplicate locations, hostile/truncated
armor/DER, encrypted keys, missing/mismatched companions, unsafe files and
permissions, failed/successful writes, labels, Trash and UI secrets. Whole-home
timings, X.509 corpus/tooling surveys and oldest-supported-OpenSSH qualification
remain prerequisites for their later phases. The metadata format follows
[OpenSSH's key specification](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key);
operations use [ssh-keygen](https://man.openbsd.org/ssh-keygen).

Add a **Keys & Certificates** page to Settings: one place that shows every SSH
key, certificate and private key the user owns, wherever it lies, says what
each one *is* and whether it is healthy, and offers the handful of actions
people otherwise look up every time (copy the public key, add a passphrase,
load into the agent, convert a `.pfx`, find out what that `.pem` in Downloads
is).

## What a survey of one real home directory showed

Taken 2026-11-10 on the development machine (names only, no contents read):

* `~/.ssh` holds four private keys. One has no `.pub` and no extension, so
  **extensions cannot be the classifier**; content is.
* 26 more candidates (`.pem`, `.crt`, `.key`, `.pfx`, `.pub`) lie outside it.
  Most belong to tools (a container dev proxy's TLS pairs, the .NET dev-cert
  store, application state). A few are true strays in Downloads, Documents and
  project folders. **A manager that offers to tidy tool-owned files breaks
  those tools**, so ownership is part of the model.
* The session exports no `SSH_AUTH_SOCK`. `gpg-agent-ssh.socket` listens but
  nothing points at it, so no agent is in use.
* The system trust store has 168 anchors, one of them added locally. A local
  anchor can sign for any site; it deserves to be visible.
* `~/.pki/nssdb` exists (the store Chromium-family browsers read).
* Present: `ssh-keygen`, `ssh-add`, `openssl`, `certutil`, `trust` (p11-kit),
  `update-ca-trust`. Nothing in the tree links a crypto library today.

Spike results (throwaway key in a scratch directory, OpenSSH 10.6, OpenSSL 3.6):

* `ssh-keygen` generates and re-encrypts with passphrases read through
  `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force`, no tty, no `-N`/`-P`. The
  prompts are distinguishable ("Enter old passphrase", "Enter new passphrase",
  "Enter same passphrase again").
* An encrypted OpenSSH private key carries its public key in clear: type,
  fingerprint, cipher and KDF are readable **without the passphrase**.
* `openssl pkcs12` takes passwords with `-passin fd:N` / `-passout fd:N`.

So no secret ever needs to be in an argv or the environment.

## Placement (D1)

Recommended: its own page, not a part of Users. Users administers *system
accounts* through the root helper and polkit; these are the *current user's*
files and need no privilege. `users.zig` is also 732 lines, close to the split
threshold. Users gets one row linking to the page.

The page has four views behind a segmented control:

```
 Keys & Certificates                        [ Scan this computer ]
 ( SSH keys ) ( Certificates ) ( Found files ) ( Trust )

 SSH keys                                   Agent: running · 1 loaded
 ┌───────────────────────────────────────────────────────────────┐
 │ ● work laptop        ED25519  SHA256:Unenw…  🔒   [Copy public] │
 │   ~/.ssh/id_ed25519 · used for github.com, 2 more   ◉ loaded   │
 │ ● staging            RSA 2048 SHA256:9fQk…  ⚠ no passphrase     │
 │   ~/.ssh/staging · no .pub file                    ○ load      │
 └───────────────────────────────────────────────────────────────┘
 [ New key… ]  [ Import… ]          Known hosts (41) ›  Authorized (2) ›
```

Selecting a row opens details in the same column (as Users and Network do):
every location of that key, fingerprints, comment, label and notes, where it
is referenced, and its actions.

## Model

Items are identified by **public-key fingerprint**, not by path:

* The same key copied to three places is one item with three locations.
* A certificate and a private key pair up when their public keys match; an SSH
  private key pairs with its `.pub`, with `authorized_keys` lines, with
  `IdentityFile` entries in `~/.ssh/config`, and with agent identities.
* Labels, notes and tags are stored against the fingerprint
  (`$XDG_DATA_HOME/rediwm/keys/index.json`), so they survive moves and apply
  to files RediWM does not own.

Kinds, decided from content (PEM armor label, then structure; DER by ASN.1
shape): OpenSSH private/public key, PuTTY key, PKCS#1 / SEC1 / PKCS#8 private
key (plain or encrypted), X.509 certificate (leaf, CA, self-signed), chain or
bundle, CSR, CRL, PKCS#12, and "unrecognised". The common "cloud `.pem`" is
shown as what it is: an RSA private key usable for SSH.

Ownership of a location:

| Class | Example | Offered |
| --- | --- | --- |
| Standard | `~/.ssh`, the vault | Everything |
| Stray | Downloads, Documents, Desktop, home root | Everything, plus *Move to vault* |
| Project | inside a git work tree | View, copy, health; move only on request. Shows whether git tracks or ignores it |
| Tool-managed | a reviewed catalog: dev proxies, mkcert, .NET, kube, cloud CLIs, VM tools | Read-only, grouped "Managed by …" |
| System | trust store, `/etc/ssl` | Read-only (D5) |

Health badges, each with a one-line explanation and, where safe, a fix:
private key without passphrase; permissions `ssh` will refuse; weak or retired
algorithm (DSA, RSA under 2048, SHA-1 signatures); certificate expired or
expiring within 30 days; `.pub` missing or not matching; private key tracked
by git; private key in a stray location; certificate whose key is nowhere to
be found; locally added trust anchor.

## Actions

SSH: generate (Ed25519 by default, comment, optional passphrase); copy public
key; add, change or remove passphrase; edit comment and label; recreate a
missing `.pub`; fix permissions; load into or remove from the agent, with a
lifetime; "use for host…" (adds a `Host` block with `IdentityFile` and
`IdentitiesOnly`); delete. `authorized_keys` and `known_hosts` get list views
with remove. "Add to GitHub/GitLab" copies the public key and opens the
provider's page.

Certificates: details (subject, issuer, names, validity, usage, fingerprints,
chain); verify against system trust; check that a key matches; copy PEM or
fingerprint; convert PEM ↔ DER; split a PKCS#12 into certificate and key, or
build one; export the public certificate; delete.

Found files: label, reveal in Files, move to vault, ignore this file or folder.

Never offered: showing or copying private key material.

## Architecture

The page is drawn by the compositor, so the rules are strict:

* **The compositor never reads key files.** A new unprivileged
  `rediwm-keys` helper scans, parses and runs operations; the page receives
  metadata only (kind, algorithm, fingerprint, flags, paths). Parsing a file
  from Downloads is parsing hostile input, and it must not happen in the
  process that owns the session.
* **Read side:** `rediwm-keys scan` runs under a `platform/seccomp.zig`
  policy (read-only filesystem calls, no network, no exec), like the PDF and
  theme helpers. Metadata parsing is native Zig: PEM armor, a tolerant DER
  walker, the OpenSSH wire format, SHA-256. No library dependency, small
  enough to fuzz.
* **Write side:** each operation is a separate `rediwm-keys` invocation that
  validates its target again and runs the reference tool with a fixed argv:
  `ssh-keygen`, `ssh-add`, `openssl`, `certutil`. We do not write private-key
  cryptography ourselves. A missing tool disables its actions with a reason.
* **Secrets** are typed into `secret_input.Input` over mlocked storage and
  travel over a pipe to the helper, which answers the tool's askpass prompts
  (or passes an fd to `openssl`). Wiped on submit, cancel, hide and page
  change, as Printers does. Never in argv, environment, logs or the arena.
* **Lifetime follows Printers:** the client exists only while the page is
  selected; bounded pipe reads, absolute deadlines, snapshots copied into the
  section arena, action generations so an old refresh cannot clear a newer
  action's busy state. Opening Settings elsewhere starts nothing.
* **No idle work.** Opening the page reads the standard locations and the
  cached result of the last scan. The whole-home scan is explicit and
  cancellable, with incremental results. No inotify watches.
* The greeter gets none of this. No new IPC request returns key material.

Proposed files:

| File | Responsibility |
| --- | --- |
| `src/keys/` (named module, no compositor imports) | `model`, `pem`, `der`, `x509`, `openssh`, `classify`, `scan`, `catalog` (tool-managed locations), `health`, `index` (labels), `agent` (agent protocol: list, remove), `ops` (operation plans and fixed argv), `protocol` |
| `src/keys/helper_main.zig` | `rediwm-keys` entry: `scan`, `op`, `askpass` modes |
| `src/keys/client.zig` | Page-side child process, snapshots, generations |
| `src/control_center/sections/keys.zig` | Section state, view switch, build |
| `sections/keys_ssh.zig`, `keys_certs.zig`, `keys_files.zig`, `keys_trust.zig`, `keys_details.zig`, `keys_forms.zig` | One file per view, split from the start |
| `panel.zig`, `tree.zig`, `keys.zig`, `search_index.zig` | Page enum, navigation, Escape handling, search entries |
| `build/` | Helper artifact, `test-keys` step |

OS differences (trust store layout, `certctl` on FreeBSD) sit behind one
adapter in `src/keys/`; process and file primitives come from `src/platform/`.

## Agent (D2)

Recommended: when the session starts with no `SSH_AUTH_SOCK`, `rediwm-session`
starts OpenSSH `ssh-agent` on a socket under `$XDG_RUNTIME_DIR` and exports it
through `child_env` and the activation environment. An agent that already
exists (set by the user, gpg-agent with SSH support, a keyring daemon) is
respected and shown by name; the agent protocol is the same, so list, load and
unload work with any of them. We do not write our own agent: that would put
decrypted keys in our process.

With an agent in place:

* Loaded state per key, load with a lifetime (until logout, 1 h, 8 h).
* Optional "forget keys when the screen locks" and "on suspend", fired after
  `Lock.announce`, never delaying the lock.
* A native passphrase prompt: `SSH_ASKPASS` points at `rediwm-keys askpass`,
  which asks the compositor to show a secret dialog. This is a dialog any
  local program can raise, so it shows the requesting program, the tool's
  prompt verbatim, and is refused for sandboxed callers without a
  `[[sandbox_allow]]` grant. It needs its own review before it ships.

## Vault (D3, D4)

Files stay ordinary files that every other tool can read; there is no
container format. SSH keys belong in `~/.ssh`. Everything else moves to
`$XDG_DATA_HOME/rediwm/keys/` (directory 0700, files 0600), named from the
label. A move is copy, verify by fingerprint, then remove the original, and
records where the file came from. No symlink is left behind by default: a
link to a private key in Downloads defeats the purpose. Project files can opt
in to a symlink.

Delete moves to the home Trash with a confirmation that names the fingerprint
and every place the key is referenced. Losing the only copy of an SSH key
locks people out of servers; a recoverable delete is the kinder default.

## Phases

0. **Facts and corpus.** No UI. Measure a whole-home scan (time, candidates,
   false positives in vendored trees). Decide the candidate rule: extension
   list, `~/.ssh`, and an optional content sniff of small files. Check
   `std.crypto.Certificate` against the system bundle and odd certificates;
   write the tolerant walker if it rejects what users have. Confirm the
   askpass behaviour on the oldest OpenSSH we support and for `ssh-add`.
   Survey trust-store tooling per distribution and FreeBSD. Draft the seccomp
   policy. Build a generated fixture corpus (never real keys) and a fuzz
   target for the parsers.
1. **SSH keys.** Page, helper, `~/.ssh` inventory with badges, details, copy
   public key, generate, passphrase, comment and label, recreate `.pub`, fix
   permissions, delete. Search entries, translations.
2. **Agent and hosts.** Session agent, loaded state and lifetimes, forget on
   lock, askpass dialog, "used for" from `~/.ssh/config`, `authorized_keys`,
   `known_hosts`.
3. **Certificates and found files.** Explicit scan, classification, pairing
   and de-duplication, ownership classes, health, certificate details and
   chain, labels and notes, reveal in Files, ignore list.
4. **Vault and conversion.** Move to vault, import, PEM/DER/PKCS#12
   conversion, export.
5. **Trust and reach.** System anchors read-only with local ones called out,
   the user NSS store (list, add, remove), expiry notifications on a
   deadline-only timer, opening a key or certificate from Files in this page.

Later, each its own plan: GPG keys (D7), FIDO2 and resident keys, PKCS#11 and
smart cards, an encrypted backup of the vault, CSR and self-signed generation,
installing a key on a server, ACME renewal, Java keystores, WireGuard keys.

## Tests

Nothing may touch the host's `~/.ssh`, agent, NSS store or trust store. Every
test runs with a scratch `HOME` and `XDG_*`, its own agent on a short socket
path, and keys generated in the test.

* `zig build test-keys`: parsers against the corpus, classification, pairing,
  health rules, ownership catalog, operation plans (argv is asserted, never
  containing a secret), index round trip, fuzz smoke.
* `tests/keys_settings.py`: inventory, badges, generate, passphrase change
  (verified with `ssh-keygen -y`), copy public key, delete to Trash, agent
  load and unload, scan with tool-managed and project fixtures, move to vault.
* `strings` on a ReleaseSafe `rediwm`: no test hooks, no new environment
  reads beyond `SSH_AUTH_SOCK`.

## Decisions

| | Question | Recommendation |
| --- | --- | --- |
| D1 | Own page or part of Users? | Own page "Keys & Certificates"; a link row in Users |
| D2 | Agent | Start OpenSSH `ssh-agent` when the session has none; respect an existing one |
| D3 | Vault location; symlinks on move | `$XDG_DATA_HOME/rediwm/keys`, SSH keys in `~/.ssh`; no symlink by default |
| D4 | Delete | Home Trash, with a confirmation naming fingerprint and references |
| D5 | Adding or removing *system* trust anchors (needs root) | Read-only in this plan. A root path means widening the accounts helper or a fixed-argv polkit action; decide separately |
| D6 | Scan scope | Home only, explicit, cached; extra folders added by the user; content sniff as an opt-in "deep scan" |
| D7 | GPG keys | Out of this plan |
| D8 | Parsing | Native metadata parsing plus reference CLI tools for operations; do not link OpenSSL |
