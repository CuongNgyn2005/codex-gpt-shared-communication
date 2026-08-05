# Roadmap đạt 2.5 token/s trên ZCU104

## 1. Mục tiêu và điều kiện nghiệm thu

Mục tiêu production:

```text
decode p50 <= 380 ms/token
decode p95 <= 400 ms/token
throughput dài hạn >= 2.5 token/s
output/logits đạt numerical contract
không CPU fallback ngoài vocab projection đã khai báo
không ZDMA, SPU, descriptor hoặc bank error
```

Kết quả chỉ được công nhận sau owner-run trên ZCU104 với SHA256 của binary, bitstream, model và exact command. Local XSim hoặc routed report không phải bằng chứng tốc độ phần cứng.

## 2. Baseline production

| Chỉ số | Baseline 02/08/2026 |
|---|---:|
| Decode | 3907.37 ms/token |
| Throughput | 0.26 token/s |
| Decode tokens | 715 |
| Q8 GEMV/token | 182 |
| VPU runs/token | 2210 |
| STAGE wall/token | khoảng 3755 ms |
| Host preparation | khoảng 2275 ms |
| IP compute | khoảng 1283 ms |
| Host result read | khoảng 193 ms |
| Weight/token | 697,761,792 B |
| Scale/token | 87,220,224 B |
| Result/token | 8,785,920 B |

Output đã đúng ngôn ngữ. P2 PL-scale và ping-pong scheduler bật, nhưng input preload, weight cache và residency tắt. Vocab projection chạy CPU.

## 3. Điều kiện khả thi

Weight INT8 không thể được giữ toàn bộ on-chip. Mỗi token phải đọc ít nhất khoảng 697.8 MB weight offloaded. Ở 2.5 token/s:

```text
minimum weight bandwidth = 697,761,792 × 2.5
                         = 1.744 GB/s
```

Sau split-scale, tổng weight + scale dự kiến khoảng 741 MB/token. Với accelerator span 300 ms, memory path phải đạt khoảng 2.47 GB/s. Một AXI 128-bit tại 187.5 MHz có trần 3.0 GB/s, nên mục tiêu chỉ khả thi khi burst efficiency cao và transfer được overlap với compute.

Hai PMAU hiện có peak danh nghĩa:

```text
2 rows × 16 INT8 MAC × 187.5 MHz = 6.0 GMAC/s
```

Khoảng 697.8 MMAC/token cần tối thiểu khoảng 116 ms ở peak. Do đó không cần thêm DSP để đạt 2.5 token/s nếu datapath đạt utilization đủ cao. Current XSim tile chỉ đạt khoảng 9.26% useful issue; control và SPU phải được sửa trước.

## 4. Budget critical path

| Thành phần | Gate cuối |
|---|---:|
| Accelerator graph span | <= 290 ms |
| Exposed host preparation | <= 20 ms |
| Weight + scale stream | <= 280 ms và overlap compute |
| PL compute | <= 160 ms |
| Final result path | <= 10 ms |
| CPU outside accelerator, gồm vocab/attention scalar/sampling | <= 90 ms |
| Token p95 | <= 400 ms |

Các thời gian overlap không được cộng hai lần. Báo cáo phải có timestamp begin/end để dựng critical path.

## 5. Dependency graph

```text
Baseline + numerical contract
        |
        +--> RTL counters --> continuous VPU/SPU pipeline
        |
        +--> P3 qualification --> split scales
        |                              |
        +--> reserved DDR contract --> packed weight store
                                       |
                              preload + long DMA descriptors
                                       |
                              cross-K accumulation
                                       |
                               2.5 token/s gate
                                       |
                          FFN fusion / prefill GEMM
```

## 6. Phase 0 - Khóa baseline và correctness

### Công việc

1. Ghi SHA256 host, bitstream và model.
2. Ghi manifest protocol/ABI/capability.
3. Chạy CPU-only reference cùng prompt, `--temp 0`.
4. Chạy P2 production `-n 64` với token/bottleneck summary.
5. Lưu logits/tensor probe cho Q, K, V, FFN gate/up/down và final logits.

### Pass

- Exact output deterministic ở `--temp 0`.
- Không fallback ngoài vocab được khai báo.
- P2 stream drop/error bằng 0.
- Decode p50 nằm trong ±5% baseline.

## 7. Phase 1 - Đo stall trong RTL và qualify P3

### PL counters bắt buộc

```text
total_cycles
read_issue_cycles
pmau_input_fire_cycles
pmau_wait_cycles
pmau_result_wait_cycles
spu_backpressure_cycles
raw_fifo_full_cycles
scale_read_cycles
scale_accum_active_cycles
result_write_cycles
job_transition_cycles
rows_completed
blocks_completed
```

### P3 gate

P3 đã có trong source và bitstream nhưng chưa active. Chạy P3 contract trước, sau đó A/B `-n 4`, rồi `-n 64`.

### Pass

- P3 logits/tensor đạt tolerance đã chốt.
- Scale bytes giảm gần 50% so với P2 packed scale.
- Không bank-lock/reject/drop/error.
- Counter tile `256×64` giải thích ít nhất 95% total cycles.

