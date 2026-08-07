# RESULT-002: TASK-002 Specification Review

Final status: BLOCKED_BY_EVIDENCE

Scope: Read-only review of TASK-002. No production source, RTL, testbench, build configuration, branch, commit, or submodule pointer was changed.

## Task summary

TASK-002 proposes:

1. A host-DRAM packed-weight catalog.
2. VPU and SPU performance counters.
3. P3 qualification.
4. An SPU pipeline.
5. Removal of VPU stop-and-wait serialization.
6. Cross-K accumulation.

The direction for Priorities 1 and 2 is feasible. The exact implementation contract is incomplete. Priorities 4–6 must remain future work.

## Review conclusion

Recommended first implementation:

~~~text
Priority 1: host catalog, writer refactor, host self-test
Priority 2: observation-only RTL counters, snapshot ABI, counter tests
~~~

Confidence:

| Area | Confidence |
|---|---|
| Host catalog direction | Medium-High |
| RTL counter direction | Medium |
| P3 qualification | Medium-Low |
| SPU pipeline | Low |
| VPU overlap redesign | Low |
| Cross-K accumulation | Very Low |

No production implementation was performed. No runtime log was used as acceptance evidence.

## Initial repository state

~~~text
Parent:  main / bd3dfd7533b7f7cef17fd65e2fa03355d61e7e41
RTL:     spu / bd2675cb2e50383dcd3d0d779c59c8fccaaaa003
Host:    main / d33e11f8c12219357c9a44bd894f6b86fc0b9e4e
~~~

The parent and both child repositories contained pre-existing modifications. They were preserved.

## Current workflow

~~~text
Q8_0 tensor
  -> thread-0 FPGA hook
  -> direct pair-interleaved weight pack into DDR WEIGHT_BASE
  -> P2 scale and ACT staging
  -> optional inactive-bank preload
  -> ZDMA to VPU bank
  -> VPU GEMV
  -> raw result stream
  -> SPU Q16 accumulation
  -> host result accumulation
~~~

Evidence:

- [ggml-cpu.c](D:/DOAN/llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1281)
- [fpga_host.cpp](D:/DOAN/llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp:4787)
- [Matrix_Vector_Multiplication.v](D:/DOAN/DATN_RTL/RTL/Matrix_Vector_Multiplication.v:1021)
- [SPU_Q8_Scale_Accum.v](D:/DOAN/DATN_RTL/RTL/SPU_Q8_Scale_Accum.v:157)
- [AXI4_Mapping.v](D:/DOAN/DATN_RTL/RTL/AXI4_Mapping.v:760)

## Intended after-change workflow

~~~text
Q8_0 tensor
  -> build host catalog once
  -> lookup packed tile and FP16 scale bits
  -> copy tile to DDR staging slot 0 or 1
  -> existing P2/P1/ZDMA/VPU/SPU path
  -> host result accumulation

VPU/SPU events
  -> 64-bit counters
  -> AXI snapshot
  -> one host aggregate per graph
~~~

The catalog removes repeated host pair packing. It does not remove the per-tile DDR-to-VPU transfer. Counters measure behavior but do not improve performance.

## Unclear information requiring task amendment

### U-01: Completion scope

TASK-002 contains six priorities but postpones Priorities 4–6.

Unclear:

- Does TASK-002 finish after Priorities 1 and 2?
- Is Priority 3 part of the same acceptance?
- Are Priorities 4–6 design notes only, or implementation requirements?

Needed:

~~~text
TASK-002 completion scope = Priority 1 + Priority 2 only
Priority 3 = separate qualification stage
Priorities 4–6 = future tasks, no implementation in TASK-002
~~~

### U-02: Host catalog memory budget

The task requires packed bytes for every immutable Q8_0 tensor but gives no host-memory limit.

Unclear:

- Maximum catalog bytes.
- Maximum single tensor bytes.
- Whether allocation may fail per tensor.
- Whether the catalog is process-local only.
- Whether the catalog may use virtual memory or memory mapping.

Needed:

