# RESULT-009: Phase 1 one-pass P2 scale staging

## Final status

`PARTIAL`

Phase 1 functional qualification is accepted from owner-provided ZCU104 evidence. The production smoke run, complete Q8 source audit, and bounded P2 Q16 scale-contract run passed without integrity, repair, stream, or unavailable-fallback failures. Performance acceptance remains partial until provenance hashes and controlled repeated long runs are recorded.

## Task summary

Phase 1 removes the complete normal-P2 `SPU_PARAM` zero pass. The host now writes every real packed scale entry exactly once and zeros only the final alignment padding. P3, raw self-test initialization, host/RTL ABI, DMA extent and ordering, and coherency behavior remain unchanged.

## Initial repository state

- Parent at Phase 1 start: branch `main`, commit `9b57f52e423f891b58d37ea14fed39cf1e1067e7`, with unrelated local changes.
- `llama.cpp`: branch `main`, commit `8c24927d0c50b921d19b4e03699a9fbdb773e595`, clean before Phase 1.
- `DATN_RTL`: branch `spu`, commit `28b06e20a2244b42dcef7f42b7cf93f76ddec419`, with unrelated local changes.
- Board: not connected to this workspace.

At final reporting, the parent commit is `3ac77e8df1eaacd5ba5c947f28766bf6ad099dba`; this parent advancement was not performed by the Phase 1 implementation.

## Investigation findings and verified root cause

The normal P2 branch in `fpga_prepare_q8_tile_job()` called `ddr_zero_range32(SPU_PARAM_BASE, job.scale_bytes)` before overwriting every useful 32-bit entry.

The scale extent is:

```text
entries     = rows * group_blocks
scale_words = ceil(entries / 4)
scale_bytes = scale_words * 16
```

Each 128-bit word contains four 32-bit entries. Therefore only zero to three final entries are padding. Clearing the complete extent duplicated volatile writes for every useful entry.

The performance contribution remains unverified because no comparable board A/B measurement was performed in this task.

## Implementation summary

- Added checked P2 scale geometry with multiplication, rounding, metadata, alignment, extent, and tail validation before the first volatile store.
- Added a shared pure helper that packs `{weight_scale_fp16[31:16], activation_scale_fp16[15:0]}` without floating-point conversion.
- Replaced the normal-P2 full clear with one checked volatile pointer, one write per useful entry, and zeroing of only the final zero to three entries.
- Added `mmio_fence()` immediately after the P2 scale writes.
- Preserved the later fence, bounded readback/DSB path, stream-quiescence gate, and ZDMA sequence.
- Added a pure layout self-test invoked before hardware mappings.

## File-by-file changes

### `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp`

- `fpga_p2_pack_scale_entry()`: packs activation FP16 into bits `[15:0]` and weight FP16 into bits `[31:16]`.
- `fpga_p2_checked_scale_shape()`: validates the complete P2 scale-table geometry and rejects inconsistent or overflowing shapes before mutation.
- `fpga_p2_scale_layout_case()` and `fpga_p2_scale_layout_self_test()`: verify exact FP16 bit placement, row-major indexing, tails `0..3`, odd/even and multi-row shapes, maximum `256 x 64`, sentinel guards, and rejected-shape non-mutation.
- `fpga_prepare_q8_tile_job()`: performs normal-P2 one-pass useful-entry staging followed by tail-only zeroing.
- `fpga_init()`: runs the pure layout self-test before UIO, DDR, VPU, or ZDMA mappings.

No header, CMake, RTL, register map, protocol, capability, P3, raw self-test, residency, DMA descriptor, timeout, or error-handling code changed.

## Host/RTL dataflow

Before:

```text
clear complete P2 scale extent
-> overwrite every useful entry
-> fence/readback
-> ZDMA to SPU PARAM
```

After:

```text
validate complete P2 scale geometry
-> write every useful entry once
-> zero only 0..3 final padding entries
-> explicit fence
-> unchanged readback/DSB
-> unchanged ZDMA to SPU PARAM
```

