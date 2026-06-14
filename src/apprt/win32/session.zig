//! Spectre session persistence.
//!
//! Serializes the live window / tab / split layout — including each
//! pane's working directory — to a JSON document, and parses it back
//! on startup so a restart can restore the workspace. This is the data
//! model + (de)serialization only; the App is responsible for walking
//! its live windows to build a `Session` and for rebuilding windows
//! from a parsed `Session`.
//!
//! Spectre-specific (lives in src/apprt/win32/ to stay merge-friendly
//! with upstream). Gated by the `window-save-state` config option,
//! which upstream Ghostty documents but only implements on macOS.
//!
//! Format: see FORMAT_VERSION. The on-disk schema always carries the
//! full split-tree shape (layout/ratio per split, cwd per leaf) so the
//! file format is forward-compatible even where a given build restores
//! only part of it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.session);

/// On-disk format version. Bump on incompatible schema changes; the
/// parser refuses versions it does not understand rather than guessing.
pub const FORMAT_VERSION: u32 = 1;

/// A node in a tab's split tree: either a single terminal pane (leaf)
/// with its working directory, or a split of two child nodes.
pub const Node = union(enum) {
    leaf: Leaf,
    split: Split,

    pub const Leaf = struct {
        /// Working directory of the pane, or null if unknown at save time.
        cwd: ?[]const u8 = null,
    };

    pub const Split = struct {
        layout: Layout,
        /// Fraction (0..1) of space given to the left/top child.
        ratio: f32,
        left: *Node,
        right: *Node,

        pub const Layout = enum { horizontal, vertical };
    };

    /// Number of leaf panes under (and including) this node.
    pub fn leafCount(self: *const Node) usize {
        return switch (self.*) {
            .leaf => 1,
            .split => |s| s.left.leafCount() + s.right.leafCount(),
        };
    }

    /// The first (left-most, depth-first) leaf under this node.
    pub fn firstLeaf(self: *const Node) *const Leaf {
        return switch (self.*) {
            .leaf => |*l| l,
            .split => |s| s.left.firstLeaf(),
        };
    }
};

pub const Tab = struct {
    root: *Node,
    /// Whether this tab was the active tab in its window.
    active: bool = false,
};

pub const WindowState = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 800,
    height: i32 = 600,
    maximized: bool = false,
    tabs: []Tab = &.{},
};

