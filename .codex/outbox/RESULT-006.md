# RESULT-006

Final status: `PASS`

## 1. Exact baseline and candidate commit

- Parent baseline: `main` at `39646257ffb4b36f5988180b3c5f0cf0e488a352`.
- Parent remote TASK-006 commit: `75576cb9da5e4df1d1d364d74557993a671e5b45`.
- Host baseline: `llama.cpp/main` at `a09059d0c545e3c378212503901d1b21eb79895d`; `origin/main` matches.
- Host version: `zcu104-gemma3-q8-v90-prepack-hotpath` before; `zcu104-gemma3-q8-v91-prepack-bench` after.
- Candidate commit: `PENDING`; the owner did not request commit or push.
- No branch was created because branch creation requires explicit owner permission.
- `DATN_RTL` was not modified.

Only `.codex/inbox/TASK-006.md` was retrieved. The parent repository was not merged or pulled to `75576cb`.

## 2. Files changed

- `llama.cpp/tests/fpga-host-prepack-bench.cpp`: standalone benchmark with `--crc-only`, `--store-only`, and `--cached-store-only` modes, exact byte accounting, safety self-tests, read-only DMA/VPU gates, exact UIO validation, and bounded DDR writes.
- `llama.cpp/ggml/src/CMakeLists.txt`: adds target `fpga-host-prepack-bench` under `USE_FPGA`.
- `llama.cpp/ggml/src/ggml-cpu/fpga_weight_layout.{h,cpp}`: adds diagnostic-only `fpga_p2_copy_packed_store_only()`, preserving 16-byte conversion and four volatile 32-bit stores without CRC.
- `llama.cpp/tests/test-fpga-host-prepack.cpp`: verifies byte-identical store output and invalid-size rejection.
- `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp`: changes only the manifest version to v91.
- `.codex/inbox/TASK-006.md`: retrieved task specification.
- `.codex/outbox/RESULT-006.md`: this report.

No production lookup, CRC, packed copy, DDR mapping, UIO flag, scheduler, DMA, VPU, SPU, P2 layout, arithmetic, quantization, preload, ping-pong, or RTL behavior changed.

## 3. Proof normal inference path is unchanged

The new executable links only its benchmark source and `fpga_weight_layout.cpp`. It does not link `fpga_host.cpp`, GGML execution, ZDMA submission, or inference scheduling.

The diagnostic store helper has call sites only in the benchmark and board-free test. `fpga_host.cpp` does not call it. Production `fpga_p2_copy_packed_crc_store()` is unchanged. The only `fpga_host.cpp` difference is the v91 manifest string.

The Linux Release build compiled `ggml-cpu` and `llama-cli` successfully after the change.

## 4. Benchmark implementation summary

Every mode processes exactly `8,784,248,832` bytes from one deterministic 512 KiB cached source buffer. The loop performs full 512 KiB passes plus an exact 327,680-byte remainder. Warm-up is outside the timer. Timing uses `std::chrono::steady_clock`. The timed loops contain no logging.

`--crc-only` calls production CRC begin, update, and finalization. It performs no FPGA initialization or UIO access.

`--store-only` repeatedly writes slot 0 at offset `0x00100000`. Every pass performs existing little-endian conversion and four volatile 32-bit stores per 16 source bytes. CRC is absent. The timer contains conversion and volatile stores. Final fences and first/last readback are outside the timer.

`--cached-store-only` runs the same helper against normal cached RAM. Each mode prints `mode`, `bytes`, `elapsed_us`, `MiB_s`, and `crc32` or `sink`. Platform telemetry reports CPU model, frequency, and governor when available.

## 5. CRC-only safety/correctness evidence

CRC-only contains no UIO, `/dev/mem`, MMIO, DMA, or START operation. Its linkage excludes `fpga_host.cpp`.

Windows x86-64 board-free result:

```text
CRC_ONLY mode=crc-only bytes=8784248832 elapsed_us=18651243 MiB_s=449.155721 crc32=0xc7cc7ecf
```

WSL x86-64 result:

```text
CRC_ONLY mode=crc-only bytes=8784248832 elapsed_us=18631343 MiB_s=449.635461 crc32=0xc7cc7ecf
```

The matching CRC proves deterministic exact-volume processing across both local builds. These are desktop measurements, not ZCU104 evidence. The existing independent bitwise-reference CRC self-test passed.

## 6. Store-only DDR/idle/no-DMA safety evidence

Before DDR mapping or writing, store-only:

1. Resolves the DMA UIO by configured reference or physical address `0xFD500000`, maps one page read-only, and requires production-authoritative `ZDMA_CH_CTRL2.EN == 0`. This accepts the board's production name `dma` while retaining address, offset, and size validation.
2. Resolves exact `MY_IP` at physical `0xA0000000`, maps one page read-only, and requires stable non-BUSY/non-ERROR VPU status, no busy/error bank state, FREE/FREE slots, zero descriptor flags, quiescent SPU stream, no P3 lock, and idle SPU control.
3. Resolves exact `fpga_ddr_low` at physical `0x70000000`, requires offset zero and the advertised 256 MiB reservation, then maps only `0x00200000` bytes covering the legal weight slots.
4. Repeats ZDMA and VPU/SPU idle gates before warm-up, after warm-up, and after timing.

