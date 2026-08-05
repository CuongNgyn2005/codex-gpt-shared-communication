# Repository Guidelines

This file belongs at the root of the parent coordination repository.

The parent repository coordinates two independent Git submodules:

- `DATN_RTL/` -> FPGA RTL, Vivado, testbench, SPU, VPU, AXI, and hardware-side work.
- `llama.cpp/` -> host runtime, model execution, FPGA driver, and software integration.

The parent repository stores project-wide instructions, task specifications, result reports, context documents, and exact submodule commit pointers. Treat each submodule as a separate Git repository with its own branches, commits, remotes, tests, and pull requests.

## Project Structure & Module Organization

- `DATN_RTL/RTL/` contains canonical Verilog for the ZCU104 VPU, SPU, AXI mapping, and memories.
- `DATN_RTL/TESTBENCH/` contains RTL testbenches; standalone Vivado/XSim scripts and file lists live in `DATN_RTL/DATN_VIVADO/manual_sim/`.
- `DATN_RTL/DATN_VIVADO/project_1/` is a generated Vivado project. Treat it as read-only: inspect reports and logs, but do not edit project sources, caches, or generated products directly.
- `llama.cpp/` contains the inference runtime. FPGA integration is primarily in `llama.cpp/ggml/src/ggml-cpu/fpga_host.{cpp,h}`.
- `.codex/inbox/` contains immutable task specifications such as `TASK-001.md`.
- `.codex/outbox/` contains completed handoff reports such as `RESULT-001.md`.
- `.codex/context/` contains durable project knowledge, including architecture, decisions, known problems, protocols, and verification history.
- Root documents such as `IMPLEMENTATION_PLAN.md`, `report.md`, and `curr_problems.txt`, when present, record architecture, measured status, and unresolved issues.

## Required Reading Order

Before investigating or changing anything, the root agent must read, in order:

1. This `AGENTS.md`.
2. `rules.txt` and `plan_maker_rules.txt`, when present.
3. The active `.codex/inbox/TASK-<number>.md`.
4. Relevant files under `.codex/context/`.
5. Current problem reports, owner logs, and architecture documents.
6. Relevant source, testbench, build, and read-only Vivado report files.
7. Git status, current branch, and current commit in the parent and both submodules.

Do not accept a task's suspected cause as fact. Verify it from source, logs, simulation, reports, or owner-provided hardware evidence.

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

Do not run synthesis, implementation, bit generation, board programming, UIO probing, `/dev/mem` access, or hardware execution unless the active task explicitly authorizes the action and the environment supports it.

## Coding Style & Naming Conventions

Follow `.clang-format`, `.clang-tidy`, and `.editorconfig` under `llama.cpp/`. Keep C/C++ changes warning-clean.

In Verilog:

- use four-space indentation;
- use nonblocking assignments for sequential logic;
- use `_r` suffixes for registers;
- use uppercase parameters;
- preserve AXI widths, addresses, signedness, metadata, and ready/valid timing.

Do not silently alter host/RTL data contracts, register layouts, buffer ownership, datatype interpretation, quantization behavior, address maps, clock assumptions, or protocol/bitstream compatibility.

## Testing Guidelines

Every functional RTL change requires XSim regression. Add focused cases to `tb_VPU_Top.v` or `tb_SPU_Top.v` for boundaries, signed values, reset, errors, backpressure, and final-write visibility. Failures must return nonzero and appear clearly in `xsim.log`.

Every host change requires the narrowest applicable build or test first, followed by broader verification when practical. Never claim that a command passed unless it was actually executed and its result was observed.

Distinguish these evidence levels explicitly:

1. Source inspection only.
2. Local compile or static check.
3. RTL simulation.
4. Read-only synthesis, timing, or utilization report inspection.
5. Owner-provided ZCU104 execution evidence.

A lower evidence level must never be presented as proof of a higher level.

## Parent Repository and Submodule Rules

The parent repository and both submodules are independent Git repositories.

Before work, record:

```bash
git status --short --branch
git submodule status

git -C DATN_RTL status --short --branch
git -C DATN_RTL rev-parse HEAD

git -C llama.cpp status --short --branch
git -C llama.cpp rev-parse HEAD
```

A submodule checked out in detached `HEAD` state is normal after `git submodule update`. Before editing a submodule, create or switch to an explicit task branch in that submodule.

For a task that changes a child repository:

1. Create or switch to the task branch inside that child.
2. Change and verify only the approved files.
3. Stage specific files only.
4. Commit inside the child repository.
5. Push the child branch or commit first.
6. Return to the parent repository.
7. Stage the changed submodule path, which records the new child commit pointer.
8. Commit and push the parent task branch only after the child commit is remotely available.