The SPU-visible payload, row-major entry order, memory window, and DMA length are unchanged.

## Commands executed and results

```text
git -C llama.cpp diff --check
```

Result: `PASS`.

```text
cmake -S llama.cpp -B llama.cpp/build_mem -DUSE_FPGA=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
```

Result: `PASS`; Ninja/MinGW configuration completed. Non-fatal Git ownership warnings were emitted.

```text
cmake --build llama.cpp/build_mem --target llama-cli -j2
```

Result: `FAIL` before compiling the changed translation unit. The first attempt could not use the default ccache temporary directory. With workspace-local ccache paths, compilation advanced and stopped in unchanged `ggml-cpu.c` because the MinGW branch lacks `pthread_once_t`, `PTHREAD_ONCE_INIT`, and `pthread_once`.

Direct Windows compilation of `fpga_host.cpp` was not possible because the Linux FPGA host requires `sys/mman.h`. WSL execution was unavailable.

## Validation evidence

- Independent host-safety inspector: `ACCEPTED_FOR_OWNER_TEST` at source-contract level.
- Independent integration inspector: `BLOCKED_BY_EVIDENCE` until the changed Linux source compiles and the new self-test executes.
- Independent build tester: diff/static checks pass; Linux build and runtime remain unavailable locally.
- RTL simulation: not required and not run because no RTL changed.
- ZCU104 execution: not run because the board is not connected here.

## Tests not executed and reasons

- Linux FPGA-enabled build: no Linux/WSL execution environment available.
- New pre-mapping self-test: part of the Linux FPGA initialization path; not executable in this Windows environment.
- Mapped volatile-write behavior: requires owner Linux runtime.
- Contract diagnostic and production inference: require the owner-connected ZCU104.

## Risks and assumptions

- A compile error specific to the changed translation unit remains possible until the owner Linux build succeeds.
- The self-test and mapped-store path have not executed.
- Performance improvement is unknown until controlled board A/B measurements return.
- CPU fallback, CPU-shadow diagnostic output, raw repair, stream drop/error, or mismatched binary/model/bitstream provenance cannot prove production FPGA correctness.

## Remaining work

1. Build the changed source on the owner Linux host.
2. Confirm `P2_SCALE_LAYOUT_SELFTEST pass` appears before hardware mapping.
3. Record deployed binary, GGUF, and actually loaded bitstream SHA-256 values.
4. Verify protocol `2`, bitstream ID `0x56505532`, P2 ABI `0x50320003`, and P3 ABI `0x50330001`.
5. Run source audit and P2 contract diagnostic separately.
6. Run three comparable production baseline and Phase 1 measurements and return complete logs.

## Owner board evidence received on 11-08-2026

Files reviewed:

- `DATN_RTL/fpga_debug.log`
- `DATN_RTL/result_prompt.txt`

The Phase 1 smoke test passed:

```text
P2_SCALE_LAYOUT_SELFTEST pass
protocol=0x00000002
bitstream_id=0x56505532
p2_abi=0x50320003
p3_abi=0x50330001
P3_CONFIG requested=0 active=0
```

The production Q8 route completed without masking failures:

```text
q8_expected_fpga=1638
q8_hw_completed=1638
q8_unavailable_cpu_fallback=0
routing_verdict=complete
contract_cpu_shadow_dst=0
raw_repairs=0
p2_stream_drops=0
p2_stream_errors=0
```

Seven decode-token records have median wall time `3574.402 ms/token`, equivalent to approximately `0.280 token/s`. The recorded v88 median was `3745.634 ms/token`, approximately `0.267 token/s`. This short run is 171.232 ms/token or 4.57% faster, but it is not a controlled multi-run acceptance sample.

The Phase 1 target metric moved in the intended direction:

```text
previous scale stage: approximately 632 ms/token
Phase 1 median prep_scale_pack_ms: 304.837 ms/token
approximate reduction: 51.8%
```

