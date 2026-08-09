# TASK-003 — Implement RESULT-002 Priorities 1–2

Status: `READY_FOR_IMPLEMENTATION`

## Repository state reviewed before implementation

The parent repository currently pins the older child commits:

```text
parent main:
DATN_RTL  -> bd2675cb2e50383dcd3d0d779c59c8fccaaaa003
llama.cpp -> d33e11f8c12219357c9a44bd894f6b86fc0b9e4e
```

TASK-003 must **not** start the child implementation branches from those stale parent pointers. Use the latest reviewed child commits:

```text
Host child:
repo    Infrastructure_GEMMA3
branch  main
commit  8c24927d0c50b921d19b4e03699a9fbdb773e595
change  fpga_host.cpp; preload and 2-worker WEIGHT packing are production defaults

RTL child:
repo    LLM_GEMMA3-1B-INT8
branch  spu
commit  8fc83108df3d4aa23bcc1a31125ee764047fa821
change  result_prompt.txt only
RTL source baseline remains identical to parent bd2675cb2e50383dcd3d0d779c59c8fccaaaa003
```

Before editing, fetch both children and verify those exact commits are present. Create:

```text
Infrastructure_GEMMA3: task-003-host-prepack from 8c24927d0c50b921d19b4e03699a9fbdb773e595
LLM_GEMMA3-1B-INT8:   task-003-perf-counters from 8fc83108df3d4aa23bcc1a31125ee764047fa821
```

If either upstream branch has advanced beyond the reviewed commit, **stop before editing**, inspect the new diff against this task, and record the new baseline in `RESULT-003.md`. Do not silently implement against unreviewed source.

Do not update the parent submodule pointers until both child implementations are committed and pushed.

## Scope

Implement only:

1. **P1 — host-DRAM P2 packed-weight catalog**: pack immutable Q8_0 weights once per model load; each launch still copies the packed tile into safe FPGA DDR and uses the existing ZDMA/VPU/SPU path.
2. **P2 — observation-only VPU/SPU counters**: 13 saturating 64-bit counters, atomic MMIO snapshot, one host aggregate per FPGA-active graph.

Do **not** implement Priority 3, SPU pipeline redesign, VPU overlap redesign, cross-K redesign, or Priorities 4–6.

## Baseline contracts that must not change

```text
P2 layout: index=((row>>1)*group_beats+beat)*2+(row&1)
P2 layout version: 2
P2 WEIGHT source: pair-interleaved, zero padded companion for odd final row
P2 coherency: DSB -> first/last volatile readback -> DSB; no msync()
FPGA DDR physical carveout: [0x70000000,0x80000000), exactly 256 MiB
WEIGHT staging window: [0x00100000,0x00200000), exactly 1 MiB relative to DDR_BASE_PHYS
current RTL last explicit register: 0x021C
```

`fpga_weight_layout_payload_words/bytes()` and `fpga_weight_layout_word_index()` are the current pure P2 layout authority. `fpga_weight_layout_word_offset()` only adds a DDR base. `fpga_weight_layout_zero_padded_companion()` is DDR-specific and must not become catalog logic.

`fpga_mark_model_tensor_validation_passed()` is qualification/source-audit evidence only; do not repurpose it as model lifetime tracking.

Current host production behavior from `8c24927` is also a compatibility contract:

```text
FPGA_P2_PACK_WORKERS unset -> 2 workers by default
FPGA_P2_PACK_WORKERS=1     -> legacy serial direct pack
FPGA_P2_PACK_WORKERS=2     -> caller + one persistent helper, disjoint row-pair ranges
FPGA_P2_INPUT_PRELOAD unset -> enabled on normal admitted P2 ping-pong
FPGA_P2_INPUT_PRELOAD=0     -> explicit preload opt-out
qualification/P3 may suppress preload under the existing rules
```

TASK-003 must preserve those defaults and must not serialize the current 2-worker direct-pack path as a side effect of P1.

---

# P1 — Host packed-weight catalog

## P1.1 Gate and incompatible modes

Add:

```text
FPGA_HOST_WEIGHT_PREPACK=0   default; current direct pack; fallback counter unchanged
FPGA_HOST_WEIGHT_PREPACK=1   enable P1
```

P1 is P2-only. During `fpga_init()`, before any data-plane work, `FPGA_HOST_WEIGHT_PREPACK=1` must fail closed if any of these is requested/enabled:

```text
FPGA_P3_SPLIT_SCALE=1
FPGA_P2_WEIGHT_RESIDENCY=1
FPGA_WEIGHT_CACHE=1
```

Do not silently disable either side of a conflict.

## P1.2 Model lifetime

Add board-free C ABI:

```c
void fpga_model_load_epoch_advance(void);
```

Files:

```text
ggml/src/ggml-cpu/fpga_host.h
ggml/src/ggml-cpu/fpga_host.cpp
src/llama-model-loader.cpp
```

Contract:

- Maintain nonzero `uint64_t g_fpga_model_epoch`.
- `fpga_model_load_epoch_advance()` frees/retires all catalog entries from the previous epoch, then increments the epoch; wrap to zero is fatal.
- It must perform **no** FPGA init, mmap, MMIO, UIO, `/dev/mem`, coherency operation, or DMA.
- In `llama_model_loader::load_all_data()`, call it once when `size_done >= size_data`, **after** all validation futures pass and **after** the final `progress_callback(1.0f, ...)` accepts completion, before returning `true`.
- Call it for every successful model load under `USE_FPGA`, independent of contract/source-audit environment variables.
- Keep the existing conditional `fpga_mark_model_tensor_validation_passed()` call and semantics unchanged.
- `fpga_cleanup()` frees the catalog after existing device-quiescence handling.

## P1.3 Catalog limits, key, states, allocation

```text
scope                  process-local heap only
eligible source         Q8_0 tensors accepted by the existing P2 FPGA path
maximum_catalog_bytes  1,073,741,824 (1 GiB)
maximum_entry_bytes    67,108,864 (64 MiB)
build policy            lazy; once per eligible tensor per model epoch
source owner            loaded model tensor storage
source mutation         forbidden/trusted for that model epoch
retry after cap/alloc failure  none in same epoch
```

Do not build entries for intentional CPU bypasses, including the vocabulary projection.

Exact key:

```text
uint64_t  model_epoch
uintptr_t src0
uintptr_t src0_data
uint32_t  src0_type
int64_t   ne[4]
uint64_t  nb[4]
uint32_t  layout_version = 2
```

Entry states:

```text
BUILDING | VALID | BYPASS_ALLOC | POISONED | RETIRED
```

Each entry owns one fixed **64-byte-aligned contiguous allocation**. No descriptor may point into a growable container; descriptors use offsets from allocation base.

Tile descriptor fields/types:

```text
int64_t  row0
uint32_t rows
int64_t  k_block0
uint32_t group_blocks
uint32_t group_beats
uint64_t packed_offset
uint64_t packed_bytes
uint64_t scale_offset
uint64_t scale_count
uint32_t packed_crc32
uint32_t scale_crc32
```

Scales are stored as raw `uint16_t` GGML FP16 bits, one per `(row, group_block)`, with no FP32 conversion.

`host_prepack_bytes` = sum of current entry allocation sizes, including metadata/descriptors/packed bytes/scales/alignment padding; exclude fixed global container overhead.

## P1.4 CRC contract

Use the repository's existing reflected CRC-32 algorithm:

```text
polynomial = 0xEDB88320
initial    = 0xFFFFFFFF
final      = bitwise NOT
```

Checksums:

- `packed_crc32`: exact packed tile bytes.
- `scale_crc32`: scale `uint16_t` values serialized little-endian.
- `metadata_crc32`: key + descriptor count + every descriptor field in the order listed above, each fixed-width integer serialized little-endian. Do not CRC raw C/C++ structs or padding.
- Source tensor contents are **not** rehashed on hits; source immutability is a model-lifetime contract.

Validation time:

```text
publish VALID: compute/store all CRCs
 every hit: key/epoch/state + metadata CRC + descriptor bounds/alignment
 every catalog copy: recompute packed CRC while copying + recompute referenced scale CRC
```

Corruption = any failed validation above. Action: `POISONED`, no DMA, no direct-pack fallback, one reason log for that tensor, existing fail-closed error path, no retry in that epoch.

Only entry-size cap, total-catalog cap, or host allocation failure may produce `BYPASS_ALLOC`. `BYPASS_ALLOC` direct-packs that tensor only and never retries that epoch.

## P1.5 One production P2 WEIGHT emitter

Add board-free files:

```text
ggml/src/ggml-cpu/fpga_weight_layout.h
ggml/src/ggml-cpu/fpga_weight_layout.cpp
```

Move/extract the pure layout functions there. The board-free module is the **single production authority** for P2 payload sizing, pair-interleaved indexing, little-endian lane stores, CRC serialization, and descriptor validation used by both `fpga_host.cpp` and the standalone self-test.

The emitter must support disjoint row-pair ranges so the current 2-worker direct pack is preserved:

```c++
typedef bool (*fpga_p2_weight_sink_fn)(
    void * ctx,
    size_t word_index,
    const int8_t lanes[16]);

bool fpga_emit_p2_weight_pair_range(
    const uint8_t * tile_row0,       // first selected Q8_0 row
    uint64_t row_stride_bytes,       // src0->nb[1]
    uint32_t rows,
    uint32_t group_blocks,
    size_t pair_begin,               // inclusive
    size_t pair_end,                 // exclusive
    fpga_p2_weight_sink_fn sink,
    void * sink_ctx);
```

Contract:

```text
group_beats = group_blocks * 2
pair_count  = (rows + 1) / 2
0 <= pair_begin <= pair_end <= pair_count
```

Rules:

- For each logical row/block, emit `qs[0..15]` then `qs[16..31]`.
- Every destination position is obtained through `fpga_weight_layout_word_index()`; there is no second production copy of `((row>>1)*group_beats+beat)*2+(row&1)`.
- When the selected range contains the final pair of an odd-row tile, emit zero 16-byte beats for the missing companion row through the same index authority.
- Host sink: bounds checked, allocation destination at least 4-byte aligned, four explicit 32-bit little-endian stores per 16-byte beat.
- DDR sink: existing bounded volatile 32-bit stores at `slot_base + word_index*16`.
- Catalog construction emits the complete range `[0,pair_count)`.
- Current serial direct packing emits `[0,pair_count)`.
- Current 2-worker direct packing keeps the existing split: caller and persistent helper invoke this same emitter on non-overlapping pair ranges. `FPGA_P2_PACK_WORKERS=2` must remain the default and must retain parallelism for ordinary direct packing and `BYPASS_ALLOC`.
- The helper thread remains CPU-store-only: no DMA, descriptor, MMIO, VPU, SPU, or `g_mutex` ownership changes.
- Delete/replace `fpga_pack_direct_weight_pair_range()` only after both current serial and parallel callers use the new common emitter.
- Do not use `fpga_weight_layout_zero_padded_companion()` in catalog code; zero-padding belongs to the common emitter.

The production code may provide a trivial whole-tile wrapper around `fpga_emit_p2_weight_pair_range(..., 0, pair_count, ...)`, but the pair-range function remains the authority used by the 2-worker path.

## P1.6 Boardless self-test

Add:

```text
tests/test-fpga-host-prepack.cpp
target: fpga-host-prepack-selftest
```

Build integration is in `ggml/src/CMakeLists.txt`, because that file currently owns `USE_FPGA` and `fpga_host.cpp`. Under `if(USE_FPGA)`, add `fpga_weight_layout.cpp` to `ggml-cpu` and add a standalone self-test executable from `tests/test-fpga-host-prepack.cpp + fpga_weight_layout.cpp`. The self-test must not link/call `fpga_host.cpp` and must not require FPGA hardware.

Because the standalone executable cannot link `fpga_host.cpp`, **do not duplicate production verification logic in the test**. `fpga_weight_layout.{h,cpp}` must expose the board-free canonical helpers required by production and test for:

```text
payload words/bytes
pair-interleaved word index
16-byte -> four uint32 little-endian packing
reflected CRC-32 update/finalization
fixed-width little-endian metadata serialization
descriptor bounds/alignment validation
```

The test may independently reproduce the pair-interleave formula only for the expected-reference buffer in step 3 below; it must call production helpers for the emitted payload and CRC/descriptor checks.

Test every cross-product:

```text
rows   = {1,2,255,256}
blocks = {1,64}
scale_bits(row,block) = {0x3400,0x3800,0x3c00,0x4000}[(row+block)&3]
qs(row,block,i) = int8_t(((row*29 + block*17 + i*7) % 255) - 127), i=0..31
```

For each case:

1. emit through a DDR-style memory sink;
2. emit through a catalog memory sink;
3. independently construct expected bytes in the **test only** using `index=((row>>1)*group_beats+beat)*2+(row&1)`;
4. assert both sink outputs equal the independent expected bytes byte-for-byte;
5. assert raw FP16 scale bits match bit-for-bit;
6. for rows 1 and 255, assert the entire padded companion row is zero;
7. assert descriptor offsets/counts are aligned and in allocation range;
8. recompute packed, scale, metadata CRCs and match stored values.

Failure exit code != 0.

Exact commands from `D:/DOAN/llama.cpp`:

```bash
cmake --build build_mem -j2
cmake --build build_mem -j2 --target fpga-host-prepack-selftest
./build_mem/bin/fpga-host-prepack-selftest
```

Do not delete/recreate `build_mem`; no explicit `cmake -S/-B`. CMake's normal auto-regeneration after CMakeLists edits is allowed.

## P1.7 Absolute DDR range proof

Add two authorities:

```c++
bool ddr_phys_range_fits(uint64_t off, uint64_t bytes); // no mapping required
bool ddr_range_fits(uint64_t off, uint64_t bytes);      // mapped-size + physical proof
```

`ddr_phys_range_fits()` rejects `bytes==0` and proves without overflow:

```text
off <= DDR_REGION_SIZE
bytes <= DDR_REGION_SIZE - off
DDR_BASE_PHYS + off >= 0x70000000
DDR_BASE_PHYS + off + bytes <= 0x80000000
```

`ddr_range_fits()` additionally requires:

```text
ddr_is_mapped()
off <= g_ddr_map_size
bytes <= g_ddr_map_size - off
```

Required use:

- `ddr_phys_range_fits(0, requested_map_size)` before DDR mmap;
- `ddr_range_fits()` before every DDR pointer/dereference, direct pack, catalog copy, coherency readback, or ZDMA DDR source/destination submit.

Failure returns `false`; the board-facing caller fails closed **before** access. No range failure may fall back to direct pack/CPU.

