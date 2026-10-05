#!/usr/bin/env python3
"""CLI v1 contract against an owned fake IPC socket; never executes actions.

The fixture requests specify the v1 wire format. Run after
`zig build`: python tests/msg.py [--binary /path/to/rediwm-msg].
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def invoke(binary, args, stdin=""):
    with tempfile.TemporaryDirectory(prefix="rediwm-msg-test-") as directory:
        path = Path(directory) / "ipc.sock"
        requests, failures = [], []
        done = threading.Event()
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(path))
            server.listen(1)
            server.settimeout(.05)

            def serve():
                try:
                    while not done.is_set():
                        try:
                            conn, _ = server.accept()
                            break
                        except socket.timeout:
                            continue
                    else:
                        return
                    with conn:
                        conn.settimeout(3)
                        reader = conn.makefile("rb")
                        request = reader.readline()
                        requests.append(json.loads(request))
                        # Screenshot saving is a local CLI operation too.
                        if "--save" in args:
                            reply = {"Ok": {"Screenshot": {"width": 1, "height": 1,
                                     "format": "png", "data": "eA=="}}}
                        else:
                            reply = {"Ok": "Handled"}
                        conn.sendall((json.dumps(reply) + "\n").encode())
                except Exception as error:
                    failures.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            try:
                expanded = [a.replace("$SAVE", str(Path(directory) / "saved.png")) for a in args]
                proc = subprocess.run([str(binary), "--socket", str(path), "--timeout", "1000",
                                       "--json", *expanded], input=stdin, text=True,
                                      capture_output=True, timeout=5)
            finally:
                done.set()
                worker.join(timeout=4)
            assert not worker.is_alive(), args
            assert not failures, (args, failures)
            saved = Path(directory) / "saved.png"
            return {"request": requests[0] if requests else None,
                    "code": proc.returncode,
                    "saved": saved.read_text() if saved.exists() else None}


def run(binary):
    cases = json.loads((ROOT / "tests/msg_v1.json").read_text())
    help_text = subprocess.run([str(binary), "--help"], capture_output=True,
                               text=True, check=True).stderr
    for case in cases:
        actual = invoke(binary, case["args"], case.get("stdin", ""))
        assert actual == case["expected"], (case["args"], case["expected"], actual)
        if actual["code"] == 0 and case["args"][0] not in ("--raw", "raw"):
            command = case["args"][1] if case["args"][0] == "action" else case["args"][0]
            assert command in help_text, f"missing help for {command}"
    assert "doctor" in help_text and "--save <PATH>" in help_text
    print(f"PASS: {len(cases)} CLI v1 contract cases and generated help")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/rediwm-msg")
    run(parser.parse_args().binary)
