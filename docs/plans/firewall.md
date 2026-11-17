# Plan: Firewall settings

Status: 2026-11-17. D1–D8 decided (as recommended). Phases 1–5 are built on
Linux and pass their tests; the FreeBSD half is written and cross-compiles but
has not run on FreeBSD (see "Not done yet"). Phase 6 (editing through `redi`)
is not started.

Scope: a Firewall section in Settings → Network that shows the whole firewall
on one screen and lets the user manage it: on/off, default policies, trust per
network, allow/deny rules for services, ports and addresses, which programs are
listening and whether the firewall lets anyone reach them, ping, logging, a
recent-blocks view, and a read-only list of rules owned by other programs
(Docker, libvirt, Tailscale, VPNs). It must work on Linux and on FreeBSD 15.x
(`freebsd.md`).

Out of scope: per-application outgoing filtering (OpenSnitch-style; needs a
resident daemon and cgroup/eBPF matching), intrusion detection, authoring NAT
or port forwarding (shown read-only), and installing firewall packages.

## Where we are

* Nothing in RediWM touches the firewall. Settings → Network is one scrolling
  page of cards (`sections/network*.zig`: overview, Ethernet, Wi-Fi, editor,
  VPN, proxy, airplane). On FreeBSD the NetworkManager and BlueZ cards are
  hidden (freebsd D3), which leaves that page almost empty. Firewall would be
  the first Network card that both systems show, so **it cannot depend on
  NetworkManager**.
* Root precedent: `rediwm-accounts-helper` runs under `pkexec`, reads stdin
  JSON, validates every field and passes argv to absolute tools. AGENTS.md
  currently says only rediwm-dm and that helper run as root (see D1).
* Lifetime precedent: Keys and Printers own their worker only while the page
  is on screen, allow one request in flight with an absolute deadline, cancel
  it on hide, close or lock, and create no idle timers.

### What we would talk to

| Stack | Where | Interface | Reading needs root? |
| --- | --- | --- | --- |
| firewalld | Fedora, openSUSE, optional elsewhere | D-Bus `org.fedoraproject.FirewallD1`, gated by polkit; zones, services, rich rules, runtime vs permanent; NM's `connection.zone` | No (`firewall.info`, P0 confirms) |
| ufw | Ubuntu, Mint, Arch (this machine: active, DROP/ACCEPT/DROP) | CLI only, `/etc/ufw`, `/etc/default/ufw`; Plasma ships its own KAuth helper (`org.kde.ufw`) | State and counters: yes |
| plain nftables | Arch `/etc/nftables.conf`, Gentoo `/var/lib/nftables/rules-save` | `nft -j`, netlink | Yes (`CAP_NET_ADMIN`) |
| RediOS `redi` | redi-iso installs | Renders `table inet redi` from the manifest's typed `Firewall::Nftables` (incoming/forwarding/outgoing, `allow_icmp`, `tcp_ports`, `udp_ports`), **starting with `flush ruleset`** | Yes |
| pf | FreeBSD (default choice) | `pfctl`, `/dev/pf`; anchors loaded at runtime, made persistent with `load anchor` in `pf.conf`; `pf_enable` in rc.conf | Yes |
| ipfw / ipf | FreeBSD alternatives | `ipfw list` | Yes |
| Docker, podman, libvirt, Tailscale, WireGuard | both (Linux mostly) | Their own tables, chains or anchors | Yes |

Two facts that shape the design:

* **Two filters stack, they don't merge.** With nftables, every base chain on a
  hook has to accept a packet: an `accept` in our table cannot override a
  `drop` in ufw's or redi's. pf's anchors are evaluated inside the main
  ruleset. A port can therefore only be opened by the program that manages
  the firewall, so **one manager at a time**, and we edit through that manager.
* **On FreeBSD, polkit answered `auth_admin` for session shells** in the VM
  probe (freebsd.md). Until that is settled, every root call may show a
  password prompt there, reads included. The page must not prompt without a
  click.

## Design

### One model, several backends