## Owner qualification evidence received on 11-08-2026

The source-only audit passed all observed eligible Q8 sources:

```text
q8_source_audit_checks=366
q8_source_audit_failures=0
raw_mismatches=0
raw_repairs=0
value_mismatches=0
```

The bounded one-tile P2 scale contract also passed:

```text
SPU_SCALE_CONTRACT_Q16_PASS rows=256 expected_raw=9216 expected_out=256
P2_TILE_BOUNDARY status=pass
p2_tile_q16_checks=1
p2_tile_boundary=1
input_integrity_failures=0
p2_stream_drops=0
p2_stream_errors=0
```

For this diagnostic, `q8_hw_completed=0`, `routing_verdict=incomplete`, and `matrix_value_contract=not_attempted` are expected: after validating the selected tile, the explicit qualification policy routes the current matmul through CPU shadow and all subsequent Q8 GEMVs through the native CPU kernel. These fields are not production-route failures. This run proves the selected P2 tile's Q16 scale/output-count contract and clean boundary state; it does not prove a full-matrix value comparison.

Run-level verdict: `PASS`.

Phase 1 functional verdict: `PASS`.

Overall TASK-009 status is `PARTIAL`, not blocked. Remaining evidence is limited to deployment provenance and controlled performance acceptance: binary/model/loaded-bitstream SHA-256 values, plus at least three comparable long production runs. A deterministic full-output CPU-reference comparison would strengthen numerical regression coverage but is not evidence of a defect in the accepted Phase 1 path.

## Repository branches and commits

- `DATN_RTL`: branch `spu`, commit `28b06e20a2244b42dcef7f42b7cf93f76ddec419`; unchanged by Phase 1.
- `llama.cpp`: branch `main`, base commit `8c24927d0c50b921d19b4e03699a9fbdb773e595`; Phase 1 remains uncommitted.
- Parent: branch `main`, current observed commit `3ac77e8df1eaacd5ba5c947f28766bf6ad099dba`; Phase 1 parent commit is `PENDING`.

## Owner build and initial verification

```bash
cd ~/llama.cpp

cmake -S . -B build_mem \
  -DUSE_FPGA=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CURL=OFF

cmake --build build_mem --target llama-cli -j2

sudo env FPGA_INIT_VERBOSE=1 FPGA_P3_SPLIT_SCALE=0 \
  ./build_mem/bin/llama-cli \
  -m ./models/gemma-3-1b-it-Q8_0.gguf \
  -p "Please write about AI" \
  -n 8 --single-turn --temp 0
```

Required initial signature:

```text
P2_SCALE_LAYOUT_SELFTEST pass
```

Stop and return the build output without running inference if the Linux build fails.

## Phase 2 actual-model weight-path measurement

### Objective and measurement boundary

Phase 2 isolates the dominant host-side operation observed after Phase 1: packing immutable GGML `Q8_0` model weights into the pair-interleaved VPU layout and writing that payload through the mapped FPGA DDR UIO aperture.

The diagnostic is enabled only with `FPGA_WEIGHT_PATH_BENCH=1`. It captures the tiler operations generated by an actual one-token model decode while the GGUF and tensor pointers remain valid in the same process. It does not generate a synthetic fixed job count and does not serialize raw pointers.

The captured workload was:

```text
jobs=2210
bytes=697761792
MiB=665.4375
maximum_single_tile_bytes=524288
```

The 2,210 jobs and 697,761,792 bytes are measured properties of this model, host tiler, hardware capability set, and one-token decode. They are evidence, not constants permitted in a future workload generator.

The diagnostic measures three paths separately:

```text
T_pack_cached
    actual Q8_0 source -> pair-interleaved packed layout in cached RAM

T_store_uio
    prepacked cached tile -> volatile mapped-DDR stores + fence/readback
    packing is explicitly outside the reported store interval

T_pack_uio
    actual Q8_0 source -> pair-interleaved layout written directly to mapped DDR
```