/// A parsed or in-progress session. Owns an arena from which every
/// window, tab, node, and string is allocated, so the whole structure
/// is freed in one `deinit`.
pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    windows: []WindowState = &.{},

    pub fn init(gpa: Allocator) Session {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *Session) Allocator {
        return self.arena.allocator();
    }

    // --- builder helpers (save path) ---

    pub fn leaf(self: *Session, cwd: ?[]const u8) Allocator.Error!*Node {
        const node = try self.alloc().create(Node);
        node.* = .{ .leaf = .{
            .cwd = if (cwd) |c| try self.alloc().dupe(u8, c) else null,
        } };
        return node;
    }

    pub fn split(
        self: *Session,
        layout: Node.Split.Layout,
        ratio: f32,
        left: *Node,
        right: *Node,
    ) Allocator.Error!*Node {
        const node = try self.alloc().create(Node);
        node.* = .{ .split = .{
            .layout = layout,
            .ratio = ratio,
            .left = left,
            .right = right,
        } };
        return node;
    }

    // --- serialization ---

    pub fn serialize(self: *const Session, writer: *std.Io.Writer) !void {
        var jws: std.json.Stringify = .{ .writer = writer };
        try jws.beginObject();
        try jws.objectField("version");
        try jws.write(FORMAT_VERSION);
        try jws.objectField("windows");
        try jws.beginArray();
        for (self.windows) |win| {
            try jws.beginObject();
            try jws.objectField("x");
            try jws.write(win.x);
            try jws.objectField("y");
            try jws.write(win.y);
            try jws.objectField("width");
            try jws.write(win.width);
            try jws.objectField("height");
            try jws.write(win.height);
            try jws.objectField("maximized");
            try jws.write(win.maximized);
            try jws.objectField("tabs");
            try jws.beginArray();
            for (win.tabs) |tab| {
                try jws.beginObject();
                try jws.objectField("active");
                try jws.write(tab.active);
                try jws.objectField("root");
                try writeNode(&jws, tab.root);
                try jws.endObject();
            }
            try jws.endArray();
            try jws.endObject();
        }
        try jws.endArray();
        try jws.endObject();
    }

    fn writeNode(jws: *std.json.Stringify, node: *const Node) !void {
        try jws.beginObject();
        switch (node.*) {
            .leaf => |l| {
                try jws.objectField("type");
                try jws.write("leaf");
                try jws.objectField("cwd");
                try jws.write(l.cwd);
            },
            .split => |s| {
                try jws.objectField("type");
                try jws.write("split");
                try jws.objectField("layout");
                try jws.write(s.layout);
                try jws.objectField("ratio");
                try jws.write(s.ratio);
                try jws.objectField("left");
                try writeNode(jws, s.left);
                try jws.objectField("right");
                try writeNode(jws, s.right);
            },
        }
        try jws.endObject();
    }

    /// Serialize to a freshly-allocated, caller-owned byte slice.
    pub fn serializeAlloc(self: *const Session, gpa: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try self.serialize(&aw.writer);
        return try gpa.dupe(u8, aw.written());
    }

    // --- parsing ---

    pub const ParseError = error{
        UnsupportedVersion,
        Malformed,
    } || Allocator.Error;

    /// Parse a session document. The returned Session owns all memory;
    /// call deinit when done. On any structural problem returns
    /// error.Malformed; on a future/unknown version,
    /// error.UnsupportedVersion (callers should treat both as "no
    /// usable session" and move on).
    pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!Session {
        var session = Session.init(gpa);
        errdefer session.deinit();

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            session.alloc(),
            bytes,
            .{},
        ) catch return error.Malformed;
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.Malformed,
        };

        const version = root.get("version") orelse return error.Malformed;
        switch (version) {
            .integer => |v| if (v != FORMAT_VERSION) return error.UnsupportedVersion,
            else => return error.Malformed,
        }

        const windows_val = root.get("windows") orelse return error.Malformed;
        const windows_arr = switch (windows_val) {
            .array => |a| a,
            else => return error.Malformed,
        };

        var windows: std.ArrayList(WindowState) = .empty;
        for (windows_arr.items) |win_val| {
            const win_obj = switch (win_val) {
                .object => |o| o,
                else => return error.Malformed,
            };
            var ws: WindowState = .{};
            ws.x = intField(win_obj, "x", 0);
            ws.y = intField(win_obj, "y", 0);
            ws.width = intField(win_obj, "width", 800);
            ws.height = intField(win_obj, "height", 600);
            ws.maximized = boolField(win_obj, "maximized", false);

            const tabs_val = win_obj.get("tabs") orelse return error.Malformed;
            const tabs_arr = switch (tabs_val) {
                .array => |a| a,
                else => return error.Malformed,
            };
            var tabs: std.ArrayList(Tab) = .empty;
            for (tabs_arr.items) |tab_val| {
                const tab_obj = switch (tab_val) {
                    .object => |o| o,
                    else => return error.Malformed,
                };
                const root_val = tab_obj.get("root") orelse return error.Malformed;
                const node = try parseNode(&session, root_val);
                try tabs.append(session.alloc(), .{
                    .root = node,
                    .active = boolField(tab_obj, "active", false),
                });
            }
            ws.tabs = try tabs.toOwnedSlice(session.alloc());
            try windows.append(session.alloc(), ws);
        }
        session.windows = try windows.toOwnedSlice(session.alloc());
        return session;
    }

    fn parseNode(session: *Session, value: std.json.Value) ParseError!*Node {
        const obj = switch (value) {
            .object => |o| o,
            else => return error.Malformed,
        };
        const type_val = obj.get("type") orelse return error.Malformed;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return error.Malformed,
        };
        if (std.mem.eql(u8, type_str, "leaf")) {
            const cwd: ?[]const u8 = if (obj.get("cwd")) |c| switch (c) {
                .string => |s| try session.alloc().dupe(u8, s),
                .null => null,
                else => return error.Malformed,
            } else null;
            return session.leaf(cwd);
        } else if (std.mem.eql(u8, type_str, "split")) {
            const layout_val = obj.get("layout") orelse return error.Malformed;
            const layout_str = switch (layout_val) {
                .string => |s| s,
                else => return error.Malformed,
            };
            const layout: Node.Split.Layout =
                if (std.mem.eql(u8, layout_str, "horizontal"))
                    .horizontal
                else if (std.mem.eql(u8, layout_str, "vertical"))
                    .vertical
                else
                    return error.Malformed;
            const ratio: f32 = switch (obj.get("ratio") orelse return error.Malformed) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => return error.Malformed,
            };
            const left = try parseNode(session, obj.get("left") orelse return error.Malformed);
            const right = try parseNode(session, obj.get("right") orelse return error.Malformed);
            return session.split(layout, ratio, left, right);
        }
        return error.Malformed;
    }
};

