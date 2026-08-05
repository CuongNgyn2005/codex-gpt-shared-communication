# RESULT-001: Inspect Project Architecture

Final status: `PASS`

Scope: TASK-001 documentation and source inspection only. No production source in `DATN_RTL/` or `llama.cpp/` was modified.

## Task summary

`ARCHITECTURE.md` now documents the host entry points, VPU/SPU modules, DDR/ZDMA transfers, datatype conversions, CPU/PL responsibilities, build commands, hardware assumptions, current status, and obstacles. (`.codex/context/ARCHITECTURE.md`)

## Initial repository state

Parent repository: branch `main`, HEAD `3509e94ff350f3a09999e011bb9dfaea46ea9fef`; status showed deleted root documents, modified submodule entries, and untracked task/context files. (`git status --short --branch`; `git rev-parse HEAD`)

`DATN_RTL`: branch `spu`, HEAD `bd2675cb2e50383dcd3d0d779c59c8fccaaaa003`; status showed untracked owner directories and artifacts, including `DATN_VIVADO/manual_sim/`. (`git -C DATN_RTL status --short --branch`; `git -C DATN_RTL rev-parse HEAD`)

`llama.cpp`: branch `main`, HEAD `d33e11f8c12219357c9a44bd894f6b86fc0b9e4e`; status showed modified `ggml/src/ggml-cpu/fpga_host.cpp` and untracked owner artifacts. (`git -C llama.cpp status --short --branch`; `git -C llama.cpp rev-parse HEAD`)

The existing child-repository changes were preserved. No child branch, commit, or parent submodule pointer was changed. (`git status --short --branch` before and after the task)

## Investigation findings

1. Host GEMV entry points are `ggml_compute_forward_mul_mat`, `fpga_try_matmul_extended`, and the C ABI in `fpga_host.h`. (`llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1259-1308`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:10536-10924`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.h:11-66`)
2. Model loading performs optional FPGA tensor validation before deferred hardware initialization. (`llama.cpp/src/llama-model-loader.cpp:19-42,507-510,1187-1195`)
3. VPU hierarchy is `VPU_Top -> MY_IP -> AXI4_Mapping -> Matrix_Vector_Multiplication -> PMAU_Full`; SPU hierarchy is integrated beside the VPU through `SPU_Top`, local memories, controller, scale accumulator, and vector engines. (`DATN_RTL/RTL/VPU_Top.v:4-18,109-176`; `DATN_RTL/RTL/AXI4_Mapping.v:757-898`; `DATN_RTL/RTL/SPU_Top.v:18-22,369-384`)
4. Host DDR staging is hardcoded at `0x70000000` with a 256 MiB region; ZDMA is mapped at `0xFD500000`; MY_IP is mapped at `0xA0000000`. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:36-51`)
5. Host transfers are restricted to DDR-to-MY_IP or MY_IP-to-DDR and split into default 64 KiB chunks. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:382-389,4074-4118`)
6. The source contract is Q8_0 weight, F32 activation, and F32 destination. The host quantizes activation to Q8_0, packs pair-interleaved weight payloads, and either sends scales through P2 SPU or accumulates raw results on the CPU. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:4306-4404,4727-4778,7525-7588,9163-9334`)
7. RTL PMAU computes 16 signed INT8 products per beat and emits INT32 results; the SPU raw stream accumulates scaled rows into Q16.16 output. (`DATN_RTL/RTL/PMAU_Full.v:1-37`; `DATN_RTL/RTL/SPU_Q8_Scale_Accum.v:4-14,184-221`)
8. Attention is explicitly CPU-bypassed in the current FPGA hook. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:10590-10602`)

## Root cause status

TASK-001 requested architecture inspection, not bug repair. No single runtime root cause was assigned.

The owner performance report identifies host preparation, repeated VPU jobs, DMA traffic, result handling, and PL compute as measured bottleneck categories; it states that internal PL stall causes are not identified by RTL counters. (`report_with_causes_vi.md:276-307,411-451,520-526`)

Board mapping compatibility remains unverified because the host requires `fpga_ddr_low` at `0x70000000`, while the stored board report lists `ddr_high` at `0x800000000` and no `fpga_ddr_low` entry. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:3075-3085`; `address_map.md:496-499,569-602`)

## Implementation summary

Only documentation was added. The architecture file records the current CPU-to-PL dataflow and separates verified source facts, stored simulation/report evidence, owner-recorded measurements, and unknown board details. (`.codex/context/ARCHITECTURE.md`)

The result file records the required handoff, validation boundary, risks, repository states, and next actions. (`.codex/outbox/RESULT-001.md`)

## File-by-file changes

| File | Previous behavior | New behavior | Reason and implementation |
|---|---|---|---|
| `.codex/context/ARCHITECTURE.md` | File did not exist. | Provides evidence-backed architecture documentation for `DATN_RTL` and `llama.cpp`. | Added separate folder missions, module roles, dataflow, contracts, status, obstacles, commands, and verification limits. |
| `.codex/outbox/RESULT-001.md` | File did not exist. | Provides the TASK-001 handoff report. | Added required findings, repository state, test evidence, unexecuted checks, risks, and remaining work. |

No function, RTL module, register, address, datatype, synchronization primitive, memory owner, or execution schedule was changed.

## Host/RTL dataflow before and after

Before this task, the dataflow existed only across source files, context documents, and reports. After this task, the same source-defined flow is consolidated in `.codex/context/ARCHITECTURE.md`; runtime behavior is unchanged. (`.codex/inbox/TASK-001.md`; `.codex/context/ARCHITECTURE.md`)

The documented flow is `Q8_0/F32 input -> host Q8 conversion and packing -> DDR -> ZDMA -> MY_IP/AXI4_Mapping -> ACT/WEIGHT -> VPU INT8 MAC -> raw INT32 -> P2 SPU Q16.16 or raw RESULT -> host F32 destination`. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:4306-4404,4074-4118,9163-9334`; `DATN_RTL/RTL/AXI4_Mapping.v:109-125`; `DATN_RTL/RTL/Matrix_Vector_Multiplication.v:1112-1200`)

