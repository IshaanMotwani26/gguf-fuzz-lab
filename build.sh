#!/usr/bin/env bash
# Build the fuzzer: instrument ggml with AddressSanitizer + coverage, then link
# our harness against it with libFuzzer. Run inside the Docker image (see README).
set -euo pipefail

REPO="${REPO:-https://github.com/ggml-org/llama.cpp.git}"

# ── 1. Get the target source (MIT-licensed; fuzzing + responsible reporting OK).
if [ ! -d llama.cpp ]; then
  git clone --depth 1 "$REPO" llama.cpp
fi

# ── 2. Build ggml (which contains the GGUF parser) WITH sanitizers + coverage.
#   -fsanitize=address        → catch out-of-bounds / use-after-free (the bugs)
#   -fsanitize=undefined      → catch integer overflow / UB (GGUF bugs love these)
#   -fsanitize=fuzzer-no-link → add coverage instrumentation but NO main()
#   -O1 -g                    → fast enough to fuzz, with symbols for triage
SAN_FLAGS="-g -O1 -fsanitize=address,undefined,fuzzer-no-link -fno-omit-frame-pointer"

cd llama.cpp
cmake -B build-fuzz \
  -DCMAKE_BUILD_TYPE=Debug \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_CURL=OFF \
  -DGGML_NATIVE=OFF \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_FLAGS="$SAN_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SAN_FLAGS"
# Build just the ggml libraries (we don't need the whole CLI).
cmake --build build-fuzz --target ggml -j"$(nproc)" || \
  cmake --build build-fuzz -j"$(nproc)"   # fallback: build everything
cd ..

# ── 3. Compile our harness and link it against the instrumented static libs.
GGML_INC="llama.cpp/ggml/include"
# Grab every libggml*.a the build produced (base, cpu, etc.). If the linker
# still complains about undefined symbols, add the missing lib to this list —
# that iteration is normal and expected with a fast-moving target.
LIBS="$(find llama.cpp/build-fuzz -name 'libggml*.a' | tr '\n' ' ')"

clang++ -g -O1 -std=c++17 \
  -fsanitize=address,undefined,fuzzer \
  -fno-omit-frame-pointer \
  -I"$GGML_INC" \
  harness/fuzz_gguf.cpp \
  $LIBS \
  -o fuzz_gguf

echo
echo "✅ Built ./fuzz_gguf"
echo "   Next:  ./run.sh"
