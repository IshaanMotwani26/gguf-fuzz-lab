# GGUF Parser Fuzzing Lab

Coverage-guided fuzzing of the **GGUF model-file parser** used by `llama.cpp` /
`ggml` — the code that every local-AI stack (Ollama, LM Studio, and llama.cpp
itself) runs the moment it opens a model file. The goal: find memory-safety bugs
in an attacker-reachable AI parser, root-cause them, and report them responsibly.

> **Why this is a real project, not a tutorial rerun.** AI inference engines parse
> binary model formats in C/C++, and those parsers leak memory-corruption bugs
> constantly — integer overflows, out-of-bounds reads, null-pointer dereferences.
> A malicious `.gguf` file downloaded from a model hub can trigger them at load
> time, before inference even starts. That's the attack surface you're testing.

---

## Concept primer (skip if you already fuzz)

- **Fuzzing** = feeding a program a flood of malformed inputs to make it crash.
- **Coverage-guided fuzzing** (libFuzzer, AFL++) is the smart kind: the fuzzer
  instruments the target, notices when an input reaches a *new* code path, and
  keeps that input as a seed to mutate further. Over time it "learns" the format
  well enough to reach deep, rarely-run code.
- **Harness** = the small glue function the fuzzer calls. For libFuzzer it's
  `LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)`; its only job is to
  turn raw bytes into a call to the function you want to test. (That's
  `harness/fuzz_gguf.cpp`.)
- **Sanitizer** = a compiler feature that makes bugs *loud*. **AddressSanitizer
  (ASan)** aborts with a precise stack trace the instant the program reads or
  writes out of bounds — turning a silent, maybe-exploitable corruption into an
  obvious crash. **UBSan** catches integer overflow and other undefined behavior
  (GGUF bugs love integer overflow).
- **Corpus** = the folder of inputs the fuzzer keeps and mutates.
- **Dictionary** = a list of interesting tokens (like the `GGUF` magic bytes) so
  the fuzzer stops guessing exact-match gates byte-by-byte.
- **Triage** = taking a raw crash and figuring out *what* and *why*: minimize it,
  find the faulting line, classify the bug, judge its impact.

---

## Setup (once)

You want **Linux** for this (libFuzzer + ASan). On Windows use **WSL2 (Ubuntu)**
or just the Docker image below — Docker is the least painful and gives you a
reproducible environment so you never fight a toolchain again.

```bash
docker build -t gguf-fuzz .
docker run --rm -it -v "$PWD":/work gguf-fuzz
# You're now inside the container, in /work:
./build.sh            # clone llama.cpp, build ggml w/ ASan+coverage, link harness
python3 make_seed.py  # create seeds/valid.gguf
./run.sh              # fuzz!
```

If the **link step** fails with "undefined symbol", add the missing `libggml-*.a`
to the `LIBS` line in `build.sh`. This iteration is normal — the target moves
fast. If the **header** isn't found, run
`grep -rl gguf_init_from_file llama.cpp/ggml/include` and fix the `#include` in
the harness.

---

## The week, day by day

### Day 1 — Learn the workflow on a *toy* target first
Don't start on llama.cpp. Do one end-to-end cycle on a deliberately-vulnerable
mini-target so the mechanics click: write a 10-line harness around a function
with a known bug, compile with `clang++ -fsanitize=address,fuzzer`, watch ASan
catch it, read the trace. (8kSec's beginner fuzzing lab, linked in RESOURCES, is
perfect for this.) **Deliverable:** you can explain "harness → coverage → ASan
crash" in your own words.

### Day 2 — Build the real harness and get it running
Use this scaffold. Get `./build.sh` green, generate a seed, and confirm the
fuzzer is actually executing the parser (libFuzzer prints `cov:` climbing and
`exec/s`). **Sanity check that matters:** if coverage never grows, your harness
isn't reaching the target — fix that before letting it run. **Deliverable:**
fuzzer running at a healthy exec/s with coverage increasing.

### Day 3 — Make it *effective*, then let it soak
Improve throughput and depth:
- Seed with a couple of different valid `.gguf` files (different metadata types,
  a tokenizer array, a few tensors).
- Confirm the `-dict` is loaded.
- (Advanced, optional) A **structure-aware** harness that fixes length fields
  after mutation lands far more inputs on real parsing logic — the biggest lever
  for structured formats.

Then let it run for hours in the background. **Deliverable:** a soak run going,
corpus growing.

### Days 4–5 — Triage crashes (the real skill)
When `crashes/crash-*` files appear, for each one:
1. **Reproduce:** `./fuzz_gguf crashes/crash-<id>` → confirm ASan fires again.
2. **Minimize:** `./fuzz_gguf -minimize_crash=1 -runs=100000 crashes/crash-<id>`
   → shrink to the smallest input that still crashes.