~~~text
maximum_catalog_bytes = <value>
maximum_entry_bytes = <value>
allocation_failure_action = <direct_pack | reject_tensor | fatal>
catalog_lifetime = <process | model | graph>
~~~

The workspace does not contain the full Gemma weight file, so exact catalog usage cannot be calculated during this review.

### U-03: Tensor immutability and lifetime

The task says one entry is allowed per immutable tensor. It does not define how immutability is guaranteed.

Unclear:

- Whether tensor pointer and shape are sufficient.
- Whether source contents can be hashed.
- Whether the model mapping remains mapped.
- Whether a catalog entry is invalidated when the model unloads.

Needed:

~~~text
catalog key fields = <explicit list>
source lifetime owner = <model context | tensor allocator | other>
source mutation policy = <forbidden and trusted | hash checked | other>
invalidation event = <explicit event>
~~~

### U-04: Catalog entry schema

The task lists required fields but does not define their exact types or ownership.

Unclear:

- Whether tile descriptors store offsets, pointers, or indices.
- Whether packed bytes use one allocation or one allocation per tile.
- Whether scale bits are global, per tile, or per row/block.
- Whether descriptors remain stable when the catalog grows.

Needed:

~~~text
entry allocation model = <one contiguous allocation | tile allocations>
tile reference = <offset | pointer | index>
scale representation = uint16_t FP16 bits
entry publication state = <building | valid | poisoned | retired>
~~~

The existing fpga_weight_tile_cache_t contains DDR-specific fields such as ddr_off, while the existing cache stores scales as float. Those fields cannot be reused as a host-catalog contract without an explicit conversion.

### U-05: Direct writer refactor

The task requires one writer for normal host memory and mapped FPGA DDR.

Unclear:

- Whether the writer uses a callback, template, overload, or destination object.
- Whether host output is byte-addressed or word-addressed.
- Whether destination alignment is mandatory.
- Whether the DDR destination retains volatile 32-bit stores.

Needed:

~~~text
host destination alignment = <required alignment>
DDR destination operation = <existing volatile writer | new writer>
layout writer interface = <specified interface>
~~~

### U-06: Host self-test invocation

The task requires no board for the byte-layout self-test. The current layout self-test is invoked from fpga_init after hardware mapping.

Unclear:

- Exact executable or test entry point.
- Whether the test runs automatically during a host build.
- Whether it is a standalone C++ test.
- Whether it runs before hardware initialization.

Needed:

~~~text
self-test command = <exact command>
self-test source = <fpga_host.cpp | separate test>
self-test board requirement = none
self-test failure result = <nonzero exit | fatal | test failure>
~~~

### U-07: Self-test data and expected bytes

The task names dimensions but does not define the synthetic Q8 tensor contents.

Unclear:

- Scale bit patterns.
- Quantized byte patterns.
- Expected packed byte generation method.
- Whether the test compares the actual refactored writer against the catalog writer.

Needed:

~~~text
test rows = 1, 2, 255, 256
test blocks = 1, 64
test odd-row case = <explicit tensor shape>
source pattern = <explicit byte formula>
comparison = direct-writer bytes == catalog bytes
~~~

### U-08: DDR staging slot layout

The task requires at most two slots but does not provide exact offsets.

Unclear:

- Slot offsets.
- Alignment.
- Whether slots are inside WEIGHT_BASE..WEIGHT_END.
- Whether each slot is fixed-size or variable-size.
- Whether slot 0 maps permanently to bank 0.

Needed:

~~~text
slot_count = 2
slot_0_offset = <offset>
slot_1_offset = <offset>
slot_alignment = <bytes>
slot_size = <runtime formula>
bank_mapping = <explicit mapping>
~~~

Under the current baseline, a maximum tile is 0x80000 bytes and two such slots exactly fill the 1 MiB WEIGHT staging window. This must be enforced against runtime hardware limits.

### U-09: Staging ownership and reuse

The task requires no overlap with an active ZDMA read but does not define the ownership protocol.

Unclear:

- Which state means CPU may write a slot.
- Which state means ZDMA owns a slot.
- Which state means the VPU bank owns copied data.
- How a failed preload releases the slot.
- How cleanup handles a busy slot.

