#!/usr/bin/env python3
"""
Create a tiny but structurally-VALID .gguf to seed the fuzzer corpus.

Why: coverage-guided fuzzers work best when they start from a real, well-formed
example and mutate outward. Give it one valid file and it learns the format's
shape almost immediately instead of spending billions of iterations guessing the
4-byte magic and header layout.

Requires:  pip install gguf numpy   (already installed in the Docker image)

If this API has drifted (gguf-py changes occasionally), the easy fallback is:
just copy ANY small real .gguf you have lying around into seeds/valid.gguf —
e.g. a tiny quantized model. Any valid file works as a seed.
"""
import os
import numpy as np
import gguf

os.makedirs("seeds", exist_ok=True)
OUT = "seeds/valid.gguf"

writer = gguf.GGUFWriter(OUT, arch="fuzzseed")

# A couple of metadata values across a few types.
writer.add_uint32("answer", 42)
writer.add_string("general.name", "fuzz-seed")
writer.add_uint32("fuzzseed.block_count", 1)

# One tiny tensor so the tensor-info table is exercised too.
tensor = np.zeros((4, 4), dtype=np.float32)
writer.add_tensor("blk.0.weight", tensor)

writer.write_header_to_file()
writer.write_kv_data_to_file()
writer.write_tensors_to_file()
writer.close()

print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes)")
