# RESULT-004

## 1. Tested source and board evidence

This is an inspection-only report. No implementation code changed. No local build or FPGA test ran.

Source inspected: `llama.cpp` branch `main`, commit `cc8d475057e5a05045fb351eb7a52e56f3de9f21`. Tracked `fpga_host.cpp` has no diff and declares `zcu104-gemma3-q8-v89-tile-scale-span`. The board manifest reports that version, build `Aug 9 2026 07:53:06`, protocol 2, bitstream `0x56505532`, P2 ABI `0x50320003`, `preload=0`, and `host_weight_prepack=1`. The board log has no Git hash, so the version match is the available binary/source identity evidence; exact commit identity is not cryptographically proven.

Current owner-provided ZCU104 evidence:

| Field | Value |
|---|---:|
| Eligible FPGA tensors / VPU jobs | 182 / 27,842 |
| Builds / misses / hits / fallbacks | 182 / 182 / 27,842 / 0 |
| Catalog bytes / build time / copy time | 741,538,304 B / 10.777285 s / 190.173577 s |
| Prompt wall / llama prompt evaluation / process total | 254.298680 s / 254.664140 s / 315.091770 s |
| Preparation / selection / scale / activation / other | 223.265912 / 11.554167 / 21.353752 / 0.080208 / 190.277785 s |
| Reported IP compute / preparation overlap | 199.964187 / 199.000219 s |
| Weight bytes / weight DMA | 8,784,248,832 B / 4.692101 s |

## 2. Catalog reuse verdict

**PASS. Catalog reconstruction is not the cause of the current approximately 254.7 s prompt evaluation.**

`fpga_weight_catalog_select()` keys entries by model epoch, tensor pointer, data pointer, type, four dimensions, four strides, and layout version. Under one catalog mutex, a missing key creates one BUILDING entry and increments `misses`; successful construction publishes that entry as VALID and increments `builds`. Equal-key accesses reuse it. A corrupt entry becomes POISONED and fails closed; it is not rebuilt. BYPASS_ALLOC remains catalogued. Retirement occurs only on model-epoch advance or cleanup.

Telemetry reports 182 eligible tensors, 182 misses, 182 builds, 27,842 hits, zero fallbacks, epoch 1, and no POISON. Aggregate telemetry cannot enumerate each tensor name, but the counts and serialized state machine contain no same-epoch duplicate/rebuild path.

## 3. Catalog-to-staging copy verdict

**FAIL: confirmed bottleneck.** `copy_us=190.173577 s`, or 6,830.457 us per tile, measures `fpga_weight_catalog_copy_to_ddr()`.

Exact measured order per hit:

1. Start timer; acquire the catalog mutex.
2. Check VALID state; validate the header and every descriptor; recompute metadata CRC over the key and complete descriptor table.
3. Resolve the selected descriptor; compare packed size.
4. Read the complete cached host packed payload and compute packed CRC.
5. Read the complete cached host scale array and compute scale CRC.
6. Resolve one volatile DDR pointer.
7. For each 16 bytes, read cached source bytes, convert them to four little-endian words, perform four volatile 32-bit O_SYNC UIO DDR stores, and update a second packed CRC.
8. Compare CRC; release the mutex; stop timer.

The interval includes lock wait/hold, one metadata pass, two packed passes, one scale pass, conversion, and staging stores. It excludes the initial DDR range check, barriers, DDR readback, descriptors, ZDMA, and DMA.

| Derived complete-run work | Count |
|---|---:|
| Packed bytes read for first CRC | 8,784,248,832 B |
| Packed bytes read during copy/second CRC | 8,784,248,832 B |
| Total packed bytes scanned | 17,568,497,664 B |
| DDR staging bytes written | 8,784,248,832 B |
| 16-byte iterations | 549,015,552 |
| Volatile 32-bit stores | 2,196,062,208 |
| Complete packed CRCs | 55,684 |
| Complete scale CRCs inside copy | 27,842 |
| Complete metadata-table validations inside copy | 27,842 |

Effective payload throughput is 44.051 MiB/s. The interval moves at least 26.353 GB of packed traffic: 17.568 GB cached reads plus 8.784 GB volatile writes. It also executes 549 million conversions, CRC work on every packed byte twice, 2.196 billion volatile stores, one scale CRC, and one complete metadata validation per tile while holding the global catalog lock. Existing timers cannot split the 190.174 s among these operations, but they prove that this exact combination consumes it.