`src/firewall/` is std + `dbus` only, with no compositor imports, and holds a
model that does not depend on any backend:

* **Status:** backend, running, starts at boot, default incoming/outgoing/
  forward policy, ping answered, logging level, lockdown active.
* **Rules:** allow/deny/reject/limit, direction, a service *or*
  protocol + port/range, source (anywhere / local network / address or CIDR),
  scope (everywhere / a trust level / an interface), IP family, comment.
  Each rule is either *ours*, which we can edit, or *foreign*, which is
  read-only and grouped by a guessed owner: `docker`, `libvirt`, `tailscale`,
  `ts-*`, `nm-*` and similar.
* **Listeners:** proto, address, port, process name, pid, uid, plus a
  *verdict* the model computes: loopback only / blocked / reachable on home
  networks / reachable from everywhere.
* **Capabilities** per backend. The UI hides or disables what a backend cannot
  express. ufw has no zones, redi has no source restriction, and firewalld has
  no "limit" outside rich rules.

| Backend | OS | Reads | Writes |
| --- | --- | --- | --- |
| `firewalld` | Linux | helper: `firewall-cmd` (zones, active zones), service XML | helper: `firewall-cmd --permanent` + `--reload` |
| `ufw` | Linux | helper: `ufw status verbose`, `ufw show added`, rule files | helper: `ufw` argv (`allow`, `delete`, `default`, `enable`, `logging`) |
| `nft` (ours) | Linux | helper: `nft -j list ruleset` | helper: atomic `nft -f` of our table only |
| `redi` | RediOS | helper: `nft -j` | `redi` CLI (D5) |
| `pf` | FreeBSD | helper: `pfctl -s info/-sr/-a rediwm -sr` | helper: `pfctl -a rediwm -f` (anchor only) |
| `foreign` | both | helper | none: a hand-written nftables.conf, ipfw or ipf is shown read-only |

**Detection** looks at every stack that is present and active. Exactly one
manager is editable. If two are active (ufw and firewalld, say), a conflict
banner explains the situation and everything stays read-only until one is
turned off. Each backend's parser is a pure function over captured output, so
it can be tested without root.

### Privileged helper: `rediwm-firewall-helper`

Built like the accounts helper:

* root under `pkexec`; stdin JSON; `PKEXEC_UID` is untrusted
* argv only, to absolute tools found through `platform.tool`, never a shell
* every field validated before anything is rendered: ports 1–65535, ranges,
  CIDRs, interface names `[A-Za-z0-9._-]{1,15}`, comments of up to 64
  printable characters with no quotes
* operations: `status` (rules, listeners and counters in one reply), `apply`
  (desired state for what we own), `enable`/`disable`, `set-defaults`,
  `add-rule`/`remove-rule`, `set-trust`, `lockdown`

