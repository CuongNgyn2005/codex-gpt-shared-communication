# RESULT-010 — Increase VPU INT8 Row Parallelism to 16×4

## 1. Final status

`ACCEPTED_FOR_OWNER_TEST`

The current project2 timing-closure iteration satisfies the local RTL
simulation, synthesis, implementation, routed setup/hold/pulse-width, and
bitstream-generation gates. The ZCU104 board is not connected to this
workspace, so physical board execution remains owner-only evidence.

The historical project1 checkpoint details below are retained for traceability;
the final project2 signoff in Section 13 is authoritative for the current
request.

## 2. Task summary

The VPU now issues one 128-bit activation beat to four logical INT8 row
PMAUs. The external pair-interleaved AXI weight layout, register map, result
format, and VPU→SPU ready/valid metadata contract remain unchanged. The
internal weight storage is remapped from two 16K row-parity leaves to four 8K
row-slot leaves per 32-bit weight shard, preserving storage capacity while
making four independent row reads possible.

The routed implementation meets the requested timing margin:

| Gate | Result |
|---|---:|
| Setup WNS | `+0.661 ns` |
| Setup TNS / failing endpoints | `0 ns` / `0` |
| Hold WHS | `+0.010 ns` |
| Hold THS / failing endpoints | `0 ns` / `0` |
| Pulse-width worst slack | `+1.166 ns` |
| Route errors / unrouted / partial nets | `0 / 0 / 0` |
| DRC errors | `0` |

## 3. Initial repository state

- Parent: `main`, commit `85decb5e7fd46bb732a5647be5246c63eca1e9dd`.
- `DATN_RTL`: `codex/task-010-dsp-16x4`, base commit
  `7685e31e55ae436c3a6b5e98006ef48fc342653`.
- `llama.cpp`: `main`, commit `1a1a5fc0ba9957b86322e03fb572c367ad7dd1d5`.
- The child already contained owner changes in `result_prompt.txt` and
  untracked project/debug directories; they were preserved and not staged.
- The ZCU104 is not connected to this workspace.

## 4. Investigation findings and verified root cause

The old two-row path used pair-parity leaves and a write-side address mapping
whose arithmetic/fanout became the critical routed path after the four-row
read expansion. An intermediate routed report identified the weight-map
address-to-leaf-address path as the worst path, with most delay in routing.
The functional failures encountered during regression were isolated to a
testbench AXI read-response delta-cycle race: a stale single-beat response
could leave the next burst's `ARREADY` low. The DUT arithmetic and row results
already passed when the testbench transaction sequencing was corrected.

The timing fix is architectural and localized: the weight index decode is a
14-stage restoring divider, followed by registered delta/base/final mapping
and one write-metadata staging register per top bank. This removes the long
common address fanout while preserving arbitrary write order within the
configured `col_beats` stride.

## 5. Implementation summary and file-by-file changes

Only these approved child files were committed in child commit
`81277c801cda7acba8af5486ca4fa2caa066eff2`:

| File and lines | Previous behavior | New behavior and reason |
|---|---|---|
| `RTL/Matrix_Vector_Multiplication.v:148-157, 238-289, 442-488, 607-681, 735-950, 1048-1120, 1400-1570` | Two row-parity leaves and two PMAUs; write mapping created a long timing path. | Four row-slot leaves, four PMAUs, four-way atomic ready/valid issue and result retirement, 14-stage restoring write decode, and per-top-bank write staging. The external payload/index ABI is unchanged. |
| `DATN_VIVADO/project_1/src/Matrix_Vector_Multiplication.v` (same regions) | IP mirror could diverge from canonical RTL. | Byte-identical mirror of the canonical Matrix RTL used by the packaged IP. |
| `RTL/SPU_Q8_Scale_Accum.v:43-53, 208-260` | One wide scale-product path with a longer timing arc. | Four `use_dsp="yes"` 32×32 partial products with registered cross/mid/full reconstruction before clamp/accumulate. |
| `DATN_VIVADO/project_1/src/SPU_Q8_Scale_Accum.v` (same regions) | IP mirror of the old SPU scale path. | Byte-identical mirror of the pipelined canonical SPU scale path. |
| `RTL/SPU_RMSNorm.v:58-95, 120-137` | Lane multiply was assigned through state-dependent control before write. | Registered `norm_product_r` captures the lane product from already-registered operands, shortening the state-decode timing arc. |
| `DATN_VIVADO/project_1/src/SPU_RMSNorm.v` (same regions) | IP mirror of the old RMSNorm path. | Byte-identical mirror of the canonical RMSNorm RTL. |
| `TESTBENCH/tb_VPU_Top.v:232-264, 784-932, 948-1067, 2820-2828` | Pair-only issue invariant and AXI helper timing; no explicit four-row case. | Four-row atomic issue checks, a 4-row/2-block regression case, and edge-aligned AXI response/burst helpers that prevent stale-response races under backpressure. |
| `RTL/RTL_FILE_OVERVIEW.md:1, 156-174, 229-246, 361-379` | Described 16×2 and stale/pending timing evidence. | Documents the 16×4 mapping/dataflow, final XSim evidence, DSP/storage resources, routed timing, route status, DRC, and bitstream evidence. |

