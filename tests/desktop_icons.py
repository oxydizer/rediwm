#!/usr/bin/env python3
"""The compositor-drawn desktop: inotify, input, transfers and persistence on an isolated headless output."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]

def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-icons-') as directory:
        tmp = Path(directory)
        desktop = tmp / 'Desktop'
        env = dict(os.environ, XDG_RUNTIME_DIR=directory, XDG_CONFIG_HOME=str(tmp/'config'), XDG_CACHE_HOME=str(tmp/'cache'), XDG_STATE_HOME=str(tmp/'state'),
                   WLR_BACKENDS='headless', REDIWM_FILES_DEVICES='0', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman',
                   REDIWM_SCALE='1', REDIWM_DESKTOP_BUILTINS="0", REDIWM_DESKTOP_DIR=str(desktop))
        config_path = tmp/'rediwm-config.toml'
        config_path.write_text('[compositor]\ndefault_file_manager = "rediwm-fixture-files.desktop"\n')
        env['REDIWM_CONFIG'] = str(config_path)
        helpers=tmp/'bin';helpers.mkdir()
        files_marker=tmp/'opened-folder'
        real_files=tmp/'launch-real-files'
        files_helper=helpers/'rediwm-files'
        files_helper.write_text('#!/bin/sh\nprintf "%s" "$1" > "'+str(files_marker)+'"\n'
            'if [ -e "'+str(real_files)+'" ]; then exec "'+str(ROOT/'zig-out/bin/rediwm-files')+'" "$@"; fi\n')
        files_helper.chmod(0o755)
        # Keep Trash deterministic on /tmp mounts where gio rejects trashing.
        trash_failure = tmp/'fail-trash'
        trash_dir = tmp/'data/Trash/files'
        gio_helper = helpers/'gio'
        gio_helper.write_text('#!/usr/bin/python3\n'
            'import pathlib, shutil, sys\n'
            f'if pathlib.Path({str(trash_failure)!r}).exists(): sys.exit(1)\n'
            f'dest = pathlib.Path({str(trash_dir)!r})\n'
            'dest.mkdir(parents=True, exist_ok=True)\n'
            'if sys.argv[1:] == ["trash", "--empty"]:\n'
            ' for path in dest.iterdir():\n'
            '  if path.is_dir(): shutil.rmtree(path)\n'
            '  else: path.unlink()\n'
            ' sys.exit(0)\n'
            'assert sys.argv[1:3] == ["trash", "--"]\n'
            'for path in sys.argv[3:]: shutil.move(path, dest/pathlib.Path(path).name)\n')
        gio_helper.chmod(0o755)
        env['PATH']=str(helpers)+':'+env.get('PATH','')
        env['XDG_DATA_HOME']=str(tmp/'data')
        applications=tmp/'data/applications';applications.mkdir(parents=True)
        (applications/'rediwm-test.desktop').write_text('[Desktop Entry]\nType=Application\nName=RediWM Test Fixture\nExec=true %F\nIcon=folder\n')
        (applications/'rediwm-fixture-files.desktop').write_text('[Desktop Entry]\nType=Application\nName=Files Fixture\nExec='+str(files_helper)+' %F\nCategories=FileManager;\n')
        env.pop('WAYLAND_DISPLAY', None)
        env.pop('REDIWM_SOCKET', None)
        processes = []
        def start(binary, **extra):
            log = (tmp / (binary + '.log')).open('w')
            p = subprocess.Popen([str(ROOT/'zig-out/bin'/binary)], env=dict(env, **extra), stdout=log, stderr=log)
            log.close()
            processes.append(p)
            return p
        def wait_for(predicate, message, timeout=10):
            deadline = time.monotonic()+timeout
            while not predicate():
                assert all(p.poll() is None for p in processes), 'process exited'
                assert time.monotonic()<deadline, message
                time.sleep(.05)
        try:
            start('rediwm')
            wait_for(lambda: list(tmp.glob('rediwm-*.sock')), 'IPC unavailable')
            sock = socket.socket(socket.AF_UNIX)
            sock.settimeout(10)
            sock.connect(str(next(tmp.glob('rediwm-*.sock'))))
            reader = sock.makefile('r')
            def request(value):
                sock.sendall((json.dumps(value)+'\n').encode())
                result = json.loads(reader.readline())
                assert 'Ok' in result, result
                return result['Ok']
            def action(name, params=None):
                return request({"version": 1, "command": name, "params": params or {}})
            action('wait_for', {'condition': 'wallpaper_presented', 'timeout_ms': 10000})
            action('wait_for', {'condition': 'catalog_published', 'timeout_ms': 10000})
            def move(x,y): action('move_cursor',{'x':x,'y':y})
            def button(pressed, code=272): action('pointer_button',{'button':code,'pressed':pressed})
            def click(x,y,code=272):
                move(x,y)
                button(True,code)
                button(False,code)
                time.sleep(.12)
            def key(code):
                for state in (True,False): action('key',{'keycode':code,'pressed':state})
            def capture(name):
                time.sleep(.3)
                path=tmp/(name+'.png')
                action('screenshot',{'path':str(path)})
                return Image.open(path).convert('RGB')
            background=capture('background')
            display=next(p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock'))
            # Pixel comparisons isolate icons from transient navigation overlays.
            # The desktop starts and stops with its config section, like any reload.
            fixed_icons = True
            def set_desktop(enabled):
                config_path.write_text('[compositor]\ndefault_file_manager = "rediwm-fixture-files.desktop"\nmini_map_enabled = false\ndesktop_icons_fixed = %s\n[desktop]\nenabled = %s\n' % (str(fixed_icons).lower(), str(enabled).lower()))
                action('reload_config')
            set_desktop(True)
            wait_for(desktop.exists,'desktop directory not created')
            time.sleep(.5)
            empty=capture('empty')
            assert ImageChops.difference(background,empty).getbbox() is None, 'empty desktop is not transparent'
            # Controlled launcher does not open or modify anything outside the temporary fixture.
            launcher=desktop/'Launch.desktop'
            marker=tmp/'launched'
            launcher.write_text('[Desktop Entry]\nType=Application\nName=Launch Test\nIcon=folder\nExec=touch "'+str(marker)+'" %U\n')
            time.sleep(.5)
            # Like a download, it is not executable: it shows as the file it is and never runs.
            click(1200,60);time.sleep(.05);click(1200,60)
            time.sleep(.8)
            assert not marker.exists(), 'an untrusted desktop launcher ran'
            # Allow Launching, the last row of its menu, marks it executable.
            click(1200,60,273)
            key(103);key(28)
            wait_for(lambda: os.access(launcher, os.X_OK), 'Allow Launching did not mark the launcher executable')
            click(600,400)
            time.sleep(5.2) # the untrusted-launcher notice expires before the pixel checks
            icons=capture('icons')
            assert ImageChops.difference(empty,icons).crop((1150,20,1270,145)).getbbox(), 'icon missing'
            # Default-on icons stay at the same pixels after a camera pan.
            move(0,0)
            action('set_camera', {'x': 300, 'y': 150})
            pinned=capture('icons-pinned')
            assert ImageChops.difference(icons,pinned).crop((0,0,1280,660)).getbbox() is None, 'fixed icons moved with camera'
            for percent in (70, 100):
                action('set_zoom', {'percent': percent})
                time.sleep(1.4)
                fixed_zoom=capture('icons-fixed-'+str(percent))
                assert ImageChops.difference(icons,fixed_zoom).crop((0,0,1280,660)).getbbox() is None, 'fixed icons scaled with camera'
            click(1200,60);time.sleep(.05);click(1200,60)
            wait_for(marker.exists,'fixed icon click after pan did not launch')
            marker.unlink()
            action('set_camera', {'x': 0, 'y': 0})
            fixed_icons = False
            set_desktop(True)
            click(600,400)
            time.sleep(1) # let the launch feedback finish before comparing icon bounds
            icons=capture('icons-unpinned')
            # With the option off, icons share the window camera and input coordinates.
            # Anchor at the origin so expected projected positions are exact.
            original_box=ImageChops.difference(empty,icons).crop((0,0,1280,660)).getbbox()
            for percent in (85,70,55):
                move(0,0)
                action('set_zoom',{'percent':percent})
                time.sleep(1.4) # let the shared zoom OSD fade out
                zoomed=capture('icons-'+str(percent))
                # Crop the taskbar: its clock may tick between captures.
                box=ImageChops.difference(empty,zoomed).crop((0,0,1280,660)).getbbox()
                z=percent/100
                assert box and all(abs(a-b*z)<=2 for a,b in zip(box,original_box)), ('icon did not scale with camera',percent,box,original_box)
            click(660,33);time.sleep(.05);click(660,33)
            wait_for(marker.exists,'zoomed double click did not launch')
            marker.unlink()
            time.sleep(.45)
            move(660,33);button(True);time.sleep(.18);move(660,99);time.sleep(.05);button(False)
            layout=tmp/'config/rediwm-desktop/layout.toml'
            wait_for(lambda: layout.exists() and 'cell_row = 1' in layout.read_text(),'zoomed drag did not persist')
            time.sleep(.45)
            move(660,99);button(True);time.sleep(.18);move(660,33);time.sleep(.05);button(False)
            wait_for(lambda: 'cell_row = 0' in layout.read_text(),'zoomed drag back did not persist')
            move(0,0)
            action('set_zoom',{'percent':100})
            time.sleep(1)
            click(1200,60)
            selected=capture('selected')
            assert ImageChops.difference(icons,selected).getbbox(), 'selection did not draw'
            click(1200,60)
            time.sleep(.05)
            click(1200,60)
            wait_for(marker.exists,'double click did not launch')
            # Drag one cell down, then check persisted layout and restart.
            time.sleep(.45)
            move(1200,60);button(True);time.sleep(.18);move(1200,180);time.sleep(.05);button(False)
            layout=tmp/'config/rediwm-desktop/layout.toml'
            wait_for(lambda: layout.exists() and 'cell_row = 1' in layout.read_text(),'drag did not persist')
            set_desktop(False);time.sleep(.3);set_desktop(True)
            time.sleep(.5)
            restored=capture('restored')
            assert ImageChops.difference(empty,restored).crop((1150,140,1270,255)).getbbox(), 'position not restored'
            click(600,300,273)
            menu=capture('menu')
            assert ImageChops.difference(restored,menu).crop((590,290,810,480)).getbbox(), 'empty context menu missing'
            move(650,345)
            hovered=capture('menu-hover')
            assert ImageChops.difference(menu,hovered).crop((600,300,800,540)).getbbox(), 'menu hover did not highlight a row'
            key(1)
            click(600,300,273)
            key(108)  # New File, using keyboard navigation in the menu.
            key(28)
            action('key',{'keycode':29,'pressed':True});key(30);action('key',{'keycode':29,'pressed':False})
            action('type_text', {'text':'Menu Keyboard.txt'})
            key(28)
            wait_for(lambda: (desktop/'Menu Keyboard.txt').is_file(), 'context-menu keyboard action failed')
            (desktop/'Menu Keyboard.txt').unlink()
            time.sleep(.4)
            key(1)
            # Reacquiring focus after Escape must allow keyboard activation.
            click(1200,180)
            marker.unlink()
            key(28)
            wait_for(marker.exists,'keyboard focus not reacquired')
            # Shared deletion dialog: close and cancel preserve the selected file.
            key(111)
            preview = capture('delete-dialog')
            preview.save('/tmp/rediwm-desktop-delete-dialog.png')
            assert launcher.exists()
            move(600,251); button(True)
            move(660,301); button(False)
            moved = capture('delete-dialog-moved')
            assert ImageChops.difference(preview.crop((450,235,650,268)),
                                        moved.crop((510,285,710,318))).getbbox() is None, 'Desktop delete dialog did not move'
            click(915,301)  # Close follows the moved titlebar.
            assert launcher.exists()
            key(111)
            key(1)
            assert launcher.exists()
            key(111)
            key(15); key(57)  # permanent checkbox
            time.sleep(.15)
            assert launcher.exists(), 'Checkbox deleted without confirmation'
            key(15); key(28)  # destructive button
            wait_for(lambda: not launcher.exists(), 'Desktop permanent deletion failed')
            time.sleep(.5)
            removed=capture('removed')
            assert ImageChops.difference(empty,removed).crop((1150,140,1270,255)).getbbox() is None, 'removed icon remains'
            # Multi-selection uses Trash by default, including after a permanent deletion.
            for name in ('Trash A.txt', 'Trash B.txt'):
                (desktop/name).write_text('trash fixture')
            time.sleep(.5)
            click(1200,60)
            action('key',{'keycode':29,'pressed':True});key(30);action('key',{'keycode':29,'pressed':False})
            trash_failure.touch()
            key(111)
            time.sleep(.15)
            assert (desktop/'Trash A.txt').exists() and (desktop/'Trash B.txt').exists()
            key(28)
            time.sleep(.5)
            assert (desktop/'Trash A.txt').exists() and (desktop/'Trash B.txt').exists(), 'Trash failure fell back to permanent deletion'
            trash_failure.unlink()
            key(111); key(28)
            wait_for(lambda: not (desktop/'Trash A.txt').exists() and not (desktop/'Trash B.txt').exists(), 'Desktop multi-item Trash failed')
            for name in ('Trash A.txt', 'Trash B.txt'):
                assert (tmp/'data/Trash/files'/name).read_text() == 'trash fixture', 'Trash was bypassed'
            time.sleep(.4)
            # Rubber-band selection and inline rename use real seat input events.
            (desktop/'Alpha.txt').write_text('alpha')
            (desktop/'Bravo.txt').write_text('bravo')
            (desktop/'Folder').mkdir()
            time.sleep(.6)
            unselected=capture('unselected-files')
            move(1140,20);button(True);move(1255,246);time.sleep(.1);button(False)
            selected_files=capture('rubber-band')
            for y in (30,142):
                assert ImageChops.difference(unselected,selected_files).crop((1160,y,1180,y+10)).getbbox(), 'rubber band missed an icon'
            key(1)
            click(1200,60)
            before_rename=capture('before-rename')
            key(60) # F2 selects the stem, leaving the extension intact.
            editor=capture('rename-editor')
            editor.save('/tmp/rediwm-desktop-rename.png')
            assert ImageChops.difference(before_rename,editor).crop((1040,94,1150,139)).getbbox(), 'rename editor clipped to icon bounds'
            action('type_text',{'text':'Preview'})
            click(1228,116) # Checkmark is outside the text field.
            wait_for(lambda: (desktop/'Preview.txt').exists(), 'confirm button did not preserve the extension')
            time.sleep(.3)
            key(60)
            action('type_text',{'text':'Cancelled'})
            click(1256,116)
            assert (desktop/'Preview.txt').exists() and not (desktop/'Cancelled.txt').exists(), 'cancel button renamed the file'
            time.sleep(.2)
            key(60)
            action('type_text',{'text':'Escaped'})
            key(1)
            assert (desktop/'Preview.txt').exists(), 'Escape renamed the file'
            click(1200,60)
            key(60)
            # Clicking and dragging selects text without moving the icon.
            move(1048,116);button(True);move(1198,116);button(False)
            action('type_text',{'text':'Dragged.txt'})
            key(28)
            wait_for(lambda: (desktop/'Dragged.txt').exists(), 'pointer selection did not replace the whole filename')
            time.sleep(.3)
            key(60)
            action('key',{'keycode':29,'pressed':True});key(30);action('key',{'keycode':29,'pressed':False})
            # Ctrl+A selects without deleting: collapse with Right, then edit.
            key(106);key(14)
            action('type_text',{'text':'t'})
            key(28)
            time.sleep(.2)
            assert (desktop/'Dragged.txt').exists(), 'Ctrl+A cleared the name instead of selecting it'
            key(60)
            action('key',{'keycode':29,'pressed':True});key(30);action('key',{'keycode':29,'pressed':False})
            action('type_text',{'text':'Renamed.txt'})
            key(28)
            wait_for(lambda: (desktop/'Renamed.txt').exists(),'inline rename failed')
            click(1200,280);time.sleep(.05);click(1200,280)
            wait_for(files_marker.exists,'folder did not open rediwm-files')
            assert files_marker.read_text()==str(desktop/'Folder')
            # New Folder is a real operation; its editor must retain keyboard focus.
            click(600,300,273);click(640,315)
            action('key',{'keycode':29,'pressed':True});key(30);action('key',{'keycode':29,'pressed':False})
            action('type_text',{'text':'Created Folder'});key(28)
            wait_for(lambda: (desktop/'Created Folder').is_dir(),'New Folder editor lost focus')
            # Installed desktop entries populate the Add Application chooser.
            click(600,300,273);click(640,375)
            action('type_text',{'text':'RediWM Test Fixture'})
            time.sleep(.8)
            key(28)
            wait_for(lambda: (desktop/'rediwm-test.desktop').exists(),'application chooser did not add the launcher')
            # Remove fixture icons before transfer checks.
            for path in desktop.iterdir():
                if path.is_dir():path.rmdir()
                else:path.unlink()
            time.sleep(.6)
            # Build a normal xdg client which sends real drag and clipboard transfers.
            protocols=Path(subprocess.check_output(['pkg-config','--variable=pkgdatadir','wayland-protocols'],text=True).strip())
            xml=protocols/'stable/xdg-shell/xdg-shell.xml'
            for mode,name in [('client-header','xdg-shell-client-protocol.h'),('private-code','xdg-shell-protocol.c')]:
                subprocess.run(['wayland-scanner',mode,str(xml),str(tmp/name)],check=True)
            decoration_protocol = protocols/'unstable/xdg-decoration/xdg-decoration-unstable-v1.xml'
            for mode,name in [('client-header','xdg-decoration-client-protocol.h'),('private-code','xdg-decoration-protocol.c')]:
                subprocess.run(['wayland-scanner',mode,str(decoration_protocol),str(tmp/name)],check=True)
            sender_bin=tmp/'transfer-client'
            subprocess.run(['cc','-Wall','-Wextra','-I'+str(tmp),str(ROOT/'tests/desktop_transfer.c'),str(tmp/'xdg-shell-protocol.c'),str(tmp/'xdg-decoration-protocol.c'),'-lwayland-client','-o',str(sender_bin)],check=True)
            original=tmp/'Drop me.txt';original.write_text('transfer fixture')
            with (tmp/'sender.log').open('w') as log:
                sender=subprocess.Popen([str(sender_bin)],env=dict(env,WAYLAND_DISPLAY=display,REDIWM_TEST_TRANSFER=original.as_uri()+'\r\n'),stdout=log,stderr=log)
            processes.append(sender)
            wait_for(lambda: request({'version': 1, 'command': 'windows'})['Windows'],'sender window absent')
            window=request({'version': 1, 'command': 'windows'})['Windows'][0]
            # Desktop must remain behind normal windows.
            action('move_window_to',{'id':window['id'],'x':200,'y':150})
            time.sleep(.3)
            move(240,240);button(True);time.sleep(.15);move(1000,400);time.sleep(.15);button(False)
            wait_for(lambda: (desktop/original.name).is_symlink(),'file drop did not create a symlink')
            assert (desktop/original.name).resolve()==original
            wait_for(lambda: 'transfer-finished' in (tmp/'sender.log').read_text(),'offer was not finished')
            (desktop/original.name).unlink()
            time.sleep(.3)
            click(240,240,273) # source sets clipboard with the genuine input serial
            click(1000,400)
            # Focus desktop with a new empty-area menu, then paste its external clipboard.
            click(1000,400,273)
            key(1)
            # Escape releases keyboard focus, so use menu Paste to reacquire it.
            click(1000,400,273)
            click(1050,541) # Paste follows four 32px rows, 6px padding and a 7px separator in the clamped menu.
            wait_for(lambda: (desktop/original.name).is_file(),'clipboard paste failed')
            assert not (desktop/original.name).is_symlink()
            assert (desktop/original.name).read_text()=='transfer fixture'
            # Crossing a normal window must not change desktop-local drag coordinates.
            time.sleep(.4)
            move(1200,60);button(True);time.sleep(.18);move(240,240);time.sleep(.1);button(False)
            wait_for(lambda: 'cell_col = 10' in layout.read_text() and 'cell_row = 1' in layout.read_text(),'drag coordinates changed over a window')
            # Wallpaper is decoded in the worker and painted behind icons.
            wallpaper=tmp/'wallpaper.jpg'
            Image.new('RGB',(8,8),(24,48,72)).save(wallpaper)
            settings=tmp/'config/rediwm-desktop/config.toml'
            settings.write_text('wallpaper = '+json.dumps(str(wallpaper))+'\nwallpaper_mode = "fill"\n')
            set_desktop(False);time.sleep(.3);set_desktop(True)
            time.sleep(.6)
            painted=capture('wallpaper')
            pixel=painted.getpixel((1000,300))
            assert all(abs(x-y)<=3 for x,y in zip(pixel,(24,48,72))), ('JPEG wallpaper missing',pixel)
            assert request({'version': 1, 'command': 'outputs'})['Outputs'][0]['bottom_exclusion']==54
            request({'version': 1, 'command': 'open_appearance'})
            reader.close();sock.close()
            # Restart with built-ins in a scratch home. Mouse actions must map
            # real Files windows; keyboard wrapping checks the menu row counts.
            for p in reversed(processes):
                p.terminate()
                p.wait(timeout=3)
            processes.clear()
            home=tmp/'home';home.mkdir()
            env.update(HOME=str(home), REDIWM_DESKTOP_BUILTINS='1')
            fixed_icons=True
            config_path.write_text('[compositor]\ndefault_file_manager = "rediwm-fixture-files.desktop"\nmini_map_enabled = false\ndesktop_icons_fixed = true\n[desktop]\nenabled = true\n')
            start('rediwm')
            wait_for(lambda: list(tmp.glob('rediwm-*.sock')), 'built-in IPC unavailable')
            sock = socket.socket(socket.AF_UNIX)
            sock.settimeout(10)
            sock.connect(str(next(tmp.glob('rediwm-*.sock'))))
            reader = sock.makefile('r')
            action('wait_for', {'condition': 'wallpaper_presented', 'timeout_ms': 10000})
            action('wait_for', {'condition': 'catalog_published', 'timeout_ms': 10000})
            time.sleep(.6)
            files_marker.unlink(missing_ok=True)
            real_files.touch()
            def close_files():
                wait_for(lambda: any(w['app_id']=='rediwm-files' for w in action('windows')['Windows']), 'desktop-launched Files did not connect to its compositor')
                for window in action('windows')['Windows']:
                    if window['app_id']=='rediwm-files': action('close_window', {'id': window['id']})
                wait_for(lambda: not action('windows')['Windows'], 'Files did not close')
            click(152,60,273);click(200,82)
            wait_for(lambda: files_marker.exists() and files_marker.read_text()==str(home), 'Home context-menu click did not open Home')
            close_files()
            files_marker.unlink()
            click(152,172,273);click(200,194)
            wait_for(lambda: files_marker.exists() and files_marker.read_text()==str(trash_dir), 'Trash context-menu click did not open Trash')
            close_files()
            real_files.unlink()
            files_marker.unlink()
            click(152,60,273);key(108);key(28)
            wait_for(lambda: files_marker.exists() and files_marker.read_text()==str(home), 'Home menu should only offer Open')
            files_marker.unlink()
            click(152,172,273);key(108);key(108);key(28)
            wait_for(lambda: files_marker.exists() and files_marker.read_text()==str(trash_dir), 'Trash menu should wrap from Empty Trash to Open')
            trashed_file=trash_dir/'empty-trash.txt';trashed_file.write_text('fixture')
            click(152,172,273);key(108);key(28)
            wait_for(lambda: not any(trash_dir.iterdir()), 'Empty Trash did not clear the scratch Trash')
            assert home.is_dir() and trash_dir.is_dir(), 'built-in action removed its folder'
            reader.close();sock.close()
            print('Desktop icons, built-in menus, Empty Trash, deletion dialogs, Trash, permanent deletion, selection, launch, persistence, rename, folders, drag/drop, clipboard, JPEG wallpaper and IPC passed')
        except Exception:
            for log in tmp.glob('*.log'): print(log.name,log.read_text()[-12000:])
            raise
        finally:
            for p in reversed(processes):
                p.terminate()
                try:p.wait(timeout=3)
                except subprocess.TimeoutExpired:p.kill();p.wait()

if __name__=='__main__':run()