Do not change `DDR_BASE_PHYS`, `DDR_REGION_SIZE`, `DDR_END_EXCLUSIVE`, or any MMIO physical base.

## P1.8 Two fixed host WEIGHT staging slots

Keep:

```text
slot 0 = 0x00100000 -> VPU bank 0
slot 1 = 0x00180000 -> VPU bank 1
alignment = 4096
slot_size = align_up(g_vpu_max_rows * g_vpu_max_beats * 16, 4096)
```

At current admitted maxima `256 x 128`, `slot_size = 0x80000`. At init require:

```text
slot_size <= 0x80000
slots do not overlap
each slot wholly inside [WEIGHT_BASE,WEIGHT_END)
each slot passes ddr_range_fits()
```

Failure is fatal before data-plane work.

Do not modify existing hardware/descriptor `fpga_slot_state_t`. Add separate host-only state:

```text
HOST_SLOT_FREE
HOST_SLOT_CPU_WRITING
HOST_SLOT_READY
HOST_SLOT_DMA_READING
HOST_SLOT_BANK_OWNED
HOST_SLOT_ERROR
```

Exact transitions:

```text
FREE -> CPU_WRITING        immediately before first CPU store
CPU_WRITING -> READY       only after CRC + coherency pass
READY -> DMA_READING       immediately before ZDMA submit
DMA_READING -> BANK_OWNED  only after successful ZDMA completion
BANK_OWNED -> FREE         only after matching VPU/SPU job retirement
pre-DMA failure -> FREE
DMA error/timeout -> ERROR
ERROR -> never reused
```

CPU may write only `CPU_WRITING`. This ownership applies whenever `g_p2_input_preload_enabled == true`, including the current **default-on** normal P2 preload route; it is not conditional on the environment variable being explicitly set to `1`.

Host staging and IP-local WEIGHT memory are distinct:

```text
ZDMA source = DDR_BASE_PHYS + selected_host_slot_offset
slot 0 source offset = 0x00100000
slot 1 source offset = 0x00180000

ZDMA destination = existing bank-selected MY_IP/LMM WEIGHT destination
do not reinterpret the host slot split as a new RTL WEIGHT address map
```

Preserve the current descriptor/bank routing that chooses the IP-local destination. TASK-003 changes only the PS-DDR source ownership/staging discipline.

Cleanup: preserve existing bounded ZDMA quiescence first; never free/reset staging ownership while ZDMA is enabled. After quiescence, retire host slots and free catalog memory.

## P1.9 Catalog-hit execution

For each catalog-served tile:

```text
1 validate exact key/epoch/state/metadata CRC/descriptor bounds
2 select its bank-matched FREE staging slot; FREE->CPU_WRITING
3 volatile-copy packed bytes; recompute packed CRC during copy
4 verify packed CRC and referenced scale CRC
5 run existing P2 CPU->device sync on that slot: DSB -> first/last volatile read -> DSB
6 CPU_WRITING->READY
7 immediately before WEIGHT ZDMA: READY->DMA_READING
8 after successful ZDMA completion: DMA_READING->BANK_OWNED
9 launch/retire through unchanged P2/P1/VPU/SPU path
10 after matching VPU/SPU retirement: BANK_OWNED->FREE
```

No `msync()`.

Weight scales come directly from catalog FP16 bits. Activation scales remain current dynamic FP16 bits. Existing `SPU_PARAM` packing and P2 arithmetic are unchanged.

## P1.10 Host telemetry and acceptance semantics

Maintain process totals and graph baselines. A graph is `graph_seq = g_current_seq_pos`; emit only for a graph that accepted at least one P2 FPGA job.

At the same graph boundary used for P2 snapshot (see P2.5), emit exactly one forced-flush line:

```text
HOST_PREPACK graph_seq=<n> builds=<n> misses=<n> hits=<n> fallbacks=<n> bytes=<n> build_us=<n> copy_us=<n> prep_direct_weight_pack_us=<n>
```

Definitions:

```text
builds      graph delta; tensors published VALID
misses      graph delta; first eligible lookup with no entry; first use = miss + build
hits        graph delta; tile lookup served from already VALID entry
fallbacks   graph delta; tile direct-packed only because tensor is BYPASS_ALLOC
bytes       current resident catalog allocation bytes
build_us    graph delta; allocation begin -> VALID publish; includes scale extraction, packing, CRC
copy_us     graph delta; first DDR store -> successful P2 DSB/readback/DSB
prep_direct_weight_pack_us  graph delta of existing direct WEIGHT packing only
```

Disabled P1 is ordinary direct pack and does not increment `fallbacks`. A catalog hit increments `prep_direct_weight_pack_us` by exactly `0`.

Board acceptance for P1:

