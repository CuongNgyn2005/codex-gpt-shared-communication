# TASK--002: Implement the First Approved Optimizations

## Repositories

Work from the parent repository.

Host submodule:

```text
llama.cpp
Source: CuongNgyn2005/Infrastructure_GEMMA3
Branch: main
```

RTL submodule:

```text
DATN_RTL
Source: CuongNgyn2005/LLM_GEMMA3-1B-INT8
Branch: spu
```

Do not modify `llama.cpp/hls_accelerator`. The deployed path uses `ggml-cpu/fpga_host.cpp` and the VPU2 RTL.

## Verified Baseline

Keep these settings until a task explicitly changes them:

```text
FPGA_P2_PACK_WORKERS=2
P2 PING-PONG enabled
P2 preload enabled
P3 disabled
ZDMA descriptor limit = 65536 bytes
VPU rows = 256
Vocabulary projection on CPU
```

Measured decode baseline:

```text
token wall       ≈ 3759 ms
weight packing   ≈ 1496 ms
scale packing    ≈ 631 ms
PL compute       ≈ 1187 ms
```

## Absolute Safety Rule

The only safe FPGA DDR range is:

```text
[0x70000000, 0x80000000)
```

Preserve these constants in `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp`:

```cpp
DDR_BASE_PHYS
DDR_REGION_SIZE
DDR_END_EXCLUSIVE
```

Every DDR operation must satisfy:

```cpp
phys >= DDR_BASE_PHYS
phys + bytes <= DDR_END_EXCLUSIVE
```

Use overflow-safe addition.

Reject invalid ranges before mapping, packing, copying, or submitting ZDMA.

Never use `0x80000000` or above.

Never implement full-model FPGA DDR residency.

## Priority 1: Remove Per-Token Weight Repacking

### Files

Primary file:

```text
llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp
```

Change these files only when required:

```text
llama.cpp/ggml/src/ggml-cpu/fpga_host.h
llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c
llama.cpp/ggml/src/ggml-cpu/CMakeLists.txt
```

### Existing Code to Reuse

Do not create a second weight layout.

Reuse the current VPU2 pair-interleaved layout and these symbols:

```text
fpga_pack_direct_weight_pair_range
fpga_weight_layout_word_offset
fpga_weight_layout_zero_padded_companion
fpga_weight_tile_cache_t
fpga_prepare_q8_tile_job
fpga_hw_q8_0_matmul_dma_to_ip_pipelined
fpga_hw_q8_0_matmul_dma_to_ip
fpga_try_matmul_extended
```

The current DDR cache code is not the final solution:

```text
build_weight_cache_entry
get_weight_cache_entry
g_weight_cache
```

It stores packed tensors in FPGA DDR. The full model cannot fit there.

### Required Design

Add a host-DRAM packed-weight catalog.

Use one catalog entry per immutable Q8_0 tensor.

Each entry must store:

```text
tensor pointer
source data pointer
K
N
row stride
layout version
tile descriptors
packed weight bytes
FP16 weight-scale bits
valid flag
```

Use the existing layout version:

```text
pair_interleaved_padded_v2
```

Build an entry once.

A lazy first-use build is acceptable.

Reuse the entry for every later token.

Do not repack the same tensor during decode.

### Required Refactor

Refactor `fpga_pack_direct_weight_pair_range()` so the layout writer can target:

```text
normal host memory
or
mapped FPGA DDR
```

Do not duplicate its row-pair index formula.

Add a host-memory pack self-test.

The self-test must compare:

```text
direct packed tile bytes
host-catalog packed tile bytes
```

Test these cases:

```text
1 row
2 rows
255 rows
256 rows
1 Q8 block
64 Q8 blocks
odd final row
```

Require byte-for-byte equality.

### Decode Path Change

Modify `fpga_prepare_q8_tile_job()`.

On a host-catalog hit:

1. Locate the packed tile.
2. Copy the packed tile into the current DDR staging area.
3. Set `job.weight_src_off` to that staging offset.
4. Skip `fpga_pack_direct_weight_pair_range()`.
5. Read weight scales from the catalog.
6. Preserve all current P2 metadata.
7. Preserve the direct-pack fallback.

Use bounded DDR staging.

Do not place the complete catalog in FPGA DDR.

Use at most two staging slots.

Calculate slot size from the maximum admitted tile.

Check both slots with `ddr_range_fits()`.

Do not overlap a slot write with an active ZDMA read from that slot.

