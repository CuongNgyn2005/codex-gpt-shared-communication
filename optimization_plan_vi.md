# Kế hoạch tối ưu v88 — bản đã khóa hợp đồng kỹ thuật

## 0. Baseline và nguyên tắc acceptance

Baseline host:
- Repository: `CuongNgyn2005/Infrastructure_GEMMA3`
- Commit: `8c24927d0c50b921d19b4e03699a9fbdb773e595`
- Host trace: `zcu104-gemma3-q8-v88-compact-telemetry`

Trước khi thay RTL phải khóa thêm:
- exact RTL commit tạo ra bitstream đang dùng với v88;
- SHA256 của bitstream;
- `BITSTREAM_ID=0x56505532`;
- `STREAM_PROTOCOL=2`;
- `P2_ABI=0x50320003`;
- tần số PL thực tế;
- board ID;
- CPU frequency/governor.

Benchmark acceptance end-to-end cố định:

```bash
sudo ./build_mem/bin/llama-cli \
  -m ./models/gemma-3-1b-it-Q8_0.gguf \
  -p "Please write about AI" \
  -n 8 \
  --single-turn \
  --temp 0
```

Mỗi thay đổi production:
1. chạy 3 process độc lập;
2. trong mỗi run bỏ decode token đầu tiên khỏi thống kê latency;
3. lấy median của 7 decode token còn lại;
4. score cuối = median của 3 median đó;
5. prompt-eval/TTFT báo riêng;
6. cùng board, bitstream, model, build flags, governor/frequency;
7. output `--temp 0` phải deterministic;
8. không CPU fallback ngoài bypass đã chủ đích;
9. stream drop/error = 0.

Một thay đổi có metric nội bộ tốt hơn nhưng median decode xấu hơn baseline thì REJECT/REVERT.

---

# Phase 1 — One-pass SPU_PARAM staging

## Mục tiêu

Loại bỏ pass zero toàn bộ `SPU_PARAM` trước khi ghi scale thực.

P2 hiện ghi entry:

```text
entry[31:16] = weight_scale_fp16
entry[15:0]  = activation_scale_fp16
```

và địa chỉ:

```text
linear = row * group_blocks + gb
word   = linear / 4
lane   = linear % 4

byte_offset = word*16 + lane*4 = linear*4
```

Do đó các entry hữu ích là contiguous 32-bit words.

## Thay đổi

- range-check toàn bộ `SPU_PARAM` một lần;
- lấy một `volatile uint32_t *`;
- ghi `dst[linear] = packed_scale`;
- zero chỉ padding cuối cùng, tối đa 0–3 entry 32-bit;
- giữ nguyên DSB/readback commit trước khi ZDMA đọc;
- không thay đổi P2 ABI, byte order, FP16 scale, DMA, RTL.

## Gate

Functional pass + end-to-end median decode phải tốt hơn v88.

---

# Phase 2 — Benchmark tách weight transform và DDR store

Đây là benchmark chẩn đoán mới; binary/tool dưới đây CHƯA tồn tại ở v88 và phải được tạo trong task Phase 2.

Tên đề xuất:

```text
fpga-host-weight-path-bench
```

## Workload chính xác

Replay đúng sequence của **một decode token v88**:
- 2210 tile jobs;
- giữ nguyên thứ tự tensor;
- giữ nguyên `row0`, `rows`, `k_block0`, `group_blocks`, `group_beats`, `weight_bytes`;
- tổng logical packed weight bytes phải bằng số đo decode v88 của run dùng để capture;
- nguồn Q8_0 phải lấy từ model đã load, không dùng shape tổng hợp thay thế cho benchmark chính.

Trace replay được capture một lần từ production path và sau đó benchmark chỉ replay weight preparation; không DMA/START VPU.

## Warm-up và repetition

Cho từng mode:
- 1 full untimed replay warm-up;
- 5 full timed replays;
- statistic quyết định = median 5 runs;
- đồng thời báo min/max.

Không dùng `drop_caches`.
Không flush CPU cache thủ công.
Warm-up phải prefault source/destination để timed run có `major_faults=0`.
Giữ nguyên CPU affinity policy như production.
Ghi lại governor/frequency trước và sau benchmark; run không hợp lệ nếu frequency thay đổi đáng kể.

Old weight cache/residency phải OFF.

## Ba mode

### A. `pack-cached`

Timed:
- source `block_q8_0` lookup;
- pair-major traversal;
- little-endian packing;
- cùng 2-worker split và helper synchronization như v88;
- output vào normal cached RAM ring >= 64 MiB;
- store cached-RAM cũng nằm trong timed region.

Không timed:
- allocation;
- prefault;
- UIO;
- DMA;
- VPU/SPU;
- logging.

### B. `store-uio`

