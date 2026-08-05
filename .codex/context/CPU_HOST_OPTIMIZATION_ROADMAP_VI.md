# Hướng dẫn tối ưu CPU và FPGA host

## 1. Phạm vi

File chính:

- `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp`
- `llama.cpp/ggml/src/ggml-cpu/fpga_host.h`
- `llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c`
- `llama.cpp/src/llama-context.cpp`
- CMake source list tương ứng nếu tách module mới.

Không thay đổi GGML tensor ownership, Q8_0 layout gốc hoặc CPU fallback policy để che lỗi FPGA.

## 2. Contract phải giữ nguyên

```text
src0: Q8_0 immutable weight tensor
src1: F32 activation
dst:  F32 output owned by GGML
decode M=1
Q8 block: 32 values, fp16 scale + 32 int8
P2 layout: pair_interleaved_padded_v2
P2 ABI: 0x50320003
P3 ABI: 0x50330001
```

Host chỉ trả `HANDLED` khi toàn bộ `dst` đã commit đúng. Mọi range, bank, job ID, tensor ID, row tail và K tail phải fail closed.

## 3. Baseline host cần chữa

Một token:

| Thành phần | Baseline |
|---|---:|
| Preparation | khoảng 2275 ms |
| Weight DMA | khoảng 329 ms |
| Scale DMA | khoảng 49 ms |
| Result DMA | khoảng 32 ms |
| Host result read | khoảng 193 ms |
| VPU jobs | 2210 |

`fpga_prepare_q8_tile_job()` đang tạo/stage payload theo tile. `fpga_hw_q8_0_matmul_dma_to_ip_pipelined()` có scheduler hai bank, nhưng primary run không bật input preload. `get_weight_cache_entry()` trả miss vì cache tắt. P3 tồn tại nhưng chưa active.

## 4. H0 - Chuẩn hóa measurement

### File và hàm

- `fpga_host.cpp`: `fpga_token_timing_emit()`, `fpga_try_matmul_extended()`, `fpga_hw_q8_0_matmul_dma_to_ip()`.

### Thay đổi

1. Mọi token summary ghi exact policy: P2/P3, cache/residency, preload, descriptor size, vocab route.
2. Ghi timestamp cho prepare begin/end, DMA begin/end, compute begin/end, drain begin/end.
3. Tách `prepared_cpu_us` khỏi `exposed_prepare_us`; thời gian overlap không được tính hai lần.
4. Ghi p50/p95/p99 sau ít nhất 64 token, không chỉ average.
5. Tách `outside_fpga_ms` thành CPU attention/scalar, vocab projection, GGML scheduling và sampling.

### Pass

- Tổng critical-path interval khớp token wall trong ±2%.
- Không dùng tổng các stage overlap để khẳng định token latency.

## 5. H1 - Qualify P3 split scale

### Hiện trạng

`fpga_init()` đã parse `FPGA_P3_SPLIT_SCALE`; deployed bitstream báo đúng P3 ABI. Tuy nhiên primary run có `requested=0 active=0`.

### Việc cần làm

1. Dùng P3 contract mode trên một tile, bao gồm odd row/tail block.
2. A/B toàn matrix cho attention, gate/up và FFN down.
3. So sánh final logits với CPU.
4. Chạy deterministic `--temp 0 -n 4`, sau đó `-n 64`.
5. Chỉ đổi production default sau tất cả gate.

### Lưu ý

Host hiện cấm P3 với input preload và P2 residency. Không xóa check này. Phải implement payload lifecycle mới trước rồi mới nới điều kiện.

### Pass

```text
scale_bytes giảm từ 87,220,224 B xuống gần 43.6 MB/token
P3 reject/drop/error = 0
token deterministic giống CPU
```

## 6. H2 - Packed-weight catalog bất biến

### Vấn đề

Weight được pack lại mỗi token dù không thay đổi. Cache hiện có chỉ là experiment nhỏ; vùng P2 residency tối đa 16 MiB không chứa được khoảng 665.4 MiB non-vocab packed weight.