Required order:

```text
child change -> child test -> child commit -> child push
-> parent pointer update -> parent result report -> parent commit -> parent push
```

The parent must never reference a child commit that has not been pushed to an accessible child remote.

Do not use `git submodule update --remote`, change configured submodule branches, or advance submodule pointers unless the task explicitly requires an update and the resulting commits are reviewed.

Do not run `git add .`, `git add -A`, or broad recursive staging inside either submodule. Local untracked files may belong to the owner and must remain untracked unless the task explicitly names them.

## Git Safety

Preserve unrelated local changes and untracked files in the parent and both submodules.

Never run without explicit user authorization:

- `git reset --hard`
- `git clean -fd` or `git clean -fdx`
- force-push
- branch deletion
- history rewriting
- automatic merge into protected branches
- changing another worktree
- deleting owner-created files
- replacing a submodule directory
- deinitializing or removing a submodule

If unexpected local changes, branch divergence, missing commits, inaccessible remotes, or submodule pointer conflicts are found, stop the affected write operation and report the exact state. Continue only with read-only investigation that cannot damage the workspace.

## Commit & Pull Request Guidelines

Use short imperative commits with a subsystem prefix, for example:

- `rtl: pipeline RMS inverse engine`
- `host: validate result bounds`
- `test: add SPU signed-boundary regression`
- `docs: record TASK-001 architecture findings`
- `parent: update TASK-001 submodule pointers`

Keep RTL, host, tests, and parent coordination changes separated when practical.

Child pull requests should state:

- the data contract;
- files and functions changed;
- simulation or build results;
- address-map or protocol impact;
- performance impact;
- unverified board behavior;
- compatibility assumptions.

The parent pull request should state:

- the task file;
- result report;
- child repository commit hashes;
- child pull requests or branches;
- updated submodule pointers;
- final acceptance status.

Exclude generated Vivado artifacts, build directories, logs, caches, and bitstreams unless the task explicitly requires them.

## Handoff Task Protocol

Each task must have one specification in `.codex/inbox/` and one result report in `.codex/outbox/`.

Use matching names:

```text
.codex/inbox/TASK-001.md
.codex/outbox/RESULT-001.md
```

The task specification is the source of truth for scope. Do not modify it after implementation begins. If the task must change, create an explicit amendment section or a new task rather than silently rewriting the original requirements.

Each task specification should define:

1. Task title and status.
2. Objective and observable expected behavior.
3. Current behavior and evidence.
4. Observed symptoms.
5. Suspected causes, clearly marked as unverified.
6. Required investigation.
7. Allowed parent and child files.
8. Prohibited changes.
9. Required build, simulation, or inspection commands.
10. Acceptance criteria.
11. Expected result file.
12. Required child and parent branch names, when applicable.

The root agent owns the task ledger and must keep the task boundary explicit throughout investigation, implementation, testing, and acceptance.

## Required Result Report

Write the final report to `.codex/outbox/RESULT-<task-number>.md`.

The report must include:

1. Final status: `ACCEPTED_FOR_OWNER_TEST`, `PASS`, `PARTIAL`, `BLOCKED_BY_BOARD`, `BLOCKED_BY_EVIDENCE`, `BLOCKED_BY_WORKSPACE`, or `NO_CHANGE`.
2. Task summary.
3. Initial repository state.
4. Investigation findings.
5. Verified root cause, or a clear statement that the root cause remains unverified.
6. Implementation summary.
7. File-by-file changes with relevant functions or modules.
8. Host/RTL dataflow before and after.
9. Commands executed.
10. Test and simulation results.
11. Tests not executed and exact reasons.
12. Risks, assumptions, and possible regressions.
13. Remaining work.
14. `DATN_RTL` branch and commit hash.
15. `llama.cpp` branch and commit hash.
16. Parent branch and commit hash, or `PENDING` before the parent commit exists.
17. Owner deployment and verification commands when board testing is required.

Do not fill the report with unnecessary raw logs. Include concise excerpts and paths to complete logs where useful.

## Present Condition

The ZCU104 is not connected to this workspace. The owner accesses a separate board-connected machine through UltraViewer.

Agents may modify and review approved files in `DATN_RTL/RTL/`, testbenches, and `llama.cpp/`, but must not attempt Linux board access, programming, UIO probing, or hardware execution here.

The owner deploys `fpga_host.cpp`, bitstreams, and other required artifacts; runs the primary and diagnostic commands; and returns logs and results. Provide reproducible commands and distinguish local simulation, report inspection, and owner-provided hardware evidence. Never claim hardware success before the required owner results arrive.