Timed:
- đọc prepacked bytes từ cached RAM ring >= 64 MiB;
- đúng 4 volatile `uint32_t` stores / 16 source bytes vào `WEIGHT_BASE`;
- exact production CPU->device commit: DSB/fence + bounded first/last-word readback sau mỗi tile.

Không có rearrangement, DMA hoặc VPU START.

### C. `pack-uio`

Timed:
- exact v88 `block_q8_0 -> pair-major -> volatile WEIGHT DDR`;
- cùng 2-worker policy;
- cùng per-tile DSB/readback commit.

Đây là đường production weight-preparation cần giải thích.

## Timed-region exclusions chung

Không bao gồm:
- model load;
- mmap/open;
- `/proc/iomem` preflight;
- memory allocation;
- source generation;
- warm-up;
- page faults do chưa prefault;
- log/printf;
- ACT/SCALE preparation;
- ZDMA;
- VPU/SPU START/poll;
- result read.

Timer dùng monotonic clock. Output tối thiểu:
`mode, replay_jobs, bytes, elapsed_us, MiB/s`,
cộng bucket `<64K`, `64–128K`, `128–256K`, `256–512K`, `>=512K`.

## Decision gate

- store-bound nếu `T_store-uio >= 0.70 * T_pack-uio`;
- transform-bound nếu `T_pack-cached >= 0.50 * T_pack-uio`;
- nếu cả hai đáng kể => mixed.

Không thay kiến trúc trước khi có verdict này.

---

# Phase 3 — Chỉ tối ưu bottleneck mà Phase 2 chứng minh

## 3A — Nếu transform-bound

Giữ direct pack architecture.

A/B:
- parallel threshold 512 KiB;
- 256 KiB;
- 128 KiB.

Chỉ giữ threshold mới nếu end-to-end `-n 8` tốt hơn.

Sau đó mới xét >2 CPU producers, và chỉ nếu producer benchmark chứng minh CPU transform còn dominant.

## 3B — Nếu store-bound

Production mapping vẫn giữ nguyên:
- reserved DDR;
- physical UIO;
- `O_SYNC`;
- `MAP_SHARED`;
- volatile stores;
- DSB + bounded readback;
- không `msync`.

Không đổi sang cacheable/write-combining bằng userspace flag.

Nếu muốn thử mapping mới:
- tạo kernel driver hoặc custom UIO mmap riêng;
- memory attributes phải do driver định nghĩa;
- phải có explicit CPU->device cache-maintenance/commit contract;
- benchmark byte-for-byte readback trước;
- không VPU START trong qualification;
- chỉ thay production sau khi DMA readback và inference A/B cùng PASS.

Không dùng `/dev/mem` làm production P2 mapping.

---

# Phase 4 — Hardware cycle telemetry

## DONE nào là authority?

`REG_STATUS.DONE/core_done` chỉ là GEMV-core completion, KHÔNG phải P2 job completion.

Định nghĩa hai mốc:

### `CORE_DONE`
Cycle core GEMV hoàn tất job và `done_job_id` tương ứng được latch.

### `P2_DONE` — authority cho Phase 4
Cycle đầu tiên sau final SPU_OUT write tại đó tất cả điều kiện cùng đúng:
- VPU raw end-of-stream của đúng job đã được thấy;
- accepted/processed entries = `rows * group_blocks`;
- final SPU writes = `rows`;
- stream FIFO empty;
- cả scale accumulator lanes idle;
- không có SPU_OUT write trong cycle hiện tại;
- drop/error = 0;
- last job ID/bank match;
- stream quiescent.

`JOB_CYCLES = P2_DONE - START`.

`START` là cycle `ctrl_start` được core accept và config/job-id được snapshot.

## PERF ABI đề xuất

Không bump P2 data ABI chỉ để thêm telemetry.

Giữ:
```text
P2 ABI = 0x50320003
```

Thêm read-only:
```text
PERF ABI = 0x50460001   // "PF", v1
```

Register map đề xuất, bắt đầu sau register hiện dùng cuối 0x021C:

```text
0x0220 PERF_ABI          32-bit
0x0224 PERF_SEQ          32-bit
0x0228 PERF_JOB_ID       32-bit
0x022C PERF_FLAGS        32-bit

0x0230 START_CYCLE_LO    32-bit
0x0234 START_CYCLE_HI    32-bit

0x0238 CORE_DONE_LO      32-bit
0x023C CORE_DONE_HI      32-bit

0x0240 P2_DONE_LO        32-bit
0x0244 P2_DONE_HI        32-bit
```

Internal:
- một free-running 64-bit cycle counter;
- các timestamp latch 64-bit;
- clock domain = cùng `AXI4_Mapping.clk` đang clock VPU/SPU;
- không CDC cho ba timestamp trên.

