# Firewall (`firewall/`, `firewall_helper/`, `firewall_main.zig`)

Plan and decisions: `docs/plans/firewall.md`. Settings side:
`control_center/sections/firewall*.zig` (notes in `src/control_center/AGENTS.md`).

* **`firewall/` is the shared module** (std only): the model Settings draws,
  the request protocol, validation, and pure parsers/renderers per manager
  (`ufw.zig`, `firewalld.zig`, `own.zig` for our nftables table and pf anchor,
  `inventory.zig`, `sockets.zig`, `blocks.zig`). Test them with
  `zig build test-firewall`; nothing here runs a tool.
* **`rediwm-firewall-helper` runs as root under pkexec** and is the only code
  that runs tools or writes system files. `read` (status, recent blocks) and
  `manage` (everything) are separate polkit actions, chosen by argv1
  (`data/org.rediwm.firewall.policy`); the helper refuses a change in `read`
  mode. `sync` re-applies our saved rules (boot unit, NetworkManager
  dispatcher). Requests are untrusted: every field passes `validate.zig`
  before a renderer or argv sees it, which is why renderers never escape.
  Removals use `validate.removal` (port lists, a manager's own `raw` text,
  matched against its listing).
* **Tools come from system directories only** (`run.tool`), run with a fixed
  C-locale environment (`run.environment`), never a shell. Failures reach the
  page as fixed words (`failure` in `firewall_main.zig`), never tool output.
* **One manager at a time.** nftables base chains stack, so our table cannot
  open what ufw or RediOS drops. `linux.zig` detects our table, firewalld,
  ufw and RediOS; edits go through whichever manages, and nothing is editable
  while two are active. Our own table (`inet rediwm`) and pf anchor
  (`rediwm`) are written only by us; other tables, pf.conf rules and ipfw
  are read-only. pf.conf is changed only to add the anchor (backup kept) or,
  when missing, written from `own.pf_conf`.
* **Trust** is a connection's NetworkManager zone (`networks.zig`): firewalld
  follows it natively; our table's `home_ifaces` set is filled by `sync`
  (dispatcher). Without NetworkManager (FreeBSD) trust is per interface in our
  state.
* **Revert**: a change with `revert_after` forks a detached watchdog
  (`state.arm`) that applies the computed undo unless `confirm` stops it. It
  closes stdio so Settings' pipe ends now. Lockdown is a separate
  `inet rediwm_lockdown` table (priority -200), runtime only.
* **State files** are root-only: `${sysconfdir}/rediwm/firewall.json` (ours;
  re-validated on load), rendered `firewall.nft` / `pf.rediwm.conf`, run state
  under `${rundir}/rediwm-firewall`. Use `install_paths`, never literals; the
  systemd unit and dispatcher paths are third-party locations and literal.
* **Tests never touch the host firewall**: `tests/firewall_helper.py` runs the
  real helper as namespace root in `unshare -rmn` with config/run dirs on
  tmpfs and nmcli/systemctl/ufw/firewall-cmd hidden;
  `tests/firewall_settings.py` drives Settings with a fake pkexec
  (`tests/fixtures/firewall_pkexec.sh`) and fake helper. pf is checked on the
  FreeBSD VM (`pfctl -nf`).