3. **Root-cause:** read the ASan report (bug type + faulting function + line).
   Open that source file. Explain *why* in one paragraph: which length/field was
   trusted without validation? See TRIAGE below for the template.
4. **Classify:** null-deref / OOB read / OOB write / integer overflow / DoS. OOB
   *write* is the most severe (write-what-where → potential RCE); null-deref is
   usually DoS. Be honest about impact — overclaiming is a rookie tell.

**Deliverable:** 1–3 minimized, root-caused findings. Even one clean, well-explained
finding is a strong result. Reproducing a *known* bug (see RESOURCES for the CVE
references) with your own harness and analysis absolutely counts.

### Day 6 — Disclose responsibly (do this right; recruiters notice)
See DISCLOSURE below. Short version: report privately first, give maintainers
time, don't publish weaponized exploits, coordinate the public writeup.

### Day 7 — Write it up
Turn the repo into the portfolio piece. Your README should tell the story:
target and why it matters → harness design → how you drove coverage → the
findings with minimized reproducers and root-cause analysis → impact assessment →
disclosure timeline. Keep exploit detail responsible. Then the LinkedIn post.

---

## TRIAGE — root-cause template (copy per finding into `findings/NN.md`)

```
### Finding NN — <one-line summary>
- Target commit: <git rev-parse HEAD of llama.cpp>
- Crash type (ASan): <heap-buffer-overflow READ | null deref | int overflow | ...>
- Faulting function / file:line: <from the ASan trace>
- Minimized reproducer: findings/NN.gguf  (<size> bytes)

**Root cause.** <Which field was read from the file and trusted? Which bounds
check is missing or wrong? Why does the mutated input drive execution there?>

**Impact.** <DoS / info-leak / potential memory corruption. What can an attacker
who controls the .gguf actually do? Be precise, don't overclaim.>

**Suggested fix.** <e.g. validate length before allocation; check pointer for
NULL before deref; use checked arithmetic on the size field.>
```

---

## DISCLOSURE — do this the professional way

Fuzzing MIT-licensed open-source and reporting what you find is legitimate,
welcomed security research. Doing the *disclosure* well is what separates a
researcher from someone who just ran a tool.

1. **Report privately first.** Use the project's security policy /
   `SECURITY.md`, or GitHub's **"Report a vulnerability"** (private security
   advisory) on the repo. Do **not** open a public issue for a memory-safety bug.
2. **Give a clear, minimal report:** affected commit, build flags, the ASan
   trace, the minimized reproducer, your root-cause paragraph, and suggested fix.
3. **Give them time.** Standard coordinated-disclosure windows are ~90 days.
   Don't publish details or reproducers until there's a fix or the window passes.
4. **Don't build or publish weaponized exploits.** A crash PoC + analysis is the
   deliverable. Turning an OOB write into a working RCE and releasing it is not.
5. **Request a CVE** through the project or a CNA once it's fixed — that's the
   line that reads best on a résumé, and you earned it by doing steps 1–4 right.

If you're unsure whether something is safe to publish, default to *ask the
maintainers first*.

---

## RESOURCES (real, current)

- **Snyk Labs — fuzzing a GGUF parser (Cortex.cpp):** the canonical worked
  example of exactly this harness pattern (the `#ifdef FUZZ` trick, `clang++
  -fsanitize=address`, buffer-vs-file parse, triage). Your #1 reference.
- **8kSec — "AI-Assisted Fuzzing: libFuzzer harnesses":** beginner-friendly
  primer on harness + sanitizer + dictionaries + structure-aware harnesses,
  with a downloadable first-timer lab. Use for Day 1.
- **GGUF parser CVEs to study / reproduce:** `CVE-2024-41130` (null-pointer
  dereference in `gguf_init_from_file` in ggml). Also read the May 2026
  oss-security thread disclosing multiple llama.cpp GGUF parser flaws — great
  root-cause reading and proof the surface is fruitful.
- **AFL++ docs** and **libFuzzer docs** — the two fuzzer options. This scaffold
  uses libFuzzer (simplest to start); AFL++ is a strong alternative once you're
  comfortable.
- **`ggml-org/llama.cpp`** — the target repo. GGUF parsing lives in the `ggml`
  subtree; entry point `gguf_init_from_file`.

---

## Files in this scaffold

| file | what it does |
|---|---|
| `Dockerfile` | reproducible clang/cmake/libFuzzer environment |
| `build.sh` | clone llama.cpp, build ggml with ASan+coverage, compile harness |
| `run.sh` | seed corpus + launch libFuzzer with the dictionary |
| `harness/fuzz_gguf.cpp` | the libFuzzer harness (the core of the project) |
| `make_seed.py` | generate a valid `.gguf` seed |
| `gguf.dict` | dictionary of magic bytes + metadata keys |
| `findings/` | (you create) one root-cause writeup per bug |
