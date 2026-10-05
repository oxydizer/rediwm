//! Shared desktop-entry syntax and locale matching with the compositor launcher.
pub const parser = @import("../start_menu/applications.zig");
pub const DesktopEntry = parser.ParsedEntry;
pub const parse = parser.parseDesktopFile;
pub const Locale = parser.Locale;