Each path executes one untimed warm-up followed by five timed full-workload replays. Results report median, minimum, maximum, throughput, bytes, and job count.

### Capture-lifecycle correction and safety evidence

The first owner attempt failed safely with:

```text
WEIGHT_PATH_BENCH_CAPTURE_FAIL tensor=blk.0.attn_q.weight layer=0
seq=13 jobs=148 bytes=47775744
action=abort_no_ddr_write_no_zdma_no_vpu_start
```

Root cause: llama.cpp startup warm-up or multi-token prefill created an unreplayed capture bound to an earlier graph sequence. Replay accepts only the matching one-token boundary, so the stale trace survived until the first real decode at sequence 13. The capture function rejected the sequence mismatch before mutating DDR.

The host diagnostic was corrected so that an unreplayed host-only trace is discarded at a non-single-token boundary or rebound when a later graph sequence begins. Same-sequence tensor operations continue to aggregate. Reset clears only in-process job records, counters, and the reusable cached tile; it is forbidden after replay begins.

The accepted run contains explicit resets:

```text
WEIGHT_PATH_BENCH_CAPTURE_RESET old_seq=0 new_seq=2
stale_jobs=74 stale_bytes=23887872
reason=sequence_advanced_before_single_token_boundary

WEIGHT_PATH_BENCH_CAPTURE_RESET old_seq=2 new_seq=0
stale_jobs=0 stale_bytes=0
reason=sequence_advanced_before_single_token_boundary

WEIGHT_PATH_BENCH_CAPTURE_RESET old_seq=0 new_seq=13
stale_jobs=74 stale_bytes=23887872
reason=sequence_advanced_before_single_token_boundary
```

These discarded records are not included in the final 2,210-job replay.

Benchmark initialization maps only the verified MY_IP UIO aperture for read-only identity/capability access and the existing bounded 4 MiB low-DDR UIO aperture. It does not map or initialize ZDMA, issue descriptors, start the VPU, write an inference destination, or enlarge a mapping. Only replay writes the bounded DDR `WEIGHT` window.

Owner cleanup evidence confirms the passive diagnostic boundary:

```text
dma_mapped=0
fpga_calls=0
vpu_runs=0
q8_hw_completed=0
p2_stream_drops=0
p2_stream_errors=0
weight_path_bench_passive=1
```

`routing_verdict=incomplete` is expected in this mode. The captured inference remains CPU-owned and the diagnostic intentionally performs no FPGA GEMV. These counters must not be interpreted as a production-route failure or as FPGA numerical evidence.

### Phase 2 measured results

```text
T_pack_cached
median_us=765950
min_us=765704
max_us=766047
MiB_s=868.774

T_store_uio
median_us=1475322
min_us=1474551
max_us=1475486
MiB_s=451.046
timing_scope=sum_per_job_store_intervals_prepack_excluded

T_pack_uio
median_us=1631329
min_us=1631073
max_us=1631636
MiB_s=407.911
```

The five timed repetitions are tightly grouped:

```text
T_pack_cached spread = 343 us
T_store_uio spread   = 935 us
T_pack_uio spread    = 563 us
```

This stability is sufficient to identify the dominant measured host stage for this captured workload.

### Speed interpretation

The terminal reported:

```text
eval time = 28224.42 ms / 1 run
reported rate = 0.04 token/s
```

This is not production inference speed. The benchmark deliberately replays the complete 697,761,792-byte workload six times for each of three modes:

```text
6 * (0.765950 + 1.475322 + 1.631329) seconds
= 23.235606 seconds of reported replay work
```

`T_store_uio` additionally pre-packs each job outside its reported store interval. That work still contributes to llama.cpp wall time. The diagnostic replay overhead plus ordinary CPU-owned token evaluation explains the 28.224-second evaluation. Therefore `0.04 token/s` must be excluded from every Phase 1 or production-speed comparison.

The earlier normal FPGA run remains approximately `0.280 token/s`; a new production run with `FPGA_WEIGHT_PATH_BENCH` unset is still required for any updated end-to-end claim.

