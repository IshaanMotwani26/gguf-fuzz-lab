#include <stdint.h>
#include <stddef.h>

// The target lives in vuln.c; the harness only knows its signature.
int parse_record(const uint8_t *data, size_t size);

// THE HARNESS: libFuzzer hands us mutated bytes; we forward them to the target.
// That's the whole job. Keep it tiny, stateless, and memory-safe.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    parse_record(data, size);
    return 0;
}
