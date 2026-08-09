# TASK-006 — Isolate CRC vs FPGA DDR Staging Cost

Status: `READY_FOR_IMPLEMENTATION`

## Purpose

TASK-004/v90 made the static-weight prepack path functionally correct and much faster, but the remaining catalog HIT cost is still dominated by one fused loop:

```text
copy_stream_crc_store_us = 107,183,966 us
copy_payload_bytes       = 8,784,248,832 B
```

RESULT-005 concludes that current evidence cannot separate this 107.18 s into:

```text
A. CRC computation
B. cached catalog source reads
C. endian/conversion loop overhead
D. volatile/O_SYNC FPGA staging-DDR stores
```

TASK-006 must add **diagnostic benchmarks only** so the owner can measure these components on the ZCU104 before any further optimization is attempted.

Do not optimize the production inference path in this task.

---

## Reviewed baseline

Parent repository:

```text
repo   CuongNgyn2005/codex-gpt-shared-communication
branch main
latest reviewed parent commit: 39646257ffb4b36f5988180b3c5f0cf0e488a352
input report: .codex/outbox/RESULT-005.md
```

Host child:

```text
repo    CuongNgyn2005/Infrastructure_GEMMA3
branch  main
commit  a09059d0c545e3c378212503901d1b21eb79895d
change  host: optimize P1 prepack hot path
version zcu104-gemma3-q8-v90-prepack-hotpath
```

Before editing:

1. fetch the host child;
2. verify `a09059d0c545e3c378212503901d1b21eb79895d` exists;
3. inspect staged/unstaged changes;
4. if `main` has advanced beyond the reviewed commit, inspect the diff before editing and record the actual baseline in the result;
5. create a dedicated diagnostic branch, for example:

```text
task-006-prepack-bench
```

No RTL modification is authorized.

---

# 1. Scope

Add one standalone diagnostic executable:

```text
fpga-host-prepack-bench
```

Required modes:

```text
--crc-only
--store-only
```

Optional but recommended:

```text
--cached-store-only
```

The benchmark exists only to measure the current v90 implementation primitives. It must not change normal `llama-cli` behavior.

Do not change:

```text
production catalog lookup
production packed-weight copy algorithm
production CRC contract
production DDR mapping
UIO mmap flags
volatile semantics
store width
ZDMA
VPU/SPU
RTL
P2 layout
bank ownership
preload scheduler
quantization
```

---

# 2. Common benchmark contract

Use the same aggregate byte volume measured by the v90 prompt:

```text
TARGET_BYTES = 8,784,248,832 bytes
```

The executable must print machine-readable summary lines containing at least:

```text
mode=
bytes=
elapsed_us=
MiB_s=
checksum_or_sink=
```

Also print, when available:

```text
cpu_model=
cpu_freq_khz=
governor=
```

Use a monotonic wall-clock timer.

Avoid logging inside the timed inner loop.

The benchmark must process the exact requested aggregate byte count or print the exact actual count if an implementation constraint requires rounding. Any rounding must be explicit.

Use deterministic source data so repeated runs are comparable.

Run a short untimed warm-up before the timed section where appropriate, but do not include it in `elapsed_us`.

Prevent the compiler from removing benchmark work by consuming the final CRC or sink value in observable output.

---

# 3. CRC-only benchmark

`--crc-only` must measure the current production CRC implementation with **no UIO/FPGA DDR access**.

Requirements:

1. Allocate a representative normal cached host buffer. It does not need to allocate 8.784 GB at once; reuse a bounded buffer repeatedly.
2. Fill it deterministically.
3. Process exactly `TARGET_BYTES` through the same production CRC update/finalization implementation used by v90.
4. Perform no FPGA init, no UIO mmap, no `/dev/mem`, no ZDMA, no MMIO and no FPGA START.
5. Keep the data hot/cached after warm-up so this primarily measures the production CRC + normal source-read loop rather than filesystem/model loading.
6. Report:

```text
CRC_ONLY mode=crc-only bytes=8784248832 elapsed_us=<...> MiB_s=<...> crc32=0x........
```

The CRC polynomial/init/final contract remains:

```text
polynomial = 0xEDB88320
initial    = 0xFFFFFFFF
final      = bitwise NOT
```

Do not substitute another CRC algorithm for the benchmark.

---

# 4. Store-only benchmark

`--store-only` must measure the existing v90 catalog-to-staging store primitive with CRC disabled.

This benchmark is board-facing and must be fail-closed.

## 4.1 DDR safety

The only FPGA-safe reserved physical DDR range is:

```text
[0x70000000, 0x80000000)
```

Never access outside it.

Use only the existing valid WEIGHT staging slots:

```text
slot 0 offset = 0x00100000
slot 1 offset = 0x00180000
maximum current slot payload = 0x80000 bytes
```

relative to `DDR_BASE_PHYS`.

Do not walk sequentially through the entire 8.784 GB address space. Reuse one legal staging slot repeatedly until aggregate written bytes reach `TARGET_BYTES`.

Every pass must use the existing physical-range and mapped-range validation before dereference.

## 4.2 Hardware must remain idle

The benchmark must not:

```text
publish slot READY to production scheduling
submit a ZDMA descriptor
start ZDMA
write VPU START
write SPU START
launch inference
modify production bank ownership
```

Before the timed benchmark, verify the device is idle using existing safe status checks if available. If idle cannot be proven, exit nonzero without writing DDR.

Use only CPU writes into the staging slot.

## 4.3 Preserve existing write semantics

