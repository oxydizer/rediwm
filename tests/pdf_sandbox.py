#!/usr/bin/env python3
"""Exercise the actual PDF parser's OS/Wayland sandbox and fail-closed path."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile

from ipc_client import IPCClient, ROOT, spawn_compositor, stop_process
from pdf_viewer import generate_fixture_pdf
from xwayland import wait_for, wayland_display_name


def run():
    with tempfile.TemporaryDirectory(prefix="rediwm-pdf-sandbox-") as directory:
        tmp = Path(directory)
        document = tmp / "document.pdf"
        generate_fixture_pdf(document)
        original = document.read_bytes()
        secret = tmp / "unrelated-secret"
        secret.write_text("must not be readable by the PDF parser")
        hook = tmp / "probe.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "tests/pdf_sandbox_hook.c"), "-lwayland-client", "-ldl",
                        "-o", str(hook)], check=True)
        font = subprocess.check_output(["fc-match", "-f", "%{file}", "sans"], text=True)
        compositor, log = spawn_compositor(
            tmp, config_content="[compositor]\nxwayland = false\n",
            renderer=os.environ.get("REDIWM_TEST_RENDERER", "pixman"),
            env_extra={"DBUS_SESSION_BUS_ADDRESS": "", "XDG_CACHE_HOME": str(tmp / "cache")})
        viewer = None
        try:
            with IPCClient(tmp) as ipc, secret.open("rb") as original_file, os.fdopen(
                    fcntl.fcntl(original_file.fileno(), fcntl.F_DUPFD_CLOEXEC, 100), "rb") as inherited:
                env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp),
                           WAYLAND_DISPLAY=wayland_display_name(tmp), LD_PRELOAD=str(hook),
                           REDIWM_PDF_TEST_DOCUMENT=str(document), REDIWM_PDF_TEST_SECRET=str(secret),
                           REDIWM_PDF_TEST_WRITE=str(tmp / "must-not-exist"), REDIWM_PDF_TEST_FONT=font,
                           REDIWM_PDF_TEST_FD=str(inherited.fileno()), REDIWM_PDF_TEST_PID=str(compositor.pid),
                           REDIWM_PDF_TEST_TOKEN="test-only-secret")
                for failure in (False, True):
                    case_env = dict(env)
                    if failure:
                        case_env["REDIWM_PDF_TEST_FAIL_POLICY"] = "1"
                    viewer_log = tmp / f"viewer-{failure}.log"
                    with viewer_log.open("w") as output:
                        viewer = subprocess.Popen(
                            [str(ROOT / "zig-out/bin/rediwm-pdf"), str(document)], env=case_env,
                            pass_fds=(inherited.fileno(),), stdin=subprocess.DEVNULL,
                            stdout=output, stderr=output)
                    if failure:
                        assert viewer.wait(timeout=10) != 0
                        text = viewer_log.read_text()
                        assert "SandboxUnavailable" in text, text
                        assert "PASS: PDF parser" not in text, text
                        print("PASS: sandbox setup failure refuses to invoke the PDF parser")
                    else:
                        def opened():
                            assert viewer.poll() is None, viewer_log.read_text()
                            return next((w for w in ipc.get_windows()
                                         if w["app_id"] == "rediwm-pdf" and "(1/2)" in w["title"]), None)
                        window = wait_for(opened, lambda: viewer_log.read_text())
                        assert window["sandbox"]["engine"] == "org.rediwm.pdf", window
                        assert window["sandbox"]["app_id"] == "rediwm-pdf", window
                        assert "PASS: PDF parser" in viewer_log.read_text(), viewer_log.read_text()
                        print(next(line for line in viewer_log.read_text().splitlines() if line.startswith("PASS:")))
                    stop_process(viewer)
                    viewer = None
                assert document.read_bytes() == original
                assert secret.read_text() == "must not be readable by the PDF parser"
                assert not (tmp / "must-not-exist").exists()
                assert compositor.poll() is None
                fifo = tmp / "not-a-regular-file"
                os.mkfifo(fifo)
                for path in (fifo, tmp):
                    rejected = subprocess.run(
                        [str(ROOT / "zig-out/bin/rediwm-pdf"), str(path)],
                        env=env, pass_fds=(inherited.fileno(),), stdin=subprocess.DEVNULL,
                        capture_output=True, text=True, timeout=5)
                    assert rejected.returncode != 0 and "CannotOpenRegularFile" in rejected.stderr, rejected
                    assert "PASS: PDF parser" not in rejected.stderr
                print("PASS: non-regular document paths rejected before parsing without blocking")
        except Exception:
            for path in tmp.glob("viewer-*.log"):
                print(path.read_text(errors="replace"))
            print((tmp / "compositor.log").read_text(errors="replace")[-2500:])
            raise
        finally:
            if viewer is not None:
                stop_process(viewer)
            stop_process(compositor)
            log.close()


if __name__ == "__main__":
    run()
