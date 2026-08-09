# TASK-004 — Optimize P1 Static-Weight Prepack Hot Path

Status: `READY_FOR_IMPLEMENTATION`

## Purpose

TASK-003 proved that the P1 host-DRAM packed-weight catalog concept works, but the catalog-hit hot path is far too expensive on the ZCU104.

This task fixes **only the host-side P1 reuse path** before any further FPGA/RTL optimization.

The goal is:

```text
Q8_0 tensor
    -> BUILD once per model epoch
    -> immutable VALID catalog entry
    -> later HIT
    -> one necessary packed-data traversal while staging
    -> one necessary scale traversal while building SPU_PARAM
    -> existing ZDMA/VPU/SPU path unchanged
```

Do not redesign the FPGA datapath in this task.

---

## Reviewed baseline

Host child:

```text
repo    CuongNgyn2005/Infrastructure_GEMMA3
branch  main
commit  cc8d475057e5a05045fb351eb7a52e56f3de9f21
version zcu104-gemma3-q8-v89-tile-scale-span
```

Parent investigation input:

```text
.codex/outbox/RESULT-004.md
parent commit b7c58580e4edf6971021b798159a421d480ab067
```

Before editing:

1. fetch the host child;
2. verify `cc8d475057e5a05045fb351eb7a52e56f3de9f21` is present;
3. verify the implementation still identifies itself as `zcu104-gemma3-q8-v89-tile-scale-span`;
4. inspect staged and unstaged changes;
5. create a dedicated implementation branch from the reviewed baseline, for example:

```text
task-004-prepack-hotpath
```

If `Infrastructure_GEMMA3/main` has advanced beyond `cc8d475`, stop before editing, inspect the new diff, and record the actual baseline. Do not silently implement against unreviewed behavior.

No RTL child modification is authorized by TASK-004.

---

## Board evidence that drives this task

Current v89 board run:

```text
matmuls=182
vpu_runs=27842

HOST_PREPACK:
builds=182
misses=182
hits=27842
fallbacks=0
bytes=741538304
build_us=10777285
copy_us=190173577
prep_direct_weight_pack_us=0

PREPARATION:
prep_total_ms=223265.912
prep_weight_select_ms=11554.167
prep_scale_pack_ms=21353.752
prep_act_pack_ms=80.208
prep_other_ms=190277.785

WEIGHT:
weight_bytes=8784248832
weight_dma_ms=4692.101

TIMING:
token_wall_ms=254298.680
ip_compute_sum_ms=199964.187
prep_overlap_ms=199000.219

RUN:
prompt eval ~= 254.664 s
total process ~= 315.092 s
```

RESULT-004 established:

- catalog reconstruction is not the current problem;
- 182 misses/builds followed by 27,842 hits is consistent with one build per eligible tensor;
- `copy_us=190.174 s` is the largest directly measured P1 host cost;
- the copy path performs repeated metadata/CRC work plus 549,015,552 16-byte iterations and 2,196,062,208 volatile 32-bit staging stores;
- `prep_weight_select_ms=11.554 s` contains about `10.777 s` of first-use catalog construction, so normal post-build lookup is secondary;
- `prep_scale_pack_ms=21.354 s` still contains repeated static-scale/metadata validation and staging work;
- `ip_compute_sum_ms` is **not a trustworthy pure-PL measurement** because host preparation overlaps launch-to-observed-DONE intervals.

Important correction to RESULT-004 section 7:

```text
prep_overlap_ms = 199000.219
```

does **not** prove that all 199.000 s is fake FPGA compute time. It proves only that host preparation overlaps the host-observed running interval. Existing host timestamps cannot distinguish:

```text
CPU prepares while FPGA is genuinely computing
```

from:

```text
FPGA already finished but CPU observes DONE late
```

Therefore TASK-004 must not derive a true PL compute time by subtracting `prep_overlap_ms` from `ip_compute_sum_ms`.

---

# Scope

Implement only these host-side changes:

