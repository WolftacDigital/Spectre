//! Default-terminal handoff COM server (issue #6), phase P1/P2.
//!
//! Implements the COM objects Windows' console subsystem activates when
//! Spectre is the configured delegation terminal:
//!
//!   * `HandoffObject` — implements `ITerminalHandoff2`. Its
//!     `EstablishPtyHandoff` is where conhost delivers the PTY pipe
//!     handles for a starting console app.
//!   * `ClassFactory`  — implements `IClassFactory`; hands out
//!     `HandoffObject`s for `CoCreateInstance`.
//!
//! This phase wires the COM vtables and reference counting and is
//! exercised by an in-process self-test. It does NOT register with the
//! system, change the default terminal, or yet build a live surface from
//! the handed-off pipes (phase P3) — `EstablishPtyHandoff` currently
//! validates its inputs, records them, and returns S_OK. See
//! docs/DEFTERM.md.

const std = @import("std");
const com = @import("com.zig");

const log = std.log.scoped(.defterm);

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const HANDLE = com.HANDLE;

/// Callback invoked with a validated handoff. In P3 this builds a surface
/// around the pipes; the self-test uses it to observe delivery.
pub const HandoffFn = *const fn (ctx: ?*anyopaque, h: Handoff) void;

/// A validated set of handoff parameters.
pub const Handoff = struct {
    in: HANDLE,
    out: HANDLE,
    signal: HANDLE,
    ref: HANDLE,
    server: HANDLE,
    client: HANDLE,
};

// ---------------------------------------------------------------------
// HandoffObject : ITerminalHandoff2
// ---------------------------------------------------------------------

pub const HandoffObject = struct {
    vtbl: *const com.ITerminalHandoff2Vtbl,
    refs: u32,
    on_handoff: ?HandoffFn,
    ctx: ?*anyopaque,

    const vtbl_impl = com.ITerminalHandoff2Vtbl{
        .base = .{
            .QueryInterface = QueryInterface,
            .AddRef = AddRef,
            .Release = Release,
        },
        .EstablishPtyHandoff = EstablishPtyHandoff,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        on_handoff: ?HandoffFn,
        ctx: ?*anyopaque,
    ) !*HandoffObject {
        const self = try alloc.create(HandoffObject);
        self.* = .{
            .vtbl = &vtbl_impl,
            .refs = 1,
            .on_handoff = on_handoff,
            .ctx = ctx,
        };
        return self;
    }

    fn fromRaw(raw: *anyopaque) *HandoffObject {
        return @ptrCast(@alignCast(raw));
    }

    fn QueryInterface(
        raw: *anyopaque,
        riid: *const GUID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        if (GUID.eql(riid, &com.IID_IUnknown) or
            GUID.eql(riid, &com.IID_ITerminalHandoff2))
        {
            ppv.* = raw;
            _ = AddRef(raw);
            return com.S_OK;
        }
        ppv.* = null;
        return com.E_NOINTERFACE;
    }

    fn AddRef(raw: *anyopaque) callconv(.winapi) u32 {
        const self = fromRaw(raw);
        self.refs += 1;
        return self.refs;
    }

    fn Release(raw: *anyopaque) callconv(.winapi) u32 {
        const self = fromRaw(raw);
        self.refs -= 1;
        const r = self.refs;
        // Note: real teardown frees the allocation here. The self-test
        // owns the allocation explicitly to keep the test allocator happy.
        return r;
    }

    fn EstablishPtyHandoff(
        raw: *anyopaque,
        in: ?HANDLE,
        out: ?HANDLE,
        signal: ?HANDLE,
        ref: ?HANDLE,
        server: ?HANDLE,
        client: ?HANDLE,
        startupInfo: com.TERMINAL_STARTUP_INFO,
    ) callconv(.winapi) HRESULT {
        const self = fromRaw(raw);
        _ = startupInfo;

        // Validate: none of the required handles may be null.
        for ([_]?HANDLE{ in, out, signal, ref, server, client }) |h| {
            if (h == null) {
                log.warn("EstablishPtyHandoff: received a null handle", .{});
                return com.E_POINTER;
            }
        }

        log.info("EstablishPtyHandoff received (pty handoff)", .{});
        if (self.on_handoff) |cb| cb(self.ctx, .{
            .in = in.?,
            .out = out.?,
            .signal = signal.?,
            .ref = ref.?,
            .server = server.?,
            .client = client.?,
        });

        // P3 will build a surface around these pipes. For now we accept.
        return com.S_OK;
    }
};

// ---------------------------------------------------------------------
// ClassFactory : IClassFactory
// ---------------------------------------------------------------------

