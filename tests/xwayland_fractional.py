#!/usr/bin/env python3
"""Fractional X11 rendering, coordinates, resize and scaled decoration controls."""
from xwayland import (
    test_native_scaling_root_geometry,
    test_native_scaling_managed_window,
    test_gtk_file_dialog,
)

if __name__ == "__main__":
    for factor in (1.1, 1.5, 1.9, 4):
        print(f"Testing Xwayland rendering factor {factor}", flush=True)
        test_native_scaling_root_geometry(factor)
        test_native_scaling_managed_window(factor)
    test_gtk_file_dialog(native=True, factor=1.5)
    print("PASS: fractional Xwayland rendering and scaled decorations")
