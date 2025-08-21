const builtin = @import("builtin");
const Allocator = @import("Mem.zig").Allocator;
const Compress = @import("Compress.zig");
const Debug = @import("Debug.zig");
const IO = @import("IO.zig");
const OS = @import("OS.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

// Static JavaScript/WebAssembly libs that Zig can directly call into
const js_lib = @embedFile("js.lib");
// const wasm_lib = @embedFile("wasm.lib");

// Extern functions for WASM w/ conditional stubs for testing
const dom_op = if (OS.is_wasm) struct {
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
    getElementById = 11,

    pub const Args = union(DomOp) {
        createElement: struct { tag: []const u8 },
        appendChild: struct { parent_id: u32, child_id: u32 },
        setAttribute: struct { id: u32, name: []const u8, value: []const u8 },
        addEventListener: struct { id: u32, event: []const u8, callback_id: u32 },
        getValue: struct { id: u32, buffer: []u8 },
        setInnerHTML: struct { id: u32, html: []const u8 },
        setTextContent: struct { id: u32, text: []const u8 },
        setClassName: struct { id: u32, class_name: []const u8 },
        setId: struct { id: u32, element_id: []const u8 },
        setTitle: struct { title: []const u8 },
        addHeadElement: struct { content: []const u8, element_type: []const u8 },
        getElementById: struct { id: []const u8 },
    };

    pub fn call(args: Args) u32 {
        return switch (args) {
            .createElement => |a| dom_op(0, 0, a.tag.ptr, @intCast(a.tag.len), null, 0),
            .appendChild => |a| dom_op(1, a.parent_id, @ptrFromInt(@as(usize, a.child_id)), 0, null, 0),
            .setAttribute => |a| dom_op(2, a.id, a.name.ptr, @intCast(a.name.len), a.value.ptr, @intCast(a.value.len)),
            .addEventListener => |a| dom_op(3, a.id, a.event.ptr, @intCast(a.event.len), @ptrFromInt(@as(usize, a.callback_id)), 0),
            .getValue => |a| dom_op(4, a.id, null, 0, a.buffer.ptr, @intCast(a.buffer.len)),
            .setInnerHTML => |a| dom_op(5, a.id, a.html.ptr, @intCast(a.html.len), null, 0),
            .setTextContent => |a| dom_op(6, a.id, a.text.ptr, @intCast(a.text.len), null, 0),
            .setClassName => |a| dom_op(7, a.id, a.class_name.ptr, @intCast(a.class_name.len), null, 0),
            .setId => |a| dom_op(8, a.id, a.element_id.ptr, @intCast(a.element_id.len), null, 0),
            .setTitle => |a| dom_op(9, 0, a.title.ptr, @intCast(a.title.len), null, 0),
            .addHeadElement => |a| dom_op(10, 0, a.content.ptr, @intCast(a.content.len), a.element_type.ptr, @intCast(a.element_type.len)),
            .getElementById => |a| dom_op(11, 0, a.id.ptr, @intCast(a.id.len), null, 0),
        };
    }
};

fn createElement(tag: []const u8) u32 {
    return DomOp.call(.{ .createElement = .{ .tag = tag } });
}

fn appendChild(parent_id: u32, child_id: u32) void {
    _ = DomOp.call(.{ .appendChild = .{ .parent_id = parent_id, .child_id = child_id } });
}

fn setAttribute(id: u32, name: []const u8, value: []const u8) void {
    _ = DomOp.call(.{ .setAttribute = .{ .id = id, .name = name, .value = value } });
}

fn addEventListener(id: u32, event: []const u8, callback_id: u32) void {
    _ = DomOp.call(.{ .addEventListener = .{ .id = id, .event = event, .callback_id = callback_id } });
}

fn getValue(id: u32, buffer: []u8) []u8 {
    const len = DomOp.call(.{ .getValue = .{ .id = id, .buffer = buffer } });
    return buffer[0..len];
}

fn setInnerHTML(id: u32, html: []const u8) void {
    _ = DomOp.call(.{ .setInnerHTML = .{ .id = id, .html = html } });
}

fn setTextContent(id: u32, text: []const u8) void {
    _ = DomOp.call(.{ .setTextContent = .{ .id = id, .text = text } });
}

fn setClassName(id: u32, class_name: []const u8) void {
    _ = DomOp.call(.{ .setClassName = .{ .id = id, .class_name = class_name } });
}

fn setId(id: u32, element_id: []const u8) void {
    _ = DomOp.call(.{ .setId = .{ .id = id, .element_id = element_id } });
}

fn setTitle(title: []const u8) void {
    _ = DomOp.call(.{ .setTitle = .{ .title = title } });
}

fn addStyleSheet(css: []const u8) void {
    _ = DomOp.call(.{ .addHeadElement = .{ .content = css, .element_type = "style" } });
}

fn addJsLib(content: []const u8) void {
    _ = DomOp.call(.{ .addHeadElement = .{ .content = content, .element_type = "script" } });
}

pub fn getElementById(id: []const u8) ?u32 {
    const index = DomOp.call(.{ .getElementById = .{ .id = id } });
    return if (index == 0) null else index;
}

pub fn linkLibs(allocator: Allocator) !void {
    linkJsLib(allocator) catch |e| {
        Debug.wasm.err("Failed to link js.lib: {}", .{e});
    };

    // TODO: Link Wasm libs if needed in the future
}

fn linkJsLib(allocator: Allocator) !void {
    // Allocate space for decompression
    const decompressed = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(decompressed);

    // Decompress first
    var in_stream = IO.fixedBufferStream(js_lib);
    var out_stream = IO.fixedBufferStream(decompressed);

    try Compress.zlib.decompress(in_stream.reader(), out_stream.writer());

    // Add the JavaScript
    _ = addJsLib(decompressed[0..out_stream.pos]);
}

const wasm_op = if (OS.is_wasm) struct {
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
    fetch = 7,
    sleep = 8,
    reloadWasm = 9,
    save = 10,
    load = 11,

    pub const Args = union(WasmOp) {
        log: struct { msg: []const u8, style: []const u8 },
        warn: struct { msg: []const u8, style: []const u8 },
        err: struct { msg: []const u8, style: []const u8 },
        createThread: struct { func_id: u32 },
        threadJoin: struct { thread_id: u32 },
        terminalInit: struct { element_id: []const u8 },
        terminalWrite: struct { text: []const u8 },
        fetch: struct { url: []const u8, method: []const u8, callback_id: u32 },
        sleep: struct { ms: u32, func_id: u32 },
        reloadWasm: struct {},
        save: struct { key: []const u8, data: []const u8 },
        load: struct { key: []const u8, callback_id: u32 },
    };

    pub fn call(args: Args) u32 {
        return switch (args) {
            .log => |a| wasm_op(0, 0, a.msg.ptr, @intCast(a.msg.len), a.style.ptr, @intCast(a.style.len)),
            .warn => |a| wasm_op(1, 0, a.msg.ptr, @intCast(a.msg.len), a.style.ptr, @intCast(a.style.len)),
            .err => |a| wasm_op(2, 0, a.msg.ptr, @intCast(a.msg.len), a.style.ptr, @intCast(a.style.len)),
            .createThread => |a| wasm_op(3, a.func_id, null, 0, null, 0),
            .threadJoin => |a| wasm_op(4, a.thread_id, null, 0, null, 0),
            .terminalInit => |a| wasm_op(5, 0, a.element_id.ptr, @intCast(a.element_id.len), null, 0),
            .terminalWrite => |a| wasm_op(6, 0, a.text.ptr, @intCast(a.text.len), null, 0),
            .fetch => |a| wasm_op(7, a.callback_id, a.url.ptr, @intCast(a.url.len), a.method.ptr, @intCast(a.method.len)),
            .sleep => |a| wasm_op(8, a.ms, null, a.func_id, null, 0),
            .reloadWasm => wasm_op(9, 0, null, 0, null, 0),
            .save => |a| wasm_op(10, 0, a.key.ptr, @intCast(a.key.len), a.data.ptr, @intCast(a.data.len)),
            .load => |a| wasm_op(11, a.callback_id, a.key.ptr, @intCast(a.key.len), null, 0),
        };
    }
};

pub fn log(msg: []const u8, style: []const u8) void {
    _ = WasmOp.call(.{ .log = .{ .msg = msg, .style = style } });
}

pub fn warn(msg: []const u8, style: []const u8) void {
    _ = WasmOp.call(.{ .warn = .{ .msg = msg, .style = style } });
}

pub fn err(msg: []const u8, style: []const u8) void {
    _ = WasmOp.call(.{ .err = .{ .msg = msg, .style = style } });
}

pub fn createThread(func_id: u32) u32 {
    return WasmOp.call(.{ .createThread = .{ .func_id = func_id } });
}

pub fn threadJoin(thread_id: u32) void {
    _ = WasmOp.call(.{ .threadJoin = .{ .thread_id = thread_id } });
}

pub fn terminalInit(element_id: []const u8) void {
    _ = WasmOp.call(.{ .terminalInit = .{ .element_id = element_id } });
}

pub fn terminalWrite(text: []const u8) void {
    _ = WasmOp.call(.{ .terminalWrite = .{ .text = text } });
}

pub fn fetch(url: []const u8, method: []const u8, callback_id: u32) void {
    _ = WasmOp.call(.{ .fetch = .{ .url = url, .method = method, .callback_id = callback_id } });
}

pub fn sleep(ms: u32, func_id: u32) void {
    _ = WasmOp.call(.{ .sleep = .{ .ms = ms, .func_id = func_id } });
}

pub fn reloadWasm() void {
    _ = WasmOp.call(.{ .reloadWasm = .{} });
}

pub fn save(key: []const u8, data: []const u8) void {
    _ = WasmOp.call(.{ .save = .{ .key = key, .data = data } });
}

pub fn load(key: []const u8, callback_id: u32) void {
    _ = WasmOp.call(.{ .load = .{ .key = key, .callback_id = callback_id } });
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

pub fn buildUI() void {
    // Uncomment this if we want HotReloadig for all other UI elems in the future
    // _ = document.body().innerHTML("");

    // Check if terminal container already exists
    const terminalExists = getElementById("terminal") != null;
    if (!terminalExists) {
        terminalElement = div().elementId("terminal");
        _ = document.body().add(div().className("container").children(&.{
            terminalElement,
        }));
    }
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
