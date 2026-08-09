# TASK-005 — Decompose v90 P1 Fused Copy Cost

Status: `READY_FOR_INVESTIGATION`

## Objective

Review the current v90 P1 static-weight prepack hot path and determine what dominates:

```text
copy_stream_crc_store_us = 107183966 us
                         ≈ 107.18 s
```

Do not modify implementation code.

## Current context

Board: ZCU104

Host version: `zcu104-gemma3-q8-v90-prepack-hotpath`

Configuration:

```text
FPGA_HOST_WEIGHT_PREPACK=1
FPGA_P2_INPUT_PRELOAD=0
FPGA_P2_PACK_WORKERS=2
FPGA_WEIGHT_CACHE=0
```

Current functional evidence:

```text
builds=182
misses=182
hits=27842
fallbacks=0
prep_direct_weight_pack_us=0

metadata_full_hotpath_scans=0
packed_pre_crc_scans=0
scale_pre_crc_scans=0
```

Measured hot path:

```text
copy_us=107213958
copy_payload_bytes=8784248832
copy_lock_wait_us=3851
copy_selected_validate_us=8901
copy_stream_crc_store_us=107183966
```

The v89 `copy_us` value was `190173577 us`. v90 improved significantly but misses the TASK-004 gate of `< 95.087 s`.

## Required investigation

Determine how much of the 107.18-second fused interval comes from:

1. CRC computation.
2. Catalog-memory source reads.
3. Volatile/O_SYNC FPGA staging-DDR writes.
4. Loop and conversion overhead.

Do not assume which component dominates.

### 1. Exact inner loop

Trace every operation performed for each 16-byte payload block. Report source loads, CRC updates, endian conversion, destination stores, volatile accesses, function calls, table lookups, branches, and pointer arithmetic.

Derive for `8,784,248,832` payload bytes:

- 16-byte iterations;
- CRC bytes;
- destination store count and width;
- average time per iteration;
- effective payload MiB/s.

Confirm whether each 16-byte block still uses four volatile 32-bit stores.

### 2. CRC-only cost

Inspect whether CRC is table-driven or bitwise, its operations and table accesses per byte, source-level call frequency, possible compiler inlining limitations, and whether CRC inhibits wider source handling.

Estimate CPU cost only when assumptions are explicit. Recommend a board-safe benchmark that processes the same aggregate volume in cached RAM, calculates CRC, and performs no FPGA DDR write. It must not change inference behavior.

Required measurement: `crc_only_us`.

### 3. FPGA staging-store-only cost

Inspect `/dev/uio15`, `O_SYNC`, volatile mapping semantics, store width, and likely cacheability. Do not claim the exact ARM memory type without evidence.

Recommend a diagnostic benchmark that reads cached source and writes the same aggregate volume with the current staging primitive but no CRC. It must:

- remain inside `[0x70000000,0x80000000)`;
- repeatedly use only an existing valid staging slot;
- issue no DMA or FPGA START;
- preserve current mapping and volatile 32-bit stores;
- never overwrite arbitrary DDR addresses.

Required measurement: `staging_store_only_us`.

### 4. Loop and conversion

Separate source read, byte-to-word conversion, CRC, and volatile stores. Determine whether catalog bytes already match final little-endian packed format and whether conversion exists only to feed the 32-bit destination interface.

### 5. Prohibited changes

Do not:

- cast away volatile;
- use `memcpy` for the device destination;
- use NEON or 64/128-bit stores;
- change mmap flags, UIO mapping, memory attributes, staging addresses, ZDMA, VPU, SPU, or RTL.

### 6. Secondary scale check

Inspect without optimizing:

```text
scale_zero_fill_us=2299344
scale_crc_spuparam_us=16429739
```

State whether the same unresolved CRC-versus-volatile-store pattern exists.

## Required output

Write `.codex/outbox/RESULT-005.md` with exactly:

1. Exact copy inner loop.
2. Derived operation counts for 8.784 GB.
3. CRC-only cost estimate/measurement.
4. FPGA staging-store-only cost estimate/measurement.
5. Conversion/loop cost estimate.
6. Percentage breakdown where evidence permits.
7. Dominant bottleneck: `CRC`, `DDR STORE`, `BOTH`, or `NOT YET PROVEN`.
8. Smallest safe next optimization.
9. Exact additional board benchmark/telemetry required.

Every conclusion must be labeled as source inspection, board measurement, or derivation. If source and current telemetry cannot separate CRC from DDR stores, state that explicitly. Do not implement an optimization.
