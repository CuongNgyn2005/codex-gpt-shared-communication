# RESULT-005

Final status: `BLOCKED_BY_EVIDENCE`

TASK-005 changed no implementation code. This report uses source inspection and owner-provided ZCU104 v90 telemetry. It does not claim an FPGA test performed in this workspace.

## 1. Exact copy inner loop

Source inspection: `fpga_p2_copy_q8_payload_to_volatile_ddr_crc()` in `ggml/src/ggml-cpu/fpga_weight_layout.cpp:233` validates its arguments once, initializes CRC state, then processes 16 source bytes per iteration. Each iteration calls `fpga_p2_i8x16_le_words()` at line 245 to construct four little-endian 32-bit words, performs four volatile 32-bit stores, and calls the table-driven CRC updater at line 251 for the same 16 source bytes. The final CRC is compared with the BUILD-time packed CRC.

Source inspection: the CRC updater at `fpga_weight_layout.cpp:145` performs, for every byte, one source-byte load, one table index calculation, one 32-bit table load, one CRC shift, one XOR, and loop control. CRC state is serial: byte N+1 depends on byte N. The 256-entry table occupies 1 KiB and should fit in normal L1 data cache, but the board binary's instruction sequence and inlining are not available.

The catalog already stores the final P2 byte layout. Little-endian word construction exists because the staging interface uses 32-bit stores. The source proves volatile compiler semantics for destination stores. It does not prove the Linux kernel's exact memory type for the UIO mapping.

## 2. Derived operation counts for 8.784 GB

Owner telemetry reports `copy_payload_bytes=8,784,248,832`.

| Operation | Derived count |
|---|---:|
| 16-byte iterations | 549,015,552 |
| Endian-conversion helper invocations at source level | 549,015,552 |
| CRC-update helper invocations at source level | 549,015,552 |
| CRC bytes processed | 8,784,248,832 |
| Volatile 32-bit destination stores | 2,196,062,208 |

The compiler may inline helpers and hoist invariant work. Source-level call counts are not proof of runtime call instructions.

## 3. CRC-only cost estimate/measurement

No CRC-only board measurement exists, so its exact time is unknown.

For illustration only, an assumed 1.2 GHz CPU gives 7.32 s at one cycle per byte, 29.28 s at four cycles per byte, and 87.84 s at twelve cycles per byte for 8.784 GB. These values are not evidence: actual CPU frequency, generated instructions, cache behavior, and cycles per byte were not captured.

The current CRC is table-driven, not bit-at-a-time. Its serial CRC-state dependency can limit instruction-level parallelism even when the table remains cached.

## 4. FPGA staging-store-only cost estimate/measurement

No store-only board measurement exists, so its exact time is unknown. The current run combines source reads, endian conversion, CRC, loop control, and 2.196 billion volatile stores in one timer.

Source inspection: the UIO device is opened with `O_SYNC` at `ggml/src/ggml-cpu/fpga_host.cpp:3121` and mapped with `MAP_SHARED` at line 3126. Those facts and the volatile pointer prevent compiler removal or reordering across volatile accesses, but they do not establish whether the ARM mapping is Device, strongly ordered, or another kernel-selected memory type. Store latency, write combining, and bus transaction behavior therefore cannot be derived safely from source.

## 5. Conversion/loop cost estimate

No conversion-only measurement or board disassembly exists. Each 16-byte iteration constructs four little-endian words and contains two source-level helper calls. At `-O3`, the compiler can inline both helpers and reuse loaded bytes, but this must be verified from the deployed `libggml-cpu.so` disassembly.

The conversion and loop are likely smaller than the combined CRC and volatile-store work, but current evidence cannot assign them a time or percentage.

## 6. Percentage breakdown where evidence permits

| v90 copy substage | Time | Share of `copy_us` |
|---|---:|---:|
| Lock wait | 3,851 us | 0.0036% |
| Selected-descriptor validation | 8,901 us | 0.0083% |
| Fused source/conversion/CRC/volatile store | 107,183,966 us | 99.9720% |
| Unassigned timer remainder | 17,240 us | 0.0161% |
| Total | 107,213,958 us | 100% |

The fused interval processes 78.158 MiB/s and averages 195.229 ns per 16-byte iteration. No evidence permits a defensible percentage split inside that fused interval.

For comparison, v89 `copy_us` was 190,173,577 us. v90 is 1.774 times faster and reduces copy time by 43.62%, but still exceeds TASK-004's `<95.087 s` gate.

## 7. Dominant bottleneck

Verdict: **NOT YET PROVEN between CRC and volatile staging stores.**

The fused copy loop is the confirmed bottleneck because it accounts for 99.972% of `copy_us`. Existing evidence cannot determine whether CRC, volatile FPGA-DDR stores, endian conversion, or their interaction dominates that loop. Claiming either CRC or stores as the root cause would exceed the evidence.

The scale path shows the same unresolved mixture: `scale_crc_spuparam_us=16,429,739`, combining static-scale reads, activation-scale reads, two-byte CRC updates, FP16 word construction, and volatile SPU_PARAM stores. Scale zero fill is separately measured at 2,299,344 us; selected validation is 15,959 us. No scale-path change is authorized by TASK-005.

## 8. Smallest safe next optimization

Do not change UIO memory attributes, destination store width, DDR mapping, DMA sequencing, or hardware ownership from current evidence.

First measure CRC-only and store-only costs. If CRC dominates, the smallest safe candidate is a fixed-16-byte incremental CRC routine with the table pointer hoisted outside the outer loop, or a portable slicing-by-8/16 implementation. It must preserve the existing CRC polynomial, initial/final XOR, fused one-pass source consumption, fail-closed comparison, and corruption tests.

If volatile stores dominate, TASK-005 provides no safe implementation change. Memory attributes and supported transaction widths must be verified separately before changing the staging write mechanism.

## 9. Exact additional board benchmark/telemetry required

Run these diagnostics against the same deployed v90 Release binary or an explicitly identified diagnostic build:

1. **Binary inspection:** run `objdump -drC` on the deployed `libggml-cpu.so` around `fpga_p2_copy_q8_payload_to_volatile_ddr_crc` and `fpga_p2_crc32_update`. Record whether both helpers are inlined, whether the CRC table address is hoisted, and the exact inner-loop instructions.
2. **CRC-only benchmark:** process cached packed host buffers with the production CRC until the aggregate byte count equals exactly `8,784,248,832`. Perform no UIO access. Report elapsed microseconds, final CRC, CPU frequency/governor, and compiler flags.
3. **Store-only benchmark:** prove ZDMA disabled and VPU/SPU idle; acquire one existing weight slot in CPU-writing ownership; repeatedly write a cached representative payload through the existing endian conversion and four volatile 32-bit stores, with CRC disabled, until the aggregate byte count equals `8,784,248,832`. Restrict every write to slot 0 at offset `0x00100000` or slot 1 at `0x00180000`, with at most `0x80000` bytes per pass. Do not publish READY, submit a descriptor, start ZDMA, or issue VPU START. Restore the slot to a non-ready state after measurement.
4. **Optional conversion-only benchmark:** execute the same endian conversion and four 32-bit stores into ordinary cached RAM for the same aggregate byte count. This separates conversion/loop cost from volatile UIO stores.
5. Report `crc_only_us`, `staging_store_only_us`, optional `cached_conversion_store_us`, process CPU time, wall time, CPU frequency/governor, and thermal throttling state.

Standalone timings may not sum exactly to the fused interval because cache state and CPU/store interaction differ. They are sufficient to identify the dominant component without weakening corruption detection or touching hardware dataflow.