### New Telemetry

Add these aggregate fields:

```text
host_prepack_builds
host_prepack_hits
host_prepack_misses
host_prepack_build_us
host_prepack_copy_us
host_prepack_bytes
host_prepack_fallbacks
```

Keep `prep_direct_weight_pack_us`.

A catalog hit must not increase `prep_direct_weight_pack_us`.

### Feature Gate

Add:

```text
FPGA_HOST_WEIGHT_PREPACK=1
```

Default it to disabled during development.

Fail closed on catalog corruption.

Fall back to the existing direct pack only for allocation failure or a disabled feature.

Log the fallback reason once per tensor.

### Host Acceptance Gates

Build must succeed:

```bash
cmake --build build_mem -j2
```

No board is required for the byte-layout self-test.

Before requesting a board run, report:

```text
files changed
symbols changed
catalog memory usage
largest packed tensor
largest packed tile
DDR staging offsets
fallback behavior
self-test result
```

The later owner-run must show:

```text
prep_direct_weight_pack_ms near zero after warm-up
host_prepack_hits > 0
host_prepack_fallbacks = 0
matching token IDs
no DDR or ZDMA error
```

## Priority 2: Add RTL Performance Counters

Start this in parallel with Priority 1.

### Files

Modify:

```text
DATN_RTL/RTL/Matrix_Vector_Multiplication.v
DATN_RTL/RTL/SPU_Q8_Scale_Accum.v
DATN_RTL/RTL/AXI4_Mapping.v
```

Modify only for signal routing when required:

```text
DATN_RTL/RTL/VPU_Top.v
DATN_RTL/RTL/SPU_Top.v
DATN_RTL/RTL/MY_IP.v
```

Update tests:

```text
DATN_RTL/TESTBENCH/tb_VPU_Top.v
DATN_RTL/TESTBENCH/tb_SPU_Top.v
DATN_RTL/TESTBENCH/Matrix_Vector_Multiplication_tb.v
```

### VPU Counters

Count these events in `Matrix_Vector_Multiplication.v`:

```text
total_busy_cycles
read_issue_cycles
pmau_input_fire_cycles
wait_result_cycles
raw_stream_hold_cycles
spu_backpressure_cycles
input_pipeline_stall_cycles
result_drain_cycles
```

Use the existing signals and states:

```text
can_issue_read
pmau_input_fire
spu_raw_valid
spu_raw_ready
S_RUN
S_WAIT_RESULT
S_RAW_STREAM_HOLD
S_DRAIN_RESULT
```

Define SPU backpressure as:

```verilog
spu_raw_valid && !spu_raw_ready
```

Use 64-bit saturating counters.

Do not allow silent wraparound.

### SPU Counters

Count these events in `SPU_Q8_Scale_Accum.v`:

```text
accepted_entries
busy_cycles
idle_cycles
accumulation_completions
input_reject_cycles
```

Use the existing states:

```text
S_IDLE
S_SCALE
S_PRODUCT_MUL
S_PRODUCT_CLAMP
S_RAW_MUL
S_CONTRIB_Q16
S_ACCUM
```

Do not change the SPU datapath in this priority.

### Register Map

`AXI4_Mapping.v` currently uses registers through `0x0268`.

Reserve a new performance range beginning at:

```text
0x0270
```

Add a performance ABI signature.

Use paired low/high registers for every 64-bit counter.

Add one write register to clear all counters.

Do not reuse P2, P3, or P4 offsets.

Mirror the new offsets in `fpga_host.cpp`.

Add one aggregate log line per graph sequence.

Do not add per-cycle or per-job logs.

### RTL Acceptance Gates

Run:

```bash
make -C DATN_RTL/TESTBENCH tb_vpu
make -C DATN_RTL/TESTBENCH all
```

Add assertions for:

```text
counter reset
counter increment
counter saturation
no increment while idle
exact S_WAIT_RESULT count
exact S_RAW_STREAM_HOLD count
exact SPU backpressure count
```

Do not request an on-board run until XSim passes.

The owner-run request must include an exact command and expected performance-counter log.

## Priority 3: Qualify Existing P3 Split Scale

Do not redesign P3.

### Host Symbols

Inspect and preserve:

```text
fpga_p3_pack_fp16_pair
fpga_p3_split_scale_host_self_test
fpga_p3_verify_retirement
FPGA_P3_SPLIT_SCALE
P3_MAX_ROWS
P3_MAX_GROUP_BLOCKS
```

