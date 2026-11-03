{
  lib,
  tzdata,
  systemd,
  dejavu_fonts,
  fontconfig,
  poppler_data,
}:

# Keep distro-specific paths in the packaging layer. --replace-fail makes
# upstream changes visible rather than silently shipping broken lookups.
''
  substituteInPlace src/polkit/native.c \
    --replace-fail 'const char *paths[] = {' 'const char *paths[] = {"/run/wrappers/bin/polkit-agent-helper-1", '
  # Privileged helpers use trusted directories, never the session's PATH.
  substituteInPlace src/platform/tool.zig \
    --replace-fail 'const system_dirs = [_][]const u8{' \
      'const system_dirs = [_][]const u8{ "/run/wrappers/bin", "${lib.getBin systemd}/bin",'
  substituteInPlace src/config_runtime/region.zig src/control_center/sections/region.zig \
    --replace-fail '/usr/share/zoneinfo' '${tzdata}/share/zoneinfo'
  # Permit only these font/character-map data directories after Landlock,
  # never the whole Nix store. The UI's selected fonts are opened beforehand.
  substituteInPlace src/pdf/sandbox.c \
    --replace-fail '/usr/share/fonts' '${dejavu_fonts}/share/fonts' \
    --replace-fail '/usr/local/share/fonts' '${dejavu_fonts.minimal}' \
    --replace-fail '/usr/share/fontconfig' '${fontconfig}/etc/fonts' \
    --replace-fail '/usr/share/poppler' '${poppler_data}/share/poppler'
''
