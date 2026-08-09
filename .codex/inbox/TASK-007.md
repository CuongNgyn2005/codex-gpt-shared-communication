# TASK-007 — Optimize P1 CRC Hot Path

Status: `READY_FOR_IMPLEMENTATION`

## Purpose

TASK-006 isolated the remaining v90 packed-weight catalog HIT bottleneck on the ZCU104.

Measured for the same aggregate packed-weight volume:

```text
TARGET_BYTES = 8,784,248,832 B

production fused copy_stream_crc_store = 107.184 s
CRC-only median                        = 66.084 s   @ 126.769 MiB/s
FPGA DDR store-only median             = 18.478 s   @ 453.370 MiB/s
cached-store-only median               = 4.744 s    @ 1766.028 MiB/s
CPU frequency                           = 1,199,999 kHz
CPU governor                            = userspace
```

CRC-only is about 61.65% of the current fused production interval and is 3.576x slower than FPGA DDR store-only.

Therefore TASK-007 must optimize the **production CRC implementation** while preserving the exact CRC contract and fail-closed corruption detection.

Do not change FPGA DDR store semantics in this task.

---

## Reviewed baseline

Parent repository:

```text
repo   CuongNgyn2005/codex-gpt-shared-communication
branch main
commit 467aaeca031fca9c121a57a999abee1f55b34cfb
input  .codex/outbox/RESULT-006.md
```

Host committed baseline:

```text
repo    CuongNgyn2005/Infrastructure_GEMMA3
branch  main
commit  a09059d0c545e3c378212503901d1b21eb79895d
version zcu104-gemma3-q8-v90-prepack-hotpath
```

TASK-006 also created a local diagnostic benchmark implementation with intended v91 manifest:

```text
fpga-host-prepack-bench
--crc-only
--store-only
--cached-store-only
```

RESULT-006 states that diagnostic implementation was not yet committed/pushed to the host repo at the time of the report.

### Required starting-state rule

Before editing:

1. inspect the host worktree;
2. preserve the TASK-006 diagnostic benchmark changes if they are present;
3. verify `fpga-host-prepack-bench --crc-only` exists and reproduces the same CRC contract;
4. do not discard or overwrite uncommitted TASK-006 work;
5. if the benchmark changes are absent, recover/recreate only what is needed to retain the TASK-006 benchmark before optimizing CRC;
6. record the exact actual host baseline/worktree state in RESULT-007.

If repository policy requires explicit owner permission before branch creation/commit/push, do not violate that policy; report the candidate as pending instead.

No RTL modification is authorized.

---

# 1. Scope

Optimize only the CRC implementation used by the P1 packed-weight catalog path and its existing diagnostics/tests.

Primary production API behavior to preserve:

```text
fpga_p2_crc32_begin()
fpga_p2_crc32_update(...)
fpga_p2_crc32_final(...)
fpga_p2_crc32(...)
```

The exact function names may differ slightly in source; use the current production authority in `fpga_weight_layout.{h,cpp}`.

Do not change:

```text
CRC polynomial
CRC initial value
CRC final XOR
CRC byte ordering
metadata serialization
packed-weight bytes
scale bytes
catalog format
P2 weight layout
catalog state machine
corruption policy
volatile DDR stores
UIO mapping
mmap flags
store width
ZDMA
VPU
SPU
RTL
scheduler
preload
ping-pong
quantization
```

---

# 2. CRC correctness contract

The CRC remains reflected CRC-32:

```text
polynomial = 0xEDB88320
initial    = 0xFFFFFFFF
final      = bitwise NOT
```

The optimized implementation must be bit-identical to the existing implementation for every byte sequence and every incremental update boundary.

The following must remain true:

```text
CRC(one-shot data)
== CRC(data split into arbitrary chunks)
== CRC(data processed byte-by-byte)
```

The packed-weight catalog must continue to:

```text
BUILD: compute/store packed_crc32 and scale_crc32
HIT:   recompute packed CRC while staging the selected packed payload
       compare before DMA/START
       fail closed on mismatch
```

