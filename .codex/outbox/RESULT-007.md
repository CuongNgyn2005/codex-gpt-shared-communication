# RESULT-007

Final status: `PASS`

TASK-007 is complete. Board-free tests pass, the ZCU104 selected the ARMv8 CRC32 backend, the three-run CRC median passed the performance gate, and production inference passed the functional and copy-performance gates.

## 1. Exact host starting state and candidate state

- Parent local state: `main` at `467aaeca031fca9c121a57a999abee1f55b34cfb`; `origin/main` is `6a64b8603e124b865d0ead2725438bc5e09ee9d0`. Only `.codex/inbox/TASK-007.md` was retrieved from the remote commit. The parent was not merged or pulled.
- Host committed baseline: `llama.cpp/main` and `origin/main` at `a09059d0c545e3c378212503901d1b21eb79895d`.
- Starting host worktree: uncommitted TASK-006 benchmark changes were present in `ggml/src/CMakeLists.txt`, `fpga_weight_layout.{h,cpp}`, `fpga_host.cpp`, `tests/test-fpga-host-prepack.cpp`, and untracked `tests/fpga-host-prepack-bench.cpp`. These changes were preserved.
- Starting manifest in the local TASK-006 candidate: `zcu104-gemma3-q8-v91-prepack-bench`.
- TASK-007 candidate manifest: `zcu104-gemma3-q8-v92-crc-fast`.
- Candidate commit: `PENDING`. No branch, commit, or push was created because the owner did not authorize those actions.
- RTL repository: unchanged by TASK-007. Local `DATN_RTL` remains on `spu` at `8fc83108df3d4aa23bcc1a31125ee764047fa821`; its existing parent-pointer difference and untracked files were preserved.

## 2. Files changed

- `llama.cpp/ggml/src/ggml-cpu/fpga_weight_layout.h` lines 53-71: declares CRC backend identity, availability, direct-backend test access, and selected-backend access.
- `llama.cpp/ggml/src/ggml-cpu/fpga_weight_layout.cpp` lines 24-128 and 245-309: implements slicing-by-8, contained ARMv8 CRC32, runtime selection, and backend reporting. Lines 385-406 retain the one-pass packed CRC plus four volatile stores.
- `llama.cpp/tests/test-fpga-host-prepack.cpp` lines 10-106: adds an independent bitwise reference and backend-equivalence coverage for required lengths, alignments, and chunk boundaries. Existing packed-byte and scale-bit corruption checks remain.
- `llama.cpp/tests/fpga-host-prepack-bench.cpp` lines 157-178: reports the selected backend and fails unless the exact 8,784,248,832-byte CRC is `0xc7cc7ecf`.
- `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp` line 36 and lines 10424-10426: bumps the manifest to v92 and emits one process-level backend line when initialization diagnostics are enabled.
- `llama.cpp/ggml/src/CMakeLists.txt` lines 429-441: retained TASK-006 self-test and benchmark targets. No architecture-wide CRC compiler flag was added.
- `.codex/inbox/TASK-007.md`: retrieved task specification.
- `.codex/outbox/RESULT-007.md`: this report.

No RTL, address map, UIO mapping, mmap flag, DDR store width/order, catalog state, descriptor, DMA, VPU, SPU, scheduler, preload, ping-pong, quantization, or arithmetic code changed.

## 3. CRC implementation before/after

Before: production CRC processed one byte per table lookup. Each byte depended on the previous CRC state.

After: the portable backend processes eight bytes with eight read-only tables, then processes the tail bytewise. Explicit little-endian byte assembly avoids unaligned typed access and host-endian dependence. Linux AArch64 builds also contain a CRC-instruction backend that processes eight-byte units and then the tail.

The contract is unchanged:

```text
polynomial = 0xEDB88320
initial    = 0xFFFFFFFF
final      = bitwise NOT
```

The production HIT path remains one source traversal:

```text
catalog packed bytes
    -> selected CRC update
    -> existing little-endian conversion
    -> existing four volatile u32 DDR stores per 16 bytes
    -> finalize and compare CRC
    -> mismatch: poison and return before DMA/START
    -> match: existing DMA/START path
```

Scale CRC remains active. Scale values are consumed for SPU parameters while their CRC is updated; a scale mismatch still rejects staging.

