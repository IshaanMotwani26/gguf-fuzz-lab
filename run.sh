#!/usr/bin/env bash
# Launch the fuzzer. Crashes get saved to crashes/ ; interesting inputs that
# reach new code accumulate in corpus/.
set -euo pipefail

mkdir -p corpus crashes

# Seed the corpus with a structurally-valid .gguf if we have one. Starting from
# a real file (then mutating outward) is the single biggest speedup for a
# structured binary format — the fuzzer doesn't have to guess the header.
if [ -f seeds/valid.gguf ]; then
  cp -n seeds/valid.gguf corpus/ 2>/dev/null || true
fi

# -dict           : tokens (magic bytes, metadata keys) so mutations are smarter
# -max_len        : cap input size (GGUF headers don't need megabytes to break)
# -rss_limit_mb   : kill a run that balloons memory (also a finding worth noting)
# -artifact_prefix: where crash-reproducer files are written
exec ./fuzz_gguf \
  -dict=gguf.dict \
  -max_len=1048576 \
  -rss_limit_mb=4096 \
  -print_final_stats=1 \
  -artifact_prefix=crashes/ \
  corpus
