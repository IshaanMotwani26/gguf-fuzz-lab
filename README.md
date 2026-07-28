# Fuzzing the GGUF Model-File Parsers (llama.cpp / ggml)

A coverage-guided fuzzing project targeting the **GGUF parsers** that every local-AI
stack — llama.cpp, Ollama, LM Studio — runs the instant it opens a model file. I
built a two-pronged harness (C++ and Python), ran it against the real parsers,
and independently rediscovered **five documented memory-safety / denial-of-service
bug classes**, root-causing each and verifying it against the public record.

> **Honest framing up front.** GGUF parsing is one of the most heavily audited
> corners of AI security right now (Google OSS-Fuzz coverage plus a formal
> oss-security audit in May 2026). I did **not** find a novel 0-day, and finding
> one in a week would have been luck, not method. What this project demonstrates
> is the thing that actually transfers to the job: building the tooling, finding
> real bugs, root-causing them correctly, and rigorously checking prior art
> instead of over-claiming. Every finding below is cross-referenced to its public
> disclosure.

---

## Why GGUF parsers are a real attack surface

A `.gguf` file is parsed in C/C++ (and a Python reference implementation) **before
any inference runs**. The parser reads attacker-controllable header fields —
tensor counts, dimensions, string lengths — and acts on them. A malicious model
file downloaded from a hub can therefore trigger crashes or resource exhaustion at
load time. That makes the parser, not the model weights, the thing worth fuzzing.

---

## Methodology

Two independent harnesses, because the two implementations fail in different ways:

**C++ core (`ggml/src/gguf.cpp`) — libFuzzer + sanitizers.**
Built `ggml` with AddressSanitizer + UndefinedBehaviorSanitizer + coverage, wrote
a libFuzzer harness around `gguf_init_from_file()`, seeded it with a valid `.gguf`
and a magic-byte dictionary, and let it mutate. Sanitizers turn a silent memory
bug into a precise, reproducible crash with a file:line.

**Python reference reader (`gguf.GGUFReader`) — Atheris.**
Python is memory-safe, so here a "bug" is an *unexpected uncaught exception* (the
reader should reject bad input cleanly) or *resource exhaustion* (a tiny file that
forces a huge allocation or a hang). The harness swallows the documented rejection
(`ValueError`) and lets anything else surface, so the fuzzer walks the exception
space one class at a time.

Everything runs in a reproducible Docker image (clang, cmake, the sanitizer
runtimes, llvm-symbolizer, Atheris — all baked in).

---

## Findings

| # | Component | Type | Impact | Minimized trigger | Status |
|---|-----------|------|--------|-------------------|--------|
| 1 | C++ `gguf.cpp` | Division by zero (SIGFPE) | DoS | crafted tensor dims `[1, 0]` | Known — issue #8816, oss-sec V-06, public PoC |
| 2 | Python `gguf_reader.py` | Uncaught `KeyError` | DoS | duplicate metadata key | Known — kv-mismatch class |
| 3 | Python `gguf_reader.py` | Uncaught `IndexError` (2 sites) | DoS | empty parsed array | Known — kv/tensor-count mismatch PoC |
| 4 | Python `gguf_reader.py` | Memory exhaustion (OOM) | DoS | **48-byte** file | Known — oss-sec V-03, Databricks 2024, huntr |

All findings are **denial-of-service class** (crash or memory exhaustion), not code
execution — stated honestly, because overclaiming severity is the fastest way to
lose credibility. The upstream maintainers additionally treat "loading an untrusted
GGUF" as largely outside their threat model, which is why several of these sit as
low-priority known issues rather than patched CVEs. That contested threat model is
itself worth understanding.

### Finding 1 — Division by zero in tensor-dimension validation (C++)

`gguf_init_from_file` validates that each tensor dimension is non-negative
(`if (info.t.ne[j] < 0)`) but never that it is non-**zero**. A file declaring a
dimension of `0` passes that check, then reaches the integer-overflow guard
`INT64_MAX / info.t.ne[j]`, which divides by zero and raises a SIGFPE. My fuzzer
hit it in ~2 seconds; UBSan reported `division by zero` at the exact line before
the hardware trap fired.
**Fix:** the check should be `<= 0`.
**Prior art:** GitHub issue #8816 (Aug 2024, found via AFL), oss-security advisory
V-06 (May 2026), and a public proof-of-concept repo — same root cause, `[1, 0]`
dimensions.