## 4. Runtime backend selection logic

- Selection uses a thread-safe function-local static and occurs once per process.
- Linux AArch64 GCC/Clang builds contain the ARM CRC function with a function-specific target attribute.
- ARM execution is selected only when `getauxval(AT_HWCAP)` reports `HWCAP_CRC32`.
- Every other build selects `slicing_by_8`.
- The fused packed-copy function captures the selected update-function pointer before its 16-byte loop. Capability discovery is not executed per block.
- No global `-march=...+crc` option was added.
- `FPGA_INIT_VERBOSE=1` enables one atomic, process-level `CRC_BACKEND backend=...` line. No per-job log was added.

## 5. CRC equivalence/corruption test evidence

The self-test compares every available compiled backend directly with an independent bitwise reference. It covers:

- required lengths from 0 through 65,537 bytes and `1 MiB + 19`;
- data-pointer offsets 0 through 15;
- one-shot operation;
- incremental chunks of 1, 3, 7, 8, 15, 16, 31, 257, and 4096 bytes;
- a deterministic mixed chunk sequence;
- continuation across three calls;
- deterministic pseudo-random data;
- null plus zero length and existing invalid-input behavior;
- packed-byte corruption rejection;
- scale-bit corruption rejection.

Observed Windows and Linux result:

```text
fpga host prepack self-test passed
```

`git diff --check` passed. Both independent inspectors returned `ACCEPTED_FOR_OWNER_TEST`.

## 6. Board-free build/test result

PASS, Windows focused targets:

```powershell
cmake --build build_mem --target fpga-host-prepack-selftest fpga-host-prepack-bench --parallel 2
.\build_mem\bin\fpga-host-prepack-selftest.exe
.\build_mem\bin\fpga-host-prepack-bench.exe --crc-only
.\build_mem\bin\fpga-host-prepack-bench.exe --cached-store-only
```

Observed:

```text
fpga host prepack self-test passed
CRC_ONLY mode=crc-only backend=slicing_by_8 bytes=8784248832 elapsed_us=3352813 MiB_s=2498.592227 crc32=0xc7cc7ecf
CACHED_STORE_ONLY mode=cached-store-only bytes=8784248832 elapsed_us=457133 MiB_s=18325.766243 sink=0x207415a8
```

The invalid benchmark mode printed usage and returned nonzero as required.

PASS, clean WSL Ubuntu x86-64 Release build using GCC 11.4:

```text
fpga-host-prepack-selftest built
fpga-host-prepack-bench built
llama-cli built
fpga host prepack self-test passed
CRC_ONLY mode=crc-only backend=slicing_by_8 bytes=8784248832 elapsed_us=3540259 MiB_s=2366.299330 crc32=0xc7cc7ecf
CACHED_STORE_ONLY mode=cached-store-only bytes=8784248832 elapsed_us=453201 MiB_s=18484.761728 sink=0x207415a8
```

The full Windows `llama-cli` target was not used as acceptance evidence because pre-existing MinGW code in `ggml-cpu.c` does not define `pthread_once_t`. TASK-007 does not modify that file. The clean Linux `llama-cli` build passed.

Not run: AArch64 compilation. No AArch64 cross-compiler is installed in this workspace.

## 7. ZCU104 CRC-only three-run results and median

Owner-provided ZCU104 results at 1,199,999 kHz with the `userspace` governor:

| Run | Elapsed | Throughput | Backend | CRC |
|---|---:|---:|---|---|
| 1 | 3,726,839 us | 2,247.833 MiB/s | `armv8_crc32` | `0xc7cc7ecf` |
| 2 | 3,725,917 us | 2,248.389 MiB/s | `armv8_crc32` | `0xc7cc7ecf` |
| 3 | 3,736,699 us | 2,241.902 MiB/s | `armv8_crc32` | `0xc7cc7ecf` |

Median: `3,726,839 us`. Baseline median: `66,083,527 us`. Speedup: `17.73x`. All runs processed exactly `8,784,248,832` bytes and produced the required CRC.

## 8. CRC backend actually selected on ZCU104

PASS: `backend=armv8_crc32`. The production log emitted exactly one `CRC_BACKEND backend=armv8_crc32` line.

## 9. Store-only control result