1. remove redundant full-catalog validation from the P1 HIT hot path;
2. reduce packed-weight integrity verification to **one packed-data traversal during the actual staging copy**;
3. reduce static-scale integrity verification to **one scale traversal while the existing SPU_PARAM data is constructed**;
4. preserve fail-closed corruption detection;
5. preserve all existing FPGA DDR, ZDMA, bank, slot, P2-layout, numerical, model-epoch, preload and ping-pong contracts;
6. add only the minimum telemetry needed to prove where the new hot-path time goes;
7. extend board-free tests to prove CRC equivalence and corruption detection.

Do **not** implement:

```text
RTL changes
VPU changes
SPU changes
new MMIO counters
hardware START-to-DONE counters
cross-K accumulation
larger row tiles
gate/up fusion
direct PL DDR reader
new ZDMA protocol
larger ZDMA descriptor ABI
weight residency redesign
preload scheduler redesign
ping-pong redesign
catalog data-structure redesign
new quantization format
```

Do not reinterpret this task as permission to place the full model in PL memory.

---

# 1. Preserve the catalog lifetime and correctness model

The catalog remains:

```text
process-local host heap
lazy build
one entry per eligible immutable Q8_0 tensor per model epoch
states: BUILDING | VALID | BYPASS_ALLOC | POISONED | RETIRED
```

The model-epoch behavior introduced by TASK-003 remains unchanged.

A successful BUILD -> VALID publication remains the **full catalog-integrity boundary**.

Before publishing VALID, continue to prove and store:

- exact epoch/key;
- descriptor count;
- every descriptor field;
- every descriptor offset/count/alignment/range;
- metadata CRC;
- packed CRC for every tile;
- scale CRC for every tile;
- catalog allocation bounds;
- P2 layout version and exact packed bytes.

Do not weaken BUILD-time validation.

A catalog cap/allocation failure may still use the existing `BYPASS_ALLOC` behavior only under the existing TASK-003 contract.

Any corruption detected in a VALID entry remains fail-closed:

```text
VALID -> POISONED
no DMA
no VPU START
no direct-pack fallback
one reason log
no retry in the same model epoch
```

---

# 2. Remove full metadata-table rescans from normal HITs

Current v89 repeatedly validates the complete metadata/descriptor table on the hot path.

After TASK-004, a successful VALID entry must **not** recompute the complete metadata CRC or rescan every descriptor on every tile access.

Full metadata CRC and complete descriptor-table validation belong to BUILD -> VALID publication.

For a normal catalog HIT, retain only constant/local checks needed to bind the requested tile safely:

```text
entry state == VALID
model epoch matches
exact tensor/catalog key matches
selected descriptor identity/index is valid
selected packed offset/length is in the immutable entry allocation
selected scale offset/count is in the immutable entry allocation
selected packed byte count equals the expected P2 tile byte count
required alignments hold
```

Immediately before DMA/launch, keep the selected-entry/selected-descriptor identity and bounds checks necessary to prevent stale or mismatched staging.

Do not perform another complete descriptor-table CRC scan immediately before DMA.

Do not remove epoch, state, selected-descriptor, range, alignment, slot-ownership or DDR-safety checks.

Do not redesign the `std::list` catalog or descriptor lookup structure in TASK-004. RESULT-004 shows ordinary post-build selection is secondary. Keep the change minimal.

---

# 3. Packed-weight CRC: one traversal while copying

Current v89 performs two complete packed-payload CRC scans per catalog-served tile:

```text
full packed CRC before copy
+
CRC again while copying
```

Remove the standalone pre-copy packed CRC scan.

For each selected packed tile, use exactly one logical source traversal:

```text
catalog packed bytes
    -> read source bytes once
    -> update CRC incrementally
    -> write the same exact bytes to the existing FPGA DDR staging slot
    -> finalize CRC
    -> compare with descriptor.packed_crc32
    -> only then allow ZDMA/START
```

The CRC comparison must occur before the staged weight is allowed to become DMA-visible to the normal submission path.

If the CRC mismatches:

```text
mark entry POISONED
reject the job
no ZDMA
no VPU START
no fallback
```

