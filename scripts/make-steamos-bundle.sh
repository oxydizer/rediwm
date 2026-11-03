#!/bin/sh
# Build the working checkout in a disposable SteamOS 3.8 baseline container.
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$src/release"}
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)
engine=${REDIWM_CONTAINER_ENGINE:-podman}
image=localhost/rediwm-steamos-build:3.8
"$engine" build -t "$image" -f "$src/packaging/steamos/Containerfile" "$src/packaging/steamos"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
# Include local changes, but never host build outputs or caches.
tar -C "$src" --exclude=.git --exclude=.zig-cache --exclude=zig-out --exclude=release -cf - . | tar -C "$work" -xf -
"$engine" run --rm -v "$work:/work" -v "$out:/out" "$image" sh scripts/build-steamos-bundle.sh /out
