# Hướng dẫn tích hợp, kiểm thử và nghiệm thu

## 1. Nguyên tắc bằng chứng

| Claim | Bằng chứng tối thiểu |
|---|---|
| RTL đúng chức năng | Focused XSim pass |
| Host compile/integration | FPGA-enabled build và call-site review |
| Timing/resource | Fresh routed Vivado report |
| GEMV đúng trên PL | Exact host/bitstream ABI + tensor contract |
| Model đúng | Logits/token A/B và output hợp lệ |
| 2.5 token/s | Owner-run trên ZCU104, >=64 decode token |

Không dùng simulation để tuyên bố board speed. Không dùng một câu output đúng để chứng minh mọi tensor đúng. Không dùng average che p95 hoặc các token outlier.

## 2. Artifact manifest bắt buộc

Mỗi owner-run lưu:

```text
date/time/timezone
git/source revision hoặc source archive hash
host SHA256
bitstream SHA256
model SHA256
device-tree/boot artifact identity
FPGA clock
UIO name/physical address/size
host version
protocol/bitstream/P2/P3 ABI
all FPGA_* environment variables
full command
```

Run thiếu manifest chỉ dùng để chẩn đoán, không dùng làm milestone acceptance.

## 3. Baseline command

Owner chạy trên máy nối ZCU104:

```bash
sudo env \
  FPGA_TOKEN_TIMING=1 \
  FPGA_BOTTLENECK_SUMMARY=1 \
  FPGA_STAGE_TIMING=1 \
  FPGA_LOG_FLUSH_EVERY=256 \
  ./build_mem/bin/llama-cli \
    -m ./models/gemma-3-1b-it-Q8_0.gguf \
    -cnv \
    -p "Please write about AI" \
    --single-turn \
    --temp 0 \
    -n 64
```

Đo performance không bật per-tile trace, deep contract hoặc flush mỗi dòng vì các chế độ đó làm sai latency.

## 4. Numerical ladder

Mỗi feature đi qua đúng thứ tự:

1. Host/layout self-test.
2. RTL unit test.
3. Single tile contract.
4. Full matrix contract.
5. Selected layer outputs.
6. Final logits.
7. Deterministic token IDs.
8. Long language output.

### Tensor bắt buộc

```text
blk.0.attn_q.weight       K1152 N1024
blk.0.attn_k.weight       K1152 N256
blk.0.attn_v.weight       K1152 N256
blk.0.attn_output.weight  K1024 N1152
blk.0.ffn_gate.weight     K1152 N6912
blk.0.ffn_up.weight       K1152 N6912
blk.0.ffn_down.weight     K6912 N1152
```

Lặp lại ít nhất một middle layer và layer 25. Vocab chỉ qualify riêng khi quyết định bỏ CPU bypass.

### So sánh

Mỗi report ghi:

```text
max_abs_error
max_rel_error
RMSE
nonfinite_count
first_bad_index
CPU value / FPGA value
```

Tolerance phải được chốt trước test. Không tăng tolerance sau khi thấy failure nếu chưa giải thích rounding/quantization contract.

## 5. Host build gate

```bash
cmake -S llama.cpp -B llama.cpp/build -DGGML_USE_FPGA=ON
cmake --build llama.cpp/build --target llama-cli -j2
```

Pass khi:

- Build exit 0.
- Không warning mới liên quan signedness, overflow hoặc format.
- `fpga_try_matmul_extended()` chỉ được gọi bởi owner thread.
- Return code giữ đúng `HANDLED/NOT_HANDLED/CPU_SHADOW` contract.