Thread 0 owns the host launch; GGML barriers and atomics publish the route; the RTL holds raw tokens under ready/valid backpressure. (`llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1281-1308`; `DATN_RTL/RTL/Matrix_Vector_Multiplication.v:1179-1200`; `DATN_RTL/RTL/SPU_Top.v:303-318`)

## Commands executed

Read-only inspection commands executed:

```text
git status --short --branch
git submodule status                         [failed because the local Git shell lacked basename/sed; replaced by git ls-tree and child HEAD checks]
git -C DATN_RTL status --short --branch
git -C DATN_RTL rev-parse HEAD
git -C llama.cpp status --short --branch
git -C llama.cpp rev-parse HEAD
git ls-tree HEAD DATN_RTL llama.cpp
rg ...                                        [source, context, report, and log inspection]
Get-Content ...                               [source and report inspection]
```

The documented but unexecuted host build is:

```text
cmake -S llama.cpp -B llama.cpp/build -DUSE_FPGA=ON
cmake --build llama.cpp/build --target llama-cli -j2
```

The documented but unexecuted RTL regression is:

```powershell
cd DATN_RTL\DATN_VIVADO\manual_sim
.\run_phase2a_vpu_spu_xsim.ps1
```

The commands above come from `AGENTS.md` and `.codex/AGENTS.md`.

## Test and report results

| Check | Result | Evidence level |
|---|---|---|
| Source inspection | Completed. | Level 1: source inspection. |
| Stored Phase 2A VPU XSim log | `pass_count=27563`, `fail_count=0`, `AXI4-Full VPU TEST PASSED`. | Level 3 artifact inspection. |
| Stored Phase 2A SPU XSim log | `SPU_Top tests passed pass_count=67`. | Level 3 artifact inspection. |
| Stored descriptor VPU log | `pass_count=273`, `fail_count=0`. | Level 3 artifact inspection. |
| Stored descriptor SPU log | `pass_count=81`. | Level 3 artifact inspection. |
| Stored routed SPU timing report | WNS `1.732 ns`; zero failing setup endpoints; `187.512 MHz`. | Level 4 report inspection. |
| Host build | Not run. | No local compile result. |
| ZCU104 execution | Not run and unavailable. | Board is not connected to this workspace. |

## Tests not executed

The host build was not executed because TASK-001 changes only documentation and the host submodule already contains owner modifications. (`git -C llama.cpp status --short --branch`)

XSim was not rerun because TASK-001 changes no RTL or testbench source; stored logs were inspected instead. (`.codex/inbox/TASK-001.md`; `DATN_RTL/DATN_VIVADO/manual_sim/run_phase2a_vpu_spu_xsim.ps1`)

Synthesis, implementation, bitstream generation, board programming, UIO probing, `/dev/mem` access, and hardware execution were not run because repository instructions prohibit them for this workspace and task. (`AGENTS.md`; `.codex/AGENTS.md`)

## Risks and assumptions

- The child repositories are dirty; current working-tree source may not equal the recorded child commit. (`git -C DATN_RTL status --short --branch`; `git -C llama.cpp status --short --branch`)
- The stored board report may describe a different deployment state from the current host source; board compatibility is `Unknown`. (`address_map.md`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:3047-3085`)
- Older RTL overview documents contain protocol and capacity values that conflict with current RTL source; deployment must use current source identity registers. (`DATN_RTL/RTL/RTL_FILE_OVERVIEW.md:88-89`; `DATN_RTL/RTL/AXI4_Mapping.v:87-100`)
- Local simulation and timing reports do not prove model-level numerical correctness, host build compatibility, or board performance. (`.codex/AGENTS.md`)

## Remaining work

1. Reconcile the deployed device tree/UIO inventory with host requirements: `MY_IP`, `dma-controller`, and `fpga_ddr_low` at the source-defined addresses. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:3047-3085`; `DATN_RTL/EMBEDDED_LLAMA/zcu104-my-ip-uio.dtsi:1-15`)
2. Run the documented host build on the intended Linux environment. (`AGENTS.md`)
3. Run owner-provided board validation with the deployed bitstream ID, protocol, P2 ABI, UIO mappings, primary inference command, and diagnostic logs. (`llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:9837-10037`; `.codex/AGENTS.md`)
4. Measure the owner performance baseline again after deployment; the stored report records 0.256 token/s against a 2.5 token/s target. (`report_with_causes_vi.md:9-16`)

## Repository commits

| Repository | Branch | Commit | Status |
|---|---|---|---|
| `DATN_RTL` | `spu` | `bd2675cb2e50383dcd3d0d779c59c8fccaaaa003` | No child change made. |
| `llama.cpp` | `main` | `d33e11f8c12219357c9a44bd894f6b86fc0b9e4e` | No child change made; `fpga_host.cpp` was already modified. |
| Parent | `task-001-architecture-docs` | `67933fa2f99d4d6680748be092fd88d6720d9813` | Initial documentation commit; this report correction is the follow-up commit. |

No child commit, child push, parent submodule pointer update, merge, or destructive Git operation was performed.

## Owner deployment and verification

No board deployment command is supplied by TASK-001. The owner must deploy the matching host source and bitstream, confirm the source-required UIO resources, run the primary inference command, and return raw logs before hardware status can be marked verified. (`AGENTS.md`; `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:3047-3085,9837-10037`)
