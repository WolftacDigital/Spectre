//! Default-terminal handoff COM contract (issue #6).
//!
//! Zig definitions of the COM types Windows' console subsystem uses to
//! hand a console session to a third-party "delegation terminal":
//! IUnknown, IClassFactory, and ITerminalHandoff2, plus the
//! TERMINAL_STARTUP_INFO struct and the relevant GUIDs.
//!
//! This module is the data/ABI layer only — no registration, no system
//! state. See docs/DEFTERM.md for the full design and the phased plan.
//! Becoming the system default terminal is gated behind explicit user
//! action and is NOT wired here.

const std = @import("std");

/// Win32 HANDLE. Taken from std directly so this pure-ABI module has no
/// dependency on the win32 binding module (keeps it standalone-testable).
pub const HANDLE = std.os.windows.HANDLE;

/// A COM BSTR: a length-prefixed, null-terminated UTF-16 string owned by
/// the COM allocator. We only ever read these, so a plain pointer suffices.
pub const BSTR = ?[*:0]u16;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    /// Parse the canonical `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` form at
    /// comptime into a little-endian-friendly GUID literal.
    pub fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10_000);
        std.debug.assert(s.len == 36);
        const hex = struct {
            fn nib(c: u8) u4 {
                return switch (c) {
                    '0'...'9' => @intCast(c - '0'),
                    'a'...'f' => @intCast(c - 'a' + 10),
                    'A'...'F' => @intCast(c - 'A' + 10),
                    else => unreachable,
                };
            }
            fn byte(comptime a: u8, comptime b: u8) u8 {
                return (@as(u8, nib(a)) << 4) | nib(b);
            }
        };
        return .{
            .Data1 = (@as(u32, hex.byte(s[0], s[1])) << 24) |
                (@as(u32, hex.byte(s[2], s[3])) << 16) |
                (@as(u32, hex.byte(s[4], s[5])) << 8) |
                hex.byte(s[6], s[7]),
            .Data2 = (@as(u16, hex.byte(s[9], s[10])) << 8) | hex.byte(s[11], s[12]),
            .Data3 = (@as(u16, hex.byte(s[14], s[15])) << 8) | hex.byte(s[16], s[17]),
            .Data4 = .{
                hex.byte(s[19], s[20]), hex.byte(s[21], s[22]),
                hex.byte(s[24], s[25]), hex.byte(s[26], s[27]),
                hex.byte(s[28], s[29]), hex.byte(s[30], s[31]),
                hex.byte(s[32], s[33]), hex.byte(s[34], s[35]),
            },
        };
    }

    pub fn eql(a: *const GUID, b: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }
};

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
pub const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));

// --- Standard interface IIDs ---
pub const IID_IUnknown = GUID.parse("00000000-0000-0000-C000-000000000046");
pub const IID_IClassFactory = GUID.parse("00000001-0000-0000-C000-000000000046");

// --- Default-terminal handoff IIDs (from microsoft/terminal) ---
pub const IID_ITerminalHandoff = GUID.parse("59D55CCE-FC8A-48B4-ACE8-0A9286C6557F");
pub const IID_ITerminalHandoff2 = GUID.parse("AA6B364F-4A50-4176-9002-0AE755E7B5EF");
pub const IID_ITerminalHandoff3 = GUID.parse("6F23DA90-15C5-4203-9DB0-64E73F1B1B00");

/// Spectre's own delegation-terminal CLSID. Freshly generated for Spectre;
/// deliberately NOT Windows Terminal's. Used when registering Spectre as a
/// default-terminal candidate (a later, gated phase).
pub const CLSID_SpectreTerminal = GUID.parse("7C3F9A20-5E1B-4D6C-9F84-2A1D7E0B33C1");

/// Console startup info delivered with the handoff (ITerminalHandoff2+).
pub const TERMINAL_STARTUP_INFO = extern struct {
    pszTitle: BSTR,
    pszIconPath: BSTR,
    iconIndex: i32,
    dwX: u32,
    dwY: u32,
    dwXSize: u32,
    dwYSize: u32,
    dwXCountChars: u32,
    dwYCountChars: u32,
    dwFillAttribute: u32,
    dwFlags: u32,
    wShowWindow: u16,
};

/// IUnknown vtable (the head of every COM vtable).
pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (
        self: *anyopaque,
        riid: *const GUID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) HRESULT,
    AddRef: *const fn (self: *anyopaque) callconv(.winapi) u32,
    Release: *const fn (self: *anyopaque) callconv(.winapi) u32,
};

/// IClassFactory vtable.
pub const IClassFactoryVtbl = extern struct {
    base: IUnknownVtbl,
    CreateInstance: *const fn (
        self: *anyopaque,
        pUnkOuter: ?*anyopaque,
        riid: *const GUID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) HRESULT,
    LockServer: *const fn (
        self: *anyopaque,
        fLock: i32,
    ) callconv(.winapi) HRESULT,
};

/// ITerminalHandoff2 vtable. `EstablishPtyHandoff` receives the PTY pipe
/// handles, the keep-alive reference, the conhost (`server`) and console
/// client (`client`) processes, and the startup info.
pub const ITerminalHandoff2Vtbl = extern struct {
    base: IUnknownVtbl,
    // Handles are nullable at the ABI: conhost can legitimately pass a
    // null handle (e.g. on its own error paths), and `?*anyopaque` is
    // ABI-identical to a raw pointer-sized HANDLE.
    EstablishPtyHandoff: *const fn (
        self: *anyopaque,
        in: ?HANDLE,
        out: ?HANDLE,
        signal: ?HANDLE,
        ref: ?HANDLE,
        server: ?HANDLE,
        client: ?HANDLE,
        startupInfo: TERMINAL_STARTUP_INFO,
    ) callconv(.winapi) HRESULT,
};

test "GUID.parse matches known layout" {
    const testing = std.testing;
    // IID_IUnknown {00000000-0000-0000-C000-000000000046}
    try testing.expectEqual(@as(u32, 0), IID_IUnknown.Data1);
    try testing.expectEqual(@as(u16, 0), IID_IUnknown.Data2);
    try testing.expectEqual(@as(u8, 0xC0), IID_IUnknown.Data4[0]);
    try testing.expectEqual(@as(u8, 0x46), IID_IUnknown.Data4[7]);

    // ITerminalHandoff {59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}
    try testing.expectEqual(@as(u32, 0x59D55CCE), IID_ITerminalHandoff.Data1);
    try testing.expectEqual(@as(u16, 0xFC8A), IID_ITerminalHandoff.Data2);
    try testing.expectEqual(@as(u16, 0x48B4), IID_ITerminalHandoff.Data3);
    try testing.expectEqual(@as(u8, 0xAC), IID_ITerminalHandoff.Data4[0]);
    try testing.expectEqual(@as(u8, 0x7F), IID_ITerminalHandoff.Data4[7]);
}

test "GUID.eql" {
    const testing = std.testing;
    var a = IID_ITerminalHandoff2;
    var b = IID_ITerminalHandoff2;
    var c = IID_ITerminalHandoff3;
    try testing.expect(GUID.eql(&a, &b));
    try testing.expect(!GUID.eql(&a, &c));
}