## 6. RTL simulation gate

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim
.\run_phase2a_vpu_spu_xsim.ps1
```

Mỗi performance feature phải thêm focused case trước full regression:

| Feature | Focused case |
|---|---|
| SPU II pipeline | back-to-back 64 blocks, same row |
| Continuous VPU | 256×64, no bubble expectation |
| Backpressure | randomized ready low |
| Cross-K | 64+64+64+24 |
| P3 preload | two banks, asymmetric delays |
| Descriptor chain | missing/duplicate/out-of-order reject |
| Counter snapshot | atomic low/high read |

Pass khi exit code 0, explicit `TEST PASSED`, fail count 0 và không `Fatal`.

## 7. Synthesis/implementation gate

Owner chạy synthesis/implementation sau khi XSim pass. Thu thập:

```text
timing_summary_routed.rpt
utilization_placed.rpt
route_status.rpt
drc_routed.rpt
power_routed.rpt
```

Acceptance:

```text
WNS >= 0
TNS = 0
WHS >= 0
THS = 0
fully routed
route errors = 0
resource <= device capacity
```

Current comparison point:

```text
WNS +0.417 ns
WHS +0.009 ns
LUT 19,277
FF 23,853
BRAM 104.5
URAM 64
DSP 124
```

## 8. Board safety gate

Trước mỗi ABI/memory-map mới:

1. Dừng mọi process đang dùng MY_IP/ZDMA.
2. Xác minh FPGA manager state và clock.
3. Xác minh UIO physical address, offset và size.
4. Xác minh reserved DDR không chồng `/proc/iomem` System RAM.
5. Xác minh packed catalog nằm hoàn toàn trong reserved range.
6. Xác minh ZDMA source/destination 64-bit range và alignment.
7. Chạy một transfer self-test nhỏ trước model run.

Nếu kernel báo external abort, SMMU/IOMMU fault, bus error hoặc DMA timeout, dừng test. Không tăng timeout để che lỗi mapping/liveness.

## 9. A/B matrix theo phase

| Run | Feature | Mục tiêu |
|---|---|---|
| A0 | CPU-only | numerical reference |
| A1 | P2 production | current baseline |
| B1 | P3 split scale | scale correctness/traffic |
| B2 | packed resident weight | bỏ host packing |
| B3 | long descriptor | giảm setup overhead |
| B4 | SPU II pipeline | giảm backpressure |
| B5 | continuous VPU | tăng useful issue |
| B6 | P3 preload ping-pong | overlap transfer/compute |
| B7 | cross-K accumulation | giảm result/host partial |
| B8 | optional vocab FPGA | full-logits/top-k contract |

Mỗi B run chỉ thay một feature so với accepted run trước. Không bật đồng thời ba feature chưa qualify.

## 10. Performance report schema

Mỗi token summary cần:

```text
token_wall_ms
outside_fpga_ms
accelerator_span_ms
matmul_wall_ms
exposed_prepare_ms
weight_pack_ms
scale_pack_ms
act_pack_ms
weight_dma_ms / bytes / descriptors
scale_dma_ms / bytes / descriptors
result_dma_ms / bytes / descriptors
ip_compute_ms
host_result_ms
vpu_runs
preload_attempt/admit/late
bank idle/starvation
VPU/SPU cycle counters
fallback count and reason
```

Aggregate:

```text
count
mean
p50
p95
p99
min/max
first-token excluded/included policy
```

## 11. Gate theo milestone

### M1 - Static preparation removed

```text
weight pack <=10 ms/token
scale prep <=20 ms/token
cache/catalog hit >=99.9%
same token IDs
```

### M2 - Datapath efficient

```text
tile 256×64 <=25,000 cycles
IP compute <=160 ms/token
SPU backpressure <=5%
same tensor outputs
```

### M3 - Streaming critical path

```text
effective payload bandwidth >=2.4 GB/s
accelerator span <=290 ms
preload admission >=95%
no cross-K partial result
```

### M4 - Final goal

```text
p50 <=380 ms/token
p95 <=400 ms/token
>=64-token measured throughput >=2.5 token/s
500-token soak no error/fallback
```

## 12. Failure triage

| Triệu chứng | Kiểm tra đầu tiên |
|---|---|
| Tensor mismatch | layout, scale bank, row/block metadata |
| Chỉ FFN down sai | FIRST/CONTINUE/LAST và accumulator context |
| Token đúng nhưng chậm | critical path và counter stall |
| DMA nhanh nhưng compute chậm | PMAU issue/SPU backpressure |
| Compute nhanh nhưng token chậm | host prep, memory stream, CPU vocab |
| Sporadic outlier | scheduler, log flush, OS preemption, thermal |
| Board hang | MMIO/UIO/range/ZDMA ownership trước RTL arithmetic |
| Timing fail | exact critical path, không giảm clock trước khi xem pipeline |

## 13. Rollback

Mỗi ABI mới phải giữ một accepted compatibility path trong thời gian qualification. Rollback bằng artifact đã hash, không bằng environment override bỏ compatibility gate. Nếu feature mới fail:

1. Lưu exact log/counters.
2. Quay về host+bitstream pair đã accepted.
3. Reproduce bằng focused XSim/host unit test.
4. Không trộn fix correctness với optimization tiếp theo.

## 14. Owner handoff template

```text
Artifact hashes:
Command/environment:
FPGA identity/ABI:
UIO/reserved-memory result:
Numerical gate result:
XSim result:
Timing/resource result:
Board p50/p95 throughput:
Counter summary:
Errors/fallbacks:
Attached logs:
Decision: accept / reject / needs investigation
```