No host/runtime, AXI register, clock constraint, BRAM/URAM configuration,
generated project, or IP-XACT file was included in the child commit.

## 6. Dataflow before and after

Before:

```text
ACT beat (16 × INT8) -> PMAU row r + PMAU row r+1
                      -> 2 raw INT32 results
                      -> pair result/stream packet
```

After:

```text
ACT beat (16 × INT8) -> PMAU r, r+1, r+2, r+3
                      -> 4 raw INT32 results
                      -> serial Result-BRAM writes r..r+3
                      -> existing packet r/r+1, then packet r+2/r+3
```

The scheduler advances only after all valid PMAUs issue and all valid results
are accepted. Odd/tail rows disable only their invalid PMAUs. The external
weight stream remains `((row >> 1) * col_beats + beat) * 2 + parity`; the
internal map is `row_slot=row[1:0]` and
`local_addr=(row >> 2) * col_beats + beat`.

## 7. Commands executed and results

### XSim

Command:

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_phase2a_vpu_spu_xsim.ps1
```

Observed result: exit code `0`.

- `phase2a_vpu_xsim.log`: `[TB] pass_count=27584 fail_count=0` and
  `[TB] AXI4-Full VPU TEST PASSED`.
- `xsim.log`: `[TB][PASS] SPU_Top tests passed pass_count=94`.

### Synthesis

Command:

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\project_1\project_1.runs\synth_1
& D:\Xlinx\Vivado\2022.2\bin\vivado.bat -mode batch `
  -log runme-task010-fast5-synth.log -notrace `
  -source D:\DOAN\vivado_task010_fast.tcl
```

Observed result: `synth_design completed successfully`; synthesis finished
with `0 errors` and `0 critical warnings`.

### Implementation and routed signoff

The implementation flow routed successfully and generated
`SoC_wrapper_routed.dcp`; the supervising shell timed out during the later
post-route report sequence. The routed checkpoint was then opened for an
explicit signoff pass:

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\project_1\project_1.runs\impl_1
& D:\Xlinx\Vivado\2022.2\bin\vivado.bat -mode batch `
  -log task010-fast5-finalize.log -notrace `
  -source D:\DOAN\vivado_task010_finalize.tcl
