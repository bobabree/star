int js_string_length(__externref_t string) 
    __attribute__((import_module("wasm:js-string"), import_name("length")));
int js_string_charCodeAt(__externref_t string, int index) 
    __attribute__((import_module("wasm:js-string"), import_name("charCodeAt")));

// This is O(n) but still better than heap allocation!
// TODO: consider SIMD, or uncomment the O(1) function below in the future
extern void zig_install_externref(const char* url_str, int length);
__attribute__((export_name("install_externref")))
void install_externref(__externref_t url_ref) {
    int url_length = js_string_length(url_ref);
    
    char url_buffer[256];
    int copy_length = url_length < 255 ? url_length : 255;
    
    for (int i = 0; i < copy_length; i++) {
        url_buffer[i] = (char)js_string_charCodeAt(url_ref, i);
    }
    url_buffer[copy_length] = '\0'; 
    
    zig_install_externref(url_buffer, copy_length);
}

// TODO: move to Zig 
// export fn zig_install_externref(url_ptr: [*]const u8, length: i32) void {
//     const url_slice = url_ptr[0..@intCast(length)];
//     const url = Utf8Buffer(256).copy(url_slice).constSlice();
//     Debug.wasm.info("📦 Install package from externref URL: {s}", .{url});
// }

// TODO: uncomment this in the future. 
// This is O(1) fn but not implemented by most browsers yet
// int text_encoder_encodeStringIntoUTF8Array(__externref_t string, void* array, int start) 
//     __attribute__((import_module("wasm:text-encoder"), import_name("encodeStringIntoUTF8Array")));
// __attribute__((export_name("install_externref")))
// void install_externref(__externref_t url_ref) {
//     int url_length = js_string_length(url_ref);
    
//     char url_buffer[256];  
    
//     if (url_length < 256) {
//         int bytes_written = text_encoder_encodeStringIntoUTF8Array(url_ref, url_buffer, 0);
//         url_buffer[bytes_written] = '\0';
        
//         zig_install_externref(url_buffer, bytes_written);
//     }
// }
