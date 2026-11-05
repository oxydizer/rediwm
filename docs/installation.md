# Installation layouts and packaging

The source installer defaults to `/usr/local`. Choose another runtime prefix
with `sh scripts/install-session.sh --prefix=/usr --no-restart` (also accepted
by `scripts/install.sh`, which builds from source for this option).

For packaging, configure the runtime prefix separately from Zig's output tree:

```sh
zig build -Doptimize=ReleaseSafe -Dinstall-prefix=/usr --prefix zig-out/package
DESTDIR="$pkgdir" sh scripts/install-session-root.sh "$PWD" "$PWD/zig-out/package" yes
```

The final `yes` includes the optional display manager's systemd, sysusers,
tmpfiles and PAM files; use `no` to omit them. Staging needs no root and runs no
system commands or cache updates. Select the appropriate PAM policy for your
distribution with `REDIWM_PAM_PROFILE=arch` or `debian` (the source installer
selects Arch when `/etc/pam.d/system-local-login` exists, otherwise Debian). Packaging may instead
copy files from the output tree directly. Generated DM configuration and service
files are in `share/rediwm/`; do not install the unexpanded templates from `data/`.
`scripts/make-deb.sh` uses the prefix recorded in `zig-out/release-safe`.

`-Dinstall-prefix` defaults to `/usr/local`; `--prefix` selects only the build
output directory and never changes runtime paths. Binaries, private libraries
and data retain the relative `bin`, `lib/rediwm` and `share` layout. Supported
prefixes are absolute paths containing letters, digits, `/`, `_`, `-`, `+` and
`.` (no `.` or `..` components). Prebuilt releases retain their recorded prefix
and cannot be relocated by the installer.

`-Dsysconfdir` (default `/etc`, `/usr/local/etc` when targeting FreeBSD) is where
RediWM looks for its own system configuration: `rediwm/dm.conf`,
`rediwm/greeter.toml`, the `pam.d/rediwm` lock-screen policy and CUPS's
`cups/client.conf`. `-Drundir` (default `/run`, `/var/run` on FreeBSD) holds the
display manager's marker directory. Both follow the prefix's character rules.
The installers, units and tmpfiles still write `/etc` and `/run` (FreeBSD
packaging is phase 4 of [docs/plans/freebsd.md](plans/freebsd.md)).

System integration remains in `/etc`, `/usr/lib/{systemd/system,sysusers.d,tmpfiles.d}`
and `/usr/share/{wayland-sessions,polkit-1/actions,xdg-desktop-portal/portals}`,
under `DESTDIR` when staging. Runtime discovery of sibling executables and assets
remains relative to the running binary; privileged helper paths are fixed at
build time and match their polkit policy. Standard XDG and third-party executable
search paths still include `/usr/local` where appropriate.

Check both layouts with [tests/install_layout.py](../tests/install_layout.py)
(commands in its docstring).

## Arch Linux package

[packaging/arch/PKGBUILD](../packaging/arch/PKGBUILD) builds a `rediwm-git`
package from the `master` branch, following the layout above (`/usr` prefix,
Arch PAM profile, display-manager files included). It was contributed by Petar
Margetić. Build and install it with:

```sh
cd packaging/arch
makepkg -si
```

The package ships the display manager's service and PAM files but does not
enable the service or change the selected display manager. It conflicts with
and provides `rediwm`.
