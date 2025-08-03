const std = @import("std");
const runtime = @import("runtime.zig");

// Extern functions matching the HTML importObject.env
extern fn createElement(tag_ptr: [*]const u8, tag_len: usize) u32;
extern fn appendChild(parent: u32, child: u32) void;
extern fn setAttribute(id: u32, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize) void;
extern fn addEventListener(id: u32, event_ptr: [*]const u8, event_len: usize, callback_id: u32) void;
extern fn getValue(id: u32, buffer_ptr: [*]u8, buffer_len: usize) usize;
extern fn setTitle(title_ptr: [*]const u8, title_len: usize) void;
extern fn addStyleSheet(css_ptr: [*]const u8, css_len: usize) void;
extern fn setInnerHTML(id: u32, html_ptr: [*]const u8, html_len: usize) void;
extern fn setTextContent(id: u32, text_ptr: [*]const u8, text_len: usize) void;
extern fn setClassName(id: u32, class_ptr: [*]const u8, class_len: usize) void;
extern fn setId(id: u32, id_ptr: [*]const u8, id_len: usize) void;

const Element = struct {
    id: u32,

    pub fn innerHTML(self: Element, content: []const u8) Element {
        setInnerHTML(self.id, content.ptr, content.len);
        return self;
    }

    pub fn textContent(self: Element, content: []const u8) Element {
        setTextContent(self.id, content.ptr, content.len);
        return self;
    }

    pub fn elementId(self: Element, element_id: []const u8) Element {
        setId(self.id, element_id.ptr, element_id.len);
        return self;
    }

    pub fn className(self: Element, class_name: []const u8) Element {
        setClassName(self.id, class_name.ptr, class_name.len);
        return self;
    }

    pub fn placeholder(self: Element, text: []const u8) Element {
        setAttribute(self.id, "placeholder".ptr, 11, text.ptr, text.len);
        return self;
    }

    pub fn value(self: Element, val: []const u8) Element {
        setAttribute(self.id, "value".ptr, 5, val.ptr, val.len);
        return self;
    }

    pub fn inputType(self: Element, input_type: []const u8) Element {
        setAttribute(self.id, "type".ptr, 4, input_type.ptr, input_type.len);
        return self;
    }

    pub fn onclick(self: Element, handler: fn () void) Element {
        const callback_id = Events.register(handler);
        addEventListener(self.id, "click".ptr, 5, callback_id);
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
        const len = getValue(self.id, buffer.ptr, buffer.len);
        return buffer[0..len];
    }
};

// Element constructors
pub fn div() Element {
    return Element{ .id = createElement("div".ptr, 3) };
}
pub fn h1() Element {
    return Element{ .id = createElement("h1".ptr, 2) };
}
pub fn p() Element {
    return Element{ .id = createElement("p".ptr, 1) };
}
pub fn button() Element {
    return Element{ .id = createElement("button".ptr, 6) };
}
pub fn input() Element {
    return Element{ .id = createElement("input".ptr, 5) };
}

// Document API
pub const document = struct {
    pub fn title(page_title: []const u8) void {
        setTitle(page_title.ptr, page_title.len);
    }

    pub fn addCSS(css: []const u8) void {
        addStyleSheet(css.ptr, css.len);
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
var outputElement: Element = undefined;
var installUrlElement: Element = undefined;
var num1Element: Element = undefined;
var num2Element: Element = undefined;

// Event handlers
fn runTests() void {
    runtime.Debug.wasm.info("🧪 Running tests...", .{});

    const result1 = add(2, 3);
    const result2 = add(-1, 1);

    if (result1 == 5 and result2 == 0) {
        _ = outputElement.innerHTML("✅ All tests passed! add(2,3)=5, add(-1,1)=0");
        runtime.Debug.wasm.success("All tests passed!", .{});
    } else {
        _ = outputElement.innerHTML("❌ Tests failed!");
        runtime.Debug.wasm.err("Tests failed!", .{});
    }
}

fn installPackage() void {
    var url_buffer: [256]u8 = undefined;
    const url = installUrlElement.getInputValue(&url_buffer);

    _ = outputElement.innerHTML("📦 Installing package...");
    runtime.Debug.wasm.info("Installing package from URL: {s}", .{url});

    install(url.ptr, url.len);
}

fn calculate() void {
    var num1_buffer: [32]u8 = undefined;
    var num2_buffer: [32]u8 = undefined;

    const num1_str = num1Element.getInputValue(&num1_buffer);
    const num2_str = num2Element.getInputValue(&num2_buffer);

    const num1 = std.fmt.parseInt(i32, num1_str, 10) catch 0;
    const num2 = std.fmt.parseInt(i32, num2_str, 10) catch 0;

    const result = add(num1, num2);

    var result_buffer: [128]u8 = undefined;
    const result_text = std.fmt.bufPrint(&result_buffer, "🔢 {d} + {d} = {d}", .{ num1, num2, result }) catch "Error";

    _ = outputElement.innerHTML(result_text);
    runtime.Debug.wasm.info("Calculated: {d} + {d} = {d}", .{ num1, num2, result });
}

// Build the UI
pub fn buildUI() void {
    document.title("Zig WebAssembly Demo");

    document.addCSS(
        \\body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; background-color: #f5f5f5; }
        \\.container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        \\button { background: #007acc; color: white; border: none; padding: 10px 20px; margin: 5px; border-radius: 5px; cursor: pointer; font-size: 16px; }
        \\button:hover { background: #005a99; }
        \\#output { background: #f8f8f8; border: 1px solid #ddd; padding: 15px; margin-top: 20px; border-radius: 5px; font-family: monospace; min-height: 100px; }
        \\input { padding: 8px; margin: 5px; border: 1px solid #ddd; border-radius: 3px; font-size: 16px; }
    );

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

// Exports
pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn install(url_ptr: [*]const u8, url_len: usize) void {
    const url_slice = url_ptr[0..url_len];
    var url_buf = runtime.Utf8Buffer.Utf8Buffer(2048).copy(url_slice);
    runtime.Debug.wasm.info("Install called with URL: {s}", .{url_buf.constSlice()});
}

export fn zig_install_externref(url_ptr: [*]const u8, length: i32) void {
    const url_slice = url_ptr[0..@intCast(length)];
    const url = runtime.Utf8Buffer.Utf8Buffer(256).copy(url_slice).constSlice();
    runtime.Debug.wasm.info("📦 Install package from externref URL: {s}", .{url});
}

const Testing = runtime.Testing;

test "add function works" {
    try Testing.expect(add(2, 3) == 5);
    try Testing.expect(add(-1, 1) == 0);
}
