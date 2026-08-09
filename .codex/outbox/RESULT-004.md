# RESULT-004 — P1 Static-Weight Prepack Review

Evidence level: source inspection and owner-provided ZCU104 logs. No code was changed. No local or board test was run for this review.

## 1. Catalog reuse

**PASS**

### Evidence

- The model contains 183 Q8 tensors. One vocabulary tensor uses the configured CPU bypass, leaving 182 eligible tensors.
- Owner telemetry reports `builds=182`, `misses=182`, `hits=27842`, `fallbacks=0`, and model epoch `1`.
- The aggregate counts match one MISS → BUILD → VALID transition for each eligible tensor, followed by catalog HITs.
- The catalog key compares model epoch, tensor pointer, tensor data pointer, tensor type, four dimensions, four strides, and layout.
- Catalog entries remain VALID until model-epoch retirement or cleanup.
- The supplied evidence contains no POISONED, BYPASS_ALLOC, allocation-failure, or repeated-build event.
- Current telemetry does not identify builds by tensor name. Therefore, the aggregate result cannot independently prove that every individual tensor was built exactly once.

### Measured impact

- Unique eligible tensors built: 182 by aggregate telemetry.
- Total builds: 182.
- Total misses: 182.
- Total hits after construction opportunities: 27,842.
- Rebuilds observed: none.
- Unexpected misses observed: none.

## 2. CRC/validation

**FAIL**

### Evidence

For each catalog-served tile, the current path performs approximately:

- four metadata or descriptor validation passes;
- two complete packed-payload CRC scans;
- two scale CRC scans;
- one first-and-last-word DDR readback after staging coherency barriers.

The packed and scale CRC operations read host catalog memory, not volatile FPGA DDR. The DDR verification reads only two 32-bit words per tile.

Across 27,842 jobs, the path performs approximately 222,736 validation or CRC passes, equal to about 17,134 passes per prompt token for the 13-token prompt, excluding catalog construction.

### Measured impact

- Packed payload scanned per build: one full packed payload while the entry is constructed.
- Packed payload scanned per catalog hit: two full scans.
- Aggregate packed bytes scanned on hits: approximately 17.568 GB decimal, or 16.36 GiB.
- Static scale data scanned per scale pass: approximately 523.58 MiB across all jobs.
- Aggregate scale bytes scanned by two passes: approximately 1.02 GiB.
- The earlier scale-validation path consumed `6,821,911.528 us` or about 113.7 minutes.
- Host version v89 reduced `prep_scale_pack_ms` to `21,353.752 ms`, a reduction of approximately 99.687% or 319.47×.
- Redundant packed-payload scanning remains in the catalog-copy path.

## 3. Catalog-to-staging copy

**FAIL**

### Evidence

`fpga_weight_catalog_copy_to_ddr()` performs this sequence for each catalog hit:

1. Validate the destination range.
2. Lock the catalog for the complete copy.
3. Validate catalog metadata.
4. Calculate a CRC over the complete packed payload.
5. Calculate a CRC over the referenced scales.
6. Copy each 16-byte block through four volatile 32-bit DDR stores.
7. Calculate a second packed-payload CRC during that copy.
8. Unlock the catalog.

The inner copy loop does not repeat range validation or memory barriers. Coherency barriers and the first-and-last-word DDR readback occur after the measured copy operation. The source shows no second staging copy of the same tile.

The previous direct-pack path arranged weights while writing them once. The catalog-hit path avoids rearranging weights but adds repeated full-buffer validation scans. The supplied evidence does not contain a same-command direct-pack timing measurement, so a numerical direct-versus-catalog comparison is not available.

### Measured impact

- Catalog `copy_us`: `190,173,577 us`, or 190.174 seconds.
- Average catalog copy time: approximately 6.830 ms per job.
- Effective catalog-copy throughput: approximately 44.1 MiB/s.
- `copy_us` accounts for approximately 85.18% of `prep_ms` and 74.78% of wall time when compared as accumulated durations.
- The durations overlap FPGA execution and must not be added as independent wall-clock costs.
- Weight DMA consumed 4.692 seconds, which is much smaller than catalog copy time.
- Activation packing and coherency together consumed about 80 ms.
- The dominant measured work inside `copy_us` is the repeated host scan plus volatile per-word DDR staging write. Existing telemetry cannot separate those two costs.

## 4. Memory pressure

**FAIL**

### Evidence

- Catalog resident allocation: 741,538,304 bytes, or 707.19 MiB.
- Catalog entries: 182.
- Catalog limit: 1 GiB total and 64 MiB per entry.
- Model mapping: approximately 1,013.54 MiB.
- Compute buffer: approximately 514.25 MiB.
- KV cache: approximately 38 MiB.
- Output buffer: approximately 1 MiB.
- Known memory total: approximately 2,273.98 MiB, or 2.22 GiB, excluding executable code, libraries, allocator overhead, stacks, and other runtime allocations.
- Catalog payloads use fixed allocations stored in a list; catalog growth does not reallocate and copy existing payloads.
- `fallbacks=0` provides evidence that catalog allocations did not fail in the supplied run.
- The supplied evidence does not include `free -h`, `swapon --show`, `vmstat`, process RSS, or major-page-fault counts.
- The largest actual catalog entry is not logged. Only the 64 MiB configured limit is known.

### Measured impact

- P1 adds 707.19 MiB of confirmed resident catalog allocation.
- The known process memory requirement is at least approximately 2.22 GiB.
- Paging, swap activity, and major-page-fault cost cannot be measured from the supplied evidence.
- Memory pressure is possible on the target board but is not proven as the cause of the 113-minute delay.

## 5. Root-cause ranking

1. **CRC/validation overhead.** This is the verified cause of the original approximately 113-minute scale-preparation delay. The v89 scale-span change reduced that stage by approximately 99.687%.
2. **Catalog-to-staging copy cost.** This is the largest remaining measured P1 host cost at approximately 190.174 seconds.
3. **Memory pressure.** P1 adds 707.19 MiB, but the required operating-system memory evidence is unavailable.
4. **Catalog reuse correctness.** Aggregate telemetry matches one build per eligible tensor and shows no rebuild or fallback evidence.
