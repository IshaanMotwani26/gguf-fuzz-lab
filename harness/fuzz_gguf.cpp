// ─────────────────────────────────────────────────────────────────────────────
// fuzz_gguf.cpp — coverage-guided fuzz harness for the GGUF parser in ggml.
//
// WHAT WE'RE TARGETING
//   gguf_init_from_file() is the function that parses a .gguf model file's
//   header, key/value metadata, and tensor-info table *before* any real weights
//   are used. Every local-AI stack (llama.cpp, Ollama, LM Studio, etc.) runs
//   this code the instant it opens a model. That makes it a high-value,
//   attacker-reachable parser — a textbook fuzzing target.
//
// HOW libFuzzer TALKS TO US
//   libFuzzer repeatedly calls LLVMFuzzerTestOneInput() with a raw byte buffer
//   it has mutated. Our job ("the harness") is to turn those bytes into a call
//   to the function under test. GGUF parsing works on a *file path*, so we write
//   the bytes to a temp file on tmpfs (/dev/shm = RAM-backed, so it's fast) and
//   parse that. See README "Concept primer" if any of these words are new.
//
// HARNESS RULES WE FOLLOW (these matter — a sloppy harness fuzzes nothing):
//   • Pure function of the input bytes: no global state kept across calls.
//   • The harness itself must be memory-safe, or ASan flags OUR bug, not theirs.
//   • Always free what the parser allocates, so we don't drown in false leaks.
// ─────────────────────────────────────────────────────────────────────────────

#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

// The GGUF API moved around as llama.cpp refactored. Newer trees put it in
// "gguf.h"; older ones declared it in "ggml.h". If the build can't find the
// header, grep the repo:  grep -rl "gguf_init_from_file" llama.cpp/ggml/include
#include "gguf.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // 1) Materialize the fuzzer's bytes as a file the parser can open.
    char path[] = "/dev/shm/fuzz_gguf_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return 0;
    if (write(fd, data, size) != (ssize_t)size) {
        close(fd);
        unlink(path);
        return 0;
    }
    close(fd);

    // 2) Parse it. no_alloc=true asks ggml NOT to allocate tensor data buffers,
    //    which keeps each iteration cheap and focuses coverage on the *parsing*
    //    logic (headers, lengths, string reads) rather than big mallocs.
    struct gguf_init_params params;
    params.no_alloc = true;
    params.ctx      = NULL;

    struct gguf_context *ctx = gguf_init_from_file(path, params);

    // 3) Clean up. A well-formed file returns a ctx we must free; a malformed
    //    one returns NULL (that's a *handled* error, not a bug).
    if (ctx) {
        gguf_free(ctx);
    }
    unlink(path);
    return 0;
}
