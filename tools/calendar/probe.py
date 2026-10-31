#!/usr/bin/env python3
"""Noninstalled Calendar Phase 0 probes; never connects to provider accounts."""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PACKAGES = {
    "native": ("sqlite3", "libical", "libcurl"),
    "eds": ("libecal-2.0", "libedataserver-1.2"),
    "keyring": ("libsecret-1",),
}


def run(argv, env, timeout=30):
    """Bound commands and kill their children as well if a compiler/probe stalls."""
    process = subprocess.Popen(argv, env=env, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # A compiler's parent may have exited while a child still owns its pipes.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)
        raise
    if process.returncode:
        raise RuntimeError(f"{Path(argv[0]).name} exited {process.returncode}: "
                           f"{stderr[-4000:] or stdout[-4000:]}")
    return stdout


def private_environment(root, prefix):
    # An allowlist keeps inherited display, bus, proxy, credential and EDS settings out.
    env = {"PATH": os.environ.get("PATH", os.defpath), "LC_ALL": "C.UTF-8", "TZ": "UTC"}
    for key, directory in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                           ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                           ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime"),
                           ("TMPDIR", "tmp")):
        path = root / directory
        path.mkdir(mode=0o700)
        env[key] = str(path)
    env.update(DBUS_SESSION_BUS_ADDRESS=f"unix:path={root}/bus",
               DBUS_SYSTEM_BUS_ADDRESS=f"unix:path={root}/no-system-bus",
               XDG_CONFIG_DIRS=str(root / "config"), XDG_DATA_DIRS=str(root / "data"),
               GSETTINGS_BACKEND="memory", GIO_USE_NETWORK_MONITOR="base")
    if prefix:
        # Relocate only the supplied EDS .pc files, never dependency .pc files.
        pkgdir = root / "pkgconfig"
        pkgdir.mkdir(mode=0o700)
        for source in (prefix / "lib/pkgconfig").glob("*.pc"):
            lines = []
            for line in source.read_text().splitlines():
                key, sep, value = line.partition("=")
                if sep and (value == "/usr" or value.startswith("/usr/")):
                    line = f"{key}={prefix}{value[4:]}"
                lines.append(line)
            (pkgdir / source.name).write_text("\n".join(lines) + "\n")
        env["PKG_CONFIG_PATH"] = str(pkgdir)
        env["LD_LIBRARY_PATH"] = f"{prefix}/lib:{prefix}/lib/evolution-data-server"
    return env


def inventory(env, prefix):
    packages = {}
    for name in dict.fromkeys(p for group in PACKAGES.values() for p in group):
        try:
            packages[name] = {"status": "available", "version": run(
                ["pkg-config", "--modversion", name], env).strip()}
        except (OSError, RuntimeError) as error:
            packages[name] = {"status": "unavailable", "detail": str(error)}
    modules = []
    module_roots = [prefix / "lib/evolution-data-server"] if prefix else [
        Path("/usr/lib/evolution-data-server"), Path("/usr/lib64/evolution-data-server"),
        Path("/usr/lib/x86_64-linux-gnu/evolution-data-server")]
    for directory in module_roots:
        if directory.exists():
            modules.extend(path.name for path in directory.rglob("*.so")
                           if "m365" in path.name or "caldav" in path.name)
    return {"packages": packages, "provider_modules": sorted(set(modules)),
            "tools": {name: shutil.which(name, path=env["PATH"]) is not None
                      for name in ("cc", "pkg-config", "dbus-daemon", "gdbus",
                                   "glib-compile-schemas")},
            "keyring_access": "not_tested", "provider_access": "not_tested"}


def compile_probe(name, packages, root, env, prefix):
    flags = shlex.split(run(["pkg-config", "--cflags", "--libs", *packages], env))
    executable = root / f"{name}-probe"
    extra = []
    if prefix:
        extra = [f"-Wl,-rpath-link,{prefix}/lib",
                 f"-Wl,-rpath-link,{prefix}/lib/evolution-data-server"]
    run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-g", "-O1",
         str(HERE / f"{name}_probe.c"), "-o", str(executable), *extra, *flags], env, 60)
    return executable


def local_probe(name, root, env, prefix, idle_seconds, available):
    needed = PACKAGES[name][:2]
    missing = [p for p in needed if available["packages"][p]["status"] != "available"]
    if missing:
        return {"status": "unavailable", "missing": missing}
    try:
        executable = compile_probe(name, needed, root, env, prefix)
        if name == "native":
            return json.loads(run([str(executable), str(root / "native.sqlite")], env))
        from eds_runtime import probe
        return probe(executable, root, env, prefix, idle_seconds, run)
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        return {"status": "fail", "detail": str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inventory", "local"))
    parser.add_argument("--backend", choices=("native", "eds", "all"), default="all")
    parser.add_argument("--eds-prefix", type=Path,
                        help="optional extracted EDS /usr directory; no packages are installed")
    parser.add_argument("--idle-seconds", type=float, default=3,
                        help="EDS per-thread context-switch sample, 1–30 seconds (default 3)")
    parser.add_argument("--output", type=Path, help="write a new private JSON report (never overwrite)")
    args = parser.parse_args()
    if not 1 <= args.idle_seconds <= 30:
        parser.error("--idle-seconds must be between 1 and 30")
    prefix = args.eds_prefix.resolve() if args.eds_prefix else None
    if prefix and not (prefix / "lib/pkgconfig/libecal-2.0.pc").is_file():
        parser.error("--eds-prefix must contain lib/pkgconfig/libecal-2.0.pc")
    if args.output and args.output.exists():
        parser.error("--output already exists; choose a new report path")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="rediwm-calendar-phase0-") as directory:
        root = Path(directory)
        env = private_environment(root, prefix)
        report = {"schema_version": 1, "scope": "local_dependency_prototype",
                  "backend_decision": "pending", "phase0_complete": False,
                  "inventory": inventory(env, prefix)}
        if args.command == "local":
            selected = ("native", "eds") if args.backend == "all" else (args.backend,)
            report["probes"] = {name: local_probe(name, root, env, prefix,
                                                 args.idle_seconds, report["inventory"])
                                for name in selected}
    output = json.dumps(report, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as destination:
            destination.write(output)
    print(output, end="")
    statuses = [p["status"] for p in report.get("probes", {}).values()]
    return 1 if "fail" in statuses else 2 if "unavailable" in statuses else 0


if __name__ == "__main__":
    raise SystemExit(main())