```text
maximum fallbacks = 0
maximum catalog = 1 GiB
maximum entry = 64 MiB

warm-up/build graph:
    misses/builds are allowed because the catalog is lazy

after the workload has built every eligible entry it uses:
    every subsequent FPGA-active graph in the same model epoch has misses=0
    every subsequent FPGA-active graph has fallbacks=0
    hits>0 for eligible catalog-served work
    graph-local hits/(hits+misses) = 100%

catalog-served direct-pack time = 0 us
latency/speedup = measurement-only; no minimum speedup threshold
```

The phrase “after the first graph” is intentionally not used: a lazy first graph can legally contain `miss + build`.

---

# P2 — Observation-only RTL counters

No counter logic may change arithmetic, ready/valid, state ordering, descriptor semantics, stream semantics, or existing register values.

All live counters:

```text
width = 64-bit unsigned
reset = 0
maximum = 0xffffffffffffffff
increment at maximum = hold
saturation flag = none
count only while perf_window_active=1
```

On an accepted CLEAR or SNAPSHOT edge, no event is counted that edge:

```verilog
perf_count_enable = perf_window_active && !perf_clear_accept && !perf_snapshot_accept;
```

## P2.1 VPU predicates — `Matrix_Vector_Multiplication.v`

Add `perf_enable`, `perf_clear` inputs and 8 live counter outputs. Increment when `perf_enable` and:

```verilog
total_busy_cycles           = busy;
read_issue_cycles           = can_issue_read;
pmau_input_fire_cycles      = pmau_input_fire;
wait_result_cycles          = (state_r == S_WAIT_RESULT);
raw_stream_hold_cycles      = (state_r == S_RAW_STREAM_HOLD);
spu_backpressure_cycles     = spu_raw_valid && !spu_raw_ready;
input_pipeline_stall_cycles = (state_r == S_RUN) &&
                              (read_beat_idx_r < issue_read_limit) &&
                              !read_req_slot_open;
result_drain_cycles         = (state_r == S_DRAIN_RESULT);
```

## P2.2 SPU predicates — `SPU_Q8_Scale_Accum.v`

Add `perf_enable`, `perf_clear` inputs and 5 live counter outputs. Increment when `perf_enable` and:

```verilog
accepted_entries         = start && (state_r == S_IDLE);
busy_cycles              = (state_r != S_IDLE);
idle_cycles              = (state_r == S_IDLE);
accumulation_completions = (state_r == S_ACCUM);
input_reject_cycles      = start && (state_r != S_IDLE);
```

Do not use `entry_done` for successful completion; current error exits can assert `entry_done` from `S_SCALE` without reaching `S_ACCUM`.

Production MMIO aggregation includes only:

```text
SPU_Top.u_vpu_stream_scale_accum
SPU_Top.u_vpu_stream_pair_scale_accum
```

Exclude `SPU_Controller.u_q8_scale_accum`: tie its new perf inputs low and leave outputs unconnected.

`SPU_Top` passes perf control to the two production instances, **saturating-adds** corresponding outputs, exports 5 aggregated counters, and exports:

```verilog
perf_stream_accums_idle = !stream_accum_busy && !stream_accum_pair_busy;
```

SPU busy/idle units are accumulator-instance cycles; aggregate increment may be 2 per PL cycle.

## P2.3 Counter route

```text
AXI4_Mapping
  -> perf_enable/perf_clear -> Matrix_Vector_Multiplication
  -> perf_enable/perf_clear -> SPU_Top -> 2 production SPU_Q8_Scale_Accum
  <- 8 VPU counters
  <- 5 aggregated SPU counters
  <- perf_stream_accums_idle
  -> owns window/status/snapshot/MMIO readback
```

`MY_IP.v`/`VPU_Top.v` may change only if compilation requires pass-through; do not alter data-plane behavior.

## P2.4 MMIO ABI

Keep `0x0220..0x026F` reserved/read-zero/no-effect. Add:

| Offset | Register |
|---:|---|
| `0x0270` | `PERF_SIGNATURE` RO = `0x50455246` (`PERF`) |
| `0x0274` | `PERF_VERSION` RO = `1` |
| `0x0278` | `PERF_COUNTER_COUNT` RO = `13` |
| `0x027C` | `PERF_STATUS`: b0 active, b1 snapshot_valid, b2 clear_rejected_busy, b3 snapshot_rejected_busy |
| `0x0280` | `PERF_SNAPSHOT` WO b0 |
| `0x0284` | `PERF_CLEAR` WO b0 |
| `0x0288..0x028C` | reserved/read 0 |
| `0x0290/0x0294` | VPU total_busy LO/HI |
| `0x0298/0x029C` | VPU read_issue LO/HI |
| `0x02A0/0x02A4` | VPU pmau_input_fire LO/HI |
| `0x02A8/0x02AC` | VPU wait_result LO/HI |
| `0x02B0/0x02B4` | VPU raw_stream_hold LO/HI |
| `0x02B8/0x02BC` | VPU spu_backpressure LO/HI |
| `0x02C0/0x02C4` | VPU input_pipeline_stall LO/HI |
| `0x02C8/0x02CC` | VPU result_drain LO/HI |
| `0x02D0/0x02D4` | SPU accepted_entries LO/HI |
| `0x02D8/0x02DC` | SPU busy_cycles LO/HI |
| `0x02E0/0x02E4` | SPU idle_cycles LO/HI |
| `0x02E8/0x02EC` | SPU accumulation_completions LO/HI |
| `0x02F0/0x02F4` | SPU input_reject LO/HI |