### Findings 2 & 3 — Uncaught exceptions in the Python reader

The Python reference reader raises the *wrong exception types* on malformed input:
a `KeyError` on duplicate metadata keys (`_push_field`), and an `IndexError` in
**two** separate spots (`_get_tensor_info_field` and `_get_field_parts`) where a
parsed array is indexed with `[0]` without checking it is non-empty. A well-behaved
caller wraps `GGUFReader` in `except ValueError` (the documented rejection) — so
neither of these is caught, and a crafted file crashes any tool that inspects it.
The recurring pattern — *indexing parsed data before validating its length* —
appears in multiple functions, which is the more interesting observation than any
single crash.
**Fix:** validate array lengths before indexing; raise `ValueError` consistently.
**Prior art:** the kv/tensor-count header-mismatch class (public PoC).

### Finding 4 — Memory-exhaustion DoS from an unbounded count (Python)

The headline finding, and the smallest trigger: a **48-byte** file causes a 2 GB+
allocation. The header's `tensor_count` (and `kv_count`) is read as a raw 64-bit
value and fed straight into `for _ in range(count)` in `_build_tensor_info` /
`_build_fields`, with no check against the bytes actually remaining in the file.
Setting the count field to `0xFFFFFFFF...` makes the reader try to build structures
for ~2⁶⁴ nonexistent entries, exhausting memory.
**Fix:** bound `count` by `remaining_bytes / min_entry_size` before looping.
**Prior art:** oss-security V-03 (May 2026) flags the Python reader specifically
(`n_dims = 0xFFFFFFFF` → ~32 GB memmap); the unbounded-count-as-loop-counter class
traces back to the 2024 Databricks disclosure and is a standing huntr bounty target.

---

## What I learned (the honest version)

- **Sanitizers are the whole game for C++ fuzzing.** ASan/UBSan converted vague
  crashes into `file:line` + bug-class in one shot. Building the target *with* them
  (not just running it) is what makes fuzzing productive.
- **Triage is the real skill, not the crash.** Reproduce → minimize → root-cause →
  classify severity. Minimizing the OOM to 48 bytes is what proves the allocation
  size is attacker-*declared*, not incidental.
- **Novelty-checking is non-negotiable.** Two of my findings I was briefly excited
  about turned out to be documented. Learning to reflexively check the issue
  tracker, oss-security, and CVE databases *before* claiming anything is the
  difference between a researcher and a script-runner.
- **Know when a target is mined out.** Consistently rediscovering documented bugs
  is the signal that a heavily-audited target won't yield a novel find in a solo
  week — and recognizing that is a research skill in itself.

---

## Reproduce it

```bash
docker build -t gguf-fuzz .
docker run --rm -it -v "${PWD}:/work" gguf-fuzz

# C++ parser (libFuzzer + ASan/UBSan)
./build.sh && python3 make_seed.py && ./run.sh

# Python reader (Atheris)
mkdir -p corpus crashes_py && cp seeds/valid.gguf corpus/
python3 ./fuzz_gguf_py.py -rss_limit_mb=2048 -timeout=20 -max_len=8192 \
        -artifact_prefix=crashes_py/ corpus/
```

`day1/` contains a deliberately-vulnerable toy target used to learn the
harness → crash → ASan → triage loop before pointing it at real code.

---

## Responsible disclosure

Findings were verified against existing public disclosures before any write-up.
Because all four proved to be **previously-reported known issues**, this repository
documents mechanisms and root causes (already public) but does **not** ship
weaponized reproducers for any unreported issue. If a genuinely novel bug had
surfaced, it would have gone through private coordinated disclosure first.

---

## Repo layout

```
Dockerfile            reproducible fuzzing environment (clang, sanitizers, Atheris)
build.sh / run.sh     build + run the C++ GGUF fuzzer
harness/fuzz_gguf.cpp libFuzzer harness for gguf_init_from_file()
fuzz_gguf_py.py       Atheris harness for the Python GGUFReader
make_seed.py          generates a valid .gguf seed
gguf.dict             libFuzzer dictionary (magic bytes + metadata keys)
day1/                 toy vulnerable target for learning the workflow
```
