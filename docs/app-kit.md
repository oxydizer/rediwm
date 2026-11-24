# Building a RediWM app in another repository

`app_kit` is the module RediWM's own standalone apps are built from. Its
window host, theme loading and shared widgets are public build modules, so
an app can live in its own repository and still look and behave like the
built-in ones. The app is an ordinary Wayland client, so it needs nothing
from the compositor and runs elsewhere too (it draws its own titlebar when
the compositor doesn't decorate windows).

## What you get

`@import("app_kit")` provides:

| Declaration | What it is |
|---|---|
| `window.run(App, &app, init, options)` | One xdg-toplevel window: fractional scale, decorations, cursors, keyboard with dead keys and key repeat, live theme reloads, an idle-silent render loop |
| `settings`, `settings_watch` | The user's theme, icon pack and app settings, as Files and Calculator read them |
| `ui` | Widgets, layout, input dispatch, Cairo drawing with theme tokens, text, icons |
| `i18n`, `c` (libc, cairo, xkbcommon, …), `wayland`, `memory` | The modules those depend on |

The host drives an `App` you own. The fields and methods it needs are
listed at the top of `src/app_kit/window.zig`. `src/calculator/app.zig` is a
complete example. Set `dirty = true` to get a frame and `closed = true` to quit.

## Setting up the package

```sh
zig fetch --save=rediwm git+https://github.com/oxydizer/rediwm#<commit>
```

```zig
// build.zig
const rediwm = b.dependency("rediwm", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("app_kit", rediwm.module("app_kit"));
```

```zig
// main.zig
const kit = @import("app_kit");

pub fn main(init: std.process.Init) !void {
    defer _ = kit.memory.deinit();
    defer kit.ui.text.deinit();
    defer kit.ui.shell_icons.deinit();
    kit.i18n.init(init.minimal.environ);
    var app: App = .{};
    defer app.deinit();
    try kit.window.run(App, &app, init, .{ .app_id = "my-app" });
}
```

## Things to know

- **Use the same Zig as RediWM** (`minimum_zig_version` in `build.zig.zon`).
- **Pin a commit.** The kit has no stable API yet. Widgets and theme tokens
  change with RediWM, so update the pin on purpose and rebuild.
- **System libraries:** building needs what RediWM's UI links (cairo,
  librsvg, freetype, harfbuzz, fontconfig, xkbcommon, wayland-client,
  wayland-cursor) and wayland-protocols. The rest of RediWM's build is
  configured but not compiled.
- **Translations:** `i18n.tr` looks up RediWM's catalog, so the app's own
  strings show untranslated.
- **Binary size:** the UI fonts are embedded, so a Debug build is ~40 MB.
