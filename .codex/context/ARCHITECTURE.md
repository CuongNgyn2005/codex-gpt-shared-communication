# Project Architecture

Status: TASK-001 inspection completed on 2026-08-04.

Evidence rule: a statement below cites source, a stored report, or a stored simulation log. A detail without sufficient evidence is marked `Unknown`.

## Repository split

| Repository or folder | Mission | Evidence |
|---|---|---|
| `DATN_RTL/` | Implements the FPGA-side AXI wrapper, VPU GEMV datapath, SPU datapath, local memories, and RTL verification. | `DATN_RTL/RTL/RTL_FILE_OVERVIEW.md:4-6`; `DATN_RTL/DATN_VIVADO/manual_sim/source_files.f`; `DATN_RTL/DATN_VIVADO/manual_sim/source_files_spu.f` |
| `llama.cpp/` | Runs model inference and owns the host-side FPGA hook, physical mappings, ZDMA transfers, tensor conversion, scheduling, and result assembly. | `llama.cpp/ggml/src/ggml-cpu/fpga_host.h:11-66`; `llama.cpp/src/llama-context.cpp:15-16`; `llama.cpp/src/CMakeLists.txt:3-4,56-57` |
| `.codex/` | Stores task specifications, project context, agent rules, and result handoffs. | `AGENTS.md`; `.codex/AGENTS.md`; `.codex/inbox/TASK-001.md` |

`DATN_RTL` and `llama.cpp` are independent Git repositories; the parent records their submodule pointers. (`AGENTS.md`; parent `git ls-tree HEAD DATN_RTL llama.cpp`)

## CPU-to-programmable-logic dataflow

```text
GGUF src0 Q8_0 weight + src1 F32 activation
        |
        v
ggml_compute_forward_mul_mat()
        |
        v
fpga_try_matmul_extended()       [thread 0 owns the FPGA launch]
        |
        +--> F32 activation -> host Q8_0 blocks with FP16 activation scales
        |
        +--> Q8_0 weight -> pair-interleaved padded INT8 weight beats
        |
        v
DDR staging at 0x70000000
        |
        v
ZDMA at 0xFD500000: bounded DDR <-> MY_IP transfers
        |
        v
MY_IP at 0xA0000000 -> AXI4_Mapping -> ACT / WEIGHT / RESULT / SPU windows
        |
        v
Matrix_Vector_Multiplication -> PMAU_Full: 16-lane INT8 x INT8 -> raw INT32
        |
        +--> P2 stream -> SPU_Q8_Scale_Accum -> SPU_OUT Q16.16 row result -> host F32 dst
        |
        +--> raw diagnostic path -> RESULT raw INT32 -> host FP32 scale and accumulation -> F32 dst
```

The input contract is `Q8_0 weight x F32 activation -> F32 destination`; the host rejects other types for the DMA-to-IP tile path. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:6248-6254,10607-10608`)

`ggml_compute_forward_mul_mat` lets thread 0 call the FPGA hook, publishes the route with an atomic, and synchronizes workers with a GGML barrier. (`llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1259-1308`)

The host quantizes each F32 activation column with GGML `quantize_row_q8_0`, stores the resulting FP16 scales, and rejects non-finite input or FP16-scale overflow. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:4306-4404,4409-4455`)

The P2 host layout packs four `{weight_scale_fp16, act_scale_fp16}` entries per 128-bit `SPU_PARAM` word; the RTL reads the paired scales and writes Q16.16 row accumulations to `SPU_OUT`. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:7525-7588`; `DATN_RTL/RTL/AXI4_Mapping.v:87-100`; `DATN_RTL/RTL/SPU_Top.v:317-365`)

The raw path multiplies each raw INT32 block by the host activation and weight scales, sums blocks, and writes F32 values into `dst`. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:9163-9334`)

The P2 path consumes VPU raw tokens through a 32-entry SPU FIFO; `Matrix_Vector_Multiplication` holds the token in `S_RAW_STREAM_HOLD` until `spu_raw_ready` is asserted. (`DATN_RTL/RTL/SPU_Top.v:22,303-318,542-603`; `DATN_RTL/RTL/Matrix_Vector_Multiplication.v:1152-1200`)