## 4. Integrity-validation verdict

**FAIL: confirmed repeated hot-path work.**

| Check | BUILD | Select | Copy | Scale prep | Pre-submit | Per tile after build |
|---|---:|---:|---:|---:|---:|---:|
| Metadata CRC and all-descriptor validation | 1 | 1 | 1 | 1 | 1 | 4 |
| Selected packed CRC | 1 | 0 | 2 | 0 | 0 | 2 payloads |
| Selected scale CRC | 1 | 0 | 1 | 1 | 0 | 2 arrays |

The four per-tile metadata passes are in select, copy, scale-span retrieval, and `fpga_host_prepack_job_still_valid()`: 111,368 complete table validations in this run. Packed CRC scans 17,568,497,664 B. Two scale passes scan at most 2,196,062,208 B; the exact unpadded static-scale total is not logged. These checks read cached host heap, not FPGA DDR. Coherency barriers and first/last DDR readback happen later.

## 5. Weight-selection verdict

**CONFIRMED CONTRIBUTOR, dominated by first-use construction.** `11,554.167 ms / 27,842 = 414.991 us/tile`, but this includes 182 builds.

Each selection performs eligibility checks, full key creation, mutex acquisition, a linear `std::list` catalog scan with full key comparisons, full metadata/descriptor validation, and a linear selected-tensor descriptor scan. First use additionally allocates and zeroes the blob, creates every descriptor, packs all weight tiles, extracts scales, computes packed/scale/metadata CRCs, and publishes VALID. Complexity is `O(C + D)` per hit, with `C` catalog entries and `D` selected-tensor descriptors inspected; first use adds work linear in tensor payload and scales.

Nested telemetry assigns 10.777285 s of the 11.554167 s to builds. The residual is at most 0.776882 s, or 27.903 us/tile, for all normal selection work. Code bounds catalog entries inspected to 1..182. Exact average catalog entries, average descriptors, and maximum descriptors are not logged and cannot be derived without guessing.

## 6. Scale-preparation verdict

**CONFIRMED CONTRIBUTOR. Static scale values are reused, but full scale and metadata validation still repeats per tile.** `21,353.752 ms / 27,842 = 766.962 us/tile`.

Per hit, `fpga_weight_catalog_scale_span()` checks state, complete key, expected count, selected identity/bounds, validates every descriptor, recomputes metadata CRC, and scans the complete static scale array for CRC. It returns one immutable span with no per-scale callback or lock. The caller then zeroes the padded `SPU_PARAM` through volatile 32-bit stores and writes one packed activation/weight FP16 word per real scale element through one checked volatile pointer.

Dynamic activation-scale generation occurs before this timer. Scale DMA and its quiescence wait occur later during submission. Across the run, zero fill performs `1,098,031,104 / 4 = 274,507,776` volatile stores. Construction performs at most `1,098,031,104 / 2 = 549,015,552` more stores; exact real element count is not logged because staged bytes include padding. Existing telemetry cannot split metadata CRC, scale CRC, zero fill, and construction, but their combined interval is exactly 21.353752 s.

## 7. Scheduler/IP-compute timing verdict

**PARTIALLY CONTAMINATED. `ip_compute_sum_ms=199964.187` is not independent PL execution time.**

With `FPGA_P2_INPUT_PRELOAD=0`, the scheduler launches N, records its start, then fully prepares N+1 before calling the wait/poll function for N. Preparation includes catalog lookup, catalog copy, scale construction, activation staging, barrier, and slot readback. Only after preparation ends does the host poll N, observe DONE, and calculate `ip_compute_us = observed_done_time - start_time`. It then waits for SPU finality, drains and accumulates N, retires N, and launches N+1.

If N finishes during preparation, completion is observed late. The scheduler reports 199.000219 s of preparation intersecting observed running-job windows, and this interval is included in launch-to-observed-DONE timers. Subtraction leaves 0.963968 s for true PL execution plus remaining polling, edge jobs, and timestamp overhead. Existing telemetry proves at least 199.000219 s contamination but cannot recover true PL time. A conservative derivable aggregate PL range is 0..0.963968 s; this is a bound, not a measurement.

The minimum independent measurement is a hardware counter starting on accepted `CTRL_START` and latching on hardware DONE, accumulated per graph. A host-only alternative needs an interrupt or independent polling thread that timestamps DONE while preparation continues.