Scale CRC behavior must remain correct as well because it uses the same CRC authority.

Any CRC mismatch still requires:

```text
VALID -> POISONED
no DMA
no VPU START
no direct-pack fallback
no retry in the same model epoch
```

---

# 3. Required optimization strategy

First inspect the deployed/current CRC implementation and compiler target.

Current evidence says the v90 implementation is table-driven byte-at-a-time with a serial CRC-state dependency.

Implement the fastest safe option supported by the target while retaining a portable fallback.

## 3.1 Preferred path: ARMv8 CRC instructions when actually supported

On Linux AArch64, inspect runtime CPU capability using the normal Linux hardware-capability mechanism, for example `getauxval(AT_HWCAP)` with the appropriate CRC32 capability bit where available.

Do not assume hardware CRC support merely because the architecture is AArch64.

If both compiler and runtime support are available, add a hardware-accelerated CRC backend using standard ARM CRC intrinsics/instructions.

Requirements:

```text
runtime capability check before use
portable software fallback always available
no illegal instruction on CPUs without CRC extension
same reflected CRC-32 result
same begin/update/final API semantics
arbitrary input alignment supported
arbitrary byte length supported
arbitrary incremental chunk boundaries supported
```

Process larger chunks with the widest safe CRC intrinsic available, then handle the tail exactly.

Do not require changing the entire project architecture flag to `-march=...+crc` if that would make unrelated code require the CRC extension. Prefer a contained target-specific function or equivalent compiler-supported mechanism with runtime dispatch.

## 3.2 Portable fallback optimization

If hardware CRC instructions are unavailable, or as the software fallback, replace the serial byte-at-a-time hot path with an efficient table-driven multi-byte implementation such as slicing-by-8 or an equivalently proven method.

Requirements:

```text
portable C/C++
no per-call allocation
thread-safe
read-only initialized tables after setup
no undefined behavior from unaligned access
correct on little- and big-endian hosts, or explicitly byte-load/normalize as required
incremental API preserved
```

Do not keep the old byte-at-a-time table loop as the only production path if the board lacks hardware CRC support; TASK-007 must still attempt a meaningful software acceleration.

---

# 4. Runtime dispatch

CRC backend selection must occur outside the per-byte/per-16-byte hot loop.

Do not perform capability discovery or backend selection for every 16-byte payload block.

Preferred model:

```text
first use / static initialization
        ↓
select backend once
        ↓
software optimized OR ARM CRC backend
        ↓
all subsequent update calls use selected backend
```

The selection mechanism must be thread-safe and deterministic.

Add one concise process-level informational line, emitted at most once when FPGA host diagnostics are enabled, for example:

```text
[FPGA][INFO] CRC_BACKEND backend=armv8_crc32
```

or:

```text
[FPGA][INFO] CRC_BACKEND backend=slicing_by_8
```

Do not add per-job CRC logs.

---

# 5. Production fused copy must stay one-pass

TASK-004 already reduced packed-weight HIT handling to one logical source traversal:

```text
read packed source
    +
update CRC
    +
write exact bytes to staging DDR
```

Preserve this one-pass structure.

Do not reintroduce:

```text
pre-copy packed CRC scan
second metadata scan
second scale scan
```

After optimization the production path should remain conceptually:

```text
for selected packed payload:
    read source chunk
    update optimized CRC
    perform existing little-endian conversion
    perform existing four volatile 32-bit stores per 16 bytes
finalize CRC
compare expected CRC
only then allow normal DMA/START path
```

Do not alter the proven DDR staging semantics merely to make CRC vectorization easier.

---

# 6. Files expected to change

Keep the change small.

Expected primary files:

```text
ggml/src/ggml-cpu/fpga_weight_layout.h
ggml/src/ggml-cpu/fpga_weight_layout.cpp
tests/test-fpga-host-prepack.cpp
tests/fpga-host-prepack-bench.cpp            # if TASK-006 benchmark is present
ggml/src/ggml-cpu/fpga_host.cpp              # manifest/backend summary only if needed
ggml/src/CMakeLists.txt                       # only if target-specific compile wiring is needed
```