`FPGA_MATMUL_FPGA_DST` makes GGML workers return without recomputing `dst`; `FPGA_MATMUL_CONTRACT_CPU_SHADOW` lets the native GGML kernel write `dst` after the hardware contract completes. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.h:11-18`; `llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1298-1310`)

The Flash Attention hook exists but `fpga_try_matmul_extended` returns CPU handling when `is_attention` is true. (`llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:2053-2077`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:10590-10602`)

## DATN_RTL

### Folder missions

| Folder | Mission | Evidence or status |
|---|---|---|
| `DATN_RTL/RTL/` | Canonical Verilog source for AXI, VPU, SPU, memories, and arithmetic. | `DATN_RTL/RTL/RTL_FILE_OVERVIEW.md:4`; `DATN_RTL/RTL/VPU_Top.v`; `DATN_RTL/RTL/SPU_Top.v` |
| `DATN_RTL/TESTBENCH/` | Verilog testbenches for PMAU, VPU, SPU, and GEMV. | `DATN_RTL/TESTBENCH/tb_VPU_Top.v`; `DATN_RTL/TESTBENCH/tb_SPU_Top.v`; `DATN_RTL/TESTBENCH/README_TESTBENCH.md:72-91` |
| `DATN_RTL/DATN_VIVADO/manual_sim/` | Standalone Vivado/XSim file lists, scripts, logs, and read-only simulation evidence. | `DATN_RTL/DATN_VIVADO/manual_sim/run_phase2a_vpu_spu_xsim.ps1:1-66`; `DATN_RTL/DATN_VIVADO/manual_sim/README.md` |
| `DATN_RTL/DATN_VIVADO/project_1/` | Generated Vivado project. Direct source edits are prohibited. | `AGENTS.md`; `.codex/AGENTS.md` |
| `DATN_RTL/EMBEDDED_LLAMA/` | Stores the ZCU104 device-tree overlay for the custom IP UIO node. | `DATN_RTL/EMBEDDED_LLAMA/zcu104-my-ip-uio.dtsi:1-15` |
| `DATN_RTL/BEHAVIOR_VERIFICATION/`, `C_Code_MatrixVector/`, `BITSTREAM/`, `RTL_IncreasedDSP/`, `TESTBENCH_IncreasedDSP/`, `BASIC_SOC_COURSE---PIO-DMA-Transfer_ILA-debug_on_FPGA/` | Mission is `Unknown`; this inspection found directory names but no task-required role statement. | 2026-08-04 directory listing; no role evidence reviewed |

### RTL module roles

| Module | Role | Evidence |
|---|---|---|
| `VPU_Top.v` | Exposes the AXI4-Full integration boundary and forwards parameters and signals to `MY_IP`; it contains no register map or arithmetic. | `DATN_RTL/RTL/VPU_Top.v:4-18,109-176` |
| `MY_IP.v` | Terminates AXI AW/W/B/AR/R handshakes and serializes local map requests. | `DATN_RTL/RTL/MY_IP.v:1-25,372-400` |
| `AXI4_Mapping.v` | Converts physical/base-stripped addresses, decodes registers and memory windows, and connects VPU and SPU. | `DATN_RTL/RTL/AXI4_Mapping.v:34-51,140-160,371-465,757-898` |
| `Matrix_Vector_Multiplication.v` | Validates job configuration, reads ACT/WEIGHT memories, feeds PMAU, writes RESULT, and emits raw stream metadata. | `DATN_RTL/RTL/Matrix_Vector_Multiplication.v:1-41,191-195,329-468,973-1307` |
| `PMAU_Full.v` | Performs 16 signed INT8 multiplications per beat, a registered adder tree, INT32 accumulation, and result FIFO/backpressure. | `DATN_RTL/RTL/PMAU_Full.v:1-37,108-115,184-208,318-326` |
| `SPU_Top.v` | Owns the raw-stream FIFO, P2/P3 scale-stream control, SPU capability/status registers, and command-mode SPU integration. | `DATN_RTL/RTL/SPU_Top.v:18-22,127-158,303-384,542-741` |
| `SPU_Local_Memory.v` | Implements `SPU_IN`, `SPU_OUT`, `SPU_PARAM`, and `SPU_SCRATCH` dual-port BRAM windows with ownership checks. | `DATN_RTL/RTL/SPU_Local_Memory.v:1-20,52-76,110-142` |
| `SPU_Controller.v` | Dispatches command modes for quantization, scale accumulation, SiLU, RMSNorm, RoPE, Softmax, and copy. | `DATN_RTL/RTL/SPU_Controller.v:19-86` |
| `SPU_Q8_Scale_Accum.v` | Converts FP16 activation and weight scales to fixed point, multiplies by raw INT32, accumulates by row, and rejects invalid scales or row IDs. | `DATN_RTL/RTL/SPU_Q8_Scale_Accum.v:4-14,21-44,172-194,210-221` |

