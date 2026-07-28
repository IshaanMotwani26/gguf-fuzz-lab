# Reproducible fuzzing environment — everything baked in, nothing to reinstall.
#   docker build -t gguf-fuzz .
#   docker run --rm -it -v "${PWD}:/work" gguf-fuzz
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# clang            — required by both the C++ build AND atheris (won't use gcc)
# python3-dev      — Python.h headers; atheris compiles a C++ extension at install
# llvm-18          — provides llvm-symbolizer-18 for readable crash traces
# libclang-rt-18-dev — ASan + libFuzzer runtime for the C++ GGUF harness
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang cmake git build-essential ca-certificates \
      python3 python3-pip python3-dev \
      llvm-18 libclang-rt-18-dev \
 && rm -rf /var/lib/apt/lists/*

# atheris must build with clang; force it so pip doesn't fall back to gcc.
ENV CC=clang CXX=clang++

# gguf/numpy for building seeds + the Python target; atheris for Python fuzzing.
RUN pip3 install --break-system-packages --no-cache-dir gguf numpy pybind11
RUN pip3 install --break-system-packages --no-cache-dir --no-build-isolation atheris

WORKDIR /work
CMD ["/bin/bash"]
