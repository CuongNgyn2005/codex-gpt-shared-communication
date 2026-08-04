# Handoff: Continue P3 PL scale ownership and progress toward a Figure 5-style resident SPU graph

## Metadata

- Updated: 2026-07-29 20:49:10 +07:00, after the first ZCU104 V79/P3 owner qualification.
- Scope: Gemma 3 1B Q8_0 on ZCU104; llama.cpp FPGA host scheduling, two-row VPU, P3 split-scale SPU path, and the next PL-residency steps.
- Workspace: `D:\DOAN`.
- Recipient and authority: the next Codex session may inspect and modify canonical `llama.cpp` and `DATN_RTL/RTL` sources within the owner's stated boundaries. The owner alone runs synthesis, implementation, bitstream generation, and ZCU104 tests.
- llama.cpp source state: branch `main`, HEAD `e345dc1ddf62d54ece19cdbb40a97635f1671e2c`, dirty canonical host file.
- RTL source state: branch `spu`, HEAD `abbe331918c9cfd265df5409192f7f3fd498aaf5`, dirty canonical RTL/test files.
- Host identity: `zcu104-gemma3-q8-v79-p3-split-scale-qualification`.
- Host SHA-256: `47080C92DC0A73ABF5DC9DFDD9A9394CEB1548B2EBF1619A1EE7D500CAC5644C`.
- The authoritative V79 FPGA log is the user-pasted attachment `C:\Users\PC\.codex\attachments\0318973a-c923-4a7b-aff3-ab4a202e75bb\pasted-text.txt`. The accompanying terminal capture is `C:\Users\PC\.codex\attachments\671f5c12-30aa-42a8-ab0b-de846a59232d\pasted-text.txt`.
- The owner explicitly said not to use `D:\DOAN\DATN_RTL\fpga_debug.log` for this result. Ignore that workspace file; do not ask the owner to replace or synchronize it.

## Current status

The first P3 split-scale qualification passed on ZCU104 for one hardware tile.

The verified path was:

```text
GGML Q8_0 source validation
-> host stages pair-major activation/weight data
-> host stages dense immutable FP16 weight scales in SPU_PARAM
-> host stages one dynamic FP16 activation scale per block in SPU_SCRATCH
-> two-row VPU produces paired raw INT32 results
-> SPU reads two weight scales plus the shared activation scale in PL
-> two SPU scale accumulators produce signed Q16.16 row results
-> SPU_OUT is DMA-read for CPU-shadow numerical qualification
```

The run was intentionally bounded by `FPGA_PL_SCALE_CONTRACT_CHECK=1` and the default `FPGA_P2_TILE_LIMIT=1`. After the first verified tile, all subsequent eligible GEMVs ran through the native CPU kernel. Therefore:

- The P3 hardware/ABI/data-layout contract has initial board evidence.
- This run does not establish full-model FPGA routing.
- This run does not measure P3 production throughput.
- The terminal's `4.79 tokens/s` prompt-evaluation figure is mostly CPU-native execution after the qualification boundary and must not be reported as P3 speed.

Immediate next action: run a 256-tile CPU-shadow P3 qualification. This covers approximately three layers and exercises attention Q/K/V/output plus FFN gate/up/down shapes without allowing qualified FPGA output to own the model destination.

Stop immediately if any P3 retirement, Q16, boundary, DMA, input-integrity, mode-restoration, or fallback check fails.

## Critical context and decisions