### RTL contract and limits

The current RTL source advertises protocol `2`, bitstream ID `0x56505532` (`VPU2`), P2 ABI `0x50320003`, and P3 ABI `0x50330001`. (`DATN_RTL/RTL/AXI4_Mapping.v:84-100`)

The current VPU parameters are 128-bit AXI data, 16 lanes, 256 rows, 128 column beats, and 64 Q8 blocks per group. (`DATN_RTL/RTL/VPU_Top.v:33-46`)

The current local windows are ACT `[0x00010000,0x00020000)`, WEIGHT `[0x00100000,0x00200000)`, RESULT `[0x00200000,0x00210000)`, SPU_OUT `[0x00340000,0x00380000)`, SPU_PARAM `[0x00380000,0x003C0000)`, and SPU_SCRATCH `[0x003C0000,0x00400000)`. (`DATN_RTL/RTL/AXI4_Mapping.v:109-125`)

The P2 weight layout is adjacent even/odd rows per beat, with a zero companion for a final odd row; the physical index is `((row>>1)*group_beats+beat)*2+(row&1)`. (`DATN_RTL/RTL/Matrix_Vector_Multiplication.v:1-18,406-414`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:2298-2301,4733-4778`)

The RTL includes command-mode SiLU, RMSNorm, RoPE, and Softmax engines, but `SPU_Top.v` states that their capability bits remain clear until graph routing has an end-to-end numerical contract. (`DATN_RTL/RTL/SPU_Top.v:369-384`)

### RTL current status

The stored Phase 2A VPU log reports `pass_count=27563`, `fail_count=0`, and `AXI4-Full VPU TEST PASSED`. (`DATN_RTL/DATN_VIVADO/manual_sim/phase2a_vpu_xsim.log:26129-26136`)

The stored Phase 2A SPU log reports `SPU_Top tests passed pass_count=67`. (`DATN_RTL/DATN_VIVADO/manual_sim/xsim.log:30`)

The stored descriptor evidence reports VPU `pass_count=273`, `fail_count=0`, and SPU `pass_count=81`. (`DATN_RTL/DATN_VIVADO/manual_sim/evidence_phase2a_v56_descriptor_20260722T/vpu/xsim.log`; `.../spu/xsim.log`)

The stored routed SPU report meets its timing constraints with WNS `1.732 ns`, zero failing setup endpoints, and a `187.512 MHz` `clk_pl_0` clock. (`DATN_RTL/DATN_VIVADO/manual_sim/spu_timing_check/spu_timing_summary_routed.rpt:134-143,194-202`)

These results are artifact inspections; this task did not rerun XSim or Vivado. Board execution is `Unknown`. (`AGENTS.md`; `.codex/AGENTS.md`)

### RTL obstacles

The checked-in `RTL_FILE_OVERVIEW.md` still lists protocol `1` and bitstream `VPU1`, while `AXI4_Mapping.v` lists protocol `2` and `VPU2`; the overview is stale for identity fields. (`DATN_RTL/RTL/RTL_FILE_OVERVIEW.md:88-89`; `DATN_RTL/RTL/AXI4_Mapping.v:87-100`)

The checked-in `SOC_ARCHITECTURE_OVERVIEW.md` lists `MAX_COL_BEATS=32` and says SPU operations run on the CPU, while current RTL includes 128 beats and integrated SPU stream logic; those statements cannot define the current contract. (`DATN_RTL/RTL/SOC_ARCHITECTURE_OVERVIEW.md:79-101,124-139`; `DATN_RTL/RTL/VPU_Top.v:33-46`; `DATN_RTL/RTL/SPU_Top.v:542-741`)

The full Vivado project and deployed bitstream identity are not verified from this workspace. (`AGENTS.md`; `address_map.md`)

## llama.cpp

### Folder missions

| Folder | Mission | Evidence or status |
|---|---|---|
| `llama.cpp/ggml/` | Provides tensor types, CPU graph kernels, and the optional `USE_FPGA` host source. | `llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1259-1496`; `llama.cpp/ggml/src/CMakeLists.txt:421-425` |
| `llama.cpp/ggml/src/ggml-cpu/` | Dispatches GGML CPU work and implements the FPGA tensor hook, conversion, mapping, DMA, scheduler, and result assembly. | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp`; `llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1216-1310` |
| `llama.cpp/src/` | Loads models, validates tensor data when requested, manages context/sequence state, and advances the runtime. | `llama.cpp/src/llama-model-loader.cpp:19-42,507-510,1187-1195`; `llama.cpp/src/llama-context.cpp:830-833,1127-1130` |
| `llama.cpp/examples/` | Contains executable examples, including the `llama-cli` target named by the repository build instructions. | `.codex/AGENTS.md`; `llama.cpp/examples/` |
| `llama.cpp/tests/` | Contains runtime tests. | `llama.cpp/tests/` |
| `llama.cpp/cmake/` | Contains CMake support files. | `llama.cpp/cmake/` |
| `llama.cpp/gguf-py/` | Contains Python GGUF tooling. | `llama.cpp/gguf-py/` |
| Other top-level folders | Mission is `Unknown` for this task because no task-relevant role evidence was reviewed. | 2026-08-04 directory listing |

### Host responsibilities

`fpga_init` maps hardware resources, reads protocol/capability registers, validates P2/P3 admission, and enables the P2 ping-pong scheduler only after the required identity, capability, capacity, and quiescence checks pass. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:3047-3085,9800-10037`)

The host maps the DMA controller, MY_IP, and DDR; the DDR preflight rejects overlap with `System RAM`; P2 requires a physical UIO mapping named `fpga_ddr_low`. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:2584-2630,3047-3085,3309-3324`)