### Phase 2 verdict

`PASS_DIAGNOSTIC_STORE_BOUND`

Mapped DDR/UIO weight stores are the dominant measured component of the current host weight-staging path:

```text
cached transformation median = 0.766 s
mapped-DDR store median       = 1.475 s
direct pack-to-UIO median     = 1.631 s
```

`T_pack_cached + T_store_uio` must not be treated as a predicted implementation time. The paths have different cache and memory-pipeline interactions, and `T_store_uio` sums per-job store intervals while excluding prepacking. The measurements are deliberately non-additive.

The result supports these decisions:

1. Do not prioritize further scale-table staging optimization; Phase 1 already reduced that stage and it is no longer the dominant measured preparation cost.
2. Do not assume that cached packing followed by the same sequential volatile UIO stores will improve performance. It retains the dominant stores and adds a second pass.
3. Do not prioritize RTL compute optimization solely from this evidence. Phase 2 measures the host weight path and identifies a larger avoidable host-side cost.
4. Prioritize reducing or eliminating repeated mapped-DDR writes of immutable packed weights across decode tokens.

### Measurement limitations

- This is a host-only diagnostic, not an FPGA inference or numerical-correctness run.
- The reusable cached destination is one maximum tile of 524,288 bytes. It is bounded and prevents multi-gigabyte allocation, but it is not a working set deliberately sized above the ARM last-level cache. `T_pack_cached` is a valid actual-model transform measurement, not an absolute cache-independent decomposition.
- The benchmark log does not record binary, GGUF, and actually loaded bitstream SHA-256 values. Runtime capability admission occurred in code, but artifact provenance remains incomplete.
- The run provides one diagnostic capture with five internal repetitions, not three independent production runs.
- Internal PL interconnect behavior is unobservable because the benchmark never starts the VPU.

## Recommended next optimization: bounded packed-weight residency

### Objective

Avoid rewriting immutable packed Q8 weight tiles for every decode token. On the first use, pack a validated tile into an explicitly budgeted, FPGA-readable reserved-DDR arena. On later tokens, resolve the same tensor/tile metadata to that resident physical offset and reuse it instead of performing the direct CPU-to-UIO packing stores again.

```text
first eligible use
actual GGUF Q8_0 tile
-> validate source and geometry
-> pack once into owned reserved DDR
-> publish resident metadata only after complete write/fence/readback

later decode token
same immutable tensor + same geometry + same ABI
-> metadata lookup
-> resident hit
-> reuse DDR tile
-> avoid repeated host stores
```

### Required bounded rollout

Residency must not begin as an unbounded full-model arena. The currently documented reserved DDR region is 256 MiB, while a single decode stages approximately 665.4 MiB of weight payload across all jobs. A partial arena therefore cannot hold the complete one-token working set and must select frequently reused tiles explicitly.

Use graduated budgets only after memory preflight:

```text
64 MiB qualification
-> 128 MiB qualification
-> 256 MiB qualification
```

Before each size is enabled, prove:

- the physical range lies entirely inside the reserved FPGA DDR region;
- Linux excludes and does not allocate that range;
- UIO exposes the required range with the expected cache attributes;
- ZDMA and VPU physical-address contracts admit the selected offsets;
- the arena does not overlap ACT, WEIGHT staging, RESULT, SPU output, SPU parameters, descriptors, or another owner;
- allocation arithmetic and every tile extent are overflow checked;
- no mapping is enlarged or `/dev/mem` fallback enabled implicitly.

If the existing low-DDR UIO aperture cannot safely expose the proposed arena, residency is `BLOCKED_BY_MEMORY_PREFLIGHT`; the host must not work around that condition by broad mapping.

### Resident tile identity contract

Every resident entry must include enough immutable identity to prevent a false hit:

