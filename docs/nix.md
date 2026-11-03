# Nix and NixOS

The flake packages RediWM and its apps for `x86_64-linux`, using Zig 0.17 and
the same patched wlroots 0.20.2 as the distro releases. `flake.lock` pins
Nixpkgs; Zig's source dependencies are fetched separately with a fixed hash,
so the compilation step needs no network access.

## NixOS session

Add RediWM as an input to your system flake:

```nix
inputs.rediwm.url = "github:oxydizer/rediwm";
```

Include the module in the `modules` list of your `nixosSystem`:

```nix
rediwm.nixosModules.default
{
  programs.rediwm.enable = true;
}
```

Here `rediwm` is the flake input passed to your `outputs` function. Keep the
display manager you already use. Rebuild your system, log out, and select
**RediWM** at login. The module registers the session, enables the graphical
desktop prerequisites, configures portals and polkit, and installs a PAM
policy for the built-in lock screen. It does not select a default session.

Keep RediWM's own Nixpkgs pin initially: older Nixpkgs versions may not have
Zig 0.17 or the dependencies needed by wlroots 0.20. Override
`programs.rediwm.package` if you need a custom package.

The NixOS portal service uses its declarative configuration. Screen sharing
defaults to RediWM's picker and 30 fps; override these through
`xdg.portal.wlr.settings.screencast`. These xdpw settings also apply to other
wlroots sessions using the same service.

This first package supports RediWM under an existing display manager.
`rediwm-dm`, the account-management helper and the installer restart tool are
not installed. Manage users and login services through NixOS; RediWM's Users
settings cannot perform privileged account edits in this package. Updating
the package takes effect after logging out and back in.

## Build or try a nested session

Enable Nix's `nix-command` and `flakes` experimental features. From a checkout:

```sh
nix build
./result/bin/rediwm-msg --help
WLR_BACKENDS=wayland ./result/bin/rediwm
```

Run the last command inside an existing Wayland session. For a login session,
use the NixOS module: installing just the package does not configure PAM or
system services. Nix on other Linux distributions can build the package, but
host graphics-driver and login integration are outside this module's scope.

There is no RediWM binary cache configured yet. Nix uses cached dependencies
where available and builds RediWM and its patched wlroots locally.

## Maintenance and checks

```sh
nix flake check --print-build-logs
nix build --print-build-logs
```

The checks build the package and evaluate the NixOS module's session, portal,
polkit and PAM configuration. The GitHub Nix workflow runs them independently
of `scripts/make-release.sh`; Nix packages do not need a distro tarball.
Real display-manager login, unlock, Xwayland and browser screen sharing still
need a NixOS session acceptance check.

When changing `build.zig.zon` dependencies, set the `zigDeps` hash in
`nix/package.nix` (nixpkgs' `zig.fetchDeps`) to `""`, build
`nix build .#rediwm.zigDeps`, then replace it with the reported actual hash.
Keep `nix/wlroots.nix` aligned with `scripts/build-wlroots.sh` and the patches
in `patches/wlroots/`. Update Nixpkgs deliberately with
`nix flake update nixpkgs`, then rerun the checks.

Nix-specific runtime path substitutions live in `nix/runtime-paths.nix` and
fail if their source text changes. Privileged helpers use `platform.tool`'s
trusted directories, with `/run/wrappers/bin` and the packaged systemd's
`bin` directory searched first. Ordinary helpers such as `locale` and
`paplay` come from the package wrapper's `PATH`. The PDF sandbox grants
access only to specific font and Poppler data directories, not the whole
Nix store.
