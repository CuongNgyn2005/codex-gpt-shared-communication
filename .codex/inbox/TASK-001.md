# TASK-001: Inspect Project Architecture

## Status

READY

## Objective

Inspect the parent repository and both submodules. Document the current
CPU-to-PL dataflow without modifying production source code.

## Repositories

- `DATN_RTL`
- `llama.cpp`

## Required investigation

1. Identify the host-side entry points.
2. Identify the SPU and VPU implementations.
3. Identify DMA and DDR transfers.
4. Identify datatype conversions.
5. Identify current CPU and programmable-logic responsibilities.
6. Identify relevant build and runtime commands.
7. Identify hardcoded addresses, frequencies and hardware assumptions.

## Allowed changes

Codex may modify only:

- `.codex/context/ARCHITECTURE.md`
- `.codex/context/KNOWN_PROBLEMS.md`
- `.codex/outbox/RESULT-001.md`

## Prohibited changes

- Do not modify files inside `DATN_RTL`.
- Do not modify files inside `llama.cpp`.
- Do not update submodule pointers.
- Do not merge branches.
- Do not delete files.

## Acceptance criteria

- Current dataflow is documented.
- CPU and PL responsibilities are identified.
- Relevant files and functions are listed.
- Unknown or unverified details are clearly marked.
- `.codex/outbox/RESULT-001.md` is created.