## Agent-Specific Safety

- Read `rules.txt` and `plan_maker_rules.txt` before work when present.
- Preserve unrelated local changes.
- Report every edited file.
- Distinguish simulation evidence from synthesis, timing, and on-board validation.
- Do not broaden the task scope silently.
- Do not use CPU fallback as proof that FPGA execution is correct.
- Do not count repaired, clamped, canonicalized, or substituted output as proof of raw hardware correctness.
- Do not update parent submodule pointers merely because newer child commits exist; only record reviewed commits required by the active task.

## Multi-Agent Cooperation Protocol

When the user asks for subagents, parallel review, or the project cooperation workflow, the root agent must orchestrate the project agents in this order:

1. **Baseline:** Read the active task, latest known-problem file, owner logs, relevant source, and read-only Vivado reports. Record parent and child branches, child commit hashes, host version, protocol/bitstream ID, command, evidence level, and exact task boundary.
2. **Inspect first:** Spawn the applicable read-only inspector before any production edit. Use `host_safety_inspector` for host/driver safety, `rtl_performance_reviewer` for RTL architecture/performance, and `integration_acceptance_inspector` for cross-layer numerical or protocol changes. Inspectors return `ACCEPTED`, `CHANGES_REQUIRED`, or `BLOCKED_BY_EVIDENCE`, with a bounded worker scope.
3. **One writer:** Only after `CHANGES_REQUIRED`, spawn exactly one applicable production worker: `host_driver_worker`, `rtl_datapath_worker`, or `spu_memory_worker`. Do not run concurrent production writers on overlapping files. The worker must stay inside the inspector-approved scope and the task's allowed file list.
4. **Independent test:** After implementation, spawn `host_build_tester` for `llama.cpp` changes or `rtl_xsim_tester` for RTL changes. Use `report_regression_tester` for read-only artifact, timing, utilization, and runtime-KPI comparisons. Tester failures go back to the same worker.
5. **Acceptance loop:** Send the worker diff and tester evidence back to the original inspector and to `integration_acceptance_inspector` when the contract crosses RTL/host boundaries. Repeat worker -> tester -> inspector until `ACCEPTED_FOR_OWNER_TEST`, or report `BLOCKED_BY_BOARD` or `BLOCKED_BY_EVIDENCE` with the exact missing evidence.
6. **Child completion:** Review each changed child repository independently. Commit and push each approved child branch before updating the parent submodule pointer.
7. **Parent completion:** Update only the required submodule pointers, write the result report, review the parent diff, and commit the parent task branch. Do not merge automatically.
8. **Owner verification:** Provide reproducible deployment and primary/diagnostic commands to the owner. Local acceptance never implies ZCU104 acceptance; only owner-returned logs can close the hardware gate.

Coordination rules:

- Parallelize independent read-only inspections, but serialize edits and acceptance decisions.
- The root agent owns the task ledger, relays inspector findings through follow-up tasks, waits for all required evidence, and returns one consolidated status.
- Inspectors and report testers remain read-only. Testers may edit testbench or manual-simulation support only when their agent definition and active task explicitly allow it.
- Never bypass an inspector verdict, silently broaden scope, use CPU fallback as FPGA proof, or count repaired/canonicalized output as hardware correctness.
- Never run synthesis, implementation, bit generation, board programming, UIO probing, or `/dev/mem` access unless the user explicitly authorizes the relevant action and environment.

## Completion Checklist

Before reporting completion, verify:

- The active task specification was followed.
- Parent and child repository states were recorded.
- Only approved files were changed.
- Relevant tests were executed or explicitly marked unavailable.
- Every changed child commit was pushed before the parent pointer update.
- Child diffs and the parent submodule diff were reviewed.
- `.codex/outbox/RESULT-<task-number>.md` was completed.
- Risks and unverified hardware behavior were documented.
- No automatic merge, force-push, cleanup, or destructive Git command was performed.

## Suggested Codex Prompt

```text
Use the repository handoff and Multi-Agent Cooperation Protocol for the active
.codex/inbox task. Read AGENTS.md and the relevant .codex/context files first.
Treat DATN_RTL and llama.cpp as independent Git repositories. Inspect before
editing, allow only one production writer per overlapping scope, run the
independent tester, and return the result to the inspectors until
ACCEPTED_FOR_OWNER_TEST or explicitly blocked. Preserve all unrelated and
untracked files. Commit and push approved child changes before updating the
parent submodule pointers. Write one consolidated result report in
.codex/outbox and do not merge automatically.
```