| Decision | Why | Rejected or unsafe alternative |
|---|---|---|
| Figure 5 from `Pushing_up_to_the_limit.pdf` is the architectural reference. | Its VPU/MCU/SPU residency mindset matches the owner's goal: keep intermediates and reusable metadata in PL and reduce PS work. | Copying the paper literally without matching Gemma 3 numerical contracts or current ZCU104 interfaces. |
| P3 split-scale is the first PL-ownership foundation. | Weight scales are immutable and activation scales are shared across rows; combining them in PL removes CPU construction of repeated `{weight,activation}` pairs. | Continuing to rebuild and transfer a 32-bit scale pair for every row/block. |
| P3 remains serialized in V79. | Both PARAM BRAM ports are consumed by paired scale reads. Earlier review found that concurrent inactive-bank writes could corrupt the active read unless rejected. | Claiming scale-preload/ping-pong overlap without a third metadata port, replication, or explicit arbitration. |
| P2 remains reset/default mode; P3 is explicit opt-in. | Older bitstreams and P2 scale layout must never be silently interpreted as P3. | Automatically enabling P3 from partial capability evidence. |
| Current fixed-point RMSNorm, RoPE, Softmax, and SiLU blocks remain capability-disabled. | They do not match Gemma 3: Gemma uses F32 RMSNorm semantics, NeoX RoPE, masked/scaled attention softmax, and GELU rather than SiLU. | Advertising existing blocks as full Gemma SPU support; that would risk incorrect inference. |
| Next major architectural target is a resident FFN chain. | FFN gate/up/down dominates decode and offers the highest leverage for eliminating CPU round trips. | Offloading isolated scalar operators while returning every intermediate to CPU memory. |
| No 8-row VPU development. | Owner explicitly stopped that direction. Existing two-row VPU remains the compute baseline. | Restarting 4/8-row expansion before fixing PS/PL ownership and residency. |
| No edits in generated Vivado `project_1`, embedded host, or `promp.md` without explicit permission. | Owner-defined source-of-truth and review boundary. | Editing generated/IP project copies opportunistically. |

## Work completed

### Canonical host

- `D:\DOAN\llama.cpp\ggml\src\ggml-cpu\fpga_host.cpp`
  - Added opt-in `FPGA_P3_SPLIT_SCALE=1` support.
  - Added P3 ABI/capability admission: SPU cap bit 11 and ABI `0x50330001`.
  - Added mode register handling at `0x01FC` with quiescence, lock, SPU-idle, fence, and readback checks.
  - Added dense eight-FP16-per-128-bit PARAM/SCRATCH packing without FP32 conversion or scale repair.
  - Added exact bank-relative bounds based on the advertised 4,096 SPU words: 2,048 words or `0x8000` bytes per bank.
  - Added serialized PARAM/SCRATCH DMA before VPU launch.
  - Added fail-closed retirement checks: accepted and completed entries equal `rows * group_blocks`, one done, final writes equal rows, zero rejects/drops/errors, stream quiescent, lock released, P3 mode retained.
  - Added host-only dense-scale layout/bit-preservation self-test.
  - Added concise P3 admission/configuration/mode/retirement/summary logs.
  - Kept P2 as default and required mode-0 readback on P2 routes.
  - Corrected the optional ZDMA `/dev/mem` fallback mapping from `0x10000` to the verified `0x1000` aperture.
  - P3 disables unsafe P2 input preload/residency/ping-pong scheduling in V79.

### Canonical RTL

- `D:\DOAN\DATN_RTL\RTL\SPU_Top.v`
  - Added P3 split-scale selection, dense index generation, bank ownership, paired PARAM reads, shared SCRATCH read, and completion telemetry.
  - Added bank locking from first accepted P3 raw entry through raw-done plus complete FIFO/accumulator/final-write drain.
  - Blocked command-mode SPU start during P3 ownership and blocked new P3 acceptance while command-mode SPU is busy.
  - Corrected tail-row validation so companion metadata is checked only when `pair_valid=1`.

- `D:\DOAN\DATN_RTL\RTL\SPU_Local_Memory.v`
  - Added the second PARAM read and SCRATCH activation-scale read service.
  - Made BRAM port ownership atomic: enable, write strobes, address, and data always come from one selected owner.
  - Conflicting MMIO writes are rejected and counted instead of corrupting active scale reads.

- `D:\DOAN\DATN_RTL\RTL\AXI4_Mapping.v`
  - Added P3 mode, ABI, capability, status, and telemetry register mapping.
  - P3 mode changes require stream quiescence, no P3 lock, and no command-mode SPU work.

### Tests

- `D:\DOAN\DATN_RTL\TESTBENCH\tb_SPU_Top.v`
  - Covers dense FP16 scale lanes, normal/zero/subnormal scales, both banks, boundary index, active-bank rejection, inactive-bank collision serialization, paired backpressure stability, controller exclusion, final retirement, reset, and `$finish`.

- `D:\DOAN\DATN_RTL\TESTBENCH\tb_VPU_Top.v`
  - Covers AXI-driven P3 mode, actual paired VPU raw output into split-scale SPU accumulation, delayed raw-done/mode-write rejection, bank-1 odd tail, P2 restoration, and `$finish`.

### Explicitly not changed