The host accepts only bounded DDR-to-MY_IP or MY_IP-to-DDR transfers and splits transfers at a default 64 KiB descriptor limit. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:382-389,4074-4118`)

The host serializes the owning FPGA matmul with `g_mutex`, programs tiles, polls completion, reads SPU_OUT or RESULT, accumulates F32 values, and releases the lock. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:10590-10924`)

Model loading enables tensor validation for explicit contract or source-audit modes and signals completion before deferred FPGA initialization. (`llama.cpp/src/llama-model-loader.cpp:19-42,507-510,1187-1195`)

New sequences reset the host activation cache and successful evaluations advance the host sequence position; an actual attention accelerator cache is not proven. (`llama.cpp/src/llama-context.cpp:830-833,1127-1130,2039-2041`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:10926-10930`)

### Host build and runtime commands

The source build option is `USE_FPGA`; CMake adds `USE_FPGA` to `llama` and `ggml-cpu` and adds `fpga_host.cpp` when enabled. (`llama.cpp/src/CMakeLists.txt:3-4,56-57`; `llama.cpp/ggml/src/CMakeLists.txt:3,421-425`)

The documented host commands are listed in the repository instructions. (`AGENTS.md`; `.codex/AGENTS.md`)

```text
cmake -S llama.cpp -B llama.cpp/build -DUSE_FPGA=ON
cmake --build llama.cpp/build --target llama-cli -j2
```

The host build was not run for TASK-001. No local host compile result is available. (`AGENTS.md`; `.codex/AGENTS.md`)

### Hardcoded addresses, limits, and hardware assumptions

| Item | Current value or rule | Evidence |
|---|---|---|
| MY_IP and register base | `0xA0000000` | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:36-38` |
| ZDMA controller | `0xFD500000`, one 4 KiB page | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:40-46` |
| DDR staging | `0x70000000` through `<0x80000000`, 256 MiB | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:49-51` |
| Required DDR map | At least `0x00400000` bytes for the local windows; larger mapping is used for explicit cache/residency modes. | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:284-300,3092-3151` |
| ZDMA transfer | Default 64 KiB chunks; default DMA/IP timeout 5,000,000 microseconds | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:382-389,4090-4118` |
| VPU shape | 16 lanes, Q8 block 32 values, two 128-bit beats per block, default 256 rows and 64 blocks per group | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:334-346`; `DATN_RTL/RTL/VPU_Top.v:33-46` |
| Protocol admission | Protocol `2`, ID `0x56505532`, P2 ABI `0x50320003`, P3 ABI `0x50330001` | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:364-373`; `DATN_RTL/RTL/AXI4_Mapping.v:87-100` |
| FPGA frequency | Host default is `0.0 MHz`; runtime accepts `FPGA_CLOCK_HZ` or `FPGA_CLOCK_MHZ`. The owner report records 187.5 MHz, and the routed SPU report records 187.512 MHz. | `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:1063,9776-9782`; `report_with_causes_vi.md:16`; `DATN_RTL/DATN_VIVADO/manual_sim/spu_timing_check/spu_timing_summary_routed.rpt:150-154` |

### Host current status

The host source contains P2 ping-pong, P2 scale-stream, P3 split-scale, bounded DMA, source validation, and CPU-shadow contract paths. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:8905-9044,9163-9334,9800-10037,10536-10924`)

The host working tree has an uncommitted `fpga_host.cpp` change of 36 added and 15 removed lines; this task did not edit or interpret that diff as an approved implementation. (`git -C llama.cpp status --short --branch`; `git -C llama.cpp diff --stat -- ggml/src/ggml-cpu/fpga_host.cpp`)

The owner-recorded baseline is approximately 3900.50 ms/token at 0.256 token/s, with 2210 VPU jobs per token, 2275 ms host preparation, and 1284.60 ms measured PL compute; the internal PL stall cause is not identified by the report. (`report_with_causes_vi.md:9-16,276-307,520-526`; `.codex/context/ROADMAP_2_5_TOKENS_VI.md:22-32`)

The host defaults vocab projection to CPU for decode-sized large projections, and attention remains CPU-handled. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:10531-10534,10660-10675`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:10590-10602`)

### Host obstacles

The host requires UIO resource `fpga_ddr_low` at `0x70000000`, but the stored board report lists `ddr_high` at `0x800000000` and does not list `fpga_ddr_low`; current board mapping compatibility is `Unknown`. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:3075-3085`; `address_map.md:496-499,569-602`)