```

The signoff pass exited `0`, produced the formal routed timing summary,
utilization, route-status, DRC reports, and generated
`SoC_wrapper_task010_fast5.bit`.

Report paths:

- `DATN_VIVADO/project_1/project_1.runs/impl_1/SoC_wrapper_timing_summary_task010_fast5.rpt`
- `DATN_VIVADO/project_1/project_1.runs/impl_1/SoC_wrapper_utilization_task010_fast5.rpt`
- `DATN_VIVADO/project_1/project_1.runs/impl_1/SoC_wrapper_route_status_task010_fast5.rpt`
- `DATN_VIVADO/project_1/project_1.runs/impl_1/SoC_wrapper_drc_task010_fast5.rpt`
- `DATN_VIVADO/project_1/project_1.runs/impl_1/SoC_wrapper_task010_fast5.bit`

## 8. Resource and timing comparison

The stored task baseline records 124 DSP48E2 and 64 URAM. The current fresh
synthesis/implementation reports 164 DSP48E2, 64 URAM, 104 RAMB36/RAMB18
BRAM-equivalent tiles, and 24,238 placed CLB LUTs. The intended resource
change is the DSP-backed arithmetic increase; no storage-capacity change was
made.

The current worst setup path is no longer the weight-map address fanout. It
is the routed SPU stream scale-index path and has `+0.661 ns` slack. The
current worst hold path has `+0.010 ns` slack. Vivado reports 222 DRC
warnings, including advisory DSP output-pipeline messages, but zero DRC
errors; these warnings do not create timing violations.

## 9. Tests not executed and remaining risks

- No ZCU104 programming, UIO probing, `/dev/mem` access, or physical board
  execution was attempted because the board is not connected here.
- Owner hardware validation must confirm the generated bitstream and the
  matching host/bitstream capability identity on the real board.
- The implementation command's wrapper timeout occurred after routing, while
  post-route reports were being generated; the routed checkpoint and explicit
  signoff command completed successfully.
- The child branch push was not completed: the environment rejected external
  source-code egress to the configured GitHub remote. No workaround was used.

## 10. Repository handoff

- `DATN_RTL` branch: `codex/task-010-dsp-16x4`.
- `DATN_RTL` commit: `81277c801cda7acba8af5486ca4fa2caa066eff2`.
- Child remote push: `PENDING_OWNER_APPROVAL` because the external push was
  rejected by the environment security reviewer.
- `llama.cpp` branch/commit: `main` /
  `1a1a5fc0ba9957b86322e03fb572c367ad7dd1d5` (unchanged).
- Parent branch/commit: `main` /
  `85decb5e7fd46bb732a5647be5246c63eca1e9dd`; parent pointer/report commit
  is `PENDING` until the child commit is remotely available.

## 11. Owner follow-up

After the child branch is pushed or otherwise made available, update the
parent submodule pointer to `81277c801cda7acba8af5486ca4fa2caa066eff2` and
deploy the generated bitstream. For board validation, rerun the project’s
host-side primary and diagnostic commands using the owner’s existing
ZCU104/UltraViewer procedure, and return the raw logs before marking the task
`PASS`.

## 12. Follow-up amendment (2026-08-12)

The current authoritative report is
`DATN_RTL/DATN_VIVADO/project_1/project_1.runs/impl_1/SoC_wrapper_timing_summary_routed.rpt`,
timestamped 11:45:10. Direct inspection reports setup WNS `+0.415 ns`, TNS
`0 ns`, zero setup failures, hold WHS `+0.010 ns`, THS `0 ns`, and pulse-width
slack `+1.166 ns`. The older named `task010_fast5` report value `+0.661 ns`
is not the current canonical signoff value.

The current simulation-only iteration adds registered VPU raw scale-index
metadata and removes the production SPU row*group_blocks arithmetic from the
ready/valid timing cone. Canonical RTL and `project_1/src` mirrors remain
identical for all common production `.v` files. The six changed RTL files are
`RTL/Matrix_Vector_Multiplication.v`, `RTL/AXI4_Mapping.v`, `RTL/SPU_Top.v`,
and their three authorized `DATN_VIVADO/project_1/src` mirrors.
The follow-up child commit is `68247d61d5cdf276a7907d0fe82610fff9c4d5f5`
on branch `codex/task-010-dsp-16x4`.

Executed simulation command:

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_phase2a_vpu_spu_xsim.ps1
```

Observed result: exit code `0`; VPU `pass_count=27584 fail_count=0`; SPU
`pass_count=94`, with no failure marker. Post-change WNS and resource counts
are not measured because synthesis and implementation were intentionally not
run. The owner must run them before claiming the requested `WNS >= +0.500 ns`
gate or using a new bitstream.

The task-specific synthesis/implementation scripts and logs previously left
in the parent root were moved under
`DATN_RTL/DATN_VIVADO/manual_sim/task010_vivado/`. No new synthesis or
implementation artifacts were created in the parent root during this
follow-up.

## 13. Final project2 timing-closure signoff (iteration 19)

This section supersedes the historical project1 and pre-refresh values above
for the current request. `project_1` was not modified or used for this run.

### Final status and changes

The 16×4 INT8 VPU datapath remains in place from the preceding implementation.
This timing iteration changed only the SPU local-memory region-select path:

| File | Previous behavior | New behavior and reason |
|---|---|---|
| `RTL/SPU_Local_Memory.v:89-90, 154-164, 225-233` | `core_region` and `core2_region` directly selected the live read-data muxes. | Registered `core_region_r` and `core2_region_r` capture the selectors when their existing enables assert, removing the live selector cone from the SPU scale-read path without changing BRAM enables, addresses, AXI/MMIO timing, or protocol latency. |
| `DATN_VIVADO/project_2/src/SPU_Local_Memory.v` | Project2 source mirror. | Byte-identical mirror of canonical RTL. |
| `RTL/RTL_FILE_OVERVIEW.md` | Timing section described stale project1/source-only evidence. | Updated with project2 iteration-19 timing, resources, simulation, DRC, and bitstream evidence. |