- `D:\DOAN\DATN_RTL\DATN_VIVADO\project_1\` during the P3 implementation. The owner later synchronized the active `project_1/src` files; direct SHA-256 comparison confirmed the six core project sources match canonical RTL.
- `D:\DOAN\DATN_RTL\EMBEDDED_LLAMA\fpga_host.cpp`.
- `D:\DOAN\DATN_RTL\EMBEDDED_LLAMA\promp.md`.
- `D:\DOAN\address_map.md`.
- Physical DDR/IP base addresses.

## Source identities

```text
fpga_host.cpp
47080C92DC0A73ABF5DC9DFDD9A9394CEB1548B2EBF1619A1EE7D500CAC5644C

AXI4_Mapping.v
38299B2B202426BB158998489316DCE58DDC55541AD3E87A1245E02438E118BB

SPU_Top.v
4898CFBE87565209538CB2D8594F2CD9A7E1955A3357C8C23F1DF17FC1747263

SPU_Local_Memory.v
8772940B707326ECC9235132BA0157EACFFC77F7AF6330C0874C36E9D9DB0AAD

tb_VPU_Top.v
80E7D0B6DAFE465496D6F93119E2E0B3891815FA395716766B2BA3E7E5AE5685

tb_SPU_Top.v
D701F3AE06939322A7C9D66F646B0769CDD4A521675C865FE759E38331D7A515
```

## P3 register and memory contract

```text
Existing protocol:          2
Existing bitstream ID:      0x56505532 (VPU2)
P2 ABI:                     0x50320003
P3 ABI:                     0x50330001 at 0x0200
P3 capability:              SPU_CAPS bit 11
P3 mode:                    0x01FC bit 0

0x0204 FIFO high-water
0x0208 raw-ready stall cycles
0x020C accepted logical entries
0x0210 completed logical entries
0x0214 final SPU_OUT row writes
0x0218 rejected scale-memory writes
0x021C P3 ownership/status
```

Implemented memory capacity:

```text
SPU words total: 4096 × 128 bits = 64 KiB implemented per memory
Bank words:      2048
Bank bytes:      0x8000
Scale lanes:     8 FP16 values per word
Max entries:     16384 = 256 rows × 64 blocks

PARAM bank 0 base:   0x00380000
PARAM bank 1 base:   0x00388000
SCRATCH bank 0 base: 0x003C0000
SCRATCH bank 1 base: 0x003C8000
```

The AXI address windows remain larger (`SPU_PARAM [0x00380000,0x003C0000)`, `SPU_SCRATCH [0x003C0000,0x00400000)`), but host bank offsets are calculated from the advertised implemented word capacity, not by dividing the full address window.

## Evidence

### Verified locally

- Canonical Vivado 2022.2 XSim command:

  ```powershell
  cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim
  .\run_phase2a_vpu_spu_xsim.ps1
  ```

- VPU/AXI result: `pass_count=27561`, `fail_count=0`.
- SPU result: `pass_count=94`.
- Both testbenches reached `$finish`.
- Independent `USE_FPGA=ON` Release build passed for `ggml-cpu`, `llama`, and `llama-cli` with strict format warnings enabled.
- Host safety verdict after the ZDMA mapping correction: `ACCEPTED_FOR_OWNER_TEST`.
- Cross-layer integration verdict: `ACCEPTED_FOR_OWNER_TEST`.
- `git diff --check` passed for the reviewed host/RTL/test files.

### Verified on ZCU104 in the latest uploaded V79 qualification

- Overlay verified low DDR `[0x70000000,0x80000000)` with no System RAM overlap.
- UIO mappings:
  - ZDMA `/dev/uio4`, size `0x1000`.
  - MY_IP `/dev/uio14`, physical `0xA0000000`, mapped size `0x400000`.
  - FPGA low DDR `/dev/uio15`, physical `0x70000000`, advertised size `0x10000000`, mapped size `0x400000`.
- Identity readback passed:
  - limits `0x00800100`
  - caps `0x100040fb`
  - SPU caps `0x10000fc3`
  - protocol `2`
  - bitstream ID `0x56505532`
  - P2 ABI `0x50320003`
  - P3 ABI `0x50330001`
- P3 admission passed with 4,096 words, 2,048 words/bank, `bank_bytes=0x8000`.
- P3 host self-test passed.
- Mode 0 baseline and mode 1 transition passed.
- First tile was `blk.0.attn_q.weight`, rows 256, blocks 36.
- P3 PARAM DMA: 18,432 bytes.
- P3 SCRATCH DMA: 80 bytes.
- `P3_RETIRE_PASS`: accepted 9,216, entries 9,216, done 1, finals 256, lock released, mode retained.
- `SPU_SCALE_CONTRACT_Q16_PASS` passed.
- `P2_TILE_BOUNDARY status=pass` passed.
- Cleanup restored P3 mode to 0.
- Zero input-integrity failures, stream drops, stream errors, raw repairs, and unavailable CPU fallback.
- Process exit: `llama_exit=0`.

### Inference

- The first real board tile demonstrates that host dense FP16 packing, P3 ABI negotiation, scale DMA, two-row VPU metadata, PL scale lookup/accumulation, SPU_OUT retirement, and mode cleanup agree for the tested shape.
- P3 reduces the tested tile's scale payload from the former paired-table 36,864 bytes to 18,432 + 80 = 18,512 bytes, approximately 49.8% of the old scale payload.
- More shapes and sustained routing still need qualification; one attention-Q tile cannot prove FFN-down multi-group behavior or full-model P3 stability.

### Unverified

- Full-route P3 correctness where FPGA output owns the production GGML destination.
- Full prompt/decode P3 throughput.
- P3 behavior across hundreds of heterogeneous tiles on hardware.
- Fresh post-P3 routed WNS/WHS and utilization report identity. Local XSim is not timing evidence.
- Full Figure 5-style resident FFN, RMSNorm, NeoX RoPE, attention Softmax/KV, or complete graph ownership.

## Immediate next action

1. Run a 256-tile CPU-shadow P3 qualification on the ZCU104-connected machine.
   - Owner/environment: project owner on ZCU104 through UltraViewer.
   - Purpose: exercise attention and FFN shapes across roughly three layers while retaining CPU-native destination ownership.
   - This is correctness qualification, not a speed benchmark.

Read-only preflight:

```bash
cd ~/Cuong_test/Infrastructure_GEMMA3

