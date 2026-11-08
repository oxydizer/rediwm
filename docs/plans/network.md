# Network settings plan

Settings → Network showed IPv4/gateway/DNS/MAC for Ethernet only and offered no
way to change anything but joining a network. Scope agreed 2026-11-08 (hotspot
left out for now).

## Decisions

* **Data comes from NetworkManager's `GetManagedObjects` snapshot** that the
  page already fetches: IP4Config, IP6Config, ActiveConnection, wireless
  Bitrate and AccessPoint Frequency/HwAddress are in it. No new polling.
* **Profiles are edited as read-modify-write** (`GetSettings`, replace only the
  keys we own, `Update` with interactive authorization), like the Wi-Fi
  password update. Verified on a throwaway profile: an `Update` without
  `psk` keeps the stored secret, and `GetSettings` never returns it.
* **Unlock follows Services** (`systemd/actions.zig`): polkit
  `CheckAuthorization` for `org.freedesktop.NetworkManager.settings.modify.system`.
  The check runs without interaction when the page opens; where policy already
  allows (the default for an active local session) the page is simply unlocked
  and no button shows, otherwise an Unlock button asks with interaction.
  Proxy is per-user and never needs it.
* **Proxy** is not a NetworkManager concept (only a per-connection PAC URL).
  RediWM writes GSettings `org.gnome.system.proxy` (what GTK/GIO apps and
  Firefox's "system proxy" read; hand-declared GIO ABI) and exports
  `http_proxy`-style variables to apps it launches.

## Phases

1. Read-only details: Wi-Fi details card (SSID, security, signal, band/channel,
   link speed, BSSID, MAC), IPv6 and search domains for both, DHCP/manual.
2. Actions and editor: Forget, Disconnect, auto-connect; IP editor (IPv4/IPv6
   Automatic/Manual/Link-local/Disabled, DNS, MTU, metered); unlock.
3. Proxy page.
4. VPN (list, connect/disconnect, NM VPN + WireGuard) and airplane mode.

## Status

All four phases are built (2026-11-08). Airplane mode is an rfkill soft block
(`platform/rfkill.zig`) rather than an NM property so Bluetooth follows too; it
is not integration-tested because a test must never write the host's
`/dev/rfkill` (unit tests cover the event encoding). Hotspot, importing VPN
configurations, per-protocol proxy credentials and a NetworkManager secret
agent are left for later.

Tests: `zig build test-network` (parsing, profile round trip, proxy
environment), `tests/network_settings.py` (details, editing, forget, unlock,
VPN, proxy; against `tests/nm_fake.py`, with GSettings on a keyfile backend in
a scratch directory), and `tests/wifi_popup.py` for the older Wi-Fi paths.