### Thiết kế file

Khuyến nghị tách sau khi contract ổn định:

```text
llama.cpp/ggml/src/ggml-cpu/fpga_weight_store.h
llama.cpp/ggml/src/ggml-cpu/fpga_weight_store.cpp
```

Trong giai đoạn đầu có thể giữ implementation trong `fpga_host.cpp` để tránh refactor đồng thời với thay đổi data contract.

### Header bắt buộc

```text
magic
format_version
bitstream_id
p2_or_p3_abi
tensor_id
tensor_shape
row0 / rows
k_block0 / blocks
payload_offset / payload_bytes
weight_scale_offset / scale_bytes
payload_crc32
source_fingerprint
sealed_epoch
```

### Trình tự

1. Sau model load, duyệt 182 non-vocab Q8 tensors được offload.
2. Pack pair-interleaved một lần.
3. Pack hoặc preconvert weight scale một lần.
4. Ghi vào vùng DDR dành riêng, căn chỉnh ít nhất 64 byte và theo yêu cầu burst.
5. Tính CRC khi seal.
6. Tạo hash table theo `{tensor pointer, shape, layout, ABI}`.
7. Decode chỉ lookup physical offset.
8. Không CRC toàn payload trên mỗi hit; chỉ kiểm tra header/seal, hoặc sampling verification theo debug policy.

### Vùng nhớ

```text
non-vocab weight payload: 697,761,792 B
P3 weight scales:         khoảng 43.6 MB
headers/alignment/staging: cần margin
recommended reservation: >= 768 MiB
```

Current low reserved range 256 MiB và map 4 MiB không đủ. Host phải từ chối full residency nếu sysfs UIO size nhỏ hơn catalog requirement.

### Pass

```text
catalog build = một lần/model
lookup hit >= 99.9% sau warm-up
direct weight pack <= 10 ms/token
CRC mismatch = 0
source tensor mutation = 0
```

## 7. H3 - Descriptor và DMA efficiency

### File và hàm

- `fpga_host.cpp`: `fpga_dma_copy()`, `fpga_dma_copy_one()`, `fpga_prepare_q8_tile_job()`, `fpga_submit_q8_tile_job()`.

### Thay đổi

1. A/B `FPGA_ZDMA_MAX_TRANSFER_BYTES` tại 64, 128, 256 và 512 KiB.
2. Mỗi test ghi descriptor count, bytes, DMA p50/p95 và ZDMA error registers.
3. Coalesce transfer chỉ khi source/destination contiguous và không vượt IP memory window.
4. Không gộp ACT, WEIGHT và SCALE nếu địa chỉ đích không liên tục hoặc ownership khác nhau.
5. Khi weight resident, `job.weight_src_off` trỏ trực tiếp catalog; không copy qua scratch payload trung gian.

### Pass

```text
weight DMA effective >= 2.4 GB/s ở long tiles
descriptor overhead <= 20 ms/token
ZDMA timeout/error = 0
```

Nếu descriptor lớn không cải thiện bandwidth, giữ 64 KiB và chuyển trọng tâm sang overlap/AXI path; không tăng size vô hạn.

## 8. H4 - P3-compatible preload

### Vấn đề

Primary scheduler có hai bank nhưng `FPGA_P2_INPUT_PRELOAD=0`. P3 hiện serialize scale transfer và cấm preload. Hai feature phải có một lifecycle chung.

### Thiết kế job

```text
PREPARING
  -> ACT_READY
  -> WEIGHT_READY
  -> WEIGHT_SCALE_READY
  -> ACT_SCALE_READY
  -> READY
  -> COMPUTING
  -> OUTPUT_READY
  -> RETIRED
```

### Thay đổi