The staged bytes may already have been written when the CRC fails; that is acceptable only because the job must fail before DMA/START and the slot must not be reused as READY data.

Preserve the exact reflected CRC-32 contract:

```text
polynomial = 0xEDB88320
initial    = 0xFFFFFFFF
final      = bitwise NOT
```

## 3.1 Fast CRC implementation

The CRC algorithm contract is fixed, but the implementation is not required to remain bit-at-a-time.

Replace any hot-path bit-at-a-time CRC implementation with a board-free table-driven or equivalently efficient implementation that produces **bit-identical CRC values**.

Requirements:

- same polynomial/init/final semantics;
- support incremental/chunked updates so the copy loop can update CRC while writing;
- no per-call heap allocation;
- no hidden mutable global state after initialization;
- thread-safe;
- deterministic on ARM64 and host development machines;
- no hardware-specific CRC instruction requirement unless a portable fallback exists and equivalence is tested.

Keep a simple independent bitwise reference implementation in the self-test only, not in the production hot path.

---

# 4. Preserve staging-store semantics in this task

The current FPGA DDR staging path uses the existing UIO/O_SYNC mapping and bounded volatile stores.

TASK-004 must **not** silently cast away `volatile`, replace the device-facing copy with ordinary `memcpy`, widen stores, use NEON stores, or change memory attributes merely to chase throughput.

For this task, preserve the proven staging write semantics and coherency contract unless the repository already contains an independently proven device-memory-safe bulk-store primitive.

Preserve:

```text
DDR physical carveout [0x70000000,0x80000000)
ddr_phys_range_fits()/ddr_range_fits() proof
current WEIGHT staging slots
bank/slot ownership
DSB -> first/last volatile readback -> DSB
existing ZDMA source/destination routing
```

If the new telemetry proves that volatile staging stores remain dominant after redundant CRC/validation removal, report that result for the next task rather than introducing an unreviewed memory-type/store-width change here.

---

# 5. Static scale CRC: fuse verification with SPU_PARAM construction

Do not simply delete scale corruption detection.

Current v89 separately validates/scans the static scale span and then consumes the same scale values to build the existing SPU_PARAM staging data.

Change this to one scale-data traversal per selected tile:

```text
selected immutable uint16_t weight-scale bits
    -> read each required static scale once in descriptor order
    -> update scale CRC using the raw uint16_t serialized little-endian
    -> simultaneously construct the existing activation-scale/weight-scale SPU_PARAM word
    -> write through the existing bounded staging path
    -> finalize scale CRC
    -> compare with descriptor.scale_crc32
    -> only then allow scale DMA / job launch
```

Requirements:

- static weight scale bits remain exact raw GGML FP16 `uint16_t` values;
- dynamic activation scale handling remains numerically identical;
- existing SPU_PARAM word layout remains bit-identical;
- existing zero padding remains bit-identical;
- padding bytes are not accidentally included in the catalog scale CRC if they were not part of the original CRC contract;
- every referenced real static scale element must be covered exactly once by the retained CRC;
- CRC mismatch poisons the catalog entry and fails closed before DMA/START.

Remove the separate full static-scale CRC pass that precedes or duplicates this consumption pass.

Do not remove selected scale offset/count/bounds checks.

---

# 6. Do not over-optimize catalog lookup in this task

RESULT-004 measured:

```text
prep_weight_select_ms = 11554.167
catalog build_us       = 10777.285
```

Therefore at most about:

```text
0.776882 s
```

remains for ordinary selection work in that run.

TASK-004 may remove the repeated full metadata-table validation from selection, but must not introduce a new hash table, pointer cache, descriptor index ABI, ownership model or lifetime mechanism solely to optimize lookup.

Keep catalog lookup behavior structurally stable so the dominant 190 s copy/validation problem is isolated first.

---

# 7. Minimal hot-path telemetry

Keep all existing `HOST_PREPACK` fields.

Add aggregate 64-bit saturating host timers/counters sufficient to split the optimized path without per-job log spam.