`PERF_SEQ` tăng khi snapshot P2_DONE mới publish.
Host đọc `SEQ -> fields -> SEQ`; nếu SEQ đổi thì retry.

Phải aggregate:
- attention;
- gate;
- up;
- down;
- min/median/max cycles/job;
- total CORE cycles;
- total P2 cycles;
- `P2_DONE-CORE_DONE` để tách SPU drain/finality khỏi GEMV core.

---

# Phase 5 — Adaptive tiling nhưng giữ cố định 4096 result words

## Capacity contract

4096 result words PHẢI giữ cố định trong phase này.

Current result window:
```text
0x00200000 .. 0x00210000
= 64 KiB
```

Mỗi word:
```text
128 bit = 16 byte
```

Nên capacity:
```text
65536 / 16 = 4096 words
```

Mỗi P2 raw result word chứa 4 x INT32:
```text
max result values = 4096 * 4 = 16384
```

Tiler constraint bắt buộc:

```text
rows * group_blocks <= 16384
```

## Source changes bắt buộc trước khi tăng rows

RTL:
- không được tiếp tục suy `RESULT_WORD_DEPTH = MAX_ROWS * MAX_GROUP_BLOCKS / 4`;
- dùng explicit fixed `RESULT_WORD_CAPACITY = 4096`;
- reject config vượt 4096 words.

Host:
- giữ `cap_result_words` đọc từ `REG_CAPS`;
- không overwrite nó bằng `rows * max_blocks / 4`;
- mọi tile phải dùng actual advertised capacity.

SPU:
- tăng `SCALE_ACCUM_ROWS` chỉ đến row capability thật sự cần;
- synthesis/resource/timing bắt buộc vì weight RAM + accumulator RAM tăng theo row capacity.

## Candidate đầu tiên

Gate/up:
```text
rows = 448
group_blocks = 36
values = 16128
words = 4032 <= 4096
```

Down:
```text
rows = 288
group_blocks <= 56
values = 16128
words = 4032 <= 4096
```

Đây chỉ là candidate synthesis; không coi là feasible trước Vivado timing/resource PASS.

Attention ban đầu giữ <=256 rows để giảm regression surface.

---

# Phase 6 — Cross-K accumulation

Phase này không được chỉ nói “cộng partial trong PL”; phải khóa numerical contract.

## P2 scale-accum contract hiện tại phải giữ

Input mỗi entry:
- signed INT32 raw dot;
- activation scale FP16;
- weight scale FP16;
- row ID;
- `clear_accum`;
- `last_block`.

Scale validation:
- negative FP16: reject;
- NaN/Inf: reject;
- zero: hợp lệ.

FP16 -> internal Q0.32:
- subnormal: `frac << 8`;
- normal: `{1,frac} << (exp+7)`.

Scale product:
- multiply full precision;
- nếu high overflow bits set => clamp product-scale thành all-ones 64-bit;
- nếu không => truncate bits `[95:32]`;
- không round-to-nearest.

Contribution:
```text
signed raw * Q0.32_scale_product
>> 16 arithmetic
=> signed Q16.16
```

Accumulator:
- signed 64-bit;
- cộng theo đúng thứ tự block;
- không saturation;
- overflow behavior hiện tại là two's-complement truncation/wrap;
- `clear_accum` chỉ ở block đầu;
- `last_block` chỉ publish output ở block cuối.

## Điểm bắt buộc phải xử lý

v88 hiện chuyển Q16.16 partial của mỗi K-chunk thành F32 rồi cộng ở host.

Do đó:
```text
continuous Q16.16 accumulation across 4 chunks
```
không mặc nhiên bit-identical với:
```text
Q16.16 -> F32 -> F32 add
```

Phase 6 phải chọn một trong hai và ghi rõ ABI:

### Option A — bit-exact v88
Mỗi K-chunk:
1. SPU tạo Q16.16 partial như hiện tại;
2. convert sang IEEE-754 F32 đúng như host cast;
3. F32 accumulate theo đúng chunk order, round-to-nearest-even;
4. chỉ publish F32 cuối sau final chunk.

### Option B — continuous Q16.16
Chỉ được dùng nếu chứng minh bằng exhaustive/corpus A/B rằng rounding khác biệt không ảnh hưởng contract đã chấp nhận.
Đây là numeric ABI mới.

Khi cross-K semantics thay đổi, bump:
```text
P2 ABI v3 -> v4
```
và thêm capability riêng cho cross-K chaining.

---

# Phase 7 — FFN fusion phải giữ exact graph + quantization boundary

v88 graph contract cho parallel gated SiLU FFN:

```text
up   = W_up   * hidden
gate = W_gate * hidden
fused = SiLU(gate) * up
down = W_down * fused
```

FPGA matmul host contract:
```text
weight = GGML_TYPE_Q8_0
activation input = GGML_TYPE_F32
output = GGML_TYPE_F32
```

Trước mỗi FPGA matmul, F32 activation được quantize bằng canonical GGML `quantize_row_q8_0`.

Q8_0 block contract:
- QK = 32;
- `amax = max(abs(x[i]))`;
- `d = amax / 127`;
- `d` lưu FP16;
- `qs[i] = round(x[i] / d)` theo implementation authority của deployed GGML build.

## Production fused path phải tương đương

```text
hidden F32
   ↓
canonical Q8_0(hidden)
   ├──────────────┐
   ↓              ↓
W_gate Q8_0     W_up Q8_0
   ↓              ↓
gate F32         up F32
   └──────┬───────┘
          ↓
exact F32 SiLU(gate) * up
          ↓
canonical Q8_0 quantize fused vector
          ↓
W_down Q8_0
          ↓
down F32
```

Có thể reuse cùng Q8_0(hidden) cho gate và up vì input giống hệt nhau, nhưng bytes phải giống canonical host quantizer.

## Không được dùng SPU_SiLU_Mul hiện tại để production fusion

Module hiện tại:
- input/output signed Q8.8;
- sigmoid là clipped-linear approximation;
- saturate 16-bit.

Nó không tương đương GGML F32 SiLU.
Capability SiLU hiện cũng đang intentionally hidden/clear trong `SPU_Top`.

Phase 7 phải tách:
- 7A: implement/validate F32-compatible SwiGLU + canonical Q8_0 quantizer bridge;
- 7B: chỉ sau matrix/logit A/B PASS mới giữ gate/up intermediate on-chip và nối trực tiếp xuống down.

Không bật capability trước A/B.

---

# Phase 8 — ZDMA descriptor qualification

Baseline production giữ 64 KiB.

Qualification tuần tự:
```text
64 KiB
128 KiB
256 KiB
```

Không nhảy trực tiếp 512 KiB vì project đã có lịch sử corruption.

Mỗi size phải pass:
- exact source/destination physical range;
- byte-for-byte integrity;
- no ZDMA error;
- repeated transfer;
- full inference A/B.

Chỉ sau đó mới giảm descriptor count production.

---

# Phase 9 — Persistent PL-readable weight arena

Đây là hướng dài hạn để bỏ CPU staging gần 698 MB/token.

Không quay lại:
```text
host packed catalog -> copy to staging every token
```

Preferred architecture:

```text
model load
   ↓
pack immutable Q8_0 weight once
   ↓
dedicated persistent DMA-visible physical weight arena
   ↓
per-token:
ZDMA reads directly from persistent arena
   ↓
VPU
```

## Mapping/coherency contract

Không được DMA trực tiếp từ arbitrary llama.cpp virtual pointer/mmap address.

Preferred:
1. boot-time reserved contiguous physical DDR region, excluded from Linux;
2. exact region ownership verified;
3. exposed through dedicated driver/UIO;
4. model packed once into it;
5. explicit CPU->device commit before first use;
6. read-only for inference epoch;
7. ZDMA source uses known physical/DMA address.

Nếu không thể reserve contiguous arena:
- dùng kernel-managed pinned/scatter-gather/SMMU DMA mapping;
- userspace nhận DMA address/handle từ driver;
- không tự suy physical address từ virtual address.

FPD ZDMA không được giả định coherent với CPU cache.
Cacheable/write-combining mapping chỉ được dùng khi kernel driver định nghĩa memory attributes và explicit cache-maintenance contract đã được board-qualify.

Cho tới khi có device-tree/kernel ownership proof mới:
```text
[0x70000000, 0x80000000)
```
là hard safety boundary duy nhất.

---

# Roadmap cuối cùng

```text
Phase 0  Freeze v88 + exact RTL/bitstream provenance
   ↓
Phase 1  One-pass SPU_PARAM
   ↓
Phase 2  Exact weight-path benchmark
   ↓
   ├─ transform-bound → Phase 3A pack parallelism
   └─ store-bound     → Phase 3B mapping qualification
   ↓
Phase 4  Hardware START/CORE_DONE/P2_DONE counters
   ↓
Phase 5  Fixed-4096 adaptive FFN tiling
   ↓
Phase 6  Cross-K accumulation with explicit numeric ABI
   ↓
Phase 7  Exact FFN numerical bridge, then gate/up/SiLU/down fusion
   ↓
Phase 8  ZDMA 64→128→256 KiB qualification
   ↓
Phase 9  Persistent PL-readable weight arena / PL-centric weight streaming
```

Phase 9 có thể được nghiên cứu song song sau khi Phase 2 xác nhận DDR staging là giới hạn lớn, nhưng không được thay production memory map trước khi ownership/coherency qualification hoàn tất.