Command write acceptance uses current AXI rule:

```verilog
address_match && wr_strb4[0] && wr_data32[0]
```

Define:

```verilog
perf_units_idle = !core_busy && perf_stream_accums_idle;
```

Reset:

```text
live=0; snapshot=0; active=0; snapshot_valid=0; reject_bits=0
```

Accepted `PERF_CLEAR` only when idle:

```text
live=0; snapshot=0; active=1; snapshot_valid=0; reject_bits=0
```

Busy CLEAR: no live/snapshot/window change; sticky status b2=1.

Accepted `PERF_SNAPSHOT` only when idle:

```text
atomically snapshot all 13 live counters; active=0; snapshot_valid=1
```

Busy SNAPSHOT: no live/snapshot/window change; sticky status b3=1.

Counter MMIO reads always return the latched snapshot, never live values. Host reads LO then HI.

## P2.5 Host counter use

Add matching constants to `fpga_host.cpp`. After normal VPU identity/capability admission, read signature/version/count once.

Mismatch:

```text
one warning
no perf CLEAR/SNAPSHOT/read after mismatch
continue inference unchanged
```

Use existing `g_mutex`; add no hardware lock and no counter-only polling delay.

Graph lifecycle:

```text
first accepted P2 job for graph_seq:
    while units are already idle, PERF_CLEAR immediately before first VPU launch
    mark graph perf window active
    capture HOST_PREPACK graph baselines

fpga_advance_sequence_position(n_tokens):
    preserve existing timing/event emission
    before changing g_current_seq_pos, briefly take g_mutex for telemetry
    if previous graph accepted FPGA work:
        require units idle; PERF_SNAPSHOT
        if snapshot_valid: read 13 LO/HI pairs
        emit exactly one FPGA_PERF line
        emit exactly one HOST_PREPACK line
    release mutex; then advance sequence

fpga_cleanup():
    after existing ZDMA-disabled/device-quiescent proof and before unmapping,
    snapshot/read/emit any final active graph if units are idle
```

Normal CLEAR/SNAPSHOT rejection: emit one `FPGA_PERF_ERROR`, disable further perf MMIO for the process, continue inference. It is a TASK-003 acceptance failure.

Exact performance line:

```text
FPGA_PERF graph_seq=<n> signature=0x50455246 version=1 count=13 vpu_total_busy_cycles=<n> vpu_read_issue_cycles=<n> vpu_pmau_input_fire_cycles=<n> vpu_wait_result_cycles=<n> vpu_raw_stream_hold_cycles=<n> vpu_spu_backpressure_cycles=<n> vpu_input_pipeline_stall_cycles=<n> vpu_result_drain_cycles=<n> spu_accepted_entries=<n> spu_busy_cycles=<n> spu_idle_cycles=<n> spu_accumulation_completions=<n> spu_input_reject_cycles=<n>
```

One forced-flush `FPGA_PERF` and one forced-flush `HOST_PREPACK` per FPGA-active graph; no per-tile success log.

## P2.6 RTL tests

Update canonical testbenches:

```text
TESTBENCH/tb_VPU_Top.v
TESTBENCH/tb_SPU_Top.v
```

Required cases after successful CLEAR/window activation:

| Case | Stimulus | Required result |
|---|---|---|
| reset | `resetn=0` 4 rising edges, then 1 | live/snapshot 0, active 0 |
| write strobe | CLEAR b0 with `wr_strb4[0]=0` | no effect |
| VPU wait | force `S_WAIT_RESULT` 7 edges | wait=7 |
| VPU raw hold | force `S_RAW_STREAM_HOLD` 5 edges | raw_hold=5 |
| VPU backpressure | `spu_raw_valid=1, spu_raw_ready=0` 9 edges | backpressure=9 |
| VPU input stall | `S_RUN`, `read_beat_idx=0`, `issue_read_limit=2`, `read_req_slot_open=0` 4 edges | input_stall=4 |
| VPU drain | force `S_DRAIN_RESULT` 3 edges | drain=3 |
| saturation | preload one live counter=`64'hffff_ffff_ffff_fffe`, predicate 2 edges | `64'hffff_ffff_ffff_ffff` |
| SPU accept | production accumulator `start=1` in `S_IDLE`, 1 edge | accepted=1 |
| SPU reject | production accumulator `start=1` in `S_SCALE`, 2 edges | reject=2 |
| SPU complete | production accumulator in `S_ACCUM`, 1 edge | completion=1 |
| SPU idle | both production accumulators idle 6 active edges | aggregate idle=12 |
| snapshot | create 3 target events; idle; SNAPSHOT; then create/force 2 later events | snapshot remains 3, active=0 |
| clear | nonzero snapshot; idle; CLEAR | live/snapshot=0, active=1 |
| clear busy | VPU busy; CLEAR | values unchanged, status b2=1 |
| snapshot busy | VPU or production SPU busy; SNAPSHOT | values unchanged, status b3=1 |
| ABI | MMIO reads | `0x50455246`, version 1, count 13 |