strings ./build_mem/bin/libggml-cpu.so | \
  grep -F zcu104-gemma3-q8-v79-p3-split-scale-qualification

sha256sum ./build_mem/bin/libggml-cpu.so \
  ./build_mem/bin/llama-cli \
  ./models/gemma-3-1b-it-Q8_0.gguf
```

The V79 marker must be found. Record the hashes with the returned log.

Run:

```bash
sudo rm -f /tmp/fpga_debug.log

sudo ./overlay_procedure.sh run -- env \
  -u FPGA_PL_SCALE_DISABLE \
  -u FPGA_P2_INPUT_PRELOAD \
  -u FPGA_P2_WEIGHT_RESIDENCY \
  -u FPGA_PIPELINE_ENABLE \
  FPGA_PL_SCALE_ENABLE=1 \
  FPGA_PL_SCALE_CONTRACT_CHECK=1 \
  FPGA_P2_ALLOW_MULTITILE=1 \
  FPGA_P2_TILE_LIMIT=256 \
  FPGA_P3_SPLIT_SCALE=1 \
  FPGA_ABORT_ON_CPU_FALLBACK=1 \
  FPGA_P2_PACK_WORKERS=1 \
  FPGA_WEIGHT_CACHE=0 \
  FPGA_FUSE_RAW_RESULT_ACCUM=0 \
  FPGA_ACCELERATE_VOCAB=0 \
  FPGA_INPUT_INTEGRITY_CHECK=1 \
  FPGA_P2_BOUNDARY_DIAGNOSTICS=0 \
  FPGA_LOG_FLUSH_EVERY=1 \
  ./build_mem/bin/llama-cli --check-tensors \
    -m ./models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 1 --single-turn --no-warmup --temp 0 --seed 1