```text
tensor object identity
tensor data identity
GGML type = Q8_0
ne[0], ne[1]
nb[0], nb[1]
source byte span
row0, rows
k_block0, group_blocks, group_beats
packed payload bytes
hardware protocol and bitstream ID
P2 packing ABI and layout version
runtime tiler limits
resident DDR offset and allocated extent
generation/state and validity marker
```

Metadata must be committed last. A tile is reusable only after packing completes, the write fence/readback completes, and all metadata matches. Any mismatch, stale pointer, ABI change, range violation, incomplete build, collision, or ownership uncertainty must produce a counted miss and use the existing validated direct-staging path. It must never produce a guessed or partially valid hit.

### Initial selection policy

Start with deterministic, frequently reused projection tiles rather than full-model residency. Rank candidates using observed reuse and payload size. Attention and FFN projection weights are reasonable candidates only after telemetry proves their hit frequency and arena fit.

The selection policy must be reproducible and log:

```text
selected tensors and tile ranges
logical bytes
allocated bytes including alignment
remaining arena bytes
entries built
entries rejected and exact reason
```

### Required telemetry

```text
residency_enabled
arena_base and arena_bytes
slots_used / slots_total
builds and build_failures
lookup probes and lookup time
hits and misses
miss reason: alignment/shape/collision/stale/ABI/range/capacity/ownership
logical resident bytes
allocated resident bytes
bytes written during build
bytes avoided per token
direct-stage bytes remaining per token
resident and direct-stage job counts
token p50/p95
raw mismatch/repair/integrity/stream/DMA counters
```

### Functional acceptance gates

1. Source audit remains complete with zero failures.
2. P2 Q16 tile contract remains passing.
3. Resident and direct-staged tiles produce the same packed bytes for representative boundary cases before hardware launch.
4. Deterministic production output matches the locked non-resident reference under identical artifacts and settings.
5. `raw_mismatches=0`, `raw_repairs=0`, `value_mismatches=0`, `input_integrity_failures=0`, `p2_stream_drops=0`, and `p2_stream_errors=0`.
6. No CPU-unavailability fallback or CPU shadow is counted as FPGA production success.
7. A metadata mismatch produces a safe direct-stage miss, never a resident hit.
8. Cleanup invalidates host metadata before unmapping or releasing the arena.

### Performance acceptance gates

Use identical binary, model, loaded bitstream, board governor, clocks, prompt, token count, and environment for resident-off and resident-on measurements. Record SHA-256 values for all deployed artifacts.

Run at least three independent `-n 64` production runs for each condition. Exclude warm-up according to one locked rule and report:

```text
decode token p50 and p95
prep_direct_weight_pack_ms p50/p95
resident hits/misses
bytes avoided per token
remaining direct-stage bytes per token
host-to-IP DMA time
IP compute time
result-read time
complete FPGA routing counters
```

The optimization is accepted only when it produces nonzero validated resident hits, measured avoided bytes, unchanged functional output/contracts, no new repair/fallback/error activity, and a repeatable end-to-end decode improvement. Residency telemetry without avoided bytes or production speed improvement is not sufficient.

### Stop conditions

Stop before any arena write or FPGA launch if memory ownership, mapped extent, physical address, ABI identity, tensor identity, source span, tile geometry, allocation bounds, or metadata state cannot be proven. Do not increase the aperture, enable `/dev/mem`, silently clamp a tile, repair output, or substitute CPU execution to claim success.

## Updated repository and evidence status

- Phase 1 host commit: `b236a5195d943378dcdce87eb447fdb82e60fb51`, pushed to `llama.cpp` `origin/main`.
- Phase 2 diagnostic implementation and capture-lifecycle correction remain uncommitted in the `llama.cpp` worktree for further owner iteration.
- Phase 2 benchmark diagnostic verdict: `PASS_DIAGNOSTIC_STORE_BOUND`.
- Phase 1 functional verdict: `PASS` from owner-provided evidence.
- Overall TASK-009 status remains `PARTIAL` until provenance, controlled production A/B performance, and the next optimization's functional gates are complete.
