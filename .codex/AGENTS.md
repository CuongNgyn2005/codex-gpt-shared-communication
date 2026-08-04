# Repository Guidelines

## Project Structure & Module Organization

- `DATN_RTL/RTL/` contains canonical Verilog for the ZCU104 VPU, SPU, AXI mapping, and memories.
- `DATN_RTL/TESTBENCH/` contains RTL testbenches; standalone Vivado/XSim scripts and file lists live in `DATN_RTL/DATN_VIVADO/manual_sim/`.
- `DATN_RTL/DATN_VIVADO/project_1/` is a generated Vivado project. Treat it as read-only: inspect reports and logs, but do not edit project sources, caches, or generated products directly.
- `llama.cpp/` contains the inference runtime. FPGA integration is primarily in `llama.cpp/ggml/src/ggml-cpu/fpga_host.{cpp,h}`.
- Root documents (`IMPLEMENTATION_PLAN.md`, `report.md`, `curr_problems.txt`) record architecture, measured status, and unresolved issues.

## Build, Test, and Development Commands

Run RTL regression from a Vivado-enabled PowerShell:

```powershell
cd DATN_RTL\DATN_VIVADO\manual_sim
.\run_phase2a_vpu_spu_xsim.ps1
```

Use `run_phase1a_xsim.ps1` for packed-Q8 layout tests. The Python layout model is a lightweight check only and does not replace XSim.

Build the host/runtime with CMake:

```bash
cmake -S llama.cpp -B llama.cpp/build -DUSE_FPGA=ON
cmake --build llama.cpp/build --target llama-cli -j2
```

Do not run synthesis or implementation unless the task explicitly authorizes it.

## Coding Style & Naming Conventions

Follow `.clang-format`, `.clang-tidy`, and `.editorconfig` under `llama.cpp/`. Keep C/C++ changes warning-clean. In Verilog, use four-space indentation, nonblocking sequential assignments, `_r` register suffixes, and uppercase parameters. Preserve AXI widths, addresses, signedness, metadata, and ready/valid timing.

## Testing Guidelines

Every functional RTL change requires XSim regression. Add focused cases to `tb_VPU_Top.v` or `tb_SPU_Top.v` for boundaries, signed values, reset, errors, and final-write visibility. Failures must return nonzero and appear clearly in `xsim.log`.

## Commit & Pull Request Guidelines

Use short imperative commits with a subsystem prefix, for example `rtl: pipeline RMS inverse engine` or `host: validate result bounds`. Keep RTL, host, and documentation changes separated. Pull requests should state the data contract, files changed, simulation results, address-map impact, and unverified board behavior. Exclude generated Vivado artifacts, build directories, and bitstreams unless requested.

## Present Condition

The ZCU104 is not connected to this workspace. The owner accesses a separate board-connected machine through UltraViewer. Agents modify and review `DATN_RTL/RTL/`, testbenches, and `llama.cpp/`; do not attempt Linux board access, programming, UIO probing, or hardware execution here. The owner deploys `fpga_host.cpp` and bitstreams, runs the primary command, and returns logs/results. Provide reproducible verification commands and distinguish local simulation, report inspection, and owner-provided hardware evidence. Never claim hardware success before those results arrive.

## Agent-Specific Safety

Read `rules.txt` and `plan_maker_rules.txt` before work. Preserve unrelated local changes. Report every edited file, and distinguish simulation evidence from synthesis, timing, and on-board validation.

## Multi-Agent Cooperation Protocol

When the user asks for subagents, parallel review, or the project cooperation workflow, the root agent must orchestrate the project agents in this order:

1. **Baseline:** Read the latest `DATN_RTL/curr_problems.txt`, owner logs, relevant source, and read-only Vivado reports. Record the host version, protocol/bitstream ID, command, and exact task boundary.
2. **Inspect first:** Spawn the applicable read-only inspector before any production edit. Use `host_safety_inspector` for host/driver safety, `rtl_performance_reviewer` for RTL architecture/performance, and `integration_acceptance_inspector` for cross-layer numerical or protocol changes. Inspectors return `ACCEPTED`, `CHANGES_REQUIRED`, or `BLOCKED_BY_EVIDENCE`, with a bounded worker scope.
3. **One writer:** Only after `CHANGES_REQUIRED`, spawn exactly one applicable production worker: `host_driver_worker`, `rtl_datapath_worker`, or `spu_memory_worker`. Do not run concurrent production writers on overlapping files. The worker must stay inside the inspector-approved scope.
4. **Independent test:** After implementation, spawn `host_build_tester` for `llama.cpp` changes or `rtl_xsim_tester` for RTL changes. Use `report_regression_tester` for read-only artifact, timing, utilization, and runtime-KPI comparisons. Tester failures go back to the same worker.
5. **Acceptance loop:** Send the worker diff and tester evidence back to the original inspector and `integration_acceptance_inspector` when the contract crosses RTL/host boundaries. Repeat worker -> tester -> inspector until `ACCEPTED_FOR_OWNER_TEST`, or report `BLOCKED_BY_BOARD`/`BLOCKED_BY_EVIDENCE` with the exact missing evidence.
6. **Owner verification:** Provide reproducible deployment and primary/diagnostic commands to the owner. Local acceptance never implies ZCU104 acceptance; only owner-returned logs can close the hardware gate.

Coordination rules:

- Parallelize independent read-only inspections, but serialize edits and acceptance decisions.
- The root agent owns the task ledger, relays inspector findings through follow-up tasks, waits for all required evidence, and returns one consolidated status.
- Inspectors and report testers remain read-only. Testers may edit testbench/manual-simulation support only when their agent definition explicitly allows it.
- Never bypass an inspector verdict, silently broaden scope, use CPU fallback as FPGA proof, or count repaired/canonicalized output as hardware correctness.
- Never run synthesis, implementation, bit generation, board programming, UIO probing, or `/dev/mem` access unless the user explicitly authorizes the relevant action and environment.

Suggested App prompt:

```text
Use the repository Multi-Agent Cooperation Protocol for this task. Inspect first,
allow only one production worker to edit, run the independent tester, then return
the result to the inspectors until ACCEPTED_FOR_OWNER_TEST or explicitly blocked.
Wait for all required agents and give me one consolidated report.
```