### RTL Files

Inspect and preserve:

```text
DATN_RTL/RTL/AXI4_Mapping.v
DATN_RTL/RTL/SPU_Controller.v
DATN_RTL/RTL/SPU_Q8_Scale_Accum.v
```

P3 ABI must remain:

```text
0x50330001
```

P3 weight scales remain in `SPU_PARAM`.

P3 activation scales remain in `SPU_SCRATCH`.

### Qualification Order

Perform these gates in order:

```text
host self-test
RTL tile test
RTL matrix test
owner-run short generation
owner-run 64-token generation
```

Compare:

```text
Q16 tile values
selected tensor outputs
final logits
generated token IDs
P3 retirement counters
P3 reject counters
```

Keep P3 disabled by default until every gate passes.

Do not combine P3 with preload or P2 residency during initial qualification.

## Priority 4: Pipeline the SPU

Do not start until Priority 2 identifies the measured stall.

Primary file:

```text
DATN_RTL/RTL/SPU_Q8_Scale_Accum.v
```

The current path is serialized through seven states.

Replace it with a pipelined ready/valid design.

Target:

```text
initiation interval <= 2 cycles
```

Preserve:

```text
raw value
row ID
block ID
weight scale
activation scale
clear-accumulator flag
last-block flag
job ID
bank ID
```

Do not change numerical rounding or saturation.

Do not change the P2 or P3 ABI.

Pass XSim before creating a bitstream.

## Priority 5: Remove VPU Stop-and-Wait Serialization

Do not start until Priority 4 is stable.

Primary file:

```text
DATN_RTL/RTL/Matrix_Vector_Multiplication.v
```

The current critical loop is:

```text
S_RUN
S_WAIT_RESULT
S_RAW_STREAM_HOLD
S_RUN
```

Allow new input work while older results retire.

Preserve exact row and block order.

Preserve lossless ready/valid behavior.

Never drop `spu_raw_*` or `spu_raw_pair_*`.

Keep PING-PONG bank ownership unchanged.

Use the new counters to prove improvement.

Target:

```text
useful issue cycles >= 75%
SPU backpressure cycles <= 5%
```

## Priority 6: Add Cross-K Accumulation

Do not start until Priority 5 passes.

Primary files:

```text
DATN_RTL/RTL/Matrix_Vector_Multiplication.v
DATN_RTL/RTL/SPU_Controller.v
DATN_RTL/RTL/SPU_Q8_Scale_Accum.v
llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp
```

Support FFN-down accumulation across:

```text
64 + 64 + 64 + 24 Q8 blocks
```

Add explicit controls:

```text
FIRST
CONTINUE
LAST
OUTPUT
```

Return one final row vector.

Do not return intermediate row vectors.

Expected result:

```text
FFN-down host-visible jobs: 520 -> 130
intermediate result traffic: -75%
CPU cross-K accumulation: removed
```

## Do Not Start

Do not work on these items in TASK--002:

```text
more than two packing workers
larger ZDMA descriptors
direct PL DDR AXI master
MAX_ROWS=512
more PMAUs
higher PL clock
FFN gate/up fusion
activation residency
RMSNorm offload
RoPE offload
Softmax offload
vocabulary projection offload
prefill GEMM
```

## Required Work Sequence

```text
1. Implement host-DRAM packed-weight catalog.
2. Add RTL counters in parallel.
3. Pass host self-tests and XSim.
4. Request owner-run validation.
5. Qualify P3.
6. Pipeline SPU.
7. Remove VPU stop-and-wait.
8. Add cross-K accumulation.
```

## Board-Test Rule

The agent cannot run the ZCU104 board.

Do not claim on-board validation.

When a board test is required:

1. Stop.
2. Provide the exact command.
3. List required environment variables.
4. State the safe DDR range.
5. State expected log lines.
6. State pass and fail criteria.
7. Ask the user to run it through the UltraViewer-connected machine.
8. Continue only after the user returns the log.

## Git Rule

Commit child repositories first.

Use this order:

```text
1. Commit and push llama.cpp changes.
2. Commit and push DATN_RTL changes.
3. Update both submodule pointers in the parent repository.
4. Commit and push the parent repository.
```

## Completion Report

Report these items after every implementation stage:

```text
files changed
functions or modules changed
dataflow before
dataflow after
safety impact
tests run
tests passed
tests not run
owner-run command required
measured result
remaining risk
rollback commit
```
