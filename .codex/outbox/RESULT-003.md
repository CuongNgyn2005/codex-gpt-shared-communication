# RESULT-003: P1 host-DRAM P2 packed-weight catalog

Final status: `PARTIAL`

## Scope

Implemented TASK-003 P1 only. P2 observation counters, RTL, register maps, P3, weight residency, FPGA frequency, and arithmetic were not changed.

## Baseline

```text
Parent:    main c17e9d0da75334d493959ce1e060ffbe21dace3c
DATN_RTL:  spu  8fc83108df3d4aa23bcc1a31125ee764047fa821
llama.cpp: main 8c24927d0c50b921d19b4e03699a9fbdb773e595
```

Pre-existing untracked files in both children were preserved.

## Finding

`DATN_RTL/fpga_debug.log` records direct P2 Q8 WEIGHT packing at about 1.49-1.58 seconds per token. The direct path repacks immutable Q8_0 tensor bytes for every tile and token.

The owner P1 run later recorded `prep_scale_pack_ms=6821911.528` for a 13-token prefill. Source inspection verified a P1 catalog-hit regression: `fpga_prepare_q8_tile_job()` called a helper that locked the catalog and recomputed complete metadata validation for every individual weight scale. The same run staged 1,098,031,104 scale bytes, corresponding to approximately 274,507,776 catalog scale lookups and approximately 549 million 32-bit DDR stores including zero initialization.

The optimized host identifies itself as `zcu104-gemma3-q8-v89-tile-scale-span`. Future host behavior changes require a new host-version marker so owner logs can be tied to the deployed source behavior.

## Implementation

| File | Change |
|---|---|
| `llama.cpp/ggml/src/ggml-cpu/fpga_weight_layout.h/.cpp` | Added the board-free P2 layout, emitter, CRC, and descriptor-validation authority. |
| `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp` | Added the epoch-scoped P1 catalog, CRC checks, fixed DDR host slots, physical range proof, shared direct emitter, and graph telemetry. |
| `llama.cpp/ggml/src/ggml-cpu/fpga_host.h` | Added `fpga_model_load_epoch_advance()`. |
| `llama.cpp/src/llama-model-loader.cpp` | Advances the host-only model epoch after successful final progress completion. |
| `llama.cpp/ggml/src/CMakeLists.txt` and `llama.cpp/tests/test-fpga-host-prepack.cpp` | Added the board-free `fpga-host-prepack-selftest` target. |
| `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp` | Added the missing `ddr_ptr()` forward declaration before the host weight-slot helpers. The Linux board build reported the prior declaration-order error. |
| `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp` | Replaced per-scale catalog locking and metadata/scale validation with one fail-closed validated immutable scale span per P2 tile. The P2 scale table now uses one range-checked `SPU_PARAM` pointer per tile. |

`FPGA_HOST_WEIGHT_PREPACK` defaults to `0`. `=1` is rejected before data-plane work when P3, P2 residency, or the legacy weight cache is requested.

Each valid entry has one fixed 64-byte-aligned allocation. The exact key contains epoch, tensor address, tensor data address, type, `ne[4]`, `nb[4]`, and layout version 2. Entry states are `BUILDING`, `VALID`, `BYPASS_ALLOC`, `POISONED`, and `RETIRED`.

Catalog hits validate the key, state, metadata CRC, descriptor bounds, packed CRC, and referenced scale CRC. Corruption becomes `POISONED`; it issues no DMA and no direct fallback. Only capacity or allocation failure becomes `BYPASS_ALLOC` and direct-packs for the rest of that epoch.

For scale preparation, the catalog state, exact tensor/epoch key, metadata CRC, descriptor identity and bounds, expected scale count, and referenced scale CRC are now validated once per tile. The returned span remains valid because active matmul execution holds `g_mutex`; model-epoch advancement and cleanup acquire the same mutex before catalog retirement. The inner row/group loop reads raw little-endian FP16 bits directly from that bounded immutable span. `ddr_zero_range32()`, the exact `activation_fp16 | (weight_fp16 << 16)` word, P2 addresses, coherency, DMA sequencing, descriptor ownership, and failure policy remain unchanged.

## Dataflow

Before:

```text
Q8_0 model tensor -> direct CPU pack -> DDR WEIGHT -> ZDMA -> VPU/SPU
```

After with `FPGA_HOST_WEIGHT_PREPACK=1`:

```text
model-load epoch -> host packed-weight catalog
selected tile -> CRC-verified copy -> bank-matched DDR slot
              -> DSB/readback coherency -> existing ZDMA -> VPU/SPU
```