Needed:

~~~text
slot states = <FREE, CPU_WRITING, READY, DMA_READING, BANK_OWNED, ...>
owner transition before copy = <explicit rule>
owner transition after ZDMA = <explicit rule>
failure transition = <explicit rule>
cleanup rule = <explicit rule>
~~~

### U-10: DDR safety validation

The task requires every physical range to satisfy [0x70000000, 0x80000000). The current ddr_range_fits() primarily checks mapped size.

Unclear:

- Which helper performs the physical-range proof.
- Whether all existing DDR helpers must change.
- Whether catalog staging checks both mapped and physical limits.
- Whether overflow failure is fatal or returns an error.

Needed:

~~~text
physical range helper = <name or exact rule>
overflow action = <return false | fatal>
validation required before = <map, pack, copy, ZDMA submit>
~~~

### U-11: DDR coherency sequence

The task does not state whether a host catalog copy must use the current P2 DSB/readback sequence.

Needed:

~~~text
host-to-DDR operation = <exact operation>
coherency barrier = <exact operation>
readback required = <yes/no and reason>
DMA may start after = <exact condition>
~~~

### U-12: Scale behavior

The task requires FP16 weight-scale bits in the catalog but does not define reuse rules for every mode.

Unclear:

- P2 scale layout on a catalog hit.
- P3 scale layout on a catalog hit.
- Whether scale bits copy byte-for-byte without conversion.
- Whether the first implementation supports P2 only.

Needed:

~~~text
Priority 1 supported mode = <P2 only | P2 and P3>
scale source = catalog FP16 bits
scale conversion = none
P3 interaction = <disabled and rejected | supported separately>
~~~

### U-13: Catalog corruption

The task says fail closed but does not define the corruption test.

Unclear:

- Header or metadata checksum.
- Packed-byte checksum.
- Source-content checksum.
- Detection time.
- Action after detection.

Needed:

~~~text
corruption check = <explicit fields and checksum>
check time = <build | every hit | diagnostic mode>
corruption action = <fatal | reject tensor | no DMA and return failure>
direct-pack fallback on corruption = forbidden
~~~

### U-14: Feature-gate behavior

The task adds FPGA_HOST_WEIGHT_PREPACK=1 and says the default is disabled.

Unclear:

- Whether disabled mode increments host_prepack_fallbacks.
- Whether allocation failure disables the feature globally or only for one tensor.
- Whether a catalog build failure can retry.
- Whether the gate applies to P2 only.

Needed:

~~~text
gate default = 0
disabled behavior = <direct pack without fallback count | other>
allocation failure scope = <tensor | process>
retry policy = <never | once | other>
~~~

### U-15: Host telemetry semantics

The required fields are host_prepack_builds, host_prepack_hits, host_prepack_misses, host_prepack_build_us, host_prepack_copy_us, host_prepack_bytes, and host_prepack_fallbacks.

Unclear:

- Tensor count or tile count.
- Per-token or per-graph accumulation.
- Whether host_prepack_bytes means catalog bytes or copied bytes.
- Whether build time includes scale extraction and allocation.
- Whether copy time includes DDR synchronization.

Needed:

~~~text
counter unit = <tensor | tile | token | graph>
host_prepack_bytes meaning = <catalog bytes | copied bytes>
build_us boundary = <explicit start/end>
copy_us boundary = <explicit start/end>
fallback definition = <explicit condition>
~~~

### U-16: Catalog-hit timing invariant

The task says a hit must not increase prep_direct_weight_pack_us.

Unclear:

- Whether the timing field must remain exactly unchanged.
- Whether catalog construction time is recorded as weight_pack_us.
- Whether the first-use build is a miss or a build only.

Needed:

~~~text
catalog build timing field = <host_prepack_build_us | weight_pack_us | both>
catalog hit direct-pack increment = exactly 0
first-use classification = <miss + build | build only>
~~~

### U-17: RTL register-map baseline

TASK-002 states that AXI4_Mapping.v uses registers through 0x0268. The checked-in RTL has explicit registers through 0x021C. No checked-in RTL or testbench reference to 0x0268 exists.

