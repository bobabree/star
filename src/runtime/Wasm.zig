const std = @import("std");
const builtin = @import("builtin");
const Allocator = @import("Mem.zig").Allocator;
const Debug = @import("Debug.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

// Static JavaScript/WebAssembly libs that Zig can directly call into
const js_lib = @embedFile("js.lib");
// const wasm_lib = @embedFile("wasm.lib");

// Extern functions for WASM w/ conditional stubs for testing
const dom_op = if (Debug.is_wasm) struct {
    extern fn dom_op(op: u32, id: u32, ptr1: ?[*]const u8, len1: u32, ptr2: ?[*]const u8, len2: u32) u32;
}.dom_op else (struct {
    fn f(_: u32, _: u32, _: ?[*]const u8, _: u32, _: ?[*]const u8, _: u32) u32 {
        return 0;
    }
}).f;

// DOM Operation enum
const DomOp = enum(u32) {
    createElement = 0,
    appendChild = 1,
    setAttribute = 2,
    addEventListener = 3,
    getValue = 4,
    setInnerHTML = 5,
    setTextContent = 6,
    setClassName = 7,
    setId = 8,
    setTitle = 9,
    addHeadElement = 10,
    reloadWasm = 11,

    pub fn invoke(comptime self: DomOp, args: anytype) u32 {
        return switch (self) {
            .createElement => dom_op(@intFromEnum(self), 0, args.tag.ptr, @intCast(args.tag.len), null, 0),
            .appendChild => dom_op(@intFromEnum(self), args.parent_id, @ptrFromInt(@as(usize, args.child_id)), 0, null, 0),
            .setAttribute => dom_op(@intFromEnum(self), args.id, args.name.ptr, @intCast(args.name.len), args.value.ptr, @intCast(args.value.len)),
            .addEventListener => dom_op(@intFromEnum(self), args.id, args.event.ptr, @intCast(args.event.len), @ptrFromInt(@as(usize, args.callback_id)), 0),
            .getValue => dom_op(@intFromEnum(self), args.id, null, 0, args.buffer.ptr, @intCast(args.buffer.len)),
            .setInnerHTML => dom_op(@intFromEnum(self), args.id, args.html.ptr, @intCast(args.html.len), null, 0),
            .setTextContent => dom_op(@intFromEnum(self), args.id, args.text.ptr, @intCast(args.text.len), null, 0),
            .setClassName => dom_op(@intFromEnum(self), args.id, args.class_name.ptr, @intCast(args.class_name.len), null, 0),
            .setId => dom_op(@intFromEnum(self), args.id, args.element_id.ptr, @intCast(args.element_id.len), null, 0),
            .setTitle => dom_op(@intFromEnum(self), 0, args.title.ptr, @intCast(args.title.len), null, 0),
            .addHeadElement => dom_op(@intFromEnum(self), 0, args.content.ptr, @intCast(args.content.len), args.element_type.ptr, @intCast(args.element_type.len)),
            .reloadWasm => dom_op(@intFromEnum(self), 0, null, 0, null, 0),
        };
    }
};

fn createElement(tag: []const u8) u32 {
    return DomOp.createElement.invoke(.{ .tag = tag });
}

fn appendChild(parent_id: u32, child_id: u32) void {
    _ = DomOp.appendChild.invoke(.{ .parent_id = parent_id, .child_id = child_id });
}

fn setAttribute(id: u32, name: []const u8, value: []const u8) void {
    _ = DomOp.setAttribute.invoke(.{ .id = id, .name = name, .value = value });
}

fn addEventListener(id: u32, event: []const u8, callback_id: u32) void {
    _ = DomOp.addEventListener.invoke(.{ .id = id, .event = event, .callback_id = callback_id });
}

fn getValue(id: u32, buffer: []u8) []u8 {
    const len = DomOp.getValue.invoke(.{ .id = id, .buffer = buffer });
    return buffer[0..len];
}

fn setInnerHTML(id: u32, html: []const u8) void {
    _ = DomOp.setInnerHTML.invoke(.{ .id = id, .html = html });
}

fn setTextContent(id: u32, text: []const u8) void {
    _ = DomOp.setTextContent.invoke(.{ .id = id, .text = text });
}

fn setClassName(id: u32, class_name: []const u8) void {
    _ = DomOp.setClassName.invoke(.{ .id = id, .class_name = class_name });
}

fn setId(id: u32, element_id: []const u8) void {
    _ = DomOp.setId.invoke(.{ .id = id, .element_id = element_id });
}

fn setTitle(title: []const u8) void {
    _ = DomOp.setTitle.invoke(.{ .title = title });
}

fn addStyleSheet(css: []const u8) void {
    _ = DomOp.addHeadElement.invoke(.{ .content = css, .element_type = "style" });
}

fn addJsLib(content: []const u8) void {
    _ = DomOp.addHeadElement.invoke(.{ .content = content, .element_type = "script" });
}

fn reloadWasm() void {
    _ = DomOp.reloadWasm.invoke(.{});
}

const wasm_op = if (Debug.is_wasm) struct {
    extern fn wasm_op(op: u32, id: u32, ptr1: ?[*]const u8, len1: u32, ptr2: ?[*]const u8, len2: u32) u32;
}.wasm_op else (struct {
    fn f(_: u32, _: u32, _: ?[*]const u8, _: u32, _: ?[*]const u8, _: u32) u32 {
        return 0;
    }
}).f;

pub const WasmOp = enum(u32) {
    log = 0,
    warn = 1,
    err = 2,
    createThread = 3,
    threadJoin = 4,
    terminalInit = 5,
    terminalWrite = 6,

    pub fn invoke(comptime self: WasmOp, args: anytype) u32 {
        return switch (self) {
            .log => wasm_op(@intFromEnum(self), 0, args.msg.ptr, @intCast(args.msg.len), args.style.ptr, @intCast(args.style.len)),
            .warn => wasm_op(@intFromEnum(self), 0, args.msg.ptr, @intCast(args.msg.len), args.style.ptr, @intCast(args.style.len)),
            .err => wasm_op(@intFromEnum(self), 0, args.msg.ptr, @intCast(args.msg.len), args.style.ptr, @intCast(args.style.len)),
            .createThread => wasm_op(@intFromEnum(self), args.task_id, null, 0, null, 0),
            .threadJoin => wasm_op(@intFromEnum(self), args.thread_id, null, 0, null, 0),
            .terminalInit => wasm_op(@intFromEnum(self), 0, args.element_id.ptr, @intCast(args.element_id.len), null, 0),
            .terminalWrite => wasm_op(@intFromEnum(self), 0, args.text.ptr, @intCast(args.text.len), null, 0),
        };
    }
};

pub fn createThread(task_id: u32) u32 {
    return WasmOp.createThread.invoke(.{ .task_id = task_id });
}

pub fn threadJoin(thread_id: u32) void {
    _ = WasmOp.threadJoin.invoke(.{ .thread_id = thread_id });
}

pub fn terminalInit(element_id: []const u8) void {
    _ = WasmOp.terminalInit.invoke(.{ .element_id = element_id });
}

pub fn terminalWrite(text: []const u8) void {
    _ = WasmOp.terminalWrite.invoke(.{ .text = text });
}

pub fn linkLibs(allocator: Allocator) !void {
    linkJsLib(allocator) catch |err| {
        Debug.wasm.err("Failed to link js.lib: {}", .{err});
    };

    // TODO: Link Wasm libs if needed in the future
}

fn linkJsLib(allocator: Allocator) !void {
    // Allocate space for decompression
    const decompressed = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(decompressed);

    // Decompress first
    var in_stream = std.io.fixedBufferStream(js_lib);
    var out_stream = std.io.fixedBufferStream(decompressed);

    try std.compress.zlib.decompress(in_stream.reader(), out_stream.writer());

    // Add the JavaScript
    _ = addJsLib(decompressed[0..out_stream.pos]);
}

pub const Element = struct {
    id: u32,

    pub fn innerHTML(self: Element, content: []const u8) Element {
        setInnerHTML(self.id, content);
        return self;
    }

    pub fn textContent(self: Element, content: []const u8) Element {
        setTextContent(self.id, content);
        return self;
    }

    pub fn elementId(self: Element, element_id: []const u8) Element {
        setId(self.id, element_id);
        return self;
    }

    pub fn className(self: Element, class_name: []const u8) Element {
        setClassName(self.id, class_name);
        return self;
    }

    pub fn placeholder(self: Element, text: []const u8) Element {
        setAttribute(self.id, "placeholder", text);
        return self;
    }

    pub fn value(self: Element, val: []const u8) Element {
        setAttribute(self.id, "value", val);
        return self;
    }

    pub fn inputType(self: Element, input_type: []const u8) Element {
        setAttribute(self.id, "type", input_type);
        return self;
    }

    pub fn onclick(self: Element, handler: fn () void) Element {
        const callback_id = Events.register(handler);
        addEventListener(self.id, "click", callback_id);
        return self;
    }

    pub fn add(self: Element, child: Element) Element {
        appendChild(self.id, child.id);
        return self;
    }

    pub fn children(self: Element, child_elements: []const Element) Element {
        for (child_elements) |child| {
            appendChild(self.id, child.id);
        }
        return self;
    }

    pub fn getInputValue(self: Element, buffer: []u8) []u8 {
        return getValue(self.id, buffer);
    }
};

// Element constructors
pub fn div() Element {
    return Element{ .id = createElement("div") };
}
pub fn h1() Element {
    return Element{ .id = createElement("h1") };
}
pub fn p() Element {
    return Element{ .id = createElement("p") };
}
pub fn button() Element {
    return Element{ .id = createElement("button") };
}
pub fn input() Element {
    return Element{ .id = createElement("input") };
}

// Document API
pub const document = struct {
    pub fn title(page_title: []const u8) void {
        setTitle(page_title);
    }

    pub fn addCSS(css: []const u8) void {
        addStyleSheet(css);
    }

    pub fn body() Element {
        return Element{ .id = 1 };
    }
};

// Event system
const Events = struct {
    var handlers: [32]?*const fn () void = [_]?*const fn () void{null} ** 32;
    var count: u8 = 0;

    fn register(handler: fn () void) u32 {
        handlers[count] = &handler;
        count += 1;
        return count - 1;
    }

    export fn invoke(id: u32) void {
        if (id < count and handlers[id] != null) {
            handlers[id].?();
        }
    }
};

pub var terminalElement: Element = undefined;

// Event handlers
fn runTests() void {
    Debug.wasm.info("🧪 Running tests...", .{});

    const result1 = 2 + 3;
    const result2 = -1 + 1;

    if (result1 == 5 and result2 == 0) {
        if (builtin.is_test) return;
        Debug.wasm.success("✅ All tests passed!", .{});
    } else {
        Debug.wasm.err("❌ Tests failed!", .{});
    }
}

// Build the UI
pub fn buildUI() void {
    document.title("Zig WebAssembly Demo");

    document.addCSS("body{background:#000}");

    // Store terminal element
    terminalElement = div().elementId("terminal");

    // Build UI structure
    _ = document.body().add(div().className("container").children(&.{
        terminalElement,
    }));

    terminalInit("terminal");
    terminalWrite("⭐️ Star Terminal Ready!\r\n");
    terminalWrite("Type commands here...\r\n$ ");
}

// Example:
// // UI elements for later reference
// pub var outputElement: Element = undefined;
// var installUrlElement: Element = undefined;
// var num1Element: Element = undefined;
// var num2Element: Element = undefined;

// // Event handlers
// fn installPackage() void {
//     var url_buffer: [256]u8 = undefined;
//     const url = installUrlElement.getInputValue(&url_buffer);

//     Debug.wasm.info("📦 Installing package from URL: {s}", .{url});
// }

// fn calculate() void {
//     var num1_buffer: [32]u8 = undefined;
//     var num2_buffer: [32]u8 = undefined;

//     const num1_str = num1Element.getInputValue(&num1_buffer);
//     const num2_str = num2Element.getInputValue(&num2_buffer);

//     const num1 = std.fmt.parseInt(i32, num1_str, 10) catch 0;
//     const num2 = std.fmt.parseInt(i32, num2_str, 10) catch 0;

//     const result = num1 + num2;

//     Debug.wasm.info("Calculated: {d} + {d} = {d}", .{ num1, num2, result });

//     var buffer: [256]u8 = undefined;
//     const msg = std.fmt.bufPrint(&buffer, "Calculated: {d} + {d} = {d}\r\n$ ", .{ num1, num2, result }) catch return;
//     terminalWrite(msg);
// }

// pub fn exampleBuildHtml() void {
//     document.title("Zig WebAssembly Demo");

//     document.addCSS("body{font-family:monospace}button{background:#007acc}");

//     // Store elements for later use
//     outputElement = div().elementId("output").innerHTML("📁 Output:");
//     installUrlElement = input().elementId("install-url").inputType("text").placeholder("Package URL").value("https://github.com/nlohmann/json");
//     num1Element = input().elementId("num1").inputType("number").placeholder("First number").value("5");
//     num2Element = input().elementId("num2").inputType("number").placeholder("Second number").value("3");

//     // Store terminal element
//     terminalElement = div().elementId("terminal");

//     // Build UI structure
//     _ = document.body().add(div().className("container").children(&.{
//         h1().textContent("WebAssembly Demo"),
//         p().textContent("This demonstrates Zig code running in the browser via WebAssembly."),

//         div().children(&.{
//             button().textContent("Run Tests").onclick(runTests),
//             button().textContent("Install Package").onclick(installPackage),
//             installUrlElement,
//         }),

//         div().children(&.{
//             num1Element,
//             num2Element,
//             button().textContent("Calculate").onclick(calculate),
//         }),

//         outputElement,
//         terminalElement,
//     }));

//     terminalInit("terminal");
//     terminalWrite("⭐️ Star Terminal Ready!\r\n");
//     terminalWrite("Type commands here...\r\n$ ");
// }

const Testing = @import("Testing.zig");

test "wasm tests" {
    runTests();
}