## 8. Historical 113-minute unit correction

The original field in `DATN_RTL/fpga_debug.log` is `prep_scale_pack_ms=6821911.528`. Correct conversion:

`6,821,911.528 ms = 6,821.911528 s = 113.698525 minutes`.

The previous report incorrectly labeled this value as microseconds. The historical run reports `token_wall_ms=7068827.844`, or 117.814 minutes. The current v89 scale field is 21.353752 s; current prompt evaluation is 254.664 s; current process total is 315.092 s. These are separate runs.

Source proves that the historical path repeatedly validated through a per-scale access pattern and v89 replaced it with one span validation per tile. Telemetry proves the historical scale-preparation interval consumed 113.70 minutes. It does not isolate CRC from metadata scans, locking, callbacks, and volatile staging, so CRC alone is not claimed as the historical cause.

## 9. Memory-pressure verdict

**UNPROVEN secondary risk.** Known memory is approximately 1,013.54 MiB model mapping + 514.25 MiB compute + 38 MiB KV + 1 MiB output + 707.19 MiB catalog = 2,273.98 MiB (2.22 GiB), excluding libraries, stacks, allocator overhead, and other runtime memory. Allocation succeeded with zero fallbacks. No RSS, swap, or page-fault evidence exists; the memory-pressure hypothesis remains unproven.

Required board capture during the same workload:

```bash
free -h
swapon --show
vmstat 1
grep -E 'VmRSS|VmHWM|VmSwap' /proc/$(pidof llama-cli)/status
ps -o pid,rss,vsz,maj_flt,min_flt,cmd -p $(pidof llama-cli)
```

Capture before inference, during catalog construction, during prompt evaluation, and after completion.

## 10. Root-cause ranking

| Rank | Item | Status | Evidence |
|---:|---|---|---|
| 1 | A. Catalog-to-staging copy | CONFIRMED BOTTLENECK | Direct 190.173577 s measurement. |
| 2 | E. Scheduler/timing contamination | TELEMETRY ERROR / MEASUREMENT CONTAMINATION | At least 199.000219 s of reported compute overlaps host preparation; not an additional cost. |
| 3 | D. Scale preparation | CONFIRMED CONTRIBUTOR | Direct 21.353752 s measurement. |
| 4 | C. Catalog lookup/selection | CONFIRMED CONTRIBUTOR | Direct 11.554167 s; 10.777285 s is first-use construction. |
| 5 | B. Repeated integrity validation | CONFIRMED CONTRIBUTOR | Four metadata, two packed, and two scale passes per tile; seconds overlap items A/C/D. |
| 6 | G. Memory pressure | UNPROVEN | At least 2.22 GiB known, but no OS evidence. |
| 7 | F. Catalog rebuilding | RULED OUT | 182 misses/builds, 27,842 hits, zero fallbacks, no rebuild path. |

## 11. Minimal safe fix

Recommendation only; no implementation occurred.

Use BUILD-to-VALID publication as the integrity boundary for immutable catalog content. Keep complete key/metadata CRC generation, every-descriptor bounds/alignment validation, packed and scale CRC generation, capacity checks, and epoch binding at publication.

Remove repeated full-table metadata CRC from select, copy, scale-span retrieval, and pre-submit. Remove the pre-copy packed CRC pass and the scale CRC inside copy. Keep immediately before DMA/launch: VALID state, exact epoch/tensor key, selected descriptor identity, selected offset/length bounds, expected byte count, DDR `[0x70000000,0x80000000)` range, CRC accumulated during the actual copy, bank/slot ownership, coherency barrier/readback, and fail-closed rejection before ZDMA or START.

This preserves exact P2 bytes, epoch ownership, corruption detection during transfer, DDR safety, slot ownership, and numerical behavior without changing VPU, SPU, RTL, ZDMA, arithmetic, or quantization.

## 12. Next board-test telemetry

Collect only:

1. Aggregate copy substages: lock wait, selected-descriptor validation, copy plus retained CRC, coherency/readback, total.
2. Aggregate scale substages: selected-scale validation, zero fill, SPU_PARAM construction.
3. Hardware START-to-DONE cycles accumulated per graph independently of host polling.
4. Existing builds/misses/hits/fallbacks/bytes and packed-volume counters.
5. Existing fallback, ZDMA, descriptor, stream-error, and sampled-output checks.
6. Concurrent `vmstat 1`, peak RSS, swap, and major faults.
