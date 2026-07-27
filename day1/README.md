# Day 1 — Fuzzing warm-up (do this before touching llama.cpp)

Goal: run one complete **harness → crash → ASan trace → triage** loop on a target
you fully understand, so the mechanics are muscle memory when the real target
throws a messy crash at you.

## Files
- `vuln.c` — a deliberately vulnerable toy "record parser" (format: `[1 byte
  length N][N bytes payload]`). It validates the length against the *input* size
  but forgets to validate it against the 16-byte destination buffer — a classic
  **length-trust** bug, the same class you'll hunt in GGUF.
- `fuzz_vuln.c` — the libFuzzer harness (forwards bytes to `parse_record`).
- `vuln_fixed.c` — the patched version (adds the missing bounds check).

## Run it
```bash
# Build with AddressSanitizer + libFuzzer
clang -g -O1 -fsanitize=address,fuzzer vuln.c fuzz_vuln.c -o fuzz_vuln

# Fuzz — stops at the first crash and writes a reproducer file
./fuzz_vuln -artifact_prefix=./

# Replay a crash (deterministic)
./fuzz_vuln crash-<hash>

# Shrink it to the smallest still-crashing input
./fuzz_vuln -minimize_crash=1 -runs=100000 crash-<hash>

# Prove the fix: this one should run clean (no crash)
clang -g -O1 -fsanitize=address,fuzzer vuln_fixed.c fuzz_vuln.c -o fuzz_fixed
./fuzz_fixed -max_total_time=8
```

## How to read the ASan report
```
ERROR: AddressSanitizer: stack-buffer-overflow ...     ← bug CLASS
WRITE of size 18 ...                                    ← direction + how far past
  #1 ... in parse_record vuln.c:20:5                    ← THE faulting line (the memcpy)
'buf' <== Memory access ... overflows this variable     ← which object was smashed
SUMMARY: AddressSanitizer: stack-buffer-overflow ...    ← one-line verdict
```
Reading order that saves time: **SUMMARY** (what) → the first **your-code** frame
in the stack (where) → the "overflows this variable" line (which buffer). Ignore
the libFuzzer frames; you want the first line that points at the target's source.

## What you should have learned
- A harness is just glue: bytes in → call the target.
- ASan turns a silent memory bug into a precise, reproducible crash.
- Triage = reproduce → minimize → root-cause → classify.
- Severity intuition: **OOB write** (like this) is worse than an OOB read, which
  is worse than a null-deref/DoS. The fix is almost always "validate the length
  before you trust it" — exactly what real GGUF parser fixes look like.

Next: `../README.md`, Day 2 — point this same workflow at the real GGUF parser.
