{
  lib,
  stdenv,
  callPackage,
  zig_0_17,
  pkg-config,
  wayland-scanner,
  makeWrapper,
  wrapGAppsNoGuiHook,
  autoPatchelfHook,
  wayland,
  wayland-protocols,
  libxkbcommon,
  pixman,
  cairo,
  freetype,
  harfbuzz,
  fontconfig,
  librsvg,
  gdk-pixbuf,
  pango,
  libinput,
  pam,
  libpulseaudio,
  pulseaudio,
  pipewire,
  poppler,
  libarchive,
  libjpeg,
  libpng,
  libwebp,
  readline,
  libtorrent-rasterbar,
  boost,
  openssl,
  json-glib,
  glib,
  cups,
  libxcb,
  libdrm,
  libGL,
  xwayland,
  xdg-utils,
  shared-mime-info,
  hicolor-icon-theme,
  tzdata,
  systemd,
  glibc,
  dejavu_fonts,
  poppler_data,
}:

let
  wlroots = callPackage ./wlroots.nix { };
  pname = "rediwm";
  version = builtins.head (
    builtins.match ''.*\.version = "([^"]+)".*'' (builtins.readFile ../build.zig.zon)
  );
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../build
      ../src
      ../protocol
      ../assets
      ../data
      ../po
      ../tests
      ../tools
      ../LICENSE-MIT
      ../LICENSE-APACHE
    ];
  };
  # Only this fixed-output fetch may access the network; the build gets the
  # verified package cache and runs offline. Using nixpkgs' zig.fetchDeps
  # rather than our own derivation was suggested by SpaceboyRoss.
  zigDeps = zig_0_17.fetchDeps {
    inherit pname version src;
    hash = "sha256-R5Eg4CG+DW/pgg1zU+4Y2Ov1LCY3ReJordmBQGxkiyc=";
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  strictDeps = true;
  nativeBuildInputs = [
    zig_0_17
    pkg-config
    wayland-scanner
    makeWrapper
    wrapGAppsNoGuiHook
    autoPatchelfHook
  ];
  dontWrapGApps = true;
  buildInputs = [
    # zig-wayland queries wayland-scanner.pc through the target pkg-config.
    wlroots
    wayland
    wayland-scanner
    wayland-protocols
    libxkbcommon
    pixman
    cairo
    freetype
    harfbuzz
    fontconfig
    librsvg
    gdk-pixbuf
    pango
    libinput
    pam
    libpulseaudio
    pipewire
    poppler
    libarchive
    libjpeg
    libpng
    libwebp
    readline
    libtorrent-rasterbar
    boost
    openssl
    json-glib
    glib
    cups
    libxcb
    libdrm
    libGL
  ]
  ++ wlroots.buildInputs; # wlroots.pc's Requires.private is needed for C headers too.

  # explicit_sync.c includes drm.h directly. It lives below include/libdrm,
  # which wlroots' shared-library pkg-config flags do not expose.
  env.NIX_CFLAGS_COMPILE = "-isystem ${lib.getDev libdrm}/include/libdrm";

  postPatch = import ./runtime-paths.nix {
    inherit
      lib
      tzdata
      systemd
      glibc
      pulseaudio
      dejavu_fonts
      fontconfig
      poppler_data
      ;
  };

  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    cp -R ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    zig build -Doptimize=ReleaseSafe -Dcpu=baseline -j"$NIX_BUILD_CORES" \
      -Dinstall-prefix="$out" --prefix "$out"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    # Login/account administration is configured by NixOS, not our installer.
    rm "$out/bin/rediwm-dm" "$out/bin/rediwm-accounts-helper" "$out/bin/rediwm-restart"
    rm "$out/share/polkit-1/actions/org.rediwm.accounts.policy"
    rm "$out/share/wayland-sessions/rediwm-release-safe.desktop"
    install -Dm644 data/rediwm-theme.xml "$out/share/mime/packages/rediwm-theme.xml"
    install -Dm644 LICENSE-MIT "$out/share/licenses/rediwm/LICENSE-MIT"
    install -Dm644 LICENSE-APACHE "$out/share/licenses/rediwm/LICENSE-APACHE"
    runHook postInstall
  '';
  postFixup = ''
    # Keep executables in bin/: the supervisor and clients find siblings and
    # ../share relative to /proc/self/exe, including when behind a wrapper.
    for program in "$out"/bin/*; do
      wrapProgram "$program" \
        "''${gappsWrapperArgs[@]}" \
        --prefix PATH : ${
          lib.makeBinPath [
            xwayland
            xdg-utils
            glib
          ]
        } \
        --suffix XDG_DATA_DIRS : "$out/share:${
          lib.makeSearchPath "share" [
            shared-mime-info
            hicolor-icon-theme
            dejavu_fonts
          ]
        }" \
        --set-default TZDIR ${tzdata}/share/zoneinfo
    done
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/rediwm-msg" --help > /dev/null
    test -x "$out/bin/rediwm-session"
    grep -Fx "Exec=$out/bin/rediwm-session" "$out/share/wayland-sessions/rediwm.desktop"
    grep -Fx "TryExec=$out/bin/rediwm-session" "$out/share/wayland-sessions/rediwm.desktop"
    test ! -e "$out/bin/rediwm-dm"
    test ! -e "$out/share/polkit-1/actions/org.rediwm.accounts.policy"
    test -x ${lib.getExe' pulseaudio "paplay"}
    test -x ${lib.getExe' systemd "systemctl"}
    test -x ${lib.getBin glibc}/bin/locale
    test -r ${tzdata}/share/zoneinfo/zone.tab
    runHook postInstallCheck
  '';

  passthru = {
    providedSessions = [ "rediwm" ];
    inherit wlroots zigDeps;
  };
  meta = {
    description = "RediWM Wayland desktop";
    homepage = "https://github.com/oxydizer/rediwm";
    license = with lib.licenses; [
      mit
      asl20
    ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "rediwm";
  };
}
