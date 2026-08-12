# TASK-010 — Increase VPU INT8 Row Parallelism to 16×4

Status: `READY_FOR_INSPECTION`

## Objective

Evaluate and, if technically feasible, change the VPU from the current 16-lane × 2-row INT8 parallel datapath to a 16-lane × 4-row datapath. The change must increase exercised DSP-backed arithmetic while preserving numerical behavior, AXI/register compatibility, row ordering, ready/valid losslessness, SPU stream metadata, and final-write visibility.

## Acceptance criteria

1. The canonical RTL implementation is under `DATN_RTL/RTL/`.
2. The corresponding `DATN_RTL/DATN_VIVADO/project_1/src/` IP mirror is byte-identical for every common production source file, subject to the repository rule gate below.
3. VPU and SPU XSim regressions run from `DATN_RTL/DATN_VIVADO/manual_sim/` using Vivado installed under `D:\Xlinx` and return zero.
4. Vivado synthesis and hardware implementation complete for the active `project_1` flow.
5. The matching routed timing report has no setup, hold, or pulse-width violations and reports WNS >= `+0.500 ns`.
6. The implementation report shows a justified DSP increase without an unapproved change to AXI data width, host-visible layout, or unrelated memory capacity.
7. `DATN_RTL/RTL/RTL_FILE_OVERVIEW.md` documents the final architecture, resource/timing evidence, and validation level.

## Verified baseline

- `Matrix_Vector_Multiplication.v` uses `NUM_LANES=16` and two `PMAU_Full` instances (`u_pmau`, `u_pmau_pair`) for two-row paired issue.
- Weight payloads are pair-interleaved across two row-parity UltraRAM leaves, with one compute-read port per leaf.
- The current routed report is `project_1.runs/impl_1/SoC_wrapper_timing_summary_routed.rpt`; its latest stored summary is WNS `+0.472 ns`, WHS `+0.010 ns`, zero failing endpoints, and 124 DSP48E2 / 64 URAM.
- The Vivado project file list directly references `../../RTL/*.v`; `component.xml` packages the separate `src` mirror.
- The parent and child repositories contain pre-existing uncommitted/untracked changes. They are outside this task and must be preserved.

## Suspected causes (unverified)

- The current two-row limit may be caused by row-parity memory bandwidth rather than the PMAU multiplier count alone.
- A four-row issue path may require additional read ports or a revised weight layout, which could increase URAM or alter the host data contract.
- Adding two PMAUs may reduce the current timing margin below the required +0.500 ns unless the control/read path is kept timing-safe.

## Required investigation

- Trace the activation broadcast, four candidate weight rows, PMAU handshakes, result pairing, SPU FIFO admission, and row/block metadata through stalls and odd-row tails.
- Prove whether the current memory primitive can supply four independent rows without silent duplication or a storage-resource regression.
- Compare synthesis and routed implementation resource/timing reports against the stored baseline.
- Run both VPU and SPU simulation before and after the change.

## Allowed files

- Production RTL under `DATN_RTL/RTL/`, limited to the approved datapath and directly affected wrappers/memory modules.
- Focused RTL testbench/manual-simulation support only when required to exercise the change; do not rewrite unrelated tests.
- `DATN_RTL/RTL/RTL_FILE_OVERVIEW.md`.
- The user explicitly requested synchronization of common production sources into `DATN_RTL/DATN_VIVADO/project_1/src/`, but this is gated by the repository rule that treats `project_1` as read-only. Resolve this conflict from the inspector evidence before any write there; never write any other `project_1` path manually.

## Prohibited changes

- No host/runtime, AXI register map, bitstream protocol, BRAM/URAM capacity, clock constraint, generated project, cache, IP-XACT, or unrelated test changes unless an inspector proves they are required and the user’s scope is explicitly amended.
- No edits outside the allowed `src` exception in `project_1`.
- No board programming, UIO probing, `/dev/mem`, or physical ZCU104 execution.
- No destructive Git operation, broad staging, cleanup, or overwrite of unrelated work.

## Required commands

```powershell
cd DATN_RTL\DATN_VIVADO\manual_sim
.\run_phase2a_vpu_spu_xsim.ps1
```

Run the active `project_1` synthesis and implementation flow from a Vivado-enabled PowerShell under `D:\Xlinx`, then inspect the generated routed timing, utilization, DRC, and run logs without manually editing generated products.

## Expected result

`.codex/outbox/RESULT-010.md` with the final status, repository state, inspector/worker/tester evidence, changed-file details, dataflow before/after, exact commands and outputs, timing/resource comparison, unresolved risks, and owner follow-up if hardware evidence remains unavailable.

## Amendment A — collision-free internal four-row weight mapping

The original pair-interleaved external weight-window contract remains unchanged. The internal four-row packing may decode the external write index using the configured `REG_COL_BEATS` value (`cfg_col_beats`) because the current host flow and VPU testbenches program that register before staging each weight image. Writes in arbitrary order within that configured stride remain supported; writes made before a valid stride is configured are outside this task and must not be represented as valid 4-row data.

For an external word index `idx = ((row >> 1) * col_beats + beat) * 2 + (row & 1)`, the collision-free internal map is:

- `pair = floor(idx / (2 * col_beats))`
- `beat = floor((idx mod (2 * col_beats)) / 2)`
- `row_slot = 2 * (pair mod 2) + (idx mod 2)`
- `local_addr = floor(pair / 2) * col_beats + beat`

The implementation must use the equivalent logical mapping `row_slot = row[1:0]` and `local_addr = (row >> 2) * col_beats + beat`; it must not use `row_slot = idx[1:0]` or `local_addr = idx >> 2`, which aliases rows when `col_beats > 1`. This amendment authorizes the bounded datapath worker to implement the stride decode without changing the host, AXI, or SPU interface.