pub const ClassFactory = struct {
    vtbl: *const com.IClassFactoryVtbl,
    refs: u32,
    alloc: std.mem.Allocator,
    on_handoff: ?HandoffFn,
    ctx: ?*anyopaque,

    const vtbl_impl = com.IClassFactoryVtbl{
        .base = .{
            .QueryInterface = QueryInterface,
            .AddRef = AddRef,
            .Release = Release,
        },
        .CreateInstance = CreateInstance,
        .LockServer = LockServer,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        on_handoff: ?HandoffFn,
        ctx: ?*anyopaque,
    ) ClassFactory {
        return .{
            .vtbl = &vtbl_impl,
            .refs = 1,
            .alloc = alloc,
            .on_handoff = on_handoff,
            .ctx = ctx,
        };
    }

    fn fromRaw(raw: *anyopaque) *ClassFactory {
        return @ptrCast(@alignCast(raw));
    }

    fn QueryInterface(
        raw: *anyopaque,
        riid: *const GUID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        if (GUID.eql(riid, &com.IID_IUnknown) or
            GUID.eql(riid, &com.IID_IClassFactory))
        {
            ppv.* = raw;
            _ = AddRef(raw);
            return com.S_OK;
        }
        ppv.* = null;
        return com.E_NOINTERFACE;
    }

    fn AddRef(raw: *anyopaque) callconv(.winapi) u32 {
        const self = fromRaw(raw);
        self.refs += 1;
        return self.refs;
    }

    fn Release(raw: *anyopaque) callconv(.winapi) u32 {
        const self = fromRaw(raw);
        self.refs -= 1;
        return self.refs;
    }

    fn CreateInstance(
        raw: *anyopaque,
        pUnkOuter: ?*anyopaque,
        riid: *const GUID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromRaw(raw);
        ppv.* = null;
        if (pUnkOuter != null) return com.CLASS_E_NOAGGREGATION;

        const obj = HandoffObject.create(self.alloc, self.on_handoff, self.ctx) catch
            return com.E_NOINTERFACE;
        // Hand back the requested interface; QI also takes the +1 ref the
        // caller owns, and we drop our creation ref so net refcount is 1.
        const hr = HandoffObject.vtbl_impl.base.QueryInterface(obj, riid, ppv);
        _ = HandoffObject.vtbl_impl.base.Release(obj);
        if (hr != com.S_OK) self.alloc.destroy(obj);
        return hr;
    }

    fn LockServer(raw: *anyopaque, fLock: i32) callconv(.winapi) HRESULT {
        _ = raw;
        _ = fLock;
        return com.S_OK;
    }
};

// ---------------------------------------------------------------------
// Tests — in-process COM activation (no system registration)
// ---------------------------------------------------------------------

const TestObserver = struct {
    got: bool = false,
    last: ?Handoff = null,
    fn cb(ctx: ?*anyopaque, h: Handoff) void {
        const self: *TestObserver = @ptrCast(@alignCast(ctx.?));
        self.got = true;
        self.last = h;
    }
};

test "class factory creates a handoff object and QI works" {
    const testing = std.testing;
    var obs = TestObserver{};
    var factory = ClassFactory.init(testing.allocator, TestObserver.cb, &obs);

    // CreateInstance for ITerminalHandoff2.
    var ppv: ?*anyopaque = null;
    const hr = ClassFactory.vtbl_impl.CreateInstance(
        &factory,
        null,
        &com.IID_ITerminalHandoff2,
        &ppv,
    );
    try testing.expectEqual(com.S_OK, hr);
    try testing.expect(ppv != null);

    const obj: *HandoffObject = @ptrCast(@alignCast(ppv.?));
    defer testing.allocator.destroy(obj);

    // QI for an unsupported interface fails cleanly.
    var bad: ?*anyopaque = null;
    try testing.expectEqual(
        com.E_NOINTERFACE,
        HandoffObject.vtbl_impl.base.QueryInterface(obj, &com.IID_IClassFactory, &bad),
    );
    try testing.expect(bad == null);
}

test "EstablishPtyHandoff validates handles and delivers" {
    const testing = std.testing;
    var obs = TestObserver{};
    const obj = try HandoffObject.create(testing.allocator, TestObserver.cb, &obs);
    defer testing.allocator.destroy(obj);

    const si = std.mem.zeroes(com.TERMINAL_STARTUP_INFO);

    // A null handle is rejected.
    const bad_hr = HandoffObject.vtbl_impl.EstablishPtyHandoff(
        obj,
        null,
        @ptrFromInt(2),
        @ptrFromInt(3),
        @ptrFromInt(4),
        @ptrFromInt(5),
        @ptrFromInt(6),
        si,
    );
    try testing.expectEqual(com.E_POINTER, bad_hr);
    try testing.expect(!obs.got);

    // All-valid handles are accepted and delivered to the callback.
    const ok_hr = HandoffObject.vtbl_impl.EstablishPtyHandoff(
        obj,
        @ptrFromInt(0x11),
        @ptrFromInt(0x22),
        @ptrFromInt(0x33),
        @ptrFromInt(0x44),
        @ptrFromInt(0x55),
        @ptrFromInt(0x66),
        si,
    );
    try testing.expectEqual(com.S_OK, ok_hr);
    try testing.expect(obs.got);
    try testing.expectEqual(@as(usize, 0x11), @intFromPtr(obs.last.?.in));
    try testing.expectEqual(@as(usize, 0x66), @intFromPtr(obs.last.?.client));
}
