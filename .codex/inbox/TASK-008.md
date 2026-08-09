# TASK-008 — Eliminate Repeated Static-Weight Staging with P2 Residency

Status: `READY_FOR_IMPLEMENTATION`

## Current evidence

Use the validated v92/TASK-007 state as the functional baseline.

ZCU104 v92 (`zcu104-gemma3-q8-v92-crc-fast`):

```text
CRC backend                    = armv8_crc32
CRC-only median                = 3.727 s for 8,784,248,832 B
CRC speedup vs TASK-006        = 17.73x
copy_us                        = 32.821 s
copy_stream_crc_store_us       = 32.793 s
prep_total_ms                  = 57,028.624 ms
prep_weight_select_ms          = 6,059.712 ms
prep_scale_pack_ms             = 17,973.770 ms
weight bytes staged            = 8,784,248,832 B
HOST_PREPACK                    = 182 builds / 182 misses / 27,842 hits / 0 fallbacks
FPGA coverage                  = 182/182 expected Q8 matmuls completed
unexpected CPU fallback        = 0
P2 stream drops/errors         = 0/0
```

The owner also observed about `0.16 token/s` with `-n 8`. This is supporting evidence only; do not claim a decode breakdown until per-token telemetry is collected.

CRC is no longer the main problem. The remaining structural issue is that a static packed weight is still copied from the host catalog into the temporary WEIGHT staging slot on every use before ZDMA.

Current path:

```text
host packed catalog
  -> CRC + CPU copy into temporary FPGA-visible WEIGHT slot
  -> ZDMA
  -> VPU local weight memory
```

Target residency HIT path:

```text
host packed catalog
  -> first use: copy once + verify + seal in persistent FPGA-visible DDR
  -> later uses: ZDMA directly from resident DDR address
  -> no catalog->temporary-WEIGHT CPU copy on the hit
```

## Existing infrastructure to reuse

Inspect the actual v92 worktree before editing. Existing host source already contains a P2 sealed-residency experiment with concepts/constants equivalent to:

```text
WEIGHT_CACHE_BASE
P2_WEIGHT_RESIDENCY_END
P2_WEIGHT_RESIDENCY_MAX_MB = 16
P2_WEIGHT_RESIDENCY_SLOT_CAPACITY = 128
sealed, non-evicting directory
bounded hash/index lookup
```

Do **not** create a second unrelated cache implementation. Reuse/fix/extend this P2 residency mechanism.

The only FPGA-safe reserved DDR is:

```text
[0x70000000, 0x80000000)   # 256 MiB total
```

No mapping, allocation, CPU write, or ZDMA source may reach `>= 0x80000000`.

## Exact implementation direction

### 1. Resident tile identity

A resident entry must identify the exact packed P2 tile, including at least:

```text
model epoch
source tensor identity
row0 / rows
k_block0 / group_blocks
packed layout version
packed byte count
packed CRC32
resident DDR offset
state: BUILDING / SEALED / INVALID
```

Never reuse a tile across model epochs or incompatible layout/shape identity.

### 2. First use: build and seal once

On a residency MISS for an eligible tile:

1. choose a free residency slot/region;
2. prove `resident_offset + packed_bytes` is inside both the mapped DDR aperture and `[0x70000000,0x80000000)`;
3. copy the already-packed P1 catalog bytes directly into the residency destination using the proven v92 volatile DDR store semantics;
4. compute the existing CRC during that one copy;
5. compare against catalog `packed_crc32`;
6. only on CRC match, perform required fence/readback and mark the entry `SEALED`;
7. submit ZDMA from the resident physical DDR address;
8. on CRC/range/ownership failure: mark INVALID and use the unchanged v92 temporary staging path or fail closed according to the existing policy.

A SEALED region is immutable for the remainder of that model epoch. No production CPU writer may modify it.

### 3. Residency HIT: bypass CPU weight staging

On a valid SEALED HIT:

```text
DO NOT copy catalog bytes to HOST_WEIGHT_SLOT0/1
DO NOT run copy_stream_crc_store for that hit
DO NOT recalculate the full packed CRC on every hit
```

Instead:

1. validate epoch + exact tile identity + local resident bounds;
2. obtain resident physical source address;
3. submit the existing ordered ZDMA transfer directly from resident DDR into the existing IP-local WEIGHT destination;
4. keep all existing descriptor chunking, bank, job, and VPU sequencing unchanged.

