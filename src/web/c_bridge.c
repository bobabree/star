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


// extern __externref_t js_string_fromCharCode(int char_code) 
//     __attribute__((import_module("wasm:js-string"), import_name("fromCharCode")));

// extern __externref_t js_string_concat(__externref_t a, __externref_t b)
//     __attribute__((import_module("wasm:js-string"), import_name("concat")));


// __attribute__((export_name("buffer_to_js_string")))
// __externref_t buffer_to_js_string(const char* buffer, int length) {
//     if (length == 0) {
//         return js_string_fromCharCode(0);
//     }
    
//     __externref_t result = js_string_fromCharCode((unsigned char)buffer[0]);
//     for (int i = 1; i < length; i++) {
//         __externref_t next_char = js_string_fromCharCode((unsigned char)buffer[i]);
//         result = js_string_concat(result, next_char);
//     }
    
//     return result;
// }