Release every hierarchical force after each case.

Authoritative RTL command:

```powershell
powershell -ExecutionPolicy Bypass -File D:/DOAN/DATN_RTL/DATN_VIVADO/manual_sim/run_phase2a_vpu_spu_xsim.ps1
```

Pass = both canonical testbenches reach `$finish`, zero assertion failures, process exit 0.

---

# Allowed files

Parent:

```text
.codex/inbox/TASK-003.md
.codex/outbox/RESULT-003.md
submodule pointers only after child commits are pushed
```

Host child:

```text
ggml/src/ggml-cpu/fpga_host.cpp
ggml/src/ggml-cpu/fpga_host.h
ggml/src/ggml-cpu/fpga_weight_layout.cpp      new
ggml/src/ggml-cpu/fpga_weight_layout.h        new
ggml/src/CMakeLists.txt
src/llama-model-loader.cpp
tests/test-fpga-host-prepack.cpp               new
```

RTL child:

```text
RTL/Matrix_Vector_Multiplication.v
RTL/SPU_Q8_Scale_Accum.v
RTL/SPU_Top.v
RTL/SPU_Controller.v
RTL/AXI4_Mapping.v
RTL/VPU_Top.v       pass-through only if compile requires
RTL/MY_IP.v         pass-through only if compile requires
TESTBENCH/tb_VPU_Top.v
TESTBENCH/tb_SPU_Top.v
```

# Prohibited

```text
DATN_RTL/DATN_VIVADO/project_1/**
DATN_RTL/EMBEDDED_LLAMA/**
llama.cpp/hls_accelerator/**
physical DDR/MMIO base changes
P2/P3 arithmetic/datatype changes
ready/valid timing changes
existing descriptor/REG_SLOT_STATE value changes
Priority 3 or Priorities 4–6
unrelated owner files
reset/clean/overwrite unrelated work
automatic merge to protected branches
```

Required branches:

```text
parent    task-003
llama.cpp task-003-host-prepack     base=8c24927d0c50b921d19b4e03699a9fbdb773e595
DATN_RTL  task-003-perf-counters    base=8fc83108df3d4aa23bcc1a31125ee764047fa821
```

The RTL child base includes the latest `result_prompt.txt` commit even though its RTL files are unchanged from `bd2675c`.

Do not update parent submodule pointers until both child commits are complete and pushed.

---

# Validation order

Before step 1, prove the implementation branches descend from the reviewed child baselines and that the host still reports the current production policies:

```text
host base contains 8c24927d0c50b921d19b4e03699a9fbdb773e595
RTL base contains 8fc83108df3d4aa23bcc1a31125ee764047fa821
FPGA_P2_PACK_WORKERS default remains 2
normal admitted P2 preload remains default-on/opt-out with FPGA_P2_INPUT_PRELOAD=0
```

Then:

```text
1. git diff --check in both child repos
2. cd D:/DOAN/llama.cpp && cmake --build build_mem -j2
3. cmake --build build_mem -j2 --target fpga-host-prepack-selftest
4. ./build_mem/bin/fpga-host-prepack-selftest
5. powershell -ExecutionPolicy Bypass -File D:/DOAN/DATN_RTL/DATN_VIVADO/manual_sim/run_phase2a_vpu_spu_xsim.ps1
6. only after 1–5 pass: request owner ZCU104 evidence
```

The implementation agent must not run or claim ZCU104 validation.

# Owner ZCU104 validation

Deploy from TASK-003 commits:

```text
new RTL bitstream
build_mem/bin/llama-cli
build_mem/bin/libggml-cpu.so
```

Preflight:

```bash
grep -i 'System RAM' /proc/iomem
```

Pass: no System RAM overlaps `[0x70000000,0x80000000)`; runtime still reports FPGA DDR base `0x70000000`, size `0x10000000`.

Run baseline and candidate with the **same new bitstream**; only `FPGA_HOST_WEIGHT_PREPACK` changes.

Baseline:

```bash
sudo rm -f /tmp/fpga_debug.log /tmp/task003_baseline.txt
sudo ./overlay_procedure.sh run -- env \
  -u FPGA_P3_SPLIT_SCALE -u FPGA_P2_WEIGHT_RESIDENCY -u FPGA_P2_WEIGHT_RESIDENCY_DIAGNOSTIC \
  -u FPGA_SOURCE_AUDIT_ONLY -u FPGA_CONTRACT_CHECK -u FPGA_PL_SCALE_CONTRACT_CHECK -u FPGA_PL_SCALE_DISABLE \
  FPGA_PL_SCALE_ENABLE=1 FPGA_PIPELINE_ENABLE=1 FPGA_P2_INPUT_PRELOAD=1 \
  FPGA_P2_PACK_WORKERS=2 FPGA_WEIGHT_CACHE=0 FPGA_HOST_WEIGHT_PREPACK=0 \
  FPGA_ABORT_ON_CPU_FALLBACK=1 FPGA_ACCELERATE_VOCAB=0 \
  FPGA_TOKEN_TIMING=1 FPGA_BOTTLENECK_SUMMARY=1 FPGA_LOG_FLUSH_EVERY=1 LLAMA_LOGIT_TRACE=1 \
  ./build_mem/bin/llama-cli --check-tensors -m ./models/gemma-3-1b-it-Q8_0.gguf \
  -p "Please write about AI" -n 4 --single-turn --no-warmup --temp 0 --seed 1 \
  2>&1 | tee /tmp/task003_baseline.txt
printf 'llama_exit=%s\n' "${PIPESTATUS[0]}"
```

Candidate:

```bash
sudo rm -f /tmp/fpga_debug.log /tmp/task003_candidate.txt
sudo ./overlay_procedure.sh run -- env \
  -u FPGA_P3_SPLIT_SCALE -u FPGA_P2_WEIGHT_RESIDENCY -u FPGA_P2_WEIGHT_RESIDENCY_DIAGNOSTIC \
  -u FPGA_SOURCE_AUDIT_ONLY -u FPGA_CONTRACT_CHECK -u FPGA_PL_SCALE_CONTRACT_CHECK -u FPGA_PL_SCALE_DISABLE \
  FPGA_PL_SCALE_ENABLE=1 FPGA_PIPELINE_ENABLE=1 FPGA_P2_INPUT_PRELOAD=1 \
  FPGA_P2_PACK_WORKERS=2 FPGA_WEIGHT_CACHE=0 FPGA_HOST_WEIGHT_PREPACK=1 \
  FPGA_ABORT_ON_CPU_FALLBACK=1 FPGA_ACCELERATE_VOCAB=0 \
  FPGA_TOKEN_TIMING=1 FPGA_BOTTLENECK_SUMMARY=1 FPGA_LOG_FLUSH_EVERY=1 LLAMA_LOGIT_TRACE=1 \
  ./build_mem/bin/llama-cli --check-tensors -m ./models/gemma-3-1b-it-Q8_0.gguf \
  -p "Please write about AI" -n 4 --single-turn --no-warmup --temp 0 --seed 1 \
  2>&1 | tee /tmp/task003_candidate.txt
printf 'llama_exit=%s\n' "${PIPESTATUS[0]}"
```

Diagnostic comparison:

```bash
grep -F '[LOGIT_TRACE] sampled id=' /tmp/task003_baseline.txt  > /tmp/task003_baseline.ids
grep -F '[LOGIT_TRACE] sampled id=' /tmp/task003_candidate.txt > /tmp/task003_candidate.ids
diff -u /tmp/task003_baseline.ids /tmp/task003_candidate.ids
grep -E 'HOST_PREPACK|FPGA_PERF|FPGA_PERF_ERROR|TOKEN_TIMING|BOTTLENECK|POISON|CRC|ZDMA|range|fallback' \
  /tmp/task003_candidate.txt /tmp/fpga_debug.log
```

Board pass:

```text
baseline exit=0
candidate exit=0
sampled token IDs identical
PERF signature/version/count = 0x50455246/1/13
exactly one FPGA_PERF + one HOST_PREPACK per FPGA-active graph
normal clear/snapshot rejection count = 0
spu_input_reject_cycles = 0
at quiescent normal snapshot: spu_accumulation_completions == spu_accepted_entries
candidate host_prepack_fallbacks = 0
after first completed FPGA graph: eligible hit rate = 100%
catalog-served prep_direct_weight_pack_us = 0
catalog <= 1 GiB; each entry <= 64 MiB
no POISONED/CRC/range/ZDMA/unavailable-CPU-fallback error
```

Immediate fail:

```text
any FPGA staging physical access outside [0x70000000,0x80000000)
CRC mismatch
slot CPU write while DMA_READING or BANK_OWNED
normal PERF clear/snapshot rejection
SPU reject != 0
ZDMA error/timeout
unavailable CPU fallback
sampled token mismatch
nonzero process exit
```

# RESULT-003 required output

Write `.codex/outbox/RESULT-003.md` with:

```text
final status
initial parent-pinned commits + reviewed child implementation baselines + actual branch HEADs used
any upstream drift discovered before editing and the inspection decision
changed files and exact symbols/modules
catalog total bytes, largest entry, largest tile
model-epoch hook behavior
slot offsets/state implementation
DDR physical-range/coherency implementation
host build + standalone self-test evidence
XSim evidence
implemented MMIO ABI + exact predicates
commands executed / not executed
child branches + commits
exact owner deployment/test commands
remaining owner-board evidence
risks/regressions
```

Do not claim board correctness or performance until owner logs are returned.