1. Mở rộng `fpga_tile_job_t` với readiness bitmask và immutable source offsets.
2. `fpga_prepare_q8_tile_job()` chỉ tạo metadata và dynamic activation payload.
3. Preload ACT + required scales + nonresident weight vào inactive bank.
4. Commit descriptor `READY` bằng một write cuối sau memory fence.
5. Compute bank không được nhận bất kỳ DMA write nào.
6. `fpga_wait_and_drain_q8_tile_job()` retire output độc lập với preload bank kia.
7. Giữ exact job/tile/bank ID trên mọi transition.

### Pass

```text
preload admission >= 95% eligible jobs
terminal_before_preload <= 1%
bank mismatch = 0
compute starvation <= 5%
```

## 9. H5 - Logical matrix descriptor và cross-K lifecycle

### Mục tiêu

FFN down có 216 Q8 blocks và hiện chạy bốn K-chunk cho mỗi row tile. Host phải mô tả một logical row tile, không xử lý bốn output riêng.

### Descriptor

```text
matrix_id
tensor_id
token_id
row0 / rows
total_k_blocks
chunk_k_block0 / chunk_blocks
FIRST / CONTINUE / LAST
OUTPUT_ENABLE
accum_context_id
```

### Host behavior

1. `FIRST`: cấp context, clear accumulator.
2. `CONTINUE`: không schedule result DMA.
3. `LAST`: schedule một final output DMA.
4. Host không cộng partial vector.
5. Context chỉ được reuse sau exact `LAST` completion.

### Pass

- FFN down result jobs `520 -> 130` hoặc ít hơn.
- `host_accum_ms` cho K partial bằng 0.
- Result bytes FFN down giảm khoảng 75%.

## 10. H6 - CPU remainder và vocabulary projection

### Hiện trạng

`should_bypass_vocab_projection_to_cpu()` giữ tensor `N >= 65536` trên CPU. Đây là policy correctness có chủ ý.

### Quyết định

Giữ vocab CPU cho đến khi accelerator graph span <= 290 ms. Sau đó:

1. Đo riêng CPU vocab wall time.
2. Kiểm tra thread count, Q8 repack path và NUMA không áp dụng trên A53.
3. Nếu CPU remainder <= 90 ms, không offload vocab.
4. Nếu vượt gate, qualify FPGA vocab bằng full-logits A/B.
5. Sau correctness, cân nhắc PL top-k để giảm output 262,144 logits.

Không bật `FPGA_ACCELERATE_VOCAB=1` chỉ để tăng speed khi chưa có logits contract.

## 11. H7 - Tách monolith sau khi đạt gate

`fpga_host.cpp` đã lớn và trộn safety, DMA, packing, scheduler, contract và profiling. Chỉ refactor sau khi behavior ổn định:

```text
fpga_mapping.*       UIO/range/lifecycle
fpga_zdma.*          DMA descriptor/completion
fpga_weight_store.*  immutable packed catalog
fpga_scheduler.*     job/bank ownership
fpga_contract.*      numerical verification
fpga_profile.*       counters/timing
```

Mỗi bước tách phải là mechanical change với output A/B giống hệt; không refactor đồng thời với ABI mới.

## 12. Host test matrix

| Test | Mục tiêu |
|---|---|
| Packed layout unit test | byte order, odd row, tail block |
| Catalog overflow | fail trước write |
| CRC/seal corruption | reject exact tile |
| Descriptor 64-512 KiB | no error, equal payload |
| PING/PONG randomized delay | ownership đúng |
| P3 + preload | scale bank đúng |
| Cross-K FIRST/CONT/LAST | một final output |
| CPU/FPGA tensor A/B | tolerance pass |
| `--temp 0 -n 64` | token deterministic |
| 500-token soak | no leak/error/fallback |

## 13. Hoàn thành CPU/host side

```text
static packing <= 10 ms/token
scale preparation <= 20 ms/token
descriptor overhead <= 20 ms/token
exposed preparation <= 20 ms/token nhờ overlap
host result read <= 10 ms/token
CPU outside accelerator <= 90 ms/token
```

Các KPI chỉ pass khi lấy từ exact owner-run, không suy ra từ local build.