Needed:

~~~text
correct last existing register = <value>
new performance base = 0x0270 or <value>
reserved offsets = <complete list>
~~~

### U-18: Performance ABI

The task requires a performance ABI signature but does not define its value or compatibility policy.

Needed:

~~~text
performance ABI signature = <32-bit value>
ABI version = <value>
counter count = <value>
host mismatch behavior = <ignore | disable counter reads | fail closed>
~~~

### U-19: Counter snapshot behavior

Paired low/high registers require an atomic snapshot rule.

Unclear:

- Live or snapshot source.
- Snapshot capture timing.
- Snapshot register address.
- Clear ordering.
- Counter update during snapshot.

Needed:

~~~text
snapshot write address = <offset>
snapshot action = latch all counters on accepted write
read source = latched snapshot
clear write address = <offset>
clear affects = <live counters | snapshot | both>
~~~

### U-20: VPU counter predicates

The task clearly identifies most signals but does not define all predicates.

Already precise:

~~~text
total_busy_cycles       = busy
read_issue_cycles       = can_issue_read
pmau_input_fire_cycles  = pmau_input_fire
wait_result_cycles      = state_r == S_WAIT_RESULT
raw_stream_hold_cycles  = state_r == S_RAW_STREAM_HOLD
spu_backpressure_cycles = spu_raw_valid && !spu_raw_ready
~~~

Unclear:

~~~text
input_pipeline_stall_cycles
result_drain_cycles
~~~

Needed:

~~~text
input_pipeline_stall predicate = <exact Boolean expression>
result_drain predicate = <exact Boolean expression>
~~~

### U-21: SPU counter predicates

The task requests accepted_entries, busy_cycles, idle_cycles, accumulation_completions, and input_reject_cycles.

Unclear:

- Whether accepted_entries means start && state_r == S_IDLE.
- Whether busy_cycles and idle_cycles count continuously or only between graph clear and snapshot.
- Whether entry_done with an error is a completion.
- Whether input_reject_cycles means start && busy.
- Whether production wrapper behavior can generate that rejection.

Needed:

~~~text
accepted_entries predicate = <exact expression>
busy_cycles predicate = <exact expression>
idle_cycles predicate = <exact expression>
accumulation_completions predicate = <exact expression>
input_reject predicate = <exact expression>
~~~

### U-22: Counter reset, clear, and interval

The task requests reset and a clear-all write but does not define the measurement interval.

Needed:

~~~text
reset value = 0
clear trigger = <MMIO write and exact bit>
clear allowed while busy = <yes/no>
host graph sequence = <clear before graph, snapshot after graph>
idle counting outside graph = <yes/no>
~~~

### U-23: Counter saturation

The task requires 64-bit saturation but does not specify whether saturation is per counter and whether a saturation flag is required.

Needed:

~~~text
counter width = 64
maximum = 0xffffffffffffffff
increment at maximum = hold
saturation flag = <required/not required>
~~~

### U-24: RTL signal routing

Counters originate in Matrix_Vector_Multiplication.v and SPU_Q8_Scale_Accum.v, while the register map is in AXI4_Mapping.v.

Unclear:

- Required output ports.
- Whether counters are routed through SPU_Top.
- Whether MY_IP.v or VPU_Top.v must change.
- Whether testbenches read counters through MMIO or direct module ports.

Needed:

~~~text
counter owner = <module>
counter route = <explicit port path>
MMIO read owner = AXI4_Mapping
testbench access = <MMIO | direct ports | both>
~~~

### U-25: RTL test command

The requested Makefile commands are not authoritative for the current workspace. The Makefile uses Linux shell commands, an incomplete VPU source list, and does not run the SPU testbench through all.

Needed:

~~~text
authoritative RTL command =
powershell -ExecutionPolicy Bypass -File D:/DOAN/DATN_RTL/DATN_VIVADO/manual_sim/run_phase2a_vpu_spu_xsim.ps1
~~~

If make remains mandatory, the task must specify the required shell, Vivado path, complete source list, and SPU target.

### U-26: Counter test stimuli