At minimum collect:

```text
copy_payload_bytes
copy_lock_wait_us
copy_selected_validate_us
copy_stream_crc_store_us

scale_selected_validate_us
scale_zero_fill_us
scale_crc_spuparam_us

metadata_full_hotpath_scans
packed_pre_crc_scans
scale_pre_crc_scans
```

Definitions:

- `copy_payload_bytes`: actual catalog packed bytes staged on HITs, not catalog resident allocation size.
- `copy_lock_wait_us`: time waiting to enter the protected catalog copy region, if the existing mutex remains.
- `copy_selected_validate_us`: only state/key/selected-descriptor/bounds checks retained for the copy.
- `copy_stream_crc_store_us`: fused packed source read + incremental CRC + staging stores.
- `scale_selected_validate_us`: selected scale state/key/bounds checks.
- `scale_zero_fill_us`: existing padded SPU_PARAM zeroing only.
- `scale_crc_spuparam_us`: fused real-scale CRC + SPU_PARAM construction/stores.

After TASK-004, for successful post-build catalog HITs:

```text
metadata_full_hotpath_scans = 0
packed_pre_crc_scans        = 0
scale_pre_crc_scans         = 0
```

Do not log one line per tile. Extend the existing per-graph/process aggregate only.

Do not rename or reinterpret `ip_compute_sum_ms` as true PL compute time. If touched, label it explicitly as host-observed launch-to-DONE time. Hardware-independent compute timing is deferred.

---

# 8. Board-free tests

Extend the existing P1 boardless self-test. No FPGA hardware may be required.

The self-test must prove all of the following.

## 8.1 CRC equivalence

Compare the production fast CRC implementation against an independent bitwise reference using:

```text
empty input
1-byte input
15, 16, 17-byte inputs
63, 64, 65-byte inputs
4096-byte input
multiple deterministic larger buffers
```

For every buffer verify:

- one-shot production CRC == reference CRC;
- incremental updates with several different chunk boundaries == one-shot CRC;
- byte-at-a-time incremental update == one-shot CRC.

## 8.2 Packed copy equivalence

For existing deterministic P2 layout test vectors:

- construct the immutable catalog payload;
- stage it through the production fused copy+CRC helper into a normal-memory test sink;
- compare output bytes byte-for-byte with the original catalog payload and independent expected P2 layout;
- compare retained CRC with the BUILD-time stored CRC.

## 8.3 Packed corruption detection

Flip one byte in the immutable packed payload after BUILD and before the simulated HIT copy.

Required result:

```text
CRC mismatch detected
copy helper reports failure
entry poison/fail-closed decision is exercised by the board-free control helper where practical
```

Restore the payload and verify success again.

## 8.4 Scale fusion equivalence

For deterministic activation-scale and static weight-scale vectors:

- build the reference SPU_PARAM bytes using an independent test implementation of the existing format;
- run the production fused scale-CRC + SPU_PARAM construction helper;
- require byte-for-byte equality;
- require the fused CRC to equal the BUILD-time static scale CRC.

## 8.5 Scale corruption detection

Flip one static scale bit after BUILD.

Required result:

```text
scale CRC mismatch detected before simulated DMA/START
```

## 8.6 Metadata hot-path contract

Prove that BUILD-time full descriptor/metadata validation still rejects malformed descriptors.

Prove that the normal HIT path validates the selected descriptor bounds/identity without invoking a complete-table metadata CRC rescan.

Failure exit code != 0.

Build commands remain:

```bash
cmake --build build_mem -j2
cmake --build build_mem -j2 --target fpga-host-prepack-selftest
./build_mem/bin/fpga-host-prepack-selftest
```

Do not delete or recreate `build_mem`.

---

# 9. Versioning

Bump the host manifest version so the board log cannot be confused with v89.

Use a clear v90 identifier, for example:

```text
zcu104-gemma3-q8-v90-prepack-hotpath
```

Do not change protocol, bitstream ID, P2 ABI or P3 ABI for this host-only task.

---