Do not edit RTL files.

Do not duplicate a separate CRC algorithm inside `fpga_host.cpp`.

`fpga_weight_layout.cpp` remains the production CRC authority.

---

# 7. Required correctness tests

Extend the board-free CRC test suite substantially.

Use an independent bitwise reference implementation in tests only.

For each test buffer, require:

```text
optimized one-shot CRC == reference CRC
optimized incremental CRC == reference CRC
```

Required lengths include at least:

```text
0
1
2
3
4
7
8
9
15
16
17
31
32
33
63
64
65
255
256
257
4095
4096
4097
65535
65536
65537
1 MiB + non-aligned tail
```

Also test deterministic pseudo-random buffers and multiple alignments:

```text
data pointer offsets 0..15
```

For incremental mode use chunk patterns including:

```text
1 byte
3 bytes
7 bytes
8 bytes
15 bytes
16 bytes
31 bytes
257 bytes
4096 bytes
mixed deterministic chunk sizes
```

Test that CRC state can be continued across calls exactly.

Retain existing corruption tests:

```text
flip packed byte -> mismatch detected
flip scale bit   -> mismatch detected
```

If multiple CRC backends exist, expose a test-only way to exercise every compiled backend directly and compare all of them with the independent reference.

Do not let runtime dispatch hide an untested fallback.

---

# 8. Benchmark requirements

Preserve TASK-006 benchmark modes.

The critical before/after measurement is:

```text
fpga-host-prepack-bench --crc-only
```

It must continue processing exactly:

```text
8,784,248,832 bytes
```

and must still produce:

```text
crc32=0xc7cc7ecf
```

for the deterministic TASK-006 benchmark data.

Keep `--store-only` and `--cached-store-only` unchanged so they remain controls.

Add the selected CRC backend name to CRC-only output, for example:

```text
CRC_ONLY mode=crc-only backend=armv8_crc32 bytes=8784248832 elapsed_us=... MiB_s=... crc32=0xc7cc7ecf
```

---

# 9. Versioning

When the optimized CRC is connected to production inference, bump the host manifest to a clear new version, for example:

```text
zcu104-gemma3-q8-v92-crc-fast
```

If the current local TASK-006 work already uses v91, preserve that chronology.

Do not change:

```text
stream protocol
bitstream ID
P2 ABI
P3 ABI
```

This remains a host-only change.

---

# 10. Board-free acceptance before ZCU104 test

Require:

```text
cmake --build build_mem -j2 --target fpga-host-prepack-selftest fpga-host-prepack-bench
./build_mem/bin/fpga-host-prepack-selftest
./build_mem/bin/fpga-host-prepack-bench --crc-only
```

On a non-AArch64 development machine, the portable backend must work and all tests must pass.

On AArch64 without CRC extension, the portable backend must work without illegal instructions.

Do not delete/recreate `build_mem`.

---

# 11. Exact owner ZCU104 benchmark commands

After the candidate builds on the board, run CRC-only three times:

```bash
for i in 1 2 3; do
  ./build_mem/bin/fpga-host-prepack-bench --crc-only
done
```

Run the unchanged control modes once or three times if convenient:

```bash
./build_mem/bin/fpga-host-prepack-bench --cached-store-only
sudo ./build_mem/bin/fpga-host-prepack-bench --store-only
```

Capture CPU state:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
```

Return complete output.

---

# 12. CRC benchmark performance gate

TASK-006 ZCU104 baseline:

```text
CRC-only median = 66,083,527 us
throughput      = 126.769 MiB/s
```

Minimum acceptance:

```text
CRC-only median < 33,041,764 us
```

That is at least a 2x CRC-only speedup.

Preferred target:

```text
CRC-only median <= 15,000,000 us
```

Do not weaken correctness or corruption detection to meet either target.

If the minimum 2x gate is not met, report the generated/backend path and bottleneck evidence before attempting a more invasive change.

---

# 13. Required production inference test after CRC benchmark passes

Only after CRC correctness passes and CRC-only improves by at least 2x, run the same isolated inference configuration used for v90:

```bash
sudo rm -f /tmp/fpga_debug.log