Use the same source-to-staging conversion/store primitive as v90 except CRC must be disabled for this diagnostic mode.

Preserve:

```text
/dev/uio15 mapping path used by production when available
O_SYNC
MAP_SHARED
volatile destination semantics
four 32-bit destination stores per 16-byte payload block
existing little-endian word construction
existing DDR range checks
```

Do not use `memcpy`, NEON, 64-bit stores, 128-bit stores, nonvolatile casts, alternate mmap attributes, write combining, or a different UIO mapping in TASK-006.

Use deterministic cached source data.

Repeatedly write a valid payload-sized chunk into one legal slot until aggregate bytes reach `TARGET_BYTES`.

After the timed loop, perform the existing safe coherency/readback sequence outside the timer unless RESULT-005 requires it to be part of the production inner-store timing. State exactly what is inside and outside the timed interval.

Report:

```text
STORE_ONLY mode=store-only bytes=8784248832 elapsed_us=<...> MiB_s=<...> sink=0x........
```

The sink value should depend on a safe readback or deterministic source value so the compiler cannot discard preparation work.

---

# 5. Optional cached-store baseline

If simple to add without touching production behavior, implement:

```text
--cached-store-only
```

This mode performs the same:

```text
16-byte loop
little-endian word construction
four 32-bit stores
```

but writes to ordinary cached host RAM rather than volatile UIO DDR and performs no CRC.

Purpose:

```text
store-only - cached-store-only
```

helps expose the approximate extra cost of the volatile FPGA staging destination.

Report:

```text
CACHED_STORE_ONLY mode=cached-store-only bytes=8784248832 elapsed_us=<...> MiB_s=<...> sink=0x........
```

This mode is optional; CRC-only and store-only are mandatory.

---

# 6. Build integration

Prefer a standalone diagnostic source under the existing test/diagnostic area and reuse board-free production helpers rather than copying CRC/layout logic.

Expected files are likely limited to:

```text
a new benchmark source file
ggml/src/CMakeLists.txt or the existing FPGA test build owner
```

If a tiny board-facing wrapper is required to expose the existing safe DDR staging primitive, keep it explicitly diagnostic and do not alter normal inference behavior.

Do not duplicate the CRC algorithm or P2 endian/store logic merely for benchmarking.

Build target:

```text
fpga-host-prepack-bench
```

Expected build command:

```bash
cmake --build build_mem -j2 --target fpga-host-prepack-bench
```

Do not delete or recreate `build_mem`.

---

# 7. Board-free correctness checks before store-only use

Before asking the owner to run `--store-only`, prove locally/boardlessly that:

1. CRC-only mode uses the production CRC and returns deterministic results.
2. Store-only loop writes byte-for-byte the same 16-byte -> four-word representation into a normal-memory fake sink.
3. Aggregate-byte counting cannot overflow.
4. Slot-offset + per-pass byte checks reject anything outside the configured slot.
5. `TARGET_BYTES` loop/remainder handling is exact.
6. No DMA/MMIO START call is reachable from the benchmark data path.

The executable must fail nonzero on invalid arguments, unsafe range, mapping failure, or non-idle hardware.

---

# 8. Exact owner board commands

After Codex implements and pushes the diagnostic branch, the owner will run:

```bash
cmake --build build_mem -j2 --target fpga-host-prepack-bench
```

Then CRC-only:

```bash
./build_mem/bin/fpga-host-prepack-bench --crc-only
```

Then store-only:

```bash
sudo ./build_mem/bin/fpga-host-prepack-bench --store-only
```

If implemented:

```bash
./build_mem/bin/fpga-host-prepack-bench --cached-store-only
```

Also capture CPU frequency/governor around the test:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
```

The owner must return the complete benchmark output.

---

# 9. Interpretation contract

Do not claim that standalone timings must sum exactly to the fused 107.18 s production interval. Cache state and CRC/store interaction may differ.

Use the benchmark only to identify the dominant component.

Interpretation:

```text
crc_only_us >> store_only_us
    -> CRC is the primary next optimization target

store_only_us >> crc_only_us
    -> volatile FPGA DDR staging is the primary next optimization target

similar magnitude
    -> both contribute; inspect interaction/loop cost before changing architecture
```

If the results are too close or inconsistent across runs, run each mode three times and compare median values before deciding.

Do not optimize anything as part of TASK-006 based on the benchmark result. Return the evidence first.

---

# 10. Acceptance

TASK-006 passes when:

```text
fpga-host-prepack-bench builds successfully
crc-only runs without FPGA access
store-only proves legal DDR slot range before every board-facing access
store-only issues no DMA and no VPU/SPU START
store-only preserves current volatile 32-bit staging semantics
both mandatory modes process the requested aggregate byte count
both modes report elapsed_us and MiB/s
normal llama-cli production behavior is unchanged
no RTL file changed
```

TASK-006 is a diagnostic task. There is no token/s performance gate.

---

# 11. Required result

Write:

```text
.codex/outbox/RESULT-006.md
```

with exactly:

```text
1. Exact baseline and candidate commit
2. Files changed
3. Proof normal inference path is unchanged
4. Benchmark implementation summary
5. CRC-only safety/correctness evidence
6. Store-only DDR/idle/no-DMA safety evidence
7. Build/test result
8. Exact owner board commands
9. Owner board measurements once returned
10. Verdict: CRC / DDR STORE / BOTH / NOT PROVEN
11. Recommended next optimization, but do not implement it
```

Do not overwrite RESULT-005.

TASK-006 is complete only after the owner returns the ZCU104 CRC-only and store-only measurements.