fn intField(obj: std.json.ObjectMap, key: []const u8, default: i32) i32 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .integer => |i| @intCast(i),
        else => default,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "round-trip: single window, single tab, single leaf" {
    const testing = std.testing;
    var s = Session.init(testing.allocator);
    defer s.deinit();

    const leaf = try s.leaf("C:\\Users\\test\\project");
    const tabs = try s.alloc().alloc(Tab, 1);
    tabs[0] = .{ .root = leaf, .active = true };
    const windows = try s.alloc().alloc(WindowState, 1);
    windows[0] = .{ .x = 100, .y = 120, .width = 1024, .height = 768, .tabs = tabs };
    s.windows = windows;

    const bytes = try s.serializeAlloc(testing.allocator);
    defer testing.allocator.free(bytes);

    var parsed = try Session.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.windows.len);
    try testing.expectEqual(@as(i32, 100), parsed.windows[0].x);
    try testing.expectEqual(@as(i32, 768), parsed.windows[0].height);
    try testing.expectEqual(@as(usize, 1), parsed.windows[0].tabs.len);
    try testing.expect(parsed.windows[0].tabs[0].active);
    try testing.expectEqualStrings(
        "C:\\Users\\test\\project",
        parsed.windows[0].tabs[0].root.leaf.cwd.?,
    );
}

test "round-trip: nested splits preserve shape, cwds, ratios" {
    const testing = std.testing;
    var s = Session.init(testing.allocator);
    defer s.deinit();

    // tab tree:  split(h, 0.6, leaf(A), split(v, 0.25, leaf(B), leaf(C)))
    const a = try s.leaf("A:\\a");
    const b = try s.leaf("B:\\b");
    const c = try s.leaf("C:\\c");
    const inner = try s.split(.vertical, 0.25, b, c);
    const rootnode = try s.split(.horizontal, 0.6, a, inner);

    const tabs = try s.alloc().alloc(Tab, 1);
    tabs[0] = .{ .root = rootnode, .active = true };
    const windows = try s.alloc().alloc(WindowState, 1);
    windows[0] = .{ .tabs = tabs };
    s.windows = windows;

    try testing.expectEqual(@as(usize, 3), rootnode.leafCount());

    const bytes = try s.serializeAlloc(testing.allocator);
    defer testing.allocator.free(bytes);

    var parsed = try Session.parse(testing.allocator, bytes);
    defer parsed.deinit();

    const r = parsed.windows[0].tabs[0].root;
    try testing.expectEqual(@as(usize, 3), r.leafCount());
    try testing.expect(r.* == .split);
    try testing.expectEqual(Node.Split.Layout.horizontal, r.split.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.6), r.split.ratio, 0.001);
    try testing.expectEqualStrings("A:\\a", r.split.left.leaf.cwd.?);
    try testing.expectEqual(Node.Split.Layout.vertical, r.split.right.split.layout);
    try testing.expectApproxEqAbs(@as(f32, 0.25), r.split.right.split.ratio, 0.001);
    try testing.expectEqualStrings("B:\\b", r.split.right.split.left.leaf.cwd.?);
    try testing.expectEqualStrings("C:\\c", r.split.right.split.right.leaf.cwd.?);
}

test "leaf with null cwd round-trips as null" {
    const testing = std.testing;
    var s = Session.init(testing.allocator);
    defer s.deinit();
    const leaf = try s.leaf(null);
    const tabs = try s.alloc().alloc(Tab, 1);
    tabs[0] = .{ .root = leaf };
    const windows = try s.alloc().alloc(WindowState, 1);
    windows[0] = .{ .tabs = tabs };
    s.windows = windows;

    const bytes = try s.serializeAlloc(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try Session.parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expect(parsed.windows[0].tabs[0].root.leaf.cwd == null);
}

test "parse rejects unknown version" {
    const testing = std.testing;
    const doc =
        \\{"version": 9999, "windows": []}
    ;
    try testing.expectError(error.UnsupportedVersion, Session.parse(testing.allocator, doc));
}

test "parse rejects malformed documents" {
    const testing = std.testing;
    const cases = [_][]const u8{
        "not json at all",
        "{}", // missing version
        \\{"version": 1}
        , // missing windows
        \\{"version": 1, "windows": [{"tabs": [{"root": {"type": "bogus"}}]}]}
        ,
        \\{"version": 1, "windows": [{"tabs": [{"root": {"type": "split", "layout": "diagonal", "ratio": 0.5, "left": {"type":"leaf"}, "right": {"type":"leaf"}}}]}]}
        ,
    };
    for (cases) |doc| {
        try testing.expectError(error.Malformed, Session.parse(testing.allocator, doc));
    }
}

test "empty session (no windows) round-trips" {
    const testing = std.testing;
    var s = Session.init(testing.allocator);
    defer s.deinit();
    const bytes = try s.serializeAlloc(testing.allocator);
    defer testing.allocator.free(bytes);
    var parsed = try Session.parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.windows.len);
}