Integrity is established at seal time. Do not destroy the performance benefit by rereading the full resident payload on every HIT.

### 4. Selection policy: pinned, not LRU

Do not implement a general LRU cache in this task.

Use a fixed, non-evicting residency set for the model epoch. Prefer tiles with highest expected saved staging bytes:

```text
priority score = packed_bytes * observed_or_expected_reuse_count
```

If actual reuse counts are not known before execution, use a deterministic first-fill policy for the initial 16 MiB experiment, but record per-tile hits/bytes so the next iteration can rank tiles explicitly.

Do not evict a SEALED tile during inference.

### 5. Capacity progression

First prove the existing `16 MiB` residency budget works correctly. Do not immediately consume the whole 256 MiB carveout.

After the 16 MiB board test, report:

```text
resident bytes used
resident hit bytes
copy bytes avoided
copy time avoided
hit rate
```

Only if the 16 MiB run is correct, inspect the DDR map and propose a separate graduated expansion (`32/64/128 MiB`) with explicit non-overlap proof. Do not silently enlarge the mapped/residency region in this task beyond the already-authorized existing budget.

## Required telemetry

Add one aggregate summary per graph/process:

```text
P2_RESIDENCY
capacity_bytes=
used_bytes=
builds=
build_bytes=
build_us=
hits=
hit_bytes=
misses=
miss_bytes=
copy_bytes_avoided=
copy_us_avoided_estimate=
zdma_resident_bytes=
zdma_nonresident_bytes=
invalidations=
```

Also keep existing v92 `HOST_PREPACK` counters unchanged.

For a residency HIT, `copy_bytes_avoided` must equal the packed payload bytes that would otherwise have gone through catalog->temporary staging.

## Functional constraints

Do not change:

```text
CRC algorithm/backend from v92
P2 packed layout
scale/SPU_PARAM path
activation path
result path
ZDMA descriptor size/order
VPU/SPU RTL or ABI
bank protocol
ping-pong protocol
quantization
vocab CPU bypass
```

No RTL changes are authorized.

The v92 nonresident path must remain available and byte-identical.

## Board test

First run the same isolated `-n 1` configuration used by RESULT-007 with residency explicitly enabled and the existing 16 MiB cap. Then run `-n 8` with the same deterministic prompt/configuration.

For both runs return full console and `/tmp/fpga_debug.log`.

The `-n 8` run must expose decode-token summaries so we can quantify, per generated token:

```text
token_wall_ms
prep_ms
weight copy bytes/time
residency hit/miss bytes
scale prep
DMA
result read
```

Do not infer decode savings from the 13-token prefill aggregate alone.

## Acceptance

Functional PASS requires:

```text
182/182 expected Q8 FPGA matmuls complete on the -n 1 baseline graph
0 unexpected CPU fallback
0 CRC mismatch / poison on valid data
0 P2 stream drop/error
0 ZDMA error
same deterministic output
all DDR accesses strictly inside [0x70000000,0x80000000)
resident source never overlaps temporary ACT/WEIGHT/RESULT/SPU windows
```

Optimization PASS requires all of:

```text
residency_hits > 0
copy_bytes_avoided > 0
HOST_PREPACK copy_payload_bytes decreases by the same logical amount for resident hits
resident-hit jobs perform no catalog->temporary-WEIGHT copy
```

Performance success for the 16 MiB experiment is evidence-based rather than a fixed speed gate: report exact delta versus v92 for `copy_us`, `prep_total_ms`, prompt eval, and `-n 8` decode token wall time. If the hit rate is too small to matter, do not tune CRC or DDR stores again; use the collected per-tile reuse data to select the next pinned residency set/capacity.

## Required result

Write `.codex/outbox/RESULT-008.md` with:

```text
1. exact v92 starting state
2. exact files changed
3. resident address/range proof
4. residency identity + seal rules
5. proof HIT bypasses CPU staging
6. 16 MiB occupancy/hit/avoided-byte telemetry
7. -n 1 functional result and v92 comparison
8. -n 8 decode telemetry and tokens/s comparison
9. next recommended residency capacity/selection based on measured reuse
10. PASS/FAIL verdict
```

Do not optimize scale preparation or RTL in TASK-008.