DDR slots are `0x00100000` for bank 0 and `0x00180000` for bank 1. Their host state is `FREE -> CPU_WRITING -> READY -> DMA_READING -> BANK_OWNED -> FREE`. A transfer failure leaves `ERROR` and prevents reuse.

## Post-implementation review

The requested RTL and host scan found two P1 defects outside the one-line compiler repair:

- `copy_us` is recorded before the required DSB/readback/DSB coherency transaction succeeds.
- A failure after `READY` and before WEIGHT DMA can leave a slot in `READY` instead of returning it to `FREE`.

These defects were not changed in this build-repair request. They prevent P1 acceptance for owner performance testing.

## Telemetry

One forced record is emitted at a graph boundary after an accepted P2 job:

```text
HOST_PREPACK graph_seq=<n> builds=<n> misses=<n> hits=<n> fallbacks=<n> bytes=<n> build_us=<n> copy_us=<n> prep_direct_weight_pack_us=<n>
```

`bytes` is current catalog allocation. Other values are graph deltas.

## Validation

Passed:

```powershell
cmake --build build_mem --target fpga-host-prepack-selftest -j2
.\build_mem\bin\fpga-host-prepack-selftest.exe
```

```text
fpga host prepack self-test passed
```

The self-test covers rows `{1, 2, 255, 256}` and blocks `{1, 64}`. It checks independent DDR-style and catalog sinks, raw FP16 scale bits, odd-row padding, descriptor bounds, payload CRC, scale CRC, and metadata serialization CRC.

Executed but blocked:

```powershell
cmake --build build_mem -j2
```

The existing Windows MinGW configuration fails in `ggml/src/ggml-cpu/ggml-cpu.c` before `fpga_host.cpp` compiles. Missing symbols are `pthread_once_t`, `PTHREAD_ONCE_INIT`, and `pthread_once`. A direct host syntax check also stops at the existing POSIX-only `sys/mman.h` include.

The owner-provided Linux build reached `fpga_host.cpp` and failed only because `fpga_host_weight_slot_ready()` used `ddr_ptr()` before its declaration. The declaration is now at `fpga_host.cpp:2240`; its unchanged definition is later in the file. The board machine must rebuild to prove this translation unit now compiles.

`git diff --check` passed.

The preparation optimization was also checked for removal of the old hot path: `fpga_weight_catalog_scale_bits` has zero remaining source references. `fpga_weight_catalog_scale_span` is called once before the tile scale loop, and the complete `SPU_PARAM` destination is resolved once through `ddr_checked_u32_ptr()`.

Not run: FPGA board execution, full host binary build, and RTL simulation. RTL was not changed.

## Confidence and owner test

Confidence in the preparation regression diagnosis is high because the expensive helper was inside the measured scale-preparation interval and had approximately 274 million calls in the supplied run. Confidence that the patch preserves the P2 scale bytes is high by source inspection. Performance improvement and numerical equivalence remain owner-board tests. The modified host translation unit has no local compile evidence because of the pre-existing Windows MinGW pthread/POSIX limitation. The two open P1 defects above still prevent complete P1 acceptance. No FPGA success is claimed.

On the board-connected machine:

```bash
export FPGA_HOST_WEIGHT_PREPACK=1
sudo ./build_mem/bin/llama-cli \
    -m ./models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 64 \
    --single-turn \
    --temp 0
```

First rebuild and run the standalone test:

```bash
cmake --build build_mem -j2
cmake --build build_mem -j2 --target fpga-host-prepack-selftest
./build_mem/bin/fpga-host-prepack-selftest
```

Do not start the P1 performance comparison until the two open P1 defects are fixed and independently reviewed. After that, verify `preload=1`, later-token `HOST_PREPACK` hits, zero direct-pack time for catalog-hit tiles, no FPGA fallback, no ZDMA/descriptor/stream error, and no numerical regression.

## Git state

```text
DATN_RTL:  spu  8fc83108df3d4aa23bcc1a31125ee764047fa821
llama.cpp: task-003-host-prepack cc8d475057e5a05045fb351eb7a52e56f3de9f21
Parent:    task-003 ec6ce4475e5f02a2ade5f777b960772baf497d57
```

The host child commit was pushed to `origin/task-003-host-prepack`. The parent
submodule pointer and this report are recorded in parent commit
`ec6ce4475e5f02a2ade5f777b960772baf497d57`.