Canonical RTL, project2 `src`, and the refreshed generated IP source were
verified byte-identical, each with SHA-256
`A4C5CEDEE5DC6D9094264B7B14628BF1F0EF4CF7D25C92F52CCC95DDB89C0DD8`.

### Validation evidence

| Gate | Verified result |
|---|---:|
| Integration XSim | `PASS tb_VPU_SPU8_integration`, finish at `1771 ns` |
| Standalone SPU XSim | `[TB][PASS] SPU_Top tests passed pass_count=94`, finish at `20705 ns` |
| Synthesis | completed; `0 errors`, `0 critical warnings` |
| Implementation | route and `write_bitstream` completed; `0 errors` |
| Routed setup | WNS `+0.509 ns`, TNS `0 ns`, `0` failing endpoints |
| Routed hold | WHS `+0.010 ns`, THS `0 ns`, `0` failing endpoints |
| Routed pulse width | WPWS `+1.166 ns`, TPWS `0 ns`, `0` failing endpoints |
| Timing summary | `All user specified timing constraints are met.` |
| DSP48E2 | `406` |
| RAMB36E2 / RAMB18E2 | `104 / 1` |
| URAM288 | `64` |
| Routed DRC | `0` errors, `454` warnings |

The final worst setup path is
`SPU_VPU_Stream8/pair_idx_r_reg[1]` to the SPU input BRAM
`WEBWE[0]`, with `+0.509 ns` slack and `4.108 ns` data-path delay. The
warnings are advisory implementation/DSP-pipeline and unrouted-load
diagnostics; they do not constitute timing violations, and DRC reported no
errors. The route-status report shows all `84,090` routable nets fully
routed and `0` routing errors. The generated
`project_2.ip_user_files/bd/SoC/ipshared/9e57` source cache is stale, but
the active `.gen/sources_1/bd/SoC/ipshared/9e57` source is identical to the
canonical and `project_2/src` copies; `project_2.xpr`, the active VPU XCI,
and `component.xml` do not reference the stale user-file cache. No cache
overwrite or generated-file cleanup was performed.

### Exact commands and archived evidence

The active project2 generated targets were refreshed with:

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim\project2_timing_iter16
& D:\Xlinx\Vivado\2022.2\bin\vivado.bat -mode batch -notrace `
  -log refresh_ip_iter19.log -journal refresh_ip_iter19.jou `
  -source refresh_project2_targets_iter16.tcl
```

Simulation used Vivado 2022.2 XSim against `project_2/src`; the integration
and standalone transcripts are:

- `DATN_VIVADO/manual_sim/project2_timing_iter19/xsim_integration_iter19.log`
- `DATN_VIVADO/manual_sim/project2_timing_iter19/spu/xsim_spu_iter19.log`

Synthesis and implementation used the regenerated run scripts under
`project_2/project_2.runs/synth_1` and `impl_1`, with direct Vivado batch
execution. The report/checkpoint/bitstream evidence is archived under:

- `DATN_VIVADO/manual_sim/project2_timing_iter19/synth/`
- `DATN_VIVADO/manual_sim/project2_timing_iter19/impl/`

The archived bitstream is `SoC_wrapper.bit`, SHA-256
`DAC49A26DF7372A886EC1CD09A643B08E10660F8BDAA927CBCFACB3BE709D5C2`.

### Repository state and remaining work

- `DATN_RTL` branch/commit: `chatgpt/vpu16x8-spu8` /
  `13be021a5b7df7e9a1f6eb7c4ae9d5c21894666e`.
- `llama.cpp` branch/commit: `main` /
  `1a1a5fc0ba9957b86322e03fb572c367ad7dd1d5` (unchanged).
- Parent branch/commit: `main` /
  `9be697a23fb46e09a7a47810c4c1ce295569a2f2`.
- No commit, push, branch operation, or broad staging was performed.
- Existing dirty/untracked owner and generated files were preserved.
- Board programming, UIO access, `/dev/mem`, and physical ZCU104 execution
  were not run because the board is unavailable; owner hardware validation is
  the remaining acceptance step.