echo "llama_exit=$?"
```

Expected evidence:

- P3 admission and host self-test pass.
- Mode 0 baseline and mode 1 transition pass.
- Exactly 256 P3 jobs/tiles qualify before the CPU-native boundary.
- Every launched job has `P3_RETIRE_PASS` with exact accepted/completed/final counts.
- Every checked tile has `SPU_SCALE_CONTRACT_Q16_PASS`.
- Final `P2_TILE_BOUNDARY status=pass` reports tile limit 256.
- `P3_SPLIT_SCALE_SUMMARY ... jobs=256`.
- Zero reject/drop/error deltas, input-integrity failures, raw repairs, staging restages, and unavailable CPU fallback.
- Cleanup restores mode 0.
- `llama_exit=0`.

Pass condition:

```text
All 256 tiles pass retirement and Q16 checks; no P3/DMA/input-integrity error; cleanup mode 0; exit 0.
```

Stop condition:

```text
Any P3_RETIRE_FAIL, SPU_SCALE_CONTRACT_Q16 mismatch, P2_TILE_BOUNDARY failure,
DMA fatal/error/timeout, rejected write, stream drop/error, input-integrity failure,
mode transition failure, CPU-unavailable fallback, abort, or nonzero exit.
```

Return the complete terminal output and paste the complete FPGA log as an attachment. Treat that pasted attachment as authoritative and confirm its first `ready version=` line is V79 before analysis. Do not require synchronization with `D:\DOAN\DATN_RTL\fpga_debug.log`.

## Action after the 256-tile pass

Do not jump directly to 64-token performance testing. First run one full-route, one-token production test without CPU-shadow qualification:

```bash
sudo rm -f /tmp/fpga_debug.log

sudo ./overlay_procedure.sh run -- env \
  -u FPGA_PL_SCALE_DISABLE \
  -u FPGA_PL_SCALE_CONTRACT_CHECK \
  -u FPGA_P2_ALLOW_MULTITILE \
  -u FPGA_P2_TILE_LIMIT \
  -u FPGA_P2_INPUT_PRELOAD \
  -u FPGA_P2_WEIGHT_RESIDENCY \
  -u FPGA_PIPELINE_ENABLE \
  FPGA_PL_SCALE_ENABLE=1 \
  FPGA_P3_SPLIT_SCALE=1 \
  FPGA_ABORT_ON_CPU_FALLBACK=1 \
  FPGA_P2_PACK_WORKERS=1 \
  FPGA_WEIGHT_CACHE=0 \
  FPGA_FUSE_RAW_RESULT_ACCUM=0 \
  FPGA_ACCELERATE_VOCAB=0 \
  FPGA_INPUT_INTEGRITY_CHECK=1 \
  FPGA_LOG_FLUSH_EVERY=1 \
  ./build_mem/bin/llama-cli \
    -m ./models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 1 --single-turn --no-warmup --temp 0 --seed 1

echo "llama_exit=$?"
```

This second gate must show complete FPGA routing and coherent model output. Only after it passes should the owner run 8 tokens, then 64 tokens, and compare against the V78/V75 baseline.

## Pending or deferred work

### Near-term P3 qualification

- Analyze the 256-tile board run.
- If it passes, analyze the one-token production-ownership run.
- If that passes, run 8-token then 64-token performance tests with identical prompt/seed/temperature.
- Measure actual P3 scale-preparation and scale-DMA reduction; do not infer throughput from prompt CPU timing.
- Obtain fresh synthesis/implementation evidence for the P3 sources: WNS, WHS, clock, BRAM, URAM, DSP, LUT, FF, and artifact identity.

### Next major architecture: Figure 5-style resident FFN

Target:

```text
gate GEMV ----\
               -> Gemma-compatible GELU(gate) * up
up GEMV ------/
               -> exact GGML Q8_0 quantization
               -> resident activation buffer
               -> down GEMV
               -> host only after the final FFN output
