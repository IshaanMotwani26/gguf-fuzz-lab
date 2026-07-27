#include <stdint.h>
#include <stddef.h>
#include <string.h>

// ─── A deliberately vulnerable toy "record parser" ───────────────────────────
// Wire format:  [ 1 byte: claimed length N ][ N bytes: payload ]
//
// This mimics the REAL lesson you'll hunt in GGUF: code that reads a length
// field straight out of an attacker-controlled file and trusts it.
int parse_record(const uint8_t *data, size_t size) {
    if (size < 1) return 0;
    uint8_t len = data[0];                  // length claimed by the input

    // This check LOOKS careful — it stops us reading past the input buffer...
    if ((size_t)len + 1 > size) return 0;

    char buf[16];
    // ...but we never checked len against the DESTINATION size (16).
    // BUG: stack-buffer-overflow (write) whenever len > 16.
    memcpy(buf, data + 1, len);
    return buf[0];
}