TASK-006 baseline is valid and unchanged:

| Control | Median | Throughput | Expected value |
|---|---:|---:|---:|
| cached-store-only | 4,743,590 us | 1,766.028 MiB/s | `sink=0x207415a8` |
| FPGA store-only | 18,477,886 us | 453.370 MiB/s | `sink=0x207415a8` |

TASK-007 ZCU104 results:

| Control | Candidate | Throughput | Difference from baseline | Result |
|---|---:|---:|---:|---|
| cached-store-only | 4,722,987 us | 1,773.732 MiB/s | -0.43% elapsed | PASS |
| FPGA store-only | 18,514,104 us | 452.483 MiB/s | +0.20% elapsed | PASS |

Both controls produced `sink=0x207415a8`. The first store-only attempt safely aborted on invalid VPU register contents before DDR writes. After the owner restored valid PL state, the unchanged command passed.

## 10. Production inference before/after table

| Metric | v90 before | v92 after |
|---|---:|---:|
| eligible FPGA matmuls | 182 | 182 |
| q8_hw_completed | 182 | 182 |
| unexpected CPU fallback | 0 | 0 |
| intentional vocabulary CPU bypass | 1 | 1 |
| HOST_PREPACK builds/misses/hits/fallbacks | 182 / 182 / 27842 / 0 | 182 / 182 / 27842 / 0 |
| prep_direct_weight_pack_us | 0 | 0 |
| copy_us | 107.214 s | 32.821 s |
| copy_stream_crc_store_us | 107.184 s | 32.793 s |
| prep_total_ms | 137056.306 ms | 57028.624 ms |
| token_wall_ms | 166335.922 ms | 93041.386 ms |
| prompt eval | 166413.95 ms | 93162.12 ms |

Production `copy_us` improved by `3.27x` and decreased by 69.39%. Preparation decreased by 58.39%. Token wall time decreased by 44.06%. Prompt evaluation decreased by 44.02%.

True PL START-to-DONE time cannot be recovered from host-observation-contaminated scheduler timing. TASK-007 does not change that timing system.

## 11. Functional acceptance PASS/FAIL

`PASS`.

- Manifest: `zcu104-gemma3-q8-v92-crc-fast`.
- Identity: protocol `2`, bitstream `0x56505532`, P2 ABI `0x50320003`, P3 ABI `0x50330001`.
- Coverage: 183 candidates, 182 expected FPGA operations, 182 hardware completions, one intentional vocabulary bypass, zero unavailable fallback.
- Catalog: 182 builds, 182 misses, 27,842 hits, zero fallbacks, and zero direct weight-pack time.
- Hot-path scans: zero metadata, packed pre-CRC, and scale pre-CRC scans.
- Errors: zero stream drops/errors, source-audit failures, raw mismatches/repairs, value mismatches, staging restages, and input-integrity failures.
- Output for the one-token deterministic run: `Okay`.

## 12. CRC performance acceptance PASS/FAIL

`PASS`.

Median `3,726,839 us` is below the required `33,041,764 us` and preferred `15,000,000 us` thresholds. Speedup over the ZCU104 baseline is `17.73x`.

## 13. Production copy performance acceptance PASS/FAIL

`PASS`.

Measured production `copy_us=32.821 s`, below the required `95.087 s` and preferred `60 s` thresholds. The measured fused production improvement is `3.27x`; this value is independent of the standalone CRC speedup claim.

## 14. Remaining dominant bottleneck

CRC is no longer the dominant measured isolated cost. The largest reported aggregates are `prep_total_ms=57028.624`, `ip_compute_ms=48689.123`, `prep_other_ms=32915.742`, `copy_stream_crc_store_us=32793367`, and `prep_scale_pack_ms=17973.770`, including `scale_crc_spuparam_us=15646833`.

These aggregates overlap and must not be added. `prep_overlap_ms=47727.095` does not prove timer contamination. True PL START-to-DONE time cannot be recovered until hardware-independent timing exists, so `ip_compute_ms` is not treated as pure PL compute time.

## 15. Recommended next action

Stop TASK-007. Preserve the CRC implementation and its corruption checks. Open a separate task before optimizing the remaining preparation, scale-processing, DDR-store, scheduler-timing, or RTL costs.