```

Requirements before implementation:

1. Inspect the exact Gemma 3 graph and tensor formats in `llama.cpp/src/llama-model.cpp` and `ggml-cpu` dispatch.
2. Define a new capability/ABI; do not reuse P3 split-scale ABI for fused FFN ownership.
3. Specify exact F32/mixed-precision GELU and `quantize_row_q8_0` numerical contracts.
4. Define resident buffer banking, valid/owner metadata, backpressure, and final-output visibility.
5. Preserve the existing two-row VPU; do not restart 8-row work.
6. Use URAM for large resident activations/weights where its geometry is effective; avoid recreating the prior BRAM-overuse failure.
7. Inspect timing after synthesis. If WNS is negative, pipeline the actual violating startpoint-to-endpoint path with registered metadata alignment rather than adding arbitrary delay buffers.
8. Add XSim comparison against GGML reference behavior before capability advertisement.

### Later graph operators

- Gemma-compatible F32 or qualified mixed-precision RMSNorm.
- NeoX RoPE with the model's actual position/frequency parameters.
- Masked/scaled attention Softmax and KV ownership.
- These remain disabled until exact graph-level numerical tests pass.

## Risks, assumptions, and gotchas

- The workspace is dirty. Existing unrelated edits belong to the owner; never reset or overwrite them.
- `project_1` is generated/read-only for Codex. The six core `project_1/src` files matched canonical RTL by SHA-256 at the last check, but recheck before trusting a new bitstream.
- `promp.md` contains the mandatory approved DDR range. Never stage below `0x70000000` or at/above `0x80000000`.
- `address_map.md` is older than the low-DDR overlay evidence. Runtime UIO identity and `/proc/iomem` preflight remain mandatory.
- The current V79 P3 host is serialized and normally uses one bank. Do not enable `FPGA_PIPELINE_ENABLE`, P2 input preload, P2 weight residency, or claim P3 ping-pong overlap.
- Do not enable weight cache, raw-result fusion, or vocabulary acceleration during qualification.
- A qualification CPU-shadow route is intentional and is not an unavailable fallback, but it also is not production FPGA destination ownership.
- `q8_hw_completed=0` and `routing_verdict=incomplete` are expected in the one-tile qualification because the bounded contract deliberately hands the model back to CPU after the checked tile. They are not acceptable in the later production-ownership run.
- P3 full-graph/SPU completion has not been achieved. State this explicitly in future reports.
- The existing standalone scalar blocks must not be advertised merely because they are physically instantiated.
- No local agent may attempt to connect to the ZCU104. The owner returns board evidence.

## Resume preflight

1. Read this entire handoff and `D:\DOAN\.codex\AGENTS.md` plus `D:\DOAN\rules.txt` before acting.
2. Confirm the workspace roots, branches, HEAD revisions, and file hashes still match this handoff.
3. Run `git status --short` separately in `D:\DOAN\llama.cpp` and `D:\DOAN\DATN_RTL`; preserve all unrelated dirty files.
4. Confirm the canonical host marker is V79.
5. Compare canonical RTL to `project_1/src` with SHA-256; do not edit `project_1`.
6. Use the user-pasted FPGA log attachment as the runtime source of truth. Confirm it begins with the V79 marker and P3 ABI. Ignore `D:\DOAN\DATN_RTL\fpga_debug.log` unless the owner explicitly designates it in a future request.
7. Confirm the owner used the exact command for the intended gate: qualification versus production ownership.
8. Recheck the approved DDR range and UIO resource identity before interpreting any board result.
9. If sources, bitstream ABI, logs, or hashes diverge, stop and investigate rather than continuing mechanically.

## Related artifacts

- `D:\DOAN\llama.cpp\ggml\src\ggml-cpu\fpga_host.cpp`
- `D:\DOAN\DATN_RTL\RTL\SPU_Top.v`
- `D:\DOAN\DATN_RTL\RTL\SPU_Local_Memory.v`
- `D:\DOAN\DATN_RTL\RTL\AXI4_Mapping.v`
- `D:\DOAN\DATN_RTL\TESTBENCH\tb_SPU_Top.v`
- `D:\DOAN\DATN_RTL\TESTBENCH\tb_VPU_Top.v`
- `D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim\run_phase2a_vpu_spu_xsim.ps1`
- `D:\DOAN\DATN_RTL\EMBEDDED_LLAMA\overlay_procedure.sh`
- `D:\DOAN\DATN_RTL\EMBEDDED_LLAMA\promp.md`
- `D:\DOAN\address_map.md`
- `D:\DOAN\DATN_RTL\fpga_debug.log` — not authoritative for this handoff; ignore unless the owner later says otherwise.
- Authoritative V79 FPGA log attachment: `C:\Users\PC\.codex\attachments\0318973a-c923-4a7b-aff3-ab4a202e75bb\pasted-text.txt`.
- V79 terminal attachment: `C:\Users\PC\.codex\attachments\671f5c12-30aa-42a8-ab0b-de846a59232d\pasted-text.txt`.
- Reference paper extraction: `D:\DOAN\tmp_pdf_extract\Pushing_up_to_the_limit.pdf` if present; Figure 5 is the architectural reference, adapted to Gemma 3 and the current ZCU104 design.
