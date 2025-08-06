const std = @import("std");
const Debug = @import("Debug.zig");
const Utf8Buffer = @import("Utf8Buffer.zig").Utf8Buffer;

// Extern functions for WASM, stubs for testing
// const appendChild = if (Debug.is_wasm) struct {
//     extern fn appendChild(parent: u32, child: u32) void;
// }.appendChild else (struct {
//     fn f(_: u32, _: u32) void {}
// }).f;

extern fn dom_op(op: u32, id: u32, ptr1: ?[*]const u8, len1: u32, ptr2: ?[*]const u8, len2: u32) u32;

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
    addStyleSheet = 10,
    reloadWasm = 11,
    createThread = 12,
    threadJoin = 13,
};

fn createElement(tag: []const u8) u32 {
    return dom_op(@intFromEnum(DomOp.createElement), 0, tag.ptr, @intCast(tag.len), null, 0);
}

fn appendChild(parent_id: u32, child_id: u32) void {
    // Pass child_id as the first pointer parameter (hacky but works)
    _ = dom_op(@intFromEnum(DomOp.appendChild), parent_id, @ptrFromInt(@as(usize, child_id)), 0, null, 0);
}

fn setAttribute(id: u32, name: []const u8, value: []const u8) void {
    _ = dom_op(@intFromEnum(DomOp.setAttribute), id, name.ptr, @intCast(name.len), value.ptr, @intCast(value.len));
}

fn addEventListener(id: u32, event: []const u8, callback_id: u32) void {
    _ = dom_op(@intFromEnum(DomOp.addEventListener), id, event.ptr, @intCast(event.len), @ptrFromInt(@as(usize, callback_id)), 0);
}

fn getValue(id: u32, buffer: []u8) []u8 {
    const len = dom_op(@intFromEnum(DomOp.getValue), id, null, 0, buffer.ptr, @intCast(buffer.len));
    return buffer[0..len];
}

fn setInnerHTML(id: u32, html: []const u8) void {
    _ = dom_op(@intFromEnum(DomOp.setInnerHTML), id, html.ptr, @intCast(html.len), null, 0);
}

fn setTextContent(id: u32, text: []const u8) void {
    _ = dom_op(@intFromEnum(DomOp.setTextContent), id, text.ptr, @intCast(text.len), null, 0);
}

fn setClassName(id: u32, class_name: []const u8) void {
    _ = dom_op(@intFromEnum(DomOp.setClassName), id, class_name.ptr, @intCast(class_name.len), null, 0);
}

fn setId(id: u32, element_id: []const u8) void {
    _ = dom_op(@intFromEnum(DomOp.setId), id, element_id.ptr, @intCast(element_id.len), null, 0);
}

fn setTitle(title: []const u8) void {
    _ = dom_op(@intFromEnum(DomOp.setTitle), 0, title.ptr, @intCast(title.len), null, 0);
}

fn addStyleSheet(css: []const u8) void {
    _ = dom_op(@intFromEnum(DomOp.addStyleSheet), 0, css.ptr, @intCast(css.len), null, 0);
}

fn reloadWasm() void {
    _ = dom_op(@intFromEnum(DomOp.reloadWasm), 0, null, 0, null, 0);
}

pub fn createThread(task_id: u32) u32 {
    return dom_op(@intFromEnum(DomOp.createThread), task_id, null, 0, null, 0);
}

fn threadJoin(thread_id: u32) void {
    _ = dom_op(@intFromEnum(DomOp.threadJoin), thread_id, null, 0, null, 0);
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

// UI elements for later reference
pub var outputElement: Element = undefined;
var installUrlElement: Element = undefined;
var num1Element: Element = undefined;
var num2Element: Element = undefined;

// Event handlers
fn runTests() void {
    Debug.wasm.info("🧪 Running tests...", .{});

    const result1 = 2 + 3;
    const result2 = -1 + 1;

    if (result1 == 5 and result2 == 0) {
        Debug.wasm.success("✅ All tests passed!", .{});
    } else {
        Debug.wasm.err("❌ Tests failed!", .{});
    }
}

fn installPackage() void {
    var url_buffer: [256]u8 = undefined;
    const url = installUrlElement.getInputValue(&url_buffer);

    Debug.wasm.info("📦 Installing package from URL: {s}", .{url});
}

fn calculate() void {
    var num1_buffer: [32]u8 = undefined;
    var num2_buffer: [32]u8 = undefined;

    const num1_str = num1Element.getInputValue(&num1_buffer);
    const num2_str = num2Element.getInputValue(&num2_buffer);

    const num1 = std.fmt.parseInt(i32, num1_str, 10) catch 0;
    const num2 = std.fmt.parseInt(i32, num2_str, 10) catch 0;

    const result = num1 + num2;

    Debug.wasm.info("Calculated: {d} + {d} = {d}", .{ num1, num2, result });
}

// Build the UI
pub fn buildUI() void {
    document.title("Zig WebAssembly Demo");

    document.addCSS("body{font-family:monospace}button{background:#007acc}");

    // Store elements for later use
    outputElement = div().elementId("output").innerHTML("📁 Output:");
    installUrlElement = input().elementId("install-url").inputType("text").placeholder("Package URL").value("https://example.com/package.tar");
    num1Element = input().elementId("num1").inputType("number").placeholder("First number").value("5");
    num2Element = input().elementId("num2").inputType("number").placeholder("Second number").value("3");

    // Build UI structure
    _ = document.body().add(div().className("container").children(&.{
        h1().textContent("Zig WebAssembly Demo"),
        p().textContent("This demonstrates Zig code running in the browser via WebAssembly."),

        div().children(&.{
            button().textContent("Run Tests").onclick(runTests),
            button().textContent("Install Package").onclick(installPackage),
            installUrlElement,
        }),

        div().children(&.{
            num1Element,
            num2Element,
            button().textContent("Calculate").onclick(calculate),
        }),

        outputElement,
    }));
}

const Testing = @import("Testing.zig");

test "wasm tests" {
    runTests();
}
