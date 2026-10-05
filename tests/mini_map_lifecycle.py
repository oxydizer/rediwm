#!/usr/bin/env python3
"""Mini Map focus, modal cancellation, multiple outputs and idle behavior."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from ipc_client import IPCClient, spawn_compositor, stop_process
from desktop_zoom import build_client


def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-map-life-') as directory:
        tmp = Path(directory)
        base = '[compositor]\nxwayland = false\nmini_map_hide_ms = 500\n'
        proc, log = spawn_compositor(tmp, outputs='2', config_content=base,
            renderer=os.getenv('REDIWM_TEST_RENDERER', 'pixman'),
            env_extra={'DBUS_SESSION_BUS_ADDRESS':'', 'XDG_CACHE_HOME':str(tmp/'cache'), 'XDG_CONFIG_HOME':str(tmp/'config')})
        client = None
        try:
            with IPCClient(tmp, timeout=20) as ipc:
                ipc.action('wait_for', {'condition':'wallpaper_presented', 'timeout_ms':10000})
                ipc.action('wait_for', {'condition':'catalog_published', 'timeout_ms':10000})
                outputs = sorted(ipc.get_outputs(), key=lambda o:o['x'])
                def wait(check, label, seconds=5):
                    end=time.monotonic()+seconds
                    while time.monotonic()<end:
                        if check(): return
                        time.sleep(.04)
                    raise AssertionError(label)
                def point(out): return out['logical_width']-40, out['logical_height']-out['bottom_exclusion']-40
                def visible(out):
                    x,y=point(out)
                    return ipc.hit_test(x,y,output=out['name'])['target_type']=='mini_map'
                def show(out, x=0):
                    ipc.move_cursor(30, 30, output=out['name'])
                    ipc.action('set_camera', {'x':x,'y':0})
                    wait(lambda:visible(out),'map missing on selected output')
                # Animated navigation must settle before the idle delay and fade.
                show(outputs[1], 600)
                assert not visible(outputs[0]), 'map duplicated across outputs'
                wait(lambda:not visible(outputs[1]), 'animated map failed to fade')
                # No polling timer remains after dismissal. Observe the main thread
                # without stats IPC (which would itself start GPU timing).
                time.sleep(.4)
                def switches():
                    lines=Path(f'/proc/{proc.pid}/status').read_text().splitlines()
                    return sum(int(line.split(':')[1]) for line in lines if line.startswith(('voluntary_ctxt_switches:', 'nonvoluntary_ctxt_switches:')))
                before=switches()
                time.sleep(.6)
                assert switches()-before <= 3, 'hidden map leaves periodic main-thread wakeups'
                build_client(tmp)
                display=next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
                env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display)
                with (tmp/'client.log').open('w') as stream:
                    client=subprocess.Popen([str(tmp/'client')],env=env,stdout=stream,stderr=stream)
                wait(lambda:bool(ipc.get_windows()),'client did not map')
                wid=ipc.get_windows()[0]['id']
                ipc.focus_window(wid)
                show(outputs[0])
                assert not visible(outputs[1]), 'map did not follow next navigation output'
                px,py=point(outputs[0])
                ipc.move_cursor(px,py,output=outputs[0]['name'])
                ipc.pointer_button(272,True)
                ipc.move_cursor(px-30,py-10,output=outputs[0]['name'])
                assert ipc.get_input_state()['keyboard_focused_window_id']==wid, 'map stole keyboard focus'
                ipc.pointer_button(272,False)
                assert ipc.get_input_state()['keyboard_focused_window_id']==wid
                # A modal panel cancels a grab, and its eventual release stays owned.
                show(outputs[0])
                ipc.move_cursor(px,py,output=outputs[0]['name'])
                ipc.pointer_button(272,True)
                ipc.open_power_menu()
                time.sleep(.2)
                assert not visible(outputs[0])
                ipc.pointer_button(272,False)
                ipc.close_panel('power_menu')
                wait(lambda:ipc.get_shell_state()['power_menu'] is None, 'panel did not close')
                ipc.move_cursor(20,20)
                old=ipc.request(raw_cmd={'version': 1, 'command': 'get_camera'})
                ipc.move_cursor(100,100)
                assert ipc.request(raw_cmd={'version': 1, 'command': 'get_camera'})['x']==old['x'], 'modal cancellation left drag alive'
                # Output configuration changes cancel grabs before coordinates change.
                show(outputs[1])
                px,py=point(outputs[1])
                ipc.move_cursor(px,py,output=outputs[1]['name'])
                ipc.pointer_button(272,True)
                (tmp/'rediwm-config.toml').write_text(base+'[[outputs]]\nname = "'+outputs[1]['name']+'"\nenabled = false\n')
                ipc.reload_config()
                time.sleep(.2)
                ipc.pointer_button(272,False)
                assert not visible(outputs[0])
                assert ipc.get_input_state()['cursor_mode']=='passthrough'
                print('PASS: Mini Map animated fade, idle wakeups, output selection, focus and cancellation')
        except Exception:
            print((tmp/'compositor.log').read_text()[-2500:])
            raise
        finally:
            if client: stop_process(client)
            stop_process(proc)
            log.close()

if __name__=='__main__': run()