**Unlock, like Users and Services (D1).** Editing sits behind an **Unlock**
button in the overview card. It runs the helper's `authorize` operation, which
changes nothing (as `rediwm-accounts-helper`'s does). pkexec asks for the
password, and the page is unlocked for this Settings session; the button then
reads **Lock**. Edit controls are disabled until then, with *Unlock to change
firewall settings* beneath them. The action is `auth_admin_keep`, so polkit
remembers the password for a few minutes and the edits that follow run without
a prompt. After that, the next edit asks again; the page stays unlocked
(Users behaves the same way). Lock, closing Settings, leaving the page or the
screen lock drop the unlocked state and cancel a pending prompt.

Polkit actions (`data/org.rediwm.firewall.policy`, with an `exec.path`
annotation on the helper like the accounts policy):

* `org.rediwm.firewall.read`: `allow_active=yes`, so on Linux the overview
  shows with no password. Only `status` and `recent-blocks` use it.
* `org.rediwm.firewall.manage`: `auth_admin` / `auth_admin` /
  `auth_admin_keep`. This covers `authorize` and every change.

pkexec picks the action by the helper's first argument
(`org.freedesktop.policykit.exec.argv1`). Following network changes needs no
action: NetworkManager's dispatcher runs `rediwm-firewall-helper sync` as root.

Where `read` is denied without interaction (FreeBSD today, where polkit
answered `auth_admin` in the VM probe), the overview shows *Unlock to view*
in place of the status. Unlocking then reads, so one password covers both
viewing and editing. A page never prompts without a click.

Lifetime is the Keys pattern: one request in flight, an absolute deadline, a
child process group, cancelled on hide, close or lock. A read runs when the
section comes on screen, after each write, on the Refresh button and when an
ActiveConnection change arrives that the page already receives. Nothing polls.
Not in greeter mode; IPC returns `SessionLocked` while locked.

firewalld also goes through the helper (`firewall-cmd`), not D-Bus from the
compositor: one code path, one way to test it, and the listener list needs
root anyway. Its output is read in the C locale.

### Our own table or anchor (when nothing manages the firewall)

* **nft:** we own only `table inet rediwm`. The helper renders the whole table
  and loads it in one transaction (`destroy table` + `table …` in a single
  `nft -f`), so a failed load changes nothing. It persists to
  `${sysconfdir}/rediwm/firewall.nft` (`install_paths`, never a literal
  `/etc`). At boot it is loaded by `rediwm-firewall.service`
  (`Before=network-pre.target`, running `rediwm-firewall-helper sync`), which
  the helper writes to `/etc/systemd/system` and enables when the firewall is
  turned on. Without systemd (Artix's OpenRC) there is no boot unit yet, and
  Start at boot is hidden. Other tables are never touched.
* **pf:** we own only the anchor `rediwm`, persisted to
  `${sysconfdir}/rediwm/pf.rediwm.conf` (`/usr/local/etc` on FreeBSD) and
  rendered with `quick` rules so pf's last-match rule cannot surprise us.
  * `pf.conf` already has `anchor "rediwm"` and `load anchor`: manage the
    anchor.
  * `pf.conf` exists without them: show its rules read-only and offer to add
    the two lines, showing the diff first.
  * No `pf.conf`, pf off: *Turn on* writes a minimal one after confirmation
    (`set skip on lo0`, `block in`, `pass out keep state`, the anchor), then
    runs `sysrc pf_enable=YES` and `service pf start`.
* The seed matches RediOS's: block unsolicited incoming and forwarded
  traffic, allow outgoing; accept loopback, established/related, ICMP/ICMPv6
  and DHCP client replies; open no listening ports, SSH included.

### Network trust (Public / Home)

Trust lives on the *network*, not on the interface, because `wlan0` is the
same device at home and in a café.

* **firewalld:** `connection.zone` on the NM profile (`public`/`home`). This
  is native.
* **Our nft table with NM:** trust is also `connection.zone` (`home`,
  `trusted`, `internal` and `work` count as Home), so it carries over if the
  user switches to firewalld. The table's `home_ifaces` set holds the devices
  of active Home connections. The NM dispatcher script we install
  (`/etc/NetworkManager/dispatcher.d/90-rediwm-firewall`; it runs as root on
  up/down, even before login) runs `sync`, which refills it. Unknown networks
  are Public.
* **FreeBSD (no NM) or no NM:** trust per interface, saved in our anchor file.
* **ufw:** no trust levels (capability off): rules apply everywhere, and the
  card says so.
* The connection editor and the Wi-Fi details gain a *Firewall: Public / Home*
  row where the backend supports it.

### Service catalog

`firewall/services.zig` (a table, translated in Settings): name, ports and a
suggested scope.
Examples: SSH, web server, mDNS/Avahi, KDE Connect/GSConnect, Syncthing, Steam
Remote Play and LAN transfers, Samba, IPP/CUPS sharing, DLNA, Chromecast and
Spotify Connect discovery, the Files transfers (torrent helper) listening
port, VNC/RDP, WireGuard. When firewalld runs we also show its services, and
ufw's application profiles when ufw runs (`/etc/ufw/applications.d`).

### Listening and exposure

The helper's `status` includes listeners.

* **Linux:** `/proc/net/{tcp,tcp6,udp,udp6}` plus an inode → pid scan, which
  only root can do for every user. This goes through
  `system_monitor/proc.zig`; only its Linux backend reads `/proc`.
* **FreeBSD:** `sockstat -46lq` (or `net.inet.*.pcblist`, decided in P0).

The model gives each listener a verdict, and the overview names the ones that
matter: *sshd :22 is reachable from every network* with **Block** and **Allow
on home networks** next to it.

### The page

The overview card is always on the Network page. **Manage** opens a Firewall
sub-view (D6).

```
Firewall                                              [ On ]
Protected by ufw · blocks incoming, allows outgoing
This network (Home Wi-Fi) is trusted as  [ Public | Home ]
────────────────────────────────────────────────────────────
Incoming  Block    Outgoing  Allow    Forwarding  Block
Ping      Answer   Logging   Low      Starts at boot  Yes
────────────────────────────────────────────────────────────
! sshd :22 is reachable from every network   [Block] [Home only]
Rules  6 allow · 1 deny      Also active: Docker (4), Tailscale (2)
                           [Refresh]  [Unlock]  [Manage…]
```

Sub-view cards:

1. **Rules:** list, filter, add/edit/delete, *Add service* from the catalog,
   *Add port*, source and scope pickers.
2. **Listening services:** every listener with its verdict and a quick action.
3. **Networks:** known NM profiles (or interfaces) and their trust.
4. **Advanced:** default policies (outgoing Block is guarded, see Safety),
   forwarding, ping, logging level, rate-limit SSH, IPv6 on/off for our
   rules, starts at boot.
5. **Other rules:** foreign tables, chains and anchors, grouped and
   read-only, with a note that we cannot override them.
6. **Recent blocks** (D7).

Every control is a `ui/widgets/` control. Search index entries go into
`search_index.zig` (firewall, ports, ssh, ufw, pf, block, allow, ping).

### Safety

* **Confirm, or revert automatically**, for changes that can cut the user off:
  outgoing Block, Lockdown, and turning off a rule that allows SSH while SSH
  connections are established. The helper applies the change, keeps a small
  watchdog alive on a pipe, and restores the previous state after 20 s unless
  Settings confirms (the same pattern as a display mode change).
* **Lockdown** ("Block all connections"): drops everything except loopback,
  in the runtime only, until it is turned off or the machine reboots.
* The helper renders all text itself from validated fields. A user string is
  never placed into a ruleset, a shell or a log.
* Reports and logs contain no addresses or process command lines.
* Never write the host's firewall from tests.

### Recent blocks (D7)

Our rules log drops with a prefix (`rediwm-drop`) and a rate limit (nft
`limit rate 10/minute`; pf `log` on the anchor's block rules). On demand, the
helper reads them: `journalctl -k` (or the kernel ring) on Linux, `tcpdump
-r /var/log/pflog` on FreeBSD. The view shows time, direction, protocol, port
and remote address, with *Allow this* where the backend can express it.
There is no live stream and no idle wakeups.

## Phases

Status: 0 done on Linux (nft in `unshare -rn` works, ufw's tuple format read
from its source, firewalld's API checked); its FreeBSD items wait for the VM.
1–5 built. 6 not started.

0. **Facts** (nothing shipped):
   * firewalld `info` without a prompt
   * NM `user` data key syntax and its dispatcher environment
   * stability of ufw's output across 0.36
   * `nft -j` inside `unshare -rn` (an unprivileged netns: real kernel
     validation without touching the host)
   * pf anchor load and persistence, and pkexec/polkit behaviour, on the
     HyprBSD 15.1 VM, including whether `auth_admin_keep` carries across
     separate pkexec runs there as it does on Linux
   * `sockstat` format
   * the real table and chain names of Docker, Tailscale and libvirt
   * whether `redi` can edit its firewall policy from the CLI
1. **Read-only overview, both systems:** model, the helper's `status`, parsers
   for firewalld, ufw, nft (foreign) and pf, the overview card, listeners,
   other rules.
2. **Editing through the manager:** on/off, defaults, ping, logging, rule
   CRUD within each backend's capabilities, the catalog. (No IPC
   command: the tests read the page's widgets and the helper's replies.)
3. **Our own firewall when there is none:** the nft table + boot unit, the pf
   anchor + setup, *Turn on*.
4. **Network trust:** firewalld zones, the dispatcher for nft, per-interface
   trust on FreeBSD, rows in the connection editor.
5. **Safety and insight:** confirm/revert, lockdown, SSH rate limit, recent
   blocks.
6. **RediOS:** editing through `redi` (cross-repo, D5).

## Not done yet

* **FreeBSD has not run.** `firewall_helper/freebsd.zig` (pf anchor, pf.conf
  setup, sockstat, pflog, per-interface trust) cross-compiles; on the HyprBSD
  VM still to do: `pfctl -nf` of the rendered anchor, the pf.conf insertion,
  `pkexec` with argv1 actions and whether `auth_admin_keep` carries across
  runs, sockstat's columns, and a `tests/firewall_helper.py` equivalent in a
  vnet jail.
* **firewalld is tested only by its parsers.** No firewalld runs here; try it
  in a Fedora container or VM before calling it done.
* ufw application rules whose names contain spaces cannot be removed from
  the page; OpenRC boot unit; translations of the new strings; Phase 6.

## Tests

* **Unit (`zig build test-firewall`):** parsers over captured fixtures (ufw
  status, `nft -j`, firewalld replies, `pfctl -sr`, `sockstat`,
  `/proc/net/tcp`); nft and pf renderers against goldens; validation,
  including hostile comments and interface names; the helper's operations
  over a recording executor.
* **Real kernel without root:** load the rendered table with `nft -c -f` and
  `nft -f` inside `unshare -rn`, then check a packet verdict with `nft
  monitor trace` or `conntrack`-free probes in that namespace.
* **FreeBSD:** pf in a vnet jail on the HyprBSD VM (root there is fine; it is
  a VM).
* **Real helper:** `tests/firewall_helper.py` runs it as namespace root in
  `unshare -rmn`, with config and run directories on tmpfs and nmcli,
  systemctl, ufw and firewall-cmd hidden, against real nftables.
* **Settings:** `tests/firewall_settings.py` re-runs itself in a user and
  mount namespace (namespace root is a subordinate uid, used only to
  bind-mount `tests/fixtures/firewall_pkexec.sh` over `/usr/bin/pkexec`) and
  drives the page against `tests/firewall_fake_helper.py`. No production
  override of the helper or pkexec path exists.

## Decisions (all decided 2026-11-17, as recommended)

* **D1 Root helper: decided 2026-11-17.** Add `rediwm-firewall-helper` as a
  third root program and amend the AGENTS.md rule. Changes need an
  **Unlock** button that asks for the password through pkexec (the Users
  page pattern, `auth_admin_keep`). Without the helper, only firewalld could
  be managed; ufw (this machine), plain nftables, RediOS and every FreeBSD
  system would show nothing.
* **D2 Which stacks to manage.** *Recommended:* firewalld, ufw, pf (through
  our anchor), our own nft table. Read-only: a hand-written nftables ruleset,
  ipfw, ipf.
* **D3 No firewall running.** Offer *Turn on*, which sets up our own (nft
  table + unit, or pf + anchor) with the RediOS defaults. *Recommended: yes.*
* **D4 Trust levels.** *Recommended:* Public / Home only, stored on the NM
  profile (per interface without NM), off for ufw. Alternative: firewalld's
  full zone list.
* **D5 RediOS.** Read-only ("Managed by RediOS") until `redi` gains a firewall
  edit command that we call. *Recommended* over editing its manifest
  ourselves.
* **D6 Placement.** Overview card on Network plus a Firewall sub-view
  (*recommended*), or a sidebar page of its own.
* **D7 Logging.** Off by default, with an on-demand *Recent blocks* view
  (*recommended*), or on with a low limit.
* **D8 Confirm/revert.** Only for outgoing Block, Lockdown and SSH removal
  (*recommended*), or for every change.
