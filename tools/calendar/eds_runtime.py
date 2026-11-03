"""Private local-only EDS runtime for probe.py; no host service activation."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import time
from xml.sax.saxutils import escape


def location(prefix, relative, alternatives=()):
    candidates = [prefix / relative] if prefix else [Path("/usr") / relative, *alternatives]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise RuntimeError(f"EDS runtime file missing: {relative}")


def configure(root, env, prefix, run):
    registry = location(prefix, "lib/evolution-source-registry", (
        Path("/usr/libexec/evolution-source-registry"),))
    factory = location(prefix, "lib/evolution-calendar-factory", (
        Path("/usr/libexec/evolution-calendar-factory"),))
    backend = location(prefix, "lib/evolution-data-server/calendar-backends/libecalbackendfile.so", (
        Path("/usr/lib64/evolution-data-server/calendar-backends/libecalbackendfile.so"),
        Path("/usr/lib/x86_64-linux-gnu/evolution-data-server/calendar-backends/libecalbackendfile.so"),))
    schemas = location(prefix, "share/glib-2.0/schemas")
    schema_dir = root / "schemas"
    schema_dir.mkdir(mode=0o700)
    # Compile EDS schemas alone; no dconf or host settings are used.
    for path in schemas.glob("*.gschema.xml"):
        if "evolution" in path.name.lower():
            shutil.copyfile(path, schema_dir / path.name)
    run(["glib-compile-schemas", str(schema_dir)], env)
    local_modules = root / "local-modules"
    local_modules.mkdir(mode=0o700)
    (local_modules / backend.name).symlink_to(backend)
    empty_modules = root / "empty-modules"
    empty_modules.mkdir(mode=0o700)
    env = dict(env, EDS_TESTING="1", EDS_REGISTRY_MODULES=str(empty_modules),
               EDS_CALENDAR_MODULES=str(local_modules), GSETTINGS_SCHEMA_DIR=str(schema_dir))
    config = root / "bus.conf"
    config.write_text(f"""<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path={escape(str(root / 'bus'))}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="{os.getuid()}"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
""")
    return registry, factory, config, env


def stop(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=5)
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    finally:
        # Descendants may outlive an already-exited parent or ignore SIGTERM.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait(timeout=5)


@contextmanager
def services(registry, factory, config, root, env, run, stage):
    processes, logs = {}, []
    try:
        commands = (
            ("bus", ["dbus-daemon", "--nofork", "--print-address=1", f"--config-file={config}"]),
            ("registry", [str(registry), "--disable-migration"]),
            ("calendar", [str(factory), "--keep-running", "--backend-per-process=0"]),
        )
        for name, argv in commands:
            log = (root / f"{stage}-{name}.log").open("w+")
            logs.append(log)
            processes[name] = subprocess.Popen(argv, env=env,
                                                stdout=subprocess.PIPE if name == "bus" else log,
                                                stderr=log, text=True, start_new_session=True)
            if name == "bus":
                pipe = processes[name].stdout
                if not select.select([pipe], [], [], 10)[0]:
                    raise RuntimeError("private D-Bus readiness timed out")
                address = pipe.readline().strip()
                pipe.close()
                if not address.startswith(env["DBUS_SESSION_BUS_ADDRESS"] + ",guid="):
                    raise RuntimeError("private D-Bus failed to report its address")
            else:
                bus_name = "org.gnome.evolution.dataserver." + (
                    "Sources5" if name == "registry" else "Calendar8")
                run(["gdbus", "wait", "--address", env["DBUS_SESSION_BUS_ADDRESS"],
                     "--timeout", "10", bus_name], env, 15)
        yield processes
    except Exception as error:
        details = []
        for log in logs:
            log.flush()
            log.seek(0)
            details.append(f"{Path(log.name).name}: {log.read()[-2000:]}")
        raise RuntimeError(f"{error}\n" + "\n".join(details)) from error
    finally:
        try:
            errors = []
            for process in reversed(list(processes.values())):
                try:
                    stop(process)
                except (OSError, subprocess.TimeoutExpired) as error:
                    errors.append(str(error))
            if errors:
                raise RuntimeError("private service cleanup failed: " + "; ".join(errors))
        finally:
            for log in logs:
                log.close()


def stats(processes):
    result = {}
    for name, process in processes.items():
        if process.poll() is not None:
            raise RuntimeError(f"{name} exited during idle measurement")
        base = Path(f"/proc/{process.pid}")
        if not base.exists():
            return None  # Linux-only optional observation.
        memory = {}
        try:
            for line in (base / "smaps_rollup").read_text().splitlines():
                key, _, value = line.partition(":")
                if key in ("Rss", "Pss", "Private_Clean", "Private_Dirty"):
                    memory[key + "_kib"] = int(value.split()[0])
        except (FileNotFoundError, PermissionError):
            pass
        threads = {}
        for task in (base / "task").iterdir():
            try:
                status = dict(line.split(":", 1) for line in (task / "status").read_text().splitlines())
                threads[task.name] = {
                    "name": status["Name"].strip(),
                    "voluntary": int(status["voluntary_ctxt_switches"]),
                    "involuntary": int(status["nonvoluntary_ctxt_switches"]),
                }
            except FileNotFoundError:
                continue
        result[name] = {"memory": memory, "threads": threads}
    return result


def idle_sample(processes, seconds):
    before = stats(processes)
    start = time.monotonic()
    time.sleep(seconds)
    after = stats(processes)
    if before is None or after is None:
        return {"status": "unavailable", "reason": "requires Linux procfs"}
    result = {"seconds": round(time.monotonic() - start, 3), "processes": {}}
    for name, current in after.items():
        previous = before[name]["threads"]
        threads = []
        for tid, values in current["threads"].items():
            if tid in previous:
                threads.append({"name": values["name"],
                                "voluntary_delta": values["voluntary"] - previous[tid]["voluntary"],
                                "involuntary_delta": values["involuntary"] - previous[tid]["involuntary"]})
        result["processes"][name] = {"memory": current["memory"], "threads": threads,
                                     "new_threads": len(current["threads"].keys() - previous.keys()),
                                     "exited_threads": len(previous.keys() - current["threads"].keys())}
    return result


def probe(executable, root, env, prefix, idle_seconds, run):
    registry, factory, config, env = configure(root, env, prefix, run)
    with services(registry, factory, config, root, env, run, "write"):
        written = json.loads(run([str(executable), "write", str(root)], env))
    # A fresh private bus and fresh EDS processes must read the same on-disk state.
    with services(registry, factory, config, root, env, run, "read") as processes:
        restored = json.loads(run([str(executable), "read", str(root)], env))
        time.sleep(1)  # Allow client-disconnect work to settle before measuring.
        idle = idle_sample(processes, idle_seconds)
    return {"status": "pass", "write": written, "after_service_restart": restored,
            "runtime": "local module only; backend-per-process=0; no activation services",
            "idle": idle, "provider_qualification": False}
