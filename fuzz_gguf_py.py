#!/usr/bin/env python3
"""
Atheris fuzz harness for the PYTHON gguf reference reader (gguf.GGUFReader).

WHY THIS TARGET: the C++ GGUF parser in llama.cpp is fuzzed to death (OSS-Fuzz +
a formal 2026 audit). The Python reference reader is far less picked-over and the
audit noted it skips validation the C++ side performs — a genuinely softer target.

WHAT COUNTS AS A BUG HERE: Python is memory-safe, so we're not hunting buffer
overflows. A finding is one of:
  • an UNEXPECTED, uncaught exception type — the reader should reject bad input
    cleanly (ValueError). A KeyError / IndexError / struct.error / OverflowError
    leaking out means a normal caller's `except ValueError` won't catch it, so a
    crafted file crashes the tool. That's a denial-of-service-class robustness bug.
  • resource exhaustion — a small file that triggers a giant allocation
    (caught by -rss_limit_mb) or an infinite hang (caught by -timeout). Highest value.

TRIAGE WORKFLOW (this is the Day 3 method):
  1. Run. When it crashes on an uncaught exception, read the type + gguf_reader.py line.
  2. Decide: would a careful caller EXPECT this? Documented ValueError = expected.
     A surprising exception type = a real finding — log it (save the crash file).
  3. To hunt the NEXT distinct bug, add the exception type you just triaged to the
     EXPECTED tuple below, then re-run. Repeat until no new types appear.
  4. Goal: enumerate ALL the undocumented exception classes → a hardening report.

Findings already confirmed on first runs (add more as you go):
  • KeyError  — duplicate field name (_push_field)          [low: deliberate raise, wrong type]
  • IndexError — empty tensor dimension array (_get_tensor_info_field) [unintended validation gap]
"""
import sys, os, tempfile
import atheris

with atheris.instrument_imports():
    from gguf import GGUFReader

# Exceptions we've triaged as "expected / already-logged". Start with ValueError
# (the reader's documented rejection). As you confirm each new finding, add its
# type here so the fuzzer moves on to the next distinct bug instead of re-hitting
# the same one. e.g. after logging the KeyError:  EXPECTED = (ValueError, KeyError)
EXPECTED = (ValueError, KeyError, IndexError)

def TestOneInput(data):
    if len(data) < 8:
        return
    fd, path = tempfile.mkstemp(suffix=".gguf")
    try:
        os.write(fd, data)
        os.close(fd)
        try:
            reader = GGUFReader(path, "r")
            _ = reader.fields      # force the lazy metadata-field parse
            _ = reader.tensors     # force the tensor-info parse
        except EXPECTED:
            pass                   # reader rejected it as designed — not a finding
    finally:
        try: os.close(fd)
        except OSError: pass
        try: os.unlink(path)
        except OSError: pass

atheris.Setup(sys.argv, TestOneInput)
atheris.Fuzz()
