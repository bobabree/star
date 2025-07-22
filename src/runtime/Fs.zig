const fs = @import("std").fs;

pub const max_path_bytes = fs.max_path_bytes;

// TODO: WASM edition
pub const cwd = fs.cwd;
pub const path = fs.path;
pub const selfExeDirPath = fs.selfExeDirPath;
