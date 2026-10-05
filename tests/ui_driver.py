"""High-level UI automation test driver for RediWM integration tests.

Provides helper methods for finding widgets, clicking, hovering, and waiting
deterministically for widget state changes and panel settlement barriers.
"""
import time
from typing import Any, Dict, List, Optional, Union
from ipc_client import IPCClient


class UIDriver:
    def __init__(self, ipc: IPCClient):
        self.ipc = ipc

    def widgets(self, panel: str = "control_center") -> List[Dict[str, Any]]:
        """Return the list of widgets in the given panel."""
        try:
            res = self.ipc.get_widget_tree(panel)
            return res.get("widgets", [])
        except Exception:
            return []

    def scroll_into_view(self, name: str, panel: str = "control_center", attempts: int = 30) -> Dict[str, Any]:
        """Scroll the panel's content until the widget named `name` is fully
        visible, and return it with its new box."""
        # The wheel direction depends on scroll settings, so learn it: flip
        # whenever a step moves the widget away from the viewport.
        step = -130
        last_distance = None
        for _ in range(attempts):
            tree = self.widgets(panel)
            widget = next(w for w in tree if w["name"] == name)
            if widget["visible"] and not widget["clipped"]:
                return widget
            viewport = next(w for w in tree if w["role"] == "scroll_container")
            below = widget["box"]["y"] > viewport["box"]["y"]
            distance = abs(widget["box"]["y"] - viewport["box"]["y"])
            if last_distance is not None and distance >= last_distance:
                step = -step
            last_distance = distance
            area = viewport["global_box"]
            # The viewport centre may be over a nested scroll container
            # (Appearance's wallpaper strip). Its trailing gutter belongs
            # to this container, so the wheel reaches the intended scroll.
            self.ipc.move_cursor(area["x"] + area["width"] - 8, area["y"] + area["height"] // 2)
            self.ipc.scroll(0, step if below else -step)
            time.sleep(.3)
        raise AssertionError(f"could not scroll {name} into view")

    def find(
        self,
        target: str,
        panel: Optional[str] = None,
        role: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Find a widget by path, label, name, or semantic_id.

        If panel is not specified and target has no slash, queries open panels
        from list_panels and searches each one.
        Raises LookupError if the widget is not found.
        """
        candidate_panels: List[str] = []
        if panel is not None:
            candidate_panels = [panel]
        elif "/" in target:
            prefix, _ = target.split("/", 1)
            candidate_panels = [prefix]
        else:
            try:
                panels_res = self.ipc.list_panels()
                plist = panels_res.get("panels", panels_res) if isinstance(panels_res, dict) else panels_res
                candidate_panels = [p["name"] for p in plist if isinstance(p, dict) and p.get("open", False)]
            except Exception:
                candidate_panels = ["control_center", "start_menu", "power_menu"]

        subpath = target.split("/", 1)[1] if "/" in target else target

        # 1. Match full path
        for p_name in candidate_panels:
            for w in self.widgets(p_name):
                if role is not None and w.get("role") != role:
                    continue
                if w.get("path") == target:
                    return w

        # 2. Match name
        for p_name in candidate_panels:
            for w in self.widgets(p_name):
                if role is not None and w.get("role") != role:
                    continue
                if w.get("name") in (target, subpath):
                    return w

        # 3. Match label
        for p_name in candidate_panels:
            for w in self.widgets(p_name):
                if role is not None and w.get("role") != role:
                    continue
                if w.get("label") in (target, subpath):
                    return w

        # 4. Match semantic_id
        for p_name in candidate_panels:
            for w in self.widgets(p_name):
                if role is not None and w.get("role") != role:
                    continue
                if w.get("semantic_id") in (target, subpath):
                    return w

        raise LookupError(f"Widget '{target}' not found in panels {candidate_panels}")

    def resolve_path(self, target: Union[str, Dict[str, Any]], panel: Optional[str] = None) -> str:
        """Resolve a target to a full widget path string."""
        if isinstance(target, dict):
            if "path" in target and target["path"]:
                return target["path"]
            if "name" in target and target["name"]:
                target_str = target["name"]
            elif "label" in target and target["label"]:
                target_str = target["label"]
            elif "semantic_id" in target and target["semantic_id"]:
                target_str = target["semantic_id"]
            else:
                raise ValueError(f"Widget dict has no path, name, label, or semantic_id: {target}")
        else:
            target_str = target

        if "/" in target_str or target_str in ("control_center", "start_menu", "power_menu", "taskbar", "polkit_dialog"):
            return target_str

        # If panel is specified, we can try finding it or prepend panel name
        if panel is not None:
            try:
                node = self.find(target_str, panel=panel)
                if node.get("path"):
                    return node["path"]
            except LookupError:
                pass
            return f"{panel}/{target_str}"

        # Otherwise find across open panels
        try:
            node = self.find(target_str)
            if node.get("path"):
                return node["path"]
        except LookupError:
            pass

        return target_str

    def click(
        self,
        target: Union[str, Dict[str, Any]],
        panel: Optional[str] = None,
        at: Optional[Dict[str, float]] = None,
        fraction: Optional[float] = None,
        button: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Click a widget by path, name, or node dict with fractional positioning."""
        at_coord = at
        if at_coord is None and fraction is not None:
            at_coord = {"x": fraction, "y": 0.5}

        try:
            path = self.resolve_path(target, panel=panel)
            return self.ipc.click_widget(path=path, at=at_coord, button=button)
        except Exception:
            if isinstance(target, dict):
                fx = at_coord["x"] if at_coord and "x" in at_coord else 0.5
                fy = at_coord["y"] if at_coord and "y" in at_coord else 0.5
                gx, gy = None, None
                if target.get("global_box"):
                    b = target["global_box"]
                    gx = round(b["x"] + b["width"] * fx)
                    gy = round(b["y"] + b["height"] * fy)
                elif target.get("box"):
                    p_name = panel or (target.get("path", "").split("/")[0] if "/" in target.get("path", "") else "control_center")
                    shell_st = self.ipc.get_shell_state()
                    p_box = shell_st.get(p_name, {}).get("box", {"x": 0, "y": 0})
                    b = target["box"]
                    gx = round(p_box.get("x", 0) + b["x"] + b["width"] * fx)
                    gy = round(p_box.get("y", 0) + b["y"] + b["height"] * fy)
                if gx is not None and gy is not None:
                    self.ipc.move_cursor(gx, gy)
                    btn = button if button is not None else 272
                    self.ipc.pointer_button(btn, True)
                    self.ipc.pointer_button(btn, False)
                    return {"status": "ok", "fallback_simulated": True}
            raise

    def hover(
        self,
        target: Union[str, Dict[str, Any]],
        panel: Optional[str] = None,
        at: Optional[Dict[str, float]] = None,
        fraction: Optional[float] = None,
    ) -> Dict[str, Any]:
        """Hover over a widget by path, name, or node dict."""
        at_coord = at
        if at_coord is None and fraction is not None:
            at_coord = {"x": fraction, "y": 0.5}

        try:
            path = self.resolve_path(target, panel=panel)
            return self.ipc.hover_widget(path=path, at=at_coord)
        except Exception:
            if isinstance(target, dict):
                fx = at_coord["x"] if at_coord and "x" in at_coord else 0.5
                fy = at_coord["y"] if at_coord and "y" in at_coord else 0.5
                gx, gy = None, None
                if target.get("global_box"):
                    b = target["global_box"]
                    gx = round(b["x"] + b["width"] * fx)
                    gy = round(b["y"] + b["height"] * fy)
                elif target.get("box"):
                    p_name = panel or (target.get("path", "").split("/")[0] if "/" in target.get("path", "") else "control_center")
                    shell_st = self.ipc.get_shell_state()
                    p_box = shell_st.get(p_name, {}).get("box", {"x": 0, "y": 0})
                    b = target["box"]
                    gx = round(p_box.get("x", 0) + b["x"] + b["width"] * fx)
                    gy = round(p_box.get("y", 0) + b["y"] + b["height"] * fy)
                if gx is not None and gy is not None:
                    self.ipc.move_cursor(gx, gy)
                    return {"status": "ok", "fallback_simulated": True}
            raise

    def wait_state(
        self,
        target: Union[str, Dict[str, Any]],
        field: str,
        equals: Any,
        panel: Optional[str] = None,
        timeout_ms: int = 5000,
    ) -> Dict[str, Any]:
        """Wait until the widget specified by target has field == equals."""
        path = self.resolve_path(target, panel=panel)
        return self.ipc.wait_for_widget_state(path=path, field=field, equals=equals, timeout_ms=timeout_ms)

    def wait_present(
        self,
        target: Union[str, Dict[str, Any]],
        panel: Optional[str] = None,
        timeout_ms: int = 5000,
    ) -> Dict[str, Any]:
        """Wait until the widget specified by target is present in an open panel."""
        path = self.resolve_path(target, panel=panel)
        return self.ipc.wait_for_widget_present(path=path, timeout_ms=timeout_ms)

    def wait_absent(
        self,
        target: Union[str, Dict[str, Any]],
        panel: Optional[str] = None,
        timeout_ms: int = 5000,
    ) -> Dict[str, Any]:
        """Wait until the widget specified by target is absent."""
        path = self.resolve_path(target, panel=panel)
        return self.ipc.wait_for_widget_absent(path=path, timeout_ms=timeout_ms)

    def wait_settled(self, panel: str, timeout_ms: int = 5000) -> Dict[str, Any]:
        """Wait until the specified panel has settled."""
        return self.ipc.wait_for_panel_settled(panel=panel, timeout_ms=timeout_ms)