# 10. Implementation stop point

After implementation:

1. build successfully;
2. run the board-free prepack self-test successfully;
3. inspect the diff for accidental RTL/ZDMA/arithmetic/scheduler changes;
4. commit and push the host candidate branch;
5. **stop before claiming board success**.

The implementation agent cannot infer ZCU104 performance from desktop/self-tests.

Do not update the parent submodule pointer as the accepted baseline until the owner returns the board result.

Preserve the existing `.codex/outbox/RESULT-004.md` investigation. Do not overwrite it.

Write implementation evidence to:

```text
.codex/outbox/RESULT-004-IMPLEMENTATION.md
```

until board acceptance is complete.

---

# 11. Required owner board test

Use the same isolation configuration as the v89 measurement so the comparison is valid.

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

Capture the full console output and `/tmp/fpga_debug.log`.

Also collect memory evidence during the same workload if practical:

```bash
free -h
swapon --show
vmstat 1
```

and process memory while `llama-cli` is running:

```bash
grep -E 'VmRSS|VmHWM|VmSwap' /proc/$(pidof llama-cli)/status
```

---

# 12. Functional acceptance

For the same test configuration, require:

```text
host_version reports v90 TASK-004 candidate
P2 layout self-test PASS
182 eligible FPGA matmuls remain FPGA-completed
1 vocabulary projection remains intentional CPU bypass
unavailable CPU fallback = 0
HOST_PREPACK builds = 182
HOST_PREPACK misses = 182
HOST_PREPACK hits = 27842
HOST_PREPACK fallbacks = 0
prep_direct_weight_pack_us = 0
metadata_full_hotpath_scans = 0
packed_pre_crc_scans = 0
scale_pre_crc_scans = 0
no catalog POISON on uncorrupted workload
no CRC mismatch
no DDR-range violation
no ZDMA error
no P2 stream drop/error
sampled output remains numerically identical to the v89 baseline for the deterministic command
```

If job count changes because an independently reviewed upstream graph change exists, explain it explicitly rather than forcing the old count.

---

# 13. Performance acceptance

Reference v89 values for the same command:

```text
copy_us                  = 190.173577 s
prep_total_ms            = 223265.912 ms
prep_scale_pack_ms       = 21353.752 ms
token_wall_ms            = 254298.680 ms
prompt eval              ~= 254.664 s
```

Success must first be judged by correctness, then performance.

Minimum performance gate:

```text
copy_us must improve by at least 2x versus v89
=> copy_us < 95.087 s
```

Target:

```text
copy_us <= 40 s for the same workload
```

The target is not permission to weaken corruption detection or device-memory safety.

Also require:

- `prep_scale_pack_ms` must not regress;
- `prep_total_ms` must decrease materially;
- prompt wall/evaluation time must decrease materially;
- weight DMA bytes and descriptor semantics remain unchanged in this task;
- no performance claim may use `ip_compute_sum_ms` as pure hardware compute time.

If functional checks pass but `copy_us >= 95.087 s`, TASK-004 is **not performance-complete**. Use the new substage telemetry to identify whether `copy_stream_crc_store_us` is now dominated by CRC or volatile staging writes. Do not introduce a new unreviewed store/memory-mapping mechanism in the same board-validation iteration.

---

# 14. Expected RESULT-004-IMPLEMENTATION.md

Return:

```text
1. Exact host baseline and candidate commit
2. Files changed
3. Hot-path before/after execution order
4. CRC implementation and equivalence-test result
5. Metadata validations removed from HIT path
6. Packed corruption behavior
7. Scale corruption behavior
8. Board-free self-test result
9. Exact owner board command
10. Board telemetry before/after table once owner returns logs
11. Functional acceptance PASS/FAIL
12. Performance acceptance PASS/FAIL
13. Remaining dominant bottleneck
14. Recommendation for the next task
```

Do not claim the 2.5 token/s project target is reached from TASK-004 alone.

TASK-004 is complete only when the static-weight catalog HIT path is both **correct** and **measurably faster on the ZCU104**.