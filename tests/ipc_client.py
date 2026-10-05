#!/usr/bin/env python3
"""Shared Python IPC client and test fixture helpers for rediwm.

Supports typed JSON request envelopes with request IDs, state queries,
deterministic wait barriers (WaitFor, WaitForFrame), inspection tools,
and lifecycle management.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple, Union

ROOT = Path(__file__).resolve().parents[1]

# Synthetic input, screenshots and pixel reads are off unless [ipc] automation
# is set. Tests drive the compositor through them, so every compositor started
# from a process that imports this module inherits the switch.
os.environ.setdefault("REDIWM_IPC_AUTOMATION", "1")
# The desktop's built-in Home and Trash icons would sit in every pixel check.
os.environ.setdefault("REDIWM_DESKTOP_BUILTINS", "0")


class IPCError(Exception):
    """Raised when the compositor returns an Err or error payload."""
    pass


class IPCClient:
    """Synchronous IPC client for rediwm."""

    def __init__(self, socket_path: Optional[Union[str, Path]] = None, timeout: float = 10.0):
        self.socket_path: Optional[Path] = Path(socket_path) if socket_path else None
        self.timeout = timeout
        self.sock: Optional[socket.socket] = None
        self.reader = None
        self._request_id: int = 0

    def connect(self, socket_path: Optional[Union[str, Path]] = None, timeout: Optional[float] = None) -> IPCClient:
        if socket_path:
            self.socket_path = Path(socket_path)
        if timeout is not None:
            self.timeout = timeout

        if self.socket_path and self.socket_path.is_dir():
            search_dir = self.socket_path
            self.socket_path = None
        elif not self.socket_path:
            runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
            search_dir = Path(runtime_dir) if runtime_dir else Path("/tmp")
        else:
            search_dir = None

        if search_dir:
            deadline = time.monotonic() + self.timeout
            found = None
            while time.monotonic() < deadline:
                socks = list(search_dir.glob("rediwm-*.sock"))
                if socks:
                    found = socks[0]
                    break
                time.sleep(0.05)
            if not found:
                raise FileNotFoundError(f"No rediwm-*.sock found in {search_dir}")
            self.socket_path = found

        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.socket_path))
        self.reader = self.sock.makefile("r", encoding="utf-8")
        return self

    def close(self):
        if self.reader:
            try:
                self.reader.close()
            except Exception:
                pass
            self.reader = None
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def __enter__(self) -> IPCClient:
        if not self.sock:
            self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    def send_raw(self, line: str, timeout: Optional[float] = None) -> Dict[str, Any]:
        """Send raw JSON line and read a single response line."""
        assert self.sock is not None, "Not connected"
        if not line.endswith("\n"):
            line += "\n"
        old_timeout = self.sock.gettimeout()
        if timeout is not None:
            self.sock.settimeout(timeout)
        try:
            self.sock.sendall(line.encode("utf-8"))
            resp_line = self.reader.readline()
            if not resp_line:
                raise EOFError("Compositor closed IPC connection")
            return json.loads(resp_line)
        finally:
            if timeout is not None:
                self.sock.settimeout(old_timeout)

    def request(
        self,
        query: Optional[str] = None,
        action: Optional[str] = None,
        params: Optional[Dict[str, Any]] = None,
        raw_cmd: Optional[Dict[str, Any]] = None,
        timeout: Optional[float] = None,
    ) -> Any:
        """Send a v1 command and return the unwrapped 'Ok' payload."""
        if raw_cmd is not None:
            payload = raw_cmd
        else:
            if (query is None) == (action is None):
                raise ValueError("Specify exactly one query or action")
            payload = {"version": 1, "id": self._next_id(), "command": query or action}
            if params is not None:
                payload["params"] = params

        line = json.dumps(payload)
        resp = self.send_raw(line, timeout=timeout)

        if "Err" in resp:
            raise IPCError(resp["Err"])
        if "error" in resp:
            raise IPCError(resp["error"])
        if "Ok" not in resp:
            raise IPCError(f"Malformed response missing Ok/Err: {resp}")

        ok_val = resp["Ok"]
        # Unwrap single-key dicts (e.g. {"Windows": [...]}) if matching query/action
        if isinstance(ok_val, dict) and len(ok_val) == 1:
            key = next(iter(ok_val.keys()))
            return ok_val[key]
        return ok_val

    def query(self, name: str, params: Optional[Dict[str, Any]] = None, timeout: Optional[float] = None) -> Any:
        return self.request(query=name, params=params, timeout=timeout)

    def action(self, name: str, params: Optional[Dict[str, Any]] = None, timeout: Optional[float] = None) -> Any:
        return self.request(action=name, params=params, timeout=timeout)

    # --- Convenience Query Methods ---

    def get_version(self) -> str:
        return self.query("version")

    def get_capabilities(self) -> List[str]:
        return self.query("capabilities")

    def describe(self) -> Dict[str, Any]:
        return self.query('describe_ipc')

    def get_state(self) -> Dict[str, Any]:
        return self.query('get_state')

    def get_windows(self) -> List[Dict[str, Any]]:
        res = self.query("windows")
        return res if isinstance(res, list) else []

    def get_outputs(self) -> List[Dict[str, Any]]:
        res = self.query("outputs")
        return res if isinstance(res, list) else []

    def get_focused_window(self) -> Optional[Dict[str, Any]]:
        return self.query("focused_window")

    def get_workspaces(self) -> List[Dict[str, Any]]:
        res = self.query("workspaces")
        return res if isinstance(res, list) else []

    def get_window_debug(self, window_id: int) -> Dict[str, Any]:
        return self.query('get_window_debug', {"id": window_id})

    def get_shell_state(self, output: Optional[str] = None) -> Dict[str, Any]:
        params = {"output": output} if output else None
        return self.query('get_shell_state', params)

    def get_input_state(self) -> Dict[str, Any]:
        return self.query('get_input_state')

    def hit_test(self, x: int, y: int, output: Optional[str] = None) -> Dict[str, Any]:
        params: Dict[str, Any] = {"x": x, "y": y}
        if output:
            params["output"] = output
        return self.query("hit_test", params)

    def get_scene_tree(self, max_depth: Optional[int] = None) -> Dict[str, Any]:
        params = {"max_depth": max_depth} if max_depth is not None else None
        return self.query('get_scene_tree', params)

    def get_layer_surfaces(self) -> List[Dict[str, Any]]:
        res = self.query('get_layer_surfaces')
        if isinstance(res, dict) and "surfaces" in res:
            return res["surfaces"]
        return res if isinstance(res, list) else []

    def get_widget_tree(self, panel: str) -> Dict[str, Any]:
        return self.query('get_widget_tree', {"panel": panel})

    def list_panels(self) -> Dict[str, Any]:
        return self.query("list_panels")

    def get_config(self) -> Dict[str, Any]:
        return self.query('get_config_status')

    def get_runtime(self) -> Dict[str, Any]:
        return self.query('get_runtime_info')

    def get_perf(self) -> Dict[str, Any]:
        return self.query('get_performance_stats')

    def reset_perf(self) -> Any:
        return self.action('reset_performance_stats')

    def get_night_light(self) -> Dict[str, Any]:
        return self.query("get_night_light")

    def set_night_light_clock(self, unix_seconds: Optional[int] = None) -> Any:
        return self.action("set_night_light_clock", {"unix_seconds": unix_seconds})

    # --- Wait Barriers ---

    def wait_for(
        self,
        condition: Union[str, Dict[str, Any]],
        timeout_ms: int = 5000,
        window_id: Optional[int] = None,
        app_id: Optional[str] = None,
        title: Optional[str] = None,
        output: Optional[str] = None,
        path: Optional[str] = None,
        field: Optional[str] = None,
        equals: Any = None,
        panel: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Wait for a compositor condition.

        Raises TimeoutError if the condition was not met within timeout_ms.
        """
        cond_val: Any = condition
        if isinstance(condition, str):
            if condition == "window_mapped":
                cond_dict: Dict[str, Any] = {}
                if window_id is not None:
                    cond_dict["id"] = window_id
                if app_id is not None:
                    cond_dict["app_id"] = app_id
                if title is not None:
                    cond_dict["title"] = title
                cond_val = {"window_mapped": cond_dict}
            elif condition == "window_closed":
                assert window_id is not None, "window_closed requires window_id"
                cond_val = {"window_closed": {"id": window_id}}
            elif condition == "window_focused":
                cond_val = {"window_focused": {"id": window_id} if window_id else {}}
            elif condition == "window_geometry_settled":
                assert window_id is not None, "window_geometry_settled requires window_id"
                cond_val = {"window_geometry_settled": {"id": window_id}}
            elif condition == "output_frame":
                cond_val = {"output_frame": {"output": output} if output else {}}
            elif condition == "widget_present":
                assert path is not None, "widget_present requires path"
                cond_val = {"widget_present": {"path": path}}
            elif condition == "widget_absent":
                assert path is not None, "widget_absent requires path"
                cond_val = {"widget_absent": {"path": path}}
            elif condition == "widget_state":
                assert path is not None and field is not None, "widget_state requires path and field"
                cond_val = {"widget_state": {"path": path, "field": field, "equals": equals}}
            elif condition == "panel_settled":
                assert panel is not None, "panel_settled requires panel"
                cond_val = {"panel_settled": {"panel": panel}}
            else:
                cond_val = condition

        params: Dict[str, Any] = {
            "condition": cond_val,
            "timeout_ms": timeout_ms,
        }
        # socket read timeout should allow compositor timeout + 2s buffer
        sock_timeout = (timeout_ms / 1000.0) + 2.0
        res = self.action("wait_for", params, timeout=sock_timeout)
        if isinstance(res, dict) and res.get("timed_out"):
            elapsed = res.get("elapsed_ms", timeout_ms)
            raise TimeoutError(f"Wait condition '{condition}' timed out after {elapsed}ms")
        return res

    def wait_for_widget_present(self, path: str, timeout_ms: int = 5000) -> Dict[str, Any]:
        return self.wait_for("widget_present", timeout_ms=timeout_ms, path=path)

    def wait_for_widget_absent(self, path: str, timeout_ms: int = 5000) -> Dict[str, Any]:
        return self.wait_for("widget_absent", timeout_ms=timeout_ms, path=path)

    def wait_for_widget_state(self, path: str, field: str, equals: Any, timeout_ms: int = 5000) -> Dict[str, Any]:
        return self.wait_for("widget_state", timeout_ms=timeout_ms, path=path, field=field, equals=equals)

    def wait_for_panel_settled(self, panel: str, timeout_ms: int = 5000) -> Dict[str, Any]:
        return self.wait_for("panel_settled", timeout_ms=timeout_ms, panel=panel)

    def wait_for_frame(self, timeout_ms: int = 5000, output: Optional[str] = None) -> Dict[str, Any]:
        """Wait for the next composited frame barrier."""
        params: Dict[str, Any] = {"timeout_ms": timeout_ms}
        if output:
            params["output"] = output
        sock_timeout = (timeout_ms / 1000.0) + 2.0
        res = self.action("wait_for_frame", params, timeout=sock_timeout)
        if isinstance(res, dict) and res.get("timed_out"):
            elapsed = res.get("elapsed_ms", timeout_ms)
            raise TimeoutError(f"Wait for frame timed out after {elapsed}ms")
        return res

    # --- Input Actions ---

    def move_cursor(self, x: int, y: int, output: Optional[str] = None) -> Any:
        params: Dict[str, Any] = {"x": x, "y": y}
        if output:
            params["output"] = output
        return self.action("move_cursor", params)

    def move_cursor_relative(self, dx: int, dy: int) -> Any:
        return self.action("move_cursor_relative", {"dx": dx, "dy": dy})

    def pointer_button(self, button: int, pressed: bool) -> Any:
        return self.action("pointer_button", {"button": button, "pressed": pressed})

    def click(self, button: int = 0x110) -> Any:
        return self.action("click", {"button": button})

    def click_at(self, x: int, y: int, button: int = 0x110, output: Optional[str] = None) -> Any:
        self.move_cursor(x, y, output)
        return self.click(button)

    def click_widget(
        self,
        path: str,
        button: Optional[int] = None,
        at: Optional[Union[float, List[float], Tuple[float, float], Dict[str, float]]] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"path": path}
        if button is not None:
            params["button"] = button
        if at is not None:
            params["at"] = at
        return self.action("click_widget", params)

    def hover_widget(
        self,
        path: str,
        at: Optional[Union[float, List[float], Tuple[float, float], Dict[str, float]]] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {"path": path}
        if at is not None:
            params["at"] = at
        return self.action("hover_widget", params)

    def scroll(self, dx: float, dy: float) -> Any:
        return self.action("scroll", {"dx": dx, "dy": dy})

    def key(self, keycode: int, pressed: bool) -> Any:
        return self.action("key", {"keycode": keycode, "pressed": pressed})

    def key_press(self, key: str) -> Any:
        return self.action("key_press", {"key": key})

    def key_down_up(self, keycode: int) -> None:
        self.key(keycode, True)
        self.key(keycode, False)

    def type_text(self, text: str) -> Any:
        return self.action("type_text", {"text": text})

    def drag(self, from_x: int, from_y: int, to_x: int, to_y: int, button: int = 0x110, output: Optional[str] = None) -> Any:
        params: Dict[str, Any] = {
            "from_x": from_x, "from_y": from_y,
            "to_x": to_x, "to_y": to_y,
            "button": button,
        }
        if output:
            params["output"] = output
        return self.action("drag", params)

    # --- Window & Panel Actions ---

    def maximize(self, window_id: int) -> Any:
        return self.action('maximize_window', {"id": window_id})

    def minimize(self, window_id: int) -> Any:
        return self.action('minimize_window', {"id": window_id})

    def restore(self, window_id: int) -> Any:
        return self.action('restore_window', {"id": window_id})

    def fullscreen(self, window_id: int, output: Optional[str] = None) -> Any:
        params: Dict[str, Any] = {"id": window_id}
        if output:
            params["output"] = output
        return self.action('fullscreen_window', params)

    def set_zoom(self, window_id: int, percent: int) -> Any:
        return self.action("set_window_zoom", {"id": window_id, "percent": percent})

    def focus_window(self, window_id: int) -> Any:
        return self.action("focus_window", {"id": window_id})

    def close_window(self, window_id: Optional[int] = None) -> Any:
        params = {"id": window_id} if window_id is not None else None
        return self.action("close_window", params)

    def open_start_menu(self) -> Any:
        return self.action("open_start_menu")

    def open_control_center(self) -> Any:
        return self.action("open_control_center")

    def open_power_menu(self) -> Any:
        return self.action("open_power_menu")

    def close_panel(self, panel: str) -> Any:
        return self.action("close_panel", {"panel": panel})

    def reload_config(self) -> Any:
        return self.action('reload_config')

    def launch(self, desktop_id: str) -> Any:
        return self.action('launch_app', {"desktop_id": desktop_id})

    # --- Captures & Buffers ---

    def screenshot(
        self,
        path: Optional[str] = None,
        output: Optional[str] = None,
        window_id: Optional[int] = None,
        mode: Optional[str] = None,
        include_cursor: bool = False,
        crop: Optional[Dict[str, int]] = None,
        crop_space: Optional[str] = None,
    ) -> Dict[str, Any]:
        params: Dict[str, Any] = {}
        if path:
            params["path"] = path
        if output:
            params["output"] = output
        if window_id is not None:
            params["window_id"] = window_id
        if mode:
            params["mode"] = mode
        if include_cursor:
            params["include_cursor"] = True
        if crop:
            params["crop"] = crop
        if crop_space:
            params["crop_space"] = crop_space
        return self.action("screenshot", params)

    def dump_buffer(self, target: str, window_id: Optional[int] = None, output: Optional[str] = None) -> Dict[str, Any]:
        params: Dict[str, Any] = {"target": target}
        if window_id is not None:
            params["window_id"] = window_id
        if output:
            params["output"] = output
        return self.action("dump_buffer", params)

    def sample_pixels(self, x: int, y: int, width: int = 1, height: int = 1, output: Optional[str] = None) -> Dict[str, Any]:
        params: Dict[str, Any] = {"x": x, "y": y, "width": width, "height": height}
        if output:
            params["output"] = output
        return self.action("sample_pixels", params)

    def get_notifications(self) -> Dict[str, Any]:
        return self.query("get_notifications")

    def dismiss_notification(self, notification_id: int) -> Any:
        return self.action("dismiss_notification", {"id": notification_id})

    def invoke_notification_action(self, notification_id: int, action_key: str = "default") -> Any:
        return self.action("invoke_notification_action", {"id": notification_id, "action_key": action_key})

    def set_dnd(self, enabled: bool) -> Any:
        return self.action("set_dnd", {"enabled": enabled})

    def clear_notifications(self, which: str = "all") -> Any:
        return self.action("clear_notifications", {"which": which})



def spawn_compositor(
    tmp_dir: Path,
    scale: str = "1",
    outputs: str = "1",
    config_content: str = "",
    renderer: str = "pixman",
    env_extra: Optional[Dict[str, str]] = None,
) -> Tuple[subprocess.Popen, Any]:
    """Spawn a headless rediwm compositor instance."""
    env = dict(
        os.environ,
        XDG_RUNTIME_DIR=str(tmp_dir),
        WLR_BACKENDS="headless",
        WLR_HEADLESS_OUTPUTS=str(outputs),
        WLR_RENDERER=renderer,
        REDIWM_SCALE=str(scale),
        # Opening the power menu queries CanPowerOff/CanReboot/CanSuspend
        # (session/power.zig's Manager.probeCapabilities()). Without this,
        # a test compositor would reach *this machine's* real system bus and
        # logind, making test behavior depend on real host policy — exactly
        # what plan-power-session.md's tests are required to never do.
        # A test that wants a real (private, mocked) logind, like
        # tests/power.py, overrides this via env_extra below.
        DBUS_SYSTEM_BUS_ADDRESS="unix:path=/nonexistent-rediwm-test-system-bus",
        REDIWM_IPC_AUTOMATION="1",
        REDIWM_DESKTOP_BUILTINS="0",
        # Autosaved layouts and remembered window sizes stay out of the
        # host's state (the autosave restore would also move test windows).
        XDG_STATE_HOME=str(tmp_dir / "state"),
    )
    config_path = tmp_dir / "rediwm-config.toml"
    config_path.write_text(config_content)
    env["REDIWM_CONFIG"] = str(config_path)
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("REDIWM_SOCKET", None)
    if env_extra:
        env.update(env_extra)

    log_file = (tmp_dir / "compositor.log").open("w")
    proc = subprocess.Popen(
        [str(ROOT / "zig-out/bin/rediwm")],
        env=env,
        stdout=log_file,
        stderr=log_file,
    )
    return proc, log_file


def stop_process(process: subprocess.Popen) -> None:
    """Terminate and clean up compositor process."""
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
