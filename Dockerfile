# Reproducible fuzzing environment. Build once, and you never fight a Windows
# toolchain again — everything (clang, cmake, libFuzzer, ASan) lives in here.
#
#   docker build -t gguf-fuzz .
#   docker run --rm -it -v "$PWD":/work gguf-fuzz
#   # then, inside the container:
#   ./build.sh && python3 make_seed.py && ./run.sh
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      clang \
      cmake \
      git \
      build-essential \
      ca-certificates \
      python3 \
      python3-pip \
 && rm -rf /var/lib/apt/lists/*

# gguf-py lets make_seed.py build a valid seed file; numpy is its dependency.
RUN pip3 install --break-system-packages --no-cache-dir gguf numpy

WORKDIR /work
CMD ["/bin/bash"]
