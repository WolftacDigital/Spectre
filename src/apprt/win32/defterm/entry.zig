//! Default-terminal handoff entry points (issue #6, phase P4b).
//!
//! Dispatched very early from main() on Windows. Handles three command
//! lines without touching the normal app/config/action machinery:
//!
//!   spectre --install-defterm     register the COM server (SAFE: does not
//!                                  change the default terminal)
//!   spectre --install-defterm --set-default
//!                                  ALSO make Spectre the default terminal
//!                                  (system-affecting; explicit opt-in)
//!   spectre --uninstall-defterm   remove registration; restore the system
//!                                  default terminal
//!   spectre --defterm-server      run the out-of-process COM server that
//!                                  the console subsystem activates
//!
//! `maybeRun` returns true if it handled the command line (caller should
//! exit), false to fall through to the normal terminal startup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../win32.zig");
const com = @import("com.zig");
const server = @import("server.zig");
const register = @import("register.zig");

const log = std.log.scoped(.defterm);

/// Quit the server if no handoff arrives within this window, so a stray
/// activation never leaves a Spectre process lingering.
const SERVER_IDLE_TIMEOUT_MS: u32 = 30_000;
const IDLE_TIMER_ID: usize = 0xDEF;

pub fn maybeRun(alloc: Allocator) !bool {
    const args = std.process.argsAlloc(alloc) catch return false;
    defer std.process.argsFree(alloc, args);

    var server_mode = false;
    var install = false;
    var uninstall = false;
    var set_default = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--defterm-server")) server_mode = true;
        if (std.mem.eql(u8, arg, "--install-defterm")) install = true;
        if (std.mem.eql(u8, arg, "--uninstall-defterm")) uninstall = true;
        if (std.mem.eql(u8, arg, "--set-default")) set_default = true;
    }

    if (server_mode) {
        runServer(alloc);
        return true;
    }
    if (install) {
        try runInstall(alloc, set_default);
        return true;
    }
    if (uninstall) {
        runUninstall(alloc);
        return true;
    }
    return false;
}

fn runInstall(alloc: Allocator, set_default: bool) !void {
    const exe = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(exe);
    try register.registerComServer(alloc, exe);
    std.debug.print("Spectre default-terminal COM server registered.\n", .{});
    if (set_default) {
        try register.setAsDefaultTerminal(alloc);
        std.debug.print(
            "Spectre is now the default terminal. Undo with: spectre --uninstall-defterm\n",
            .{},
        );
    } else {
        std.debug.print(
            "To make Spectre the default terminal: spectre --install-defterm --set-default\n",
            .{},
        );
    }
}

fn runUninstall(alloc: Allocator) void {
    // Restore the system default first so we never leave a dangling CLSID
    // selected as the default terminal.
    register.restoreDefaultTerminal(alloc) catch |err|
        log.warn("restore default terminal failed: {}", .{err});
    register.unregisterComServer(alloc);
    std.debug.print("Spectre default-terminal registration removed.\n", .{});
}

/// Server state shared with the handoff callback.
const ServerState = struct {
    received: bool = false,
};

fn onHandoff(ctx: ?*anyopaque, h: server.Handoff) void {
    _ = h;
    const st: *ServerState = @ptrCast(@alignCast(ctx.?));
    st.received = true;
    // P4b: we just acknowledge and quit. P3 will instead build a surface
    // around the handed-off pipes and keep the message loop running to
    // host it.
    log.info("handoff received; P4b server acknowledging and exiting", .{});
    w32.PostQuitMessage(0);
}

fn runServer(alloc: Allocator) void {
    _ = alloc;

    const hr_init = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    if (hr_init < 0) {
        log.err("CoInitializeEx failed: 0x{X}", .{@as(u32, @bitCast(hr_init))});
        return;
    }
    defer w32.CoUninitialize();

    var st = ServerState{};
    var factory = server.ClassFactory.init(std.heap.page_allocator, onHandoff, &st);

    var cookie: u32 = 0;
    const hr_reg = w32.CoRegisterClassObject(
        @ptrCast(&com.CLSID_SpectreTerminal),
        @ptrCast(&factory),
        w32.CLSCTX_LOCAL_SERVER,
        w32.REGCLS_MULTIPLEUSE,
        &cookie,
    );
    if (hr_reg < 0) {
        log.err("CoRegisterClassObject failed: 0x{X}", .{@as(u32, @bitCast(hr_reg))});
        return;
    }
    defer _ = w32.CoRevokeClassObject(cookie);

    _ = w32.CoResumeClassObjects();
    log.info("defterm COM server running (cookie={d})", .{cookie});

    // Idle-timeout so a stray activation can't leave us running forever.
    // A handoff callback PostQuitMessage's before this fires in practice.
    _ = w32.SetTimer(null, IDLE_TIMER_ID, SERVER_IDLE_TIMEOUT_MS, null);

    var msg: w32.MSG = undefined;
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        if (msg.message == w32.WM_TIMER and msg.wParam == IDLE_TIMER_ID) {
            if (!st.received) log.info("defterm server idle timeout; exiting", .{});
            break;
        }
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}