The task requires exact assertions but does not define the stimulus sequence.

Needed:

~~~text
test for S_WAIT_RESULT = <stimulus and expected count>
test for RAW_STREAM_HOLD = <stimulus and expected count>
test for backpressure = <stall injection and expected count>
test for saturation = <counter preload and expected result>
test for reset/clear = <sequence and expected values>
~~~

### U-27: Host build acceptance

The task requests cmake --build build_mem -j2.

Unclear:

- Whether the target is the complete build or llama-cli.
- Whether build_mem must be regenerated.
- Whether the existing Windows Ninja/MinGW configuration is authoritative.
- Whether a boardless host self-test must run as part of the build.

Needed:

~~~text
build working directory = D:/DOAN/llama.cpp
configure command = <exact command or no reconfigure>
build command = <exact command>
target = <all | llama-cli | other>
host self-test command = <exact command>
~~~

### U-28: Priority 1 performance acceptance

The task uses qualitative expectations:

~~~text
direct pack near zero after warm-up
hits > 0
fallback 0
matching token IDs
~~~

Needed:

~~~text
minimum catalog hit rate = <value>
maximum allowed fallback count = <value>
maximum direct-pack time after warm-up = <value>
maximum host catalog memory = <value>
latency acceptance = <value or measurement-only>
~~~

### U-29: P3 boundary

P3 is present in the current host and RTL, but the task does not state whether catalog work may run while P3 is enabled.

Needed:

~~~text
P3 during Priority 1 = disabled and rejected
or
P3 during Priority 1 = supported with separate scale catalog path
~~~

### U-30: Priority 4 SPU pipeline contract

The task gives an initiation-interval target but not a complete pipeline contract.

Needed before Priority 4:

~~~text
measurement window for II <= 2
ready/valid interface definition
metadata pipeline fields
accumulator memory access schedule
rounding and saturation reference model
backpressure test cases
resource/timing acceptance limits
~~~

### U-31: Priority 5 VPU overlap contract

The task identifies the current loop but does not define the replacement buffering protocol.

Needed before Priority 5:

~~~text
result FIFO depth
metadata ownership fields
ordering rule
bank ownership rule
stall behavior
useful_issue_cycles formula
SPU_backpressure_cycles formula
~~~

### U-32: Priority 6 cross-K contract

The task lists FIRST, CONTINUE, LAST, and OUTPUT, but does not define their register or descriptor encoding.

Needed before Priority 6:

~~~text
control-bit encoding
accumulator identity
row and block ordering
reset and error behavior
out-of-order behavior
intermediate-output suppression rule
host result ownership
~~~

### U-33: Owner-board acceptance

The task correctly prohibits agent board access, but it does not give the exact owner command and expected environment for the new catalog and counters.

Needed before board request:

~~~text
deployment files
FPGA_HOST_WEIGHT_PREPACK value
baseline environment variables
counter ABI check
primary owner command
diagnostic command
expected pass lines
expected failure lines
safe DDR range confirmation
~~~

## Minimum information needed before implementation

The following amendment is sufficient to make the first implementation stage concise:

~~~text
1. TASK-002 completion scope:
   Priority 1 + Priority 2 only.
   Priority 3 is separate qualification.
   Priorities 4–6 are future tasks.

2. Catalog:
   maximum_catalog_bytes = <value>
   maximum_entry_bytes = <value>
   catalog_lifetime = <value>
   source_immutability_rule = <value>
   catalog_key_fields = <list>
   allocation_failure_action = <value>

3. Host self-test:
   exact command = <value>
   synthetic tensor pattern = <value>
   expected comparison = direct writer bytes == catalog bytes

4. DDR staging:
   slot_0_offset = <value>
   slot_1_offset = <value>
   slot_size_formula = <value>
   slot ownership states = <value>
   coherency sequence = <value>

5. Catalog failure policy:
   corruption check = <value>
   corruption action = <value>
   disabled behavior = direct pack
   allocation failure behavior = <value>

6. Host telemetry:
   counter unit = <tensor/tile/token/graph>
   bytes meaning = <catalog/copied>
   timing boundaries = <value>
   fallback definition = <value>