## 8. Phase 2 - Loại bỏ preparation tĩnh mỗi token

### Công việc

1. Tạo packed-weight catalog một lần lúc model load hoặc offline.
2. Lưu weight scale tĩnh cạnh packed weight.
3. Cấp vùng reserved DDR riêng tối thiểu 768 MiB nếu vocab vẫn ở CPU.
4. Descriptor decode chỉ tham chiếu physical offset; không repack payload.
5. CRC kiểm tra lúc seal/load, không quét toàn payload mỗi cache hit.

### Pass

```text
prep_direct_weight_pack_ms <= 10 ms/token sau warm-up
prep_scale_pack_ms <= 20 ms/token
packed lookup hit >= 99.9%
source tensor không bị thay đổi
```

Nếu không có vùng DDR đủ lớn, phase này chưa hoàn thành; cache 16 MiB không được báo cáo như full solution.

## 9. Phase 3 - Continuous VPU/SPU throughput

### Công việc

1. Chuyển `SPU_Q8_Scale_Accum` từ FSM bảy bước/entry sang pipeline `II <= 2`.
2. Giữ row accumulator theo context thay vì BRAM read-modify-write cho từng block.
3. Cho `Matrix_Vector_Multiplication` tiếp tục issue block kế tiếp khi block trước đang retire.
4. Dùng tagged result FIFO để giữ `{job, bank, row, block, last, clear}`.
5. FIFO chỉ hấp thụ latency; average consumer throughput phải bằng producer.

### Pass

```text
tile 256×64 <= 25,000 cycles
pmau useful issue >= 75%
spu_backpressure <= 5% total cycles
drop/error = 0
IP compute <= 200 ms/token ở gate đầu
IP compute <= 160 ms/token ở gate cuối
```

## 10. Phase 4 - Streaming, preload và logical jobs

### Công việc

1. Cho P3 scale payload tham gia preload; bỏ xung đột cấu hình P3/preload sau khi RTL/host hỗ trợ đúng.
2. A/B ZDMA descriptor 64/128/256/512 KiB.
3. Giữ hai bank với ownership `FREE -> FILLING -> READY -> COMPUTING -> DRAINING -> FREE`.
4. Descriptor `FIRST/CONTINUE/LAST` giữ accumulator qua toàn bộ K.
5. Chỉ DMA final row vector sau `LAST`.
6. Nếu ZDMA + residency không đạt 2.47 GB/s, thêm PL AXI master hoặc port thứ hai.

### Pass

```text
preload admission >= 95% eligible jobs
compute starvation <= 5%
result transfers của FFN down giảm 75%
host partial accumulation = 0
accelerator graph span <= 350 ms ở gate đầu
accelerator graph span <= 290 ms ở gate cuối
```

## 11. Phase 5 - CPU remainder và vocab

Vocab CPU hiện giữ correctness. Chỉ thay đổi khi `outside_matmul_ms > 90 ms` sau Phase 4.

Thứ tự:

1. Profile CPU vocab projection, attention/KV, graph scheduling và sampler riêng.
2. Tối ưu CPU thread/repack cho vocab nếu đủ.
3. Chỉ bật `FPGA_ACCELERATE_VOCAB=1` sau full-logits A/B.
4. Nếu offload vocab, dùng streaming/top-k để không trả 262,144 logits không cần thiết về CPU.

### Pass

- CPU outside accelerator <= 90 ms.
- Full logits hoặc top-k contract pass.
- Token ID giống CPU ở `--temp 0`.

## 12. Phase 6 - Sau khi đạt decode target

1. Fused gate/up/SiLU/down với activation residency.
2. RMSNorm/RoPE/Softmax từng module, capability chỉ bật sau end-to-end contract.
3. Prefill GEMM để tái sử dụng weight cho nhiều prompt token.
4. TTFT target riêng; không đánh đổi decode correctness.

## 13. Milestone và stop condition

| Milestone | Mục tiêu |
|---|---:|
| M0 | 3.9 s/token, correctness baseline |
| M1 | host static prep < 150 ms/token |
| M2 | IP compute < 250 ms/token |
| M3 | accelerator span < 500 ms/token |
| M4 | p50 < 380 ms, p95 < 400 ms |

Nếu M2 pass nhưng M3 fail, bottleneck là memory/scheduler. Nếu M3 pass nhưng token vẫn trên 400 ms, bottleneck là CPU remainder/vocab. Không mở phase tiếp theo nếu phase hiện tại chưa có counter và numerical gate.

## 14. Decision record

**Recommended action:** bắt đầu bằng P3 qualification và RTL counters; sau đó triển khai packed-weight store đủ dung lượng và continuous SPU/VPU pipeline.

**Rejected now:** tăng clock, tăng row tile 512, thêm PMAU hoặc fuse toàn FFN trước khi sửa II.

**Primary uncertainty:** effective bandwidth của memory path sau khi bỏ host packing và dùng payload resident.

**Evidence thay đổi quyết định:** nếu measured resident ZDMA đạt dưới 2.2 GB/s dù descriptor lớn và burst đúng, chuyển AXI master/dual-port lên trước cross-K/fusion.
