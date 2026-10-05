#!/usr/bin/env python3
"""Editor caret timing, selection highlighting and title glyphs across resizes."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image, ImageChops
from ipc_client import IPCClient, ROOT
from files_browser import wait_for


def run():
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="editor-visuals-") as directory:
        tmp = Path(directory)
        config = tmp / "config.toml"
        config.write_text('[compositor]\nxwayland = false\n')
        env = dict(os.environ, HOME=directory, XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(tmp / 'config'), XDG_DATA_HOME=str(tmp / 'data'),
                   XDG_STATE_HOME=str(tmp / 'state'), XDG_CACHE_HOME=str(tmp / 'cache'),
                   REDIWM_CONFIG=str(config), WLR_BACKENDS='headless', REDIWM_FILES_DEVICES='0', WLR_HEADLESS_OUTPUTS='1',
                   WLR_RENDERER=os.environ.get('REDIWM_TEST_RENDERER', 'pixman'),
                   REDIWM_SCALE=os.environ.get('REDIWM_TEST_SCALE', '1'), DBUS_SESSION_BUS_ADDRESS='')
        env.pop('WAYLAND_DISPLAY', None)
        env.pop('REDIWM_SOCKET', None)
        procs = []
        def start(binary):
            with (tmp / (binary + '.log')).open('w') as log:
                proc = subprocess.Popen([str(ROOT / 'zig-out/bin' / binary)],env=env,stdout=log,stderr=log)
            procs.append(proc)
            return proc
        try:
            start('rediwm')
            sock = wait_for(lambda: next(tmp.glob('rediwm-*.sock'), None), 'compositor maps')
            env['WAYLAND_DISPLAY'] = next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
            env['WAYLAND_DEBUG']='client'
            editor=start('rediwm-editor')
            env.pop('WAYLAND_DEBUG')
            with IPCClient(sock) as ipc:
                def window():
                    return next((w for w in ipc.get_windows() if w['app_id']=='rediwm-editor'), None)
                win=wait_for(window,'editor maps')
                ipc.focus_window(win['id'])
                serial=0
                def capture():
                    nonlocal serial
                    serial+=1
                    path=tmp / f'capture-{serial}.png'
                    ipc.screenshot(path=str(path))
                    return Image.open(path).convert('RGB')
                csd='REDIWM_EDITOR_FORCE_CSD' in env
                debug=ipc.get_window_debug(win['id'])
                assert debug['decoration_mode'] == ('client' if csd else 'server'), debug
                titles=[]
                for width,height in [(620,350),(900,500),(620,500),(900,350)]:
                    if os.environ.get('REDIWM_EDITOR_DRAG'):
                        old=ipc.get_window_debug(win['id'])['chrome_box']
                        old_client=ipc.get_window_debug(win['id'])['client_box']
                        x=round(old['x']+old['width']-2)
                        y=round(old['y']+old['height']-2)
                        ipc.move_cursor(x,y)
                        ipc.action('pointer_button',{'button':272,'pressed':True})
                        ipc.move_cursor(round(x+width-old_client['width']),round(y+height-old_client['height']))
                    else:
                        ipc.action('set_window_size',{'id':win['id'],'width':width,'height':height})
                    time.sleep(.6)
                    shot=capture()
                    debug=ipc.get_window_debug(win['id'])
                    box=debug['client_box']
                    actual=window()
                    factor=shot.width/ipc.get_outputs()[0]['logical_width']
                    left=box['x'] if csd else actual['x']
                    top=box['y'] if csd else actual['y']
                    title_h=46 if csd else debug['titlebar_height']
                    title_w=box['width'] if csd else actual['width']
                    # Exclude the app icon and window controls. Crop glyph bounds
                    # independently of the centred position of CSD titles.
                    region=shot.crop(tuple(round(v*factor) for v in (left+40,top+6,left+title_w-180,top+title_h-6)))
                    mask=region.convert('L').point(lambda value:255 if value>155 else 0)
                    bounds=mask.getbbox()
                    assert bounds, 'title not painted'
                    glyphs=mask.crop(bounds)
                    titles.append(glyphs)
                    if os.environ.get('REDIWM_EDITOR_VISUALS'):
                        shot.save(Path(os.environ['REDIWM_EDITOR_VISUALS']) / f'editor-{width}-{height}.png')
                    print('title size',width,height,glyphs.size,flush=True)
                    if os.environ.get('REDIWM_EDITOR_DRAG'):
                        ipc.action('pointer_button',{'button':272,'pressed':False})
                assert all(image.size == titles[0].size for image in titles), 'title glyphs changed size on resize'
                title_requests=(tmp/'rediwm-editor.log').read_text().count('.set_title(')
                assert title_requests <= 2, f'unchanged title sent {title_requests} times during resize'
                print('title glyph size stays fixed across width and height changes',flush=True)
                if os.environ.get('REDIWM_EDITOR_DRAG') and not csd:
                    import threading
                    original=ipc.get_window_debug(win['id'])['chrome_box']
                    x=round(original['x']+original['width']-2)
                    y=round(original['y']+original['height']-2)
                    ipc.move_cursor(x,y)
                    ipc.action('pointer_button',{'button':272,'pressed':True})
                    stop=threading.Event()
                    def motion():
                        with IPCClient(sock) as mover:
                            step=0
                            while not stop.is_set():
                                delta=-(step % 20 if step % 40 < 20 else 40-step % 40)*12
                                mover.move_cursor(x+delta,y)
                                step+=1
                                stop.wait(.025)
                    thread=threading.Thread(target=motion)
                    thread.start()
                    try:
                        sizes=set()
                        for _ in range(10):
                            image=capture()
                            factor=image.width/ipc.get_outputs()[0]['logical_width']
                            left=original['x']+40
                            top=original['y']+6
                            region=image.crop(tuple(round(v*factor) for v in (left,top,left+240,top+title_h-12)))
                            mask=region.convert('L').point(lambda value:255 if value>155 else 0)
                            sizes.add(mask.crop(mask.getbbox()).size)
                        assert sizes=={titles[0].size}, f'title stretches during continuous motion: {sizes}'
                        print('title glyphs remain fixed during continuous dragging',flush=True)
                    finally:
                        stop.set()
                        thread.join(timeout=5)
                        ipc.action('pointer_button',{'button':272,'pressed':False})
                    time.sleep(.3)
                # The application menu lives in the tab bar with shared chrome.
                box=ipc.get_window_debug(win['id'])['client_box']
                ipc.move_cursor(round(box['x']+box['width']-(132 if csd else 18)),round(box['y']+23))
                ipc.key_down_up(1)
                for pressed in (True,False):
                    ipc.action('pointer_button',{'button':272,'pressed':pressed})
                time.sleep(.15)
                menu_shot=capture()
                if output := os.environ.get('REDIWM_EDITOR_MENU_PREVIEW'):
                    menu_shot.save(output)
                ipc.key_down_up(1)  # Escape closes the menu.
                ipc.key_down_up(68)  # F10, Home, Return activate New using the keyboard.
                ipc.key_down_up(102)
                ipc.key_down_up(28)
                wait_for(lambda: '(2/2)' in window()['title'], 'keyboard menu opens a new tab')
                ipc.key(29,True)
                ipc.key_down_up(17)
                ipc.key(29,False)
                wait_for(lambda: '(1/1)' in window()['title'], 'new tab closes')
                print('application menu supports pointer opening and keyboard activation',flush=True)
                ipc.focus_window(win['id'])
                time.sleep(.1)
                assert window()['is_focused'], 'editor lost keyboard focus'
                ipc.action('key',{'keycode':106,'pressed':True})
                ipc.action('key',{'keycode':106,'pressed':False})
                time.sleep(.08)
                debug=ipc.get_window_debug(win['id'])
                box=debug['client_box']
                def caret():
                    shot=capture()
                    factor=shot.width/ipc.get_outputs()[0]['logical_width']
                    x=box['x']+14
                    y=box['y']+40+(46 if csd else 0)
                    return shot.crop(tuple(round(v*factor) for v in (x,y,x+8,y+24)))
                on=caret()
                time.sleep(.57)
                off=caret()
                # A screenshot may wait for an output frame; sample across a
                # complete cycle instead of assuming its request time is its paint time.
                for _ in range(6):
                    if ImageChops.difference(on,off).getbbox(): break
                    time.sleep(.2)
                    off=caret()
                if os.environ.get('REDIWM_EDITOR_VISUALS'):
                    on.save(Path(os.environ['REDIWM_EDITOR_VISUALS'])/'caret-on.png')
                    off.save(Path(os.environ['REDIWM_EDITOR_VISUALS'])/'caret-off.png')
                assert ImageChops.difference(on,off).getbbox(), 'caret never blinked'
                print('caret blink paints on and off',flush=True)
                # No timer wakes after the shell's ten-second inactivity timeout.
                time.sleep(10.2)
                def switches():
                    status=Path(f'/proc/{editor.pid}/task/{editor.pid}/status').read_text()
                    return int(next(line.split(':')[1] for line in status.splitlines() if line.startswith('voluntary_ctxt_switches:')))
                before=switches()
                time.sleep(.7)
                assert switches()==before, 'caret timer keeps waking the idle editor'
                print('caret becomes solid and makes no idle wakeups',flush=True)
                # A selection between the middle rows must leave the rows
                # above and below it untouched, whichever way it is dragged.
                for row in range(5):
                    if row:
                        ipc.key_down_up(28)  # Return; TypeText only inserts printable text.
                    ipc.type_text('mmmmmmmmmmmm')
                time.sleep(.2)
                plain=capture()
                if output := os.environ.get('REDIWM_EDITOR_PREVIEW'):
                    plain.save(output)
                factor=plain.width/ipc.get_outputs()[0]['logical_width']
                text_top=box['y']+40+(46 if csd else 0)
                x0=round((box['x']+20)*factor)
                x1=round((box['x']+120)*factor)
                # Locate glyph rows so this also works at fractional scale and
                # with the configured font metrics.
                rows=[]
                was_ink=False
                for y in range(round(text_top*factor), round((text_top+160)*factor)):
                    ink=any(max(plain.getpixel((x,y)))-min(plain.getpixel((x,y))) < 40
                            and min(plain.getpixel((x,y))) > 155 for x in range(x0,x1))
                    if ink and not was_ink: rows.append([y,y])
                    if ink: rows[-1][1]=y
                    was_ink=ink
                assert len(rows)==5, f'expected five text rows: {rows}'
                centers=[(a+b)/2/factor for a,b in rows]
                probe_x=round((box['x']+300)*factor)
                for start_row,end_row in ((3,1),(1,3)):
                    ipc.move_cursor(round(box['x']+50),round(centers[start_row]))
                    ipc.action('pointer_button',{'button':272,'pressed':True})
                    ipc.move_cursor(round(box['x']+50),round(centers[end_row]))
                    ipc.action('pointer_button',{'button':272,'pressed':False})
                    time.sleep(.15)
                    selected=capture()
                    for row in (0,3,4):
                        point=(probe_x,round(centers[row]*factor))
                        assert selected.getpixel(point)==plain.getpixel(point), f'extra highlight on row {row+1}: {start_row}->{end_row}'
                    for row in (1,2):
                        point=(probe_x,round(centers[row]*factor))
                        assert selected.getpixel(point)!=plain.getpixel(point), f'missing highlight on row {row+1}: {start_row}->{end_row}'
                print('upward and downward selections highlight only selected rows',flush=True)
                # Blurring must cancel the next blink immediately.
                files=start('rediwm-files')
                other=wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id']=='rediwm-files'),None),'Files maps')
                ipc.focus_window(other['id'])
                time.sleep(.3)
                before=switches()
                time.sleep(.7)
                assert switches()==before, 'unfocused editor keeps waking'
                print('unfocused editor makes no blink wakeups',flush=True)
        finally:
            for proc in reversed(procs):
                if proc.poll() is None: proc.terminate()
            for proc in reversed(procs):
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired: proc.kill();proc.wait()

if __name__=='__main__': run()