7. RTL register ABI:
   actual last existing register = <value>
   performance base = <value>
   signature = <value>
   snapshot offset = <value>
   clear offset = <value>
   complete low/high register list = <value>

8. Counter predicates:
   input_pipeline_stall = <Boolean expression>
   result_drain = <Boolean expression>
   SPU accumulation completion = <Boolean expression>
   SPU input reject = <Boolean expression>
   clear/snapshot interval = <value>

9. Validation:
   host build command = <value>
   host self-test command = <value>
   authoritative XSim command = <value>
   exact counter stimuli = <value>
   owner-board command = <value>
~~~

## Recommended safe defaults if the task owner wants the agent to choose

These are recommendations, not verified task requirements:

~~~text
completion scope = Priority 1 + Priority 2
catalog lifetime = model lifetime
catalog allocation = lazy, one stable entry per tensor
catalog corruption = no DMA, reject tensor, no direct fallback
allocation failure = direct-pack fallback for that tensor
disabled feature = normal direct pack, not counted as a failure
catalog mode = P2 only
staging slots = two fixed slots inside WEIGHT_BASE..WEIGHT_END
counter reads = snapshot then paired low/high reads
counter interval = clear before graph, snapshot after graph
RTL acceptance = canonical manual XSim script
board request = only after host build and XSim pass
~~~

## Risks if implementation starts without clarification

1. The catalog can consume unbounded host memory.
2. A stale catalog can silently use old tensor bytes.
3. CPU writes can overlap a ZDMA source read.
4. The host can read inconsistent 64-bit counter values.
5. Host and RTL can use different register offsets.
6. Counter reports can be numerically correct but semantically misleading.
7. The Makefile can report an incomplete test result.
8. P3 can accidentally be combined with an unqualified catalog path.
9. Future pipeline work can invalidate implicit current staging ownership.
10. Performance claims can be made without a defined acceptance threshold.

## Implementation summary

No production implementation was performed.

Only the requested result report was added:

| File | Previous behavior | New behavior | Reason |
|---|---|---|---|
| .codex/outbox/RESULT-002.md | No TASK-002 review handoff existed | Records verified state, unclear requirements, requested amendments, risks, and acceptance needs | Provides the owner with a precise clarification checklist |

No source function, RTL module, register, address, ABI, datatype, memory owner, synchronization primitive, or execution schedule was changed.

## Commands executed

Read-only commands included:

~~~text
git status --short --branch
git rev-parse HEAD
git ls-tree HEAD DATN_RTL llama.cpp
git -C DATN_RTL status --short --branch
git -C DATN_RTL rev-parse HEAD
git -C llama.cpp status --short --branch
git -C llama.cpp rev-parse HEAD
rg
Get-Content
Get-ChildItem
Select-String
~~~

External protocol sanity checks used:

- AMD AXI4-Stream documentation for the TVALID and TREADY transfer rule.
- Published FPGA inference work describing reuse of transferred weight matrices across input samples.

Not executed:

~~~text
cmake --build build_mem -j2
make -C DATN_RTL/TESTBENCH tb_vpu
make -C DATN_RTL/TESTBENCH all
run_phase2a_vpu_spu_xsim.ps1
board deployment
ZDMA access
/dev/mem access
UIO probing
runtime log acceptance
~~~

Reasons:

- The request was specification review and report generation.
- No production implementation was authorized.
- The ZCU104 is not connected to this workspace.
- Existing owner changes and generated artifacts were preserved.

## Repository commit state

~~~text
DATN_RTL branch/commit: spu / bd2675cb2e50383dcd3d0d779c59c8fccaaaa003
llama.cpp branch/commit: main / d33e11f8c12219357c9a44bd894f6b86fc0b9e4e
parent branch/commit: main / bd3dfd7533b7f7cef17fd65e2fa03355d61e7e41
new child commit: none
new parent commit: none
~~~

## Next action

The owner should amend TASK-002 with the minimum information listed above. Implementation should begin only after the catalog contract, staging ownership, counter ABI, counter predicates, and authoritative validation commands are explicit.
