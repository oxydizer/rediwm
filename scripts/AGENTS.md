# Releases and install

* **`install.sh` installs a prebuilt per-distro tarball** (`--build` compiles;
  running from a checkout implies `--build`). It must stay self-contained up to
  the download, since `curl | sh` has no repo yet. `make-release.sh` builds
  each tarball in a clean podman/docker container of its distro and installs
  it with the real `install.sh` in a fresh one; run it before publishing and
  read the verify step's output.
* **One tarball per distro, not per architecture-and-glibc.** Package ABIs
  differ (libjpeg is `.so.8` on Arch/Ubuntu, `.so.62` on Debian/Fedora with a
  different struct layout). A derivative uses its parent's tarball; if its
  libraries don't match, `unresolved_libs` (missing libs or too-new glibc
  symbol versions) or a failed package install falls back to a source build.
  A checksum mismatch never falls back: it dies.
* **`DEPENDS` is generated from the built binaries' `NEEDED` libraries**
  (`release-build.sh`), never hand-kept; only the extras (Xwayland, portals,
  Python, Mesa drivers) are listed by hand. Libraries bundled in `lib/rediwm`
  are excluded, and which ones get bundled depends on what the build container
  has installed, so never install the distro's own wlroots there.
* **Releases always use the pinned, patched wlroots** from `build-wlroots.sh`,
  whose recipe hash includes the script itself (editing even a comment
  rebuilds everyone's private prefix). `rediwm`'s RUNPATH picks up the build
  prefix when linking; `release-build.sh` scrubs it with patchelf and
  `release-verify.sh` rejects any `/work/` path.
* **CPU is `-Dcpu=x86_64_v2`.** Zig defaults to the build machine's CPU, which
  would put illegal instructions into every user's binary. Releases are x86_64
  only; other CPUs build from source.
* Checksums come from the same GitHub release as the tarballs, so they catch
  corruption, not a compromised release. Signing is not done yet.
