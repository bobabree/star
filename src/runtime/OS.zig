const os = @import("std").os;

const builtin = @import("builtin");

pub const is_ios = builtin.target.os.tag == .ios;
pub const is_wasi = builtin.target.os.tag == .wasi;
pub const is_wasm = builtin.target.cpu.arch.isWasm();
pub const is_windows = builtin.target.os.tag == .windows;

pub const windows = os.windows;
