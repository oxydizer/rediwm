# wlroots patches

`0001-repair-window-titles.patch` repairs invalid bytes in xdg-toplevel titles
with `?` rather than disconnecting the client. Valid Unicode is unchanged.
The repair never increases the title's byte length, so forwarding a long title
cannot overflow Wayland's message-size limit.
App IDs and other protocol requests keep their upstream behavior. wlroots
validates titles before emitting `set_title`, so RediWM's title listener cannot
implement this policy itself.

`scripts/build-wlroots.sh` applies these patches to the checksummed wlroots
release. Its build cache includes the patch contents. To enable the policy,
including on systems that already package wlroots:

```sh
scripts/build-wlroots.sh "$PWD/zig-out/wlroots"
zig build -Dwlroots-prefix="$PWD/zig-out/wlroots"
umask 077
python3 tests/window_titles.py
```

Keep `-Dwlroots-prefix` on subsequent builds. The resulting binaries bundle
the patched library in `lib/rediwm`; the system wlroots package is unchanged.
Builds without a private prefix retain the system library's title policy.
Release tarballs (`scripts/make-release.sh`) are always built this way, so the
policy and the exact wlroots version are the same on every distro.