sudo env \
  -u FPGA_P2_TERMINAL_TRACE \
  -u FPGA_P2_EVENT_TRACE \
  -u FPGA_P2_FIRST_ACT_TRACE \
  -u FPGA_P2_BOUNDARY_DIAGNOSTICS \
  -u FPGA_LOG_FLUSH_EVERY \
  FPGA_HOST_WEIGHT_PREPACK=1 \
  FPGA_P2_INPUT_PRELOAD=0 \
  FPGA_P2_PACK_WORKERS=2 \
  FPGA_WEIGHT_CACHE=0 \
  FPGA_ABORT_ON_CPU_FALLBACK=1 \
  FPGA_ACCELERATE_VOCAB=0 \
  FPGA_TOKEN_TIMING=1 \
  FPGA_BOTTLENECK_SUMMARY=1 \
  ./build_mem/bin/llama-cli \
    -m ./models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 1 \
    --single-turn \
    --no-warmup \
    --temp 0
```

Return full console output and `/tmp/fpga_debug.log`.

---

# 14. Production functional acceptance

Require the same functional behavior as v90:

```text
eligible FPGA matmuls = 182
q8_hw_completed       = 182
intentional vocab CPU bypass = 1
unexpected CPU fallback      = 0

HOST_PREPACK:
builds    = 182
misses    = 182
hits      = 27842
fallbacks = 0
prep_direct_weight_pack_us = 0

metadata_full_hotpath_scans = 0
packed_pre_crc_scans        = 0
scale_pre_crc_scans         = 0
```

Also require:

```text
no CRC mismatch on uncorrupted workload
no POISON event
no DDR range violation
no ZDMA error
no P2 stream drop/error
same deterministic model output behavior
```

The FPGA-safe DDR range remains strictly:

```text
[0x70000000,0x80000000)
```

---

# 15. Production performance acceptance

v90 reference:

```text
copy_us                  = 107.214 s
copy_stream_crc_store_us = 107.184 s
prep_total_ms            = 137056.306 ms
token_wall_ms            = 166335.922 ms
prompt eval              = 166413.95 ms
```

TASK-007 minimum production goal:

```text
copy_us < 95.087 s
```

This is the original TASK-004 2x-v89 copy gate that v90 narrowly missed.

Preferred production target after CRC acceleration:

```text
copy_us <= 60 s
```

Do not assume CRC-only speedup transfers one-for-one into the fused production loop. Measure it.

Do not interpret `ip_compute_sum_ms` as pure PL compute time; the scheduler timing remains host-observation-contaminated.

---

# 16. Stop conditions

Stop and report rather than broadening scope if any of these occurs:

```text
optimized CRC differs from reference
incremental CRC differs at any chunk boundary
hardware backend causes illegal instruction
runtime dispatch is ambiguous
corruption test no longer fails closed
store-only behavior changes
UIO/DDR semantics need modification
RTL change appears necessary
production numerical output changes
```

Do not start DDR-store optimization in TASK-007.

---

# 17. Required RESULT-007.md

Write:

```text
.codex/outbox/RESULT-007.md
```

with:

```text
1. Exact host starting state and candidate state
2. Files changed
3. CRC implementation before/after
4. Runtime backend selection logic
5. CRC equivalence/corruption test evidence
6. Board-free build/test result
7. ZCU104 CRC-only three-run results and median
8. CRC backend actually selected on ZCU104
9. Store-only control result
10. Production inference before/after table
11. Functional acceptance PASS/FAIL
12. CRC performance acceptance PASS/FAIL
13. Production copy performance acceptance PASS/FAIL
14. Remaining dominant bottleneck
15. Recommended next action
```

Do not overwrite RESULT-006.

TASK-007 is complete only after the optimized CRC is proven bit-identical and the owner returns the ZCU104 CRC-only and production inference measurements.