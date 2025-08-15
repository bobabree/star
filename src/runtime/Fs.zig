const fs = @import("std").fs;
const builtin = @import("builtin");
const Debug = @import("Debug.zig");
const FixedBuffer = @import("FixedBuffer.zig").FixedBuffer;
const Mem = @import("Mem.zig");
const OS = @import("OS.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

pub const max_path_bytes = fs.max_path_bytes;
pub const File = fs.File;
pub const cwd = fs.cwd;
pub const selfExeDirPath = fs.selfExeDirPath;
pub const selfExePath = fs.selfExePath;

const MAX_NODES = 256;
const MAX_NAME_LEN = 32;
const MAX_PATH_LEN = 256;
const MAX_DIR_ENTRIES = 64;
const NAME_POOL_SIZE = 4096;

pub const NodeBuffer = FixedBuffer(Node, MAX_NODES);
pub const NamePool = FixedBuffer(u8, NAME_POOL_SIZE);
pub const PathBuffer = Utf8Buffer(MAX_PATH_LEN);
pub const NameBuffer = Utf8Buffer(MAX_NAME_LEN);
pub const DirEntries = FixedBuffer(u8, MAX_DIR_ENTRIES);

pub const NodeType = enum(u8) {
    empty = 0,
    file = 1,
    dir = 2,
};

pub const Node = struct {
    type: NodeType = .empty,
    name_start: u16 = 0,
    name_len: u8 = 0,
    parent: u8 = 0,
    first_child: u8 = 0,
    next_sibling: u8 = 0,

    pub fn isEmpty(self: Node) bool {
        return self.type == .empty;
    }
};

const FileSysData = struct {
    nodes: NodeBuffer,
    names: NamePool,
    current_dir: u8,

    pub fn init() FileSysData {
        var data = FileSysData{
            .nodes = NodeBuffer.init(1),
            .names = NamePool.init(1),
            .current_dir = 0,
        };

        // Initialize root directory
        data.nodes.slice()[0] = .{
            .type = .dir,
            .name_start = 0,
            .name_len = 1,
            .parent = 0,
            .first_child = 0,
            .next_sibling = 0,
        };
        data.names.slice()[0] = '/';

        return data;
    }
};

var fs_data: FileSysData = undefined;
var is_initialized: bool = false;
pub const FileSys = enum {
    wasm,
    ios,
    macos,
    linux,
    windows,

    pub fn init(comptime self: FileSys) void {
        _ = self;
        if (is_initialized) return;
        is_initialized = true;

        fs_data = FileSysData.init();
    }

    pub fn run(comptime self: FileSys) void {
        _ = self;
        // Future: Load persisted filesystem
    }

    // Public API

    pub fn getCurrentDir(comptime self: FileSys) u8 {
        _ = self;
        return fs_data.current_dir;
    }

    pub fn setCurrentDir(comptime self: FileSys, index: u8) !void {
        _ = self;
        if (index >= fs_data.nodes.len) return error.InvalidIndex;
        const node = fs_data.nodes.get(index);
        if (node.type != .dir) return error.NotADirectory;
        fs_data.current_dir = index;
    }

    pub fn getNode(comptime self: FileSys, index: u8) ?Node {
        _ = self;
        if (index >= fs_data.nodes.len) return null;
        const node = fs_data.nodes.get(index);
        if (node.isEmpty()) return null;
        return node;
    }

    pub fn getParent(comptime self: FileSys, index: u8) u8 {
        _ = self;
        if (index >= fs_data.nodes.len) return 0;
        return fs_data.nodes.get(index).parent;
    }

    pub fn getName(comptime self: FileSys, index: u8) NameBuffer {
        _ = self;
        var name = NameBuffer.init();

        if (index >= fs_data.nodes.len) {
            return name;
        }

        const node = fs_data.nodes.get(index);
        const name_slice = fs_data.names.constSlice()[node.name_start..][0..node.name_len];
        name.setSlice(name_slice);

        return name;
    }

    pub fn getType(comptime self: FileSys, index: u8) NodeType {
        _ = self;
        if (index >= fs_data.nodes.len) return .empty;
        return fs_data.nodes.get(index).type;
    }

    pub fn getChildren(comptime self: FileSys, index: u8) DirEntries {
        _ = self;
        var children = DirEntries.init(0);

        if (index >= fs_data.nodes.len) return children;

        var child_idx = fs_data.nodes.get(index).first_child;
        while (child_idx != 0 and children.len < MAX_DIR_ENTRIES) {
            children.append(child_idx);
            child_idx = fs_data.nodes.get(child_idx).next_sibling;
        }

        return children;
    }

    pub fn findChild(comptime self: FileSys, parent: u8, name: []const u8) ?u8 {
        _ = self;
        if (parent >= fs_data.nodes.len) return null;

        var child_idx = fs_data.nodes.get(parent).first_child;
        while (child_idx != 0) {
            const child = fs_data.nodes.get(child_idx);
            const child_name = fs_data.names.constSlice()[child.name_start..][0..child.name_len];

            if (Mem.eql(u8, child_name, name)) {
                return child_idx;
            }

            child_idx = child.next_sibling;
        }

        return null;
    }

    pub fn createNode(comptime self: FileSys, node_type: NodeType, name: []const u8) !u8 {
        _ = self;
        if (name.len == 0 or name.len > MAX_NAME_LEN) {
            return error.InvalidName;
        }

        // Find free node
        var node_idx: ?u8 = null;
        for (fs_data.nodes.slice()[1..], 1..) |node, i| {
            if (node.isEmpty()) {
                node_idx = @intCast(i);
                break;
            }
        }

        if (node_idx == null and fs_data.nodes.len < MAX_NODES) {
            node_idx = @intCast(fs_data.nodes.len);
            fs_data.nodes.resize(fs_data.nodes.len + 1);
        }

        const idx = node_idx orelse return error.NoSpace;

        // add name to pool
        const name_start = fs_data.names.len;
        fs_data.names.ensureUnusedCapacity(name.len);
        fs_data.names.appendSliceAssumeCapacity(name);

        // Create node
        fs_data.nodes.slice()[idx] = .{
            .type = node_type,
            .name_start = @intCast(name_start),
            .name_len = @intCast(name.len),
            .parent = 0,
            .first_child = 0,
            .next_sibling = 0,
        };

        return idx;
    }

    pub fn deleteNode(comptime self: FileSys, index: u8) !void {
        _ = self;
        if (index == 0) return error.CannotDeleteRoot;
        if (index >= fs_data.nodes.len) return error.InvalidIndex;

        fs_data.nodes.slice()[index].type = .empty;
    }

    pub fn linkChild(comptime self: FileSys, parent: u8, child: u8) !void {
        _ = self;
        if (parent >= fs_data.nodes.len or child >= fs_data.nodes.len) {
            return error.InvalidIndex;
        }

        // Update child's parent
        fs_data.nodes.slice()[child].parent = parent;

        // Add to front of parent's childrenn list
        fs_data.nodes.slice()[child].next_sibling = fs_data.nodes.get(parent).first_child;
        fs_data.nodes.slice()[parent].first_child = child;
    }

    pub fn unlinkChild(comptime self: FileSys, parent: u8, child: u8) !void {
        _ = self;
        if (parent >= fs_data.nodes.len or child >= fs_data.nodes.len) {
            return error.InvalidIndex;
        }

        // Find and rm from parent's children list
        var prev: ?u8 = null;
        var current = fs_data.nodes.get(parent).first_child;

        while (current != 0) {
            if (current == child) {
                if (prev) |p| {
                    fs_data.nodes.slice()[p].next_sibling = fs_data.nodes.get(child).next_sibling;
                } else {
                    fs_data.nodes.slice()[parent].first_child = fs_data.nodes.get(child).next_sibling;
                }
                fs_data.nodes.slice()[child].parent = 0;
                fs_data.nodes.slice()[child].next_sibling = 0;
                return;
            }
            prev = current;
            current = fs_data.nodes.get(current).next_sibling;
        }

        return error.NotFound;
    }
};

pub const fileSys: FileSys = if (OS.is_wasm)
    .wasm
else if (OS.is_ios)
    .ios
else switch (builtin.target.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => @compileError("Unsupported filesystem platform"),
};
