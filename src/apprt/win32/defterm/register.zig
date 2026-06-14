//! Default-terminal handoff registration (issue #6, phase P4).
//!
//! Writes/removes the per-user (HKCU) registry entries that let Windows
//! activate Spectre as a console delegation terminal. Two clearly
//! separated capabilities:
//!
//!   1. COM-class registration (`registerComServer` / `unregisterComServer`)
//!      — registers Spectre's CLSID as a LocalServer32 COM class so
//!      `CoCreateInstance` can launch `spectre --defterm-server`. This is
//!      SAFE: it does not change the user's default terminal.
//!
//!   2. Default-terminal selection (`setAsDefaultTerminal` /
//!      `restoreDefaultTerminal`) — points `Console\%%Startup`''s
//!      Delegation* values at our CLSID. This DOES make Spectre the system
//!      default terminal and affects every console launch; it is only ever
//!      invoked from the explicit, gated `+install-defterm --set-default`
//!      path and is fully reversible (restore writes the all-zero GUID,
//!      the "let Windows decide" sentinel).

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../win32.zig");
const com = @import("com.zig");

const log = std.log.scoped(.defterm);

/// Format a GUID in the registry string form `{XXXXXXXX-XXXX-XXXX-XXXX-
/// XXXXXXXXXXXX}` (uppercase). Writes into `buf` (>= 39 bytes) and returns
/// the slice.
pub fn guidToString(g: *const com.GUID, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 39);
    return std.fmt.bufPrint(
        buf,
        "{{{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}}}",
        .{
            g.Data1,    g.Data2,    g.Data3,
            g.Data4[0], g.Data4[1], g.Data4[2],
            g.Data4[3], g.Data4[4], g.Data4[5],
            g.Data4[6], g.Data4[7],
        },
    ) catch unreachable;
}

fn wide(alloc: Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
}

/// Create (or open) an HKCU subkey and set its default (unnamed) REG_SZ
/// value, or a named value when `value_name` is non-null.
fn writeStringValue(
    alloc: Allocator,
    subkey: []const u8,
    value_name: ?[]const u8,
    data: []const u8,
) !void {
    const subkey_w = try wide(alloc, subkey);
    defer alloc.free(subkey_w);

    var hkey: w32.HKEY = undefined;
    const rc = w32.RegCreateKeyExW(
        w32.HKEY_CURRENT_USER,
        subkey_w.ptr,
        0,
        null,
        w32.REG_OPTION_NON_VOLATILE,
        w32.KEY_WRITE,
        null,
        &hkey,
        null,
    );
    if (rc != w32.ERROR_SUCCESS) return error.RegCreateFailed;
    defer _ = w32.RegCloseKey(hkey);

    const data_w = try wide(alloc, data);
    defer alloc.free(data_w);
    const name_w: ?[:0]u16 = if (value_name) |n| try wide(alloc, n) else null;
    defer if (name_w) |n| alloc.free(n);

    // cbData includes the terminating null, in bytes.
    const cb: u32 = @intCast((data_w.len + 1) * 2);
    const set_rc = w32.RegSetValueExW(
        hkey,
        if (name_w) |n| n.ptr else null,
        0,
        w32.REG_SZ,
        @ptrCast(data_w.ptr),
        cb,
    );
    if (set_rc != w32.ERROR_SUCCESS) return error.RegSetFailed;
}

fn deleteTree(alloc: Allocator, subkey: []const u8) void {
    const subkey_w = wide(alloc, subkey) catch return;
    defer alloc.free(subkey_w);
    _ = w32.RegDeleteTreeW(w32.HKEY_CURRENT_USER, subkey_w.ptr);
}

/// SAFE: register Spectre's CLSID as a LocalServer32 COM class so the
/// console subsystem can activate `spectre --defterm-server`. Does not
/// change the default terminal.
pub fn registerComServer(alloc: Allocator, exe_path: []const u8) !void {
    var gbuf: [40]u8 = undefined;
    const clsid = guidToString(&com.CLSID_SpectreTerminal, &gbuf);

    const clsid_key = try std.fmt.allocPrint(
        alloc,
        "Software\\Classes\\CLSID\\{s}",
        .{clsid},
    );
    defer alloc.free(clsid_key);
    try writeStringValue(alloc, clsid_key, null, "Spectre Terminal Handoff");

    const ls_key = try std.fmt.allocPrint(
        alloc,
        "Software\\Classes\\CLSID\\{s}\\LocalServer32",
        .{clsid},
    );
    defer alloc.free(ls_key);
    const cmd = try std.fmt.allocPrint(alloc, "\"{s}\" --defterm-server", .{exe_path});
    defer alloc.free(cmd);
    try writeStringValue(alloc, ls_key, null, cmd);

    log.info("registered COM server CLSID {s} -> {s}", .{ clsid, cmd });
}

/// SAFE: remove the COM-class registration.
pub fn unregisterComServer(alloc: Allocator) void {
    var gbuf: [40]u8 = undefined;
    const clsid = guidToString(&com.CLSID_SpectreTerminal, &gbuf);
    const clsid_key = std.fmt.allocPrint(
        alloc,
        "Software\\Classes\\CLSID\\{s}",
        .{clsid},
    ) catch return;
    defer alloc.free(clsid_key);
    deleteTree(alloc, clsid_key);
    log.info("unregistered COM server CLSID {s}", .{clsid});
}

const ZERO_GUID = "{00000000-0000-0000-0000-000000000000}";

/// SYSTEM-AFFECTING (gated): make Spectre the default terminal by pointing
/// the console delegation values at our CLSID. Reversible via
/// `restoreDefaultTerminal`.
pub fn setAsDefaultTerminal(alloc: Allocator) !void {
    var gbuf: [40]u8 = undefined;
    const clsid = guidToString(&com.CLSID_SpectreTerminal, &gbuf);
    // The console-vs-terminal split: DelegationConsole can stay the inbox
    // default (Windows fills the console side), DelegationTerminal points
    // at us. Setting both to our CLSID is what Windows Terminal does; we
    // mirror that.
    try writeStringValue(alloc, "Console\\%%Startup", "DelegationConsole", clsid);
    try writeStringValue(alloc, "Console\\%%Startup", "DelegationTerminal", clsid);
    log.info("set Spectre as default terminal (CLSID {s})", .{clsid});
}

/// Restore the default terminal to "let Windows decide" (all-zero GUID).
pub fn restoreDefaultTerminal(alloc: Allocator) !void {
    try writeStringValue(alloc, "Console\\%%Startup", "DelegationConsole", ZERO_GUID);
    try writeStringValue(alloc, "Console\\%%Startup", "DelegationTerminal", ZERO_GUID);
    log.info("restored default terminal to system default", .{});
}

test "guidToString formats canonical registry form" {
    const testing = std.testing;
    var buf: [40]u8 = undefined;

    // IID_IUnknown -> {00000000-0000-0000-C000-000000000046}
    try testing.expectEqualStrings(
        "{00000000-0000-0000-C000-000000000046}",
        guidToString(&com.IID_IUnknown, &buf),
    );

    // ITerminalHandoff -> {59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}
    try testing.expectEqualStrings(
        "{59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}",
        guidToString(&com.IID_ITerminalHandoff, &buf),
    );

    // Spectre CLSID round-trips through the parser and formatter.
    try testing.expectEqualStrings(
        "{7C3F9A20-5E1B-4D6C-9F84-2A1D7E0B33C1}",
        guidToString(&com.CLSID_SpectreTerminal, &buf),
    );
}