The stored board report lists UIO DMA names as `dma`, while the host requests the named resource `dma-controller`; environment alias behavior on the deployed board is `Unknown`. (`address_map.md:582-632`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:3047-3055`)

The stored device-tree overlay declares only `MY_IP@a0000000`; it does not declare the host-required DDR or DMA UIO nodes. (`DATN_RTL/EMBEDDED_LLAMA/zcu104-my-ip-uio.dtsi:1-15`)

The checked-in RTL and host source agree on protocol 2/P2 ABI values, but the older RTL overview documents disagree; deployment must use the source-advertised identity. (`DATN_RTL/RTL/AXI4_Mapping.v:87-100`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:364-373`; `DATN_RTL/RTL/RTL_FILE_OVERVIEW.md:88-89`)

## Verification boundary

| Evidence level | Result for TASK-001 |
|---|---|
| Source inspection | Complete for task-relevant host, RTL, testbench, build, address, and context files. |
| Host compile | Not run. |
| RTL simulation | Pre-existing XSim logs inspected; Phase 2A VPU and SPU logs report pass. |
| Synthesis/timing report | Pre-existing routed SPU report inspected; constraints meet with 1.732 ns WNS. |
| ZCU104 execution | Not available; the board is not connected to this workspace. |

The architecture is documented, but hardware success, deployed UIO names, deployed DDR carveout, full end-to-end model numerical correctness, and 2.5 token/s performance remain `Unknown`. (`AGENTS.md`; `.codex/AGENTS.md`; `address_map.md`; `report_with_causes_vi.md`)