Every write requires slot 0 or slot 1, a nonzero 16-byte-aligned pass no larger than `0x80000`, mapped-range containment, and physical containment below `0x80000000`.

The benchmark has no DMA descriptor function, ZDMA write, VPU/SPU control write, READY publication, or inference entry point. DMA and VPU mappings use `PROT_READ`; only validated DDR uses `PROT_READ | PROT_WRITE`.

The board-free safety check verifies byte-identical four-word output, invalid-size rejection, valid boundaries, invalid offset rejection, oversized-pass rejection, undersized-map rejection, alignment rejection, and exact non-overflowing target accumulation.

The first owner run exposed an over-strict diagnostic name check before DDR access:

```text
UIO validation failed name=dma-controller phys=0xfd500000 bytes=0x1000
```

The board manifest identifies the same physical controller as `/dev/uio4(dma,O_SYNC)`. The benchmark now accepts that production alias only when physical address `0xFD500000`, map offset zero, and minimum size `0x1000` all match. No FPGA board test ran in this workspace.

## 7. Build/test result

PASS on Windows:

```text
cmake --build build_mem -j2 --target fpga-host-prepack-bench fpga-host-prepack-selftest
./build_mem/bin/fpga-host-prepack-selftest.exe
```

Both targets built. Output: `fpga host prepack self-test passed`.

PASS in clean WSL Release builds with `USE_FPGA=ON`:

```text
cmake --build /tmp/task006-build --target fpga-host-prepack-bench fpga-host-prepack-selftest -j2
/tmp/task006-build/bin/fpga-host-prepack-selftest
cmake --build /tmp/task006-build --target ggml-cpu llama-cli -j2
```

The benchmark, self-test, `ggml-cpu`, and `llama-cli` built successfully. The self-test passed. `git diff --check` passed.

Not run: ZCU104 store-only benchmark, because this workspace has no board or UIO devices.

## 8. Exact owner board commands

Stop `llama-cli` and every other FPGA user. Build without deleting `build_mem`:

```bash
cmake --build build_mem -j2 --target fpga-host-prepack-bench
```

Run every mode three times and return all output:

```bash
for i in 1 2 3; do
  ./build_mem/bin/fpga-host-prepack-bench --crc-only
done

for i in 1 2 3; do
  ./build_mem/bin/fpga-host-prepack-bench --cached-store-only
done

for i in 1 2 3; do
  sudo ./build_mem/bin/fpga-host-prepack-bench --store-only
done
```

If exact-name discovery fails, use the paths from the production manifest:

```bash
sudo env \
  FPGA_DMA_UIO=/dev/uio4 \
  FPGA_VPU_UIO=/dev/uio14 \
  FPGA_DDR_UIO=/dev/uio15 \
  ./build_mem/bin/fpga-host-prepack-bench --store-only
```

Overrides do not bypass exact name, physical address, offset, or size validation.

## 9. Owner board measurements once returned

Owner-provided ZCU104 measurements:

| Mode | Three-run median | Median throughput | Status |
|---|---:|---:|---|
| CRC-only | 66,083,527 us | 126.769 MiB/s | VALID |
| Cached-store-only | 4,743,590 us | 1,766.028 MiB/s | VALID |
| Store-only | 18,477,886 us | 453.370 MiB/s | VALID |

All CRC runs produced `0xc7cc7ecf`. All cached-store and store-only runs produced sink `0x207415a8`. The three store-only measurements were 18,475,207 us, 18,477,886 us, and 18,480,155 us. CPU frequency was 1,199,999 kHz with the `userspace` governor.

CRC-only is 61.654% of the 107.184-second fused production interval. Store-only is 17.239%. Cached conversion/store is 4.426%. CRC-only is 3.576 times slower than FPGA store-only and 13.931 times slower than cached-store-only. Standalone CRC-only plus store-only equals 78.894% of the fused interval, but the remaining 22.623 seconds cannot be assigned because standalone cache and execution interactions differ.

Required values are the three-run median `elapsed_us` and `MiB_s` for all modes, with CPU frequency and governor. Standalone values must not be added and presented as the production fused-loop time.

## 10. Verdict: CRC / DDR STORE / BOTH / NOT PROVEN

`CRC`.

ZCU104 evidence proves CRC costs about 66.084 seconds and FPGA staging stores cost about 18.478 seconds for the same production byte volume. CRC is 3.576 times slower and is the primary next optimization target. FPGA staging stores are a measured secondary cost.

## 11. Recommended next optimization, but do not implement it

- If median `crc_only_us` greatly exceeds `store_only_us`, optimize CRC while preserving its polynomial, initialization, final XOR, incremental behavior, and corruption checks.
- If `store_only_us` greatly exceeds `crc_only_us`, verify kernel memory attributes and supported transaction widths before changing volatile store semantics.
- If they are similar, measure fused interaction and conversion-only cost before changing production architecture.

No production optimization was implemented in TASK-006.
