# Hướng dẫn tối ưu PL, VPU và SPU

## 1. Phạm vi file

Các file production chính:

- `DATN_RTL/RTL/Matrix_Vector_Multiplication.v`
- `DATN_RTL/RTL/PMAU_Full.v`
- `DATN_RTL/RTL/SPU_Q8_Scale_Accum.v`
- `DATN_RTL/RTL/SPU_Top.v`
- `DATN_RTL/RTL/AXI4_Mapping.v`
- `DATN_RTL/RTL/MY_IP.v`
- `DATN_RTL/RTL/VPU_Top.v`
- `DATN_RTL/TESTBENCH/tb_VPU_Top.v`
- `DATN_RTL/TESTBENCH/tb_SPU_Top.v`

`project_1` chỉ dùng để đọc report. Mọi thay đổi interface Block Design phải được owner thực hiện trong flow Vivado riêng, không sửa generated products.

## 2. Baseline phần cứng

```text
clock                 = 187.5 MHz
NUM_LANES             = 16/PMAU
PMAU instances        = 2 cho paired rows
MAX_ROWS              = 256
MAX_COL_BEATS         = 128
MAX_GROUP_Q8_BLOCKS   = 64
DSP                    = 124/1728
URAM                   = 64/96
BRAM                   = 104.5/312
WNS                    = +0.417 ns
WHS                    = +0.009 ns
```

XSim tile `256 rows × 64 blocks` mất `176,882` cycles. Two-row useful issue minimum là `16,384` cycles. Useful issue efficiency khoảng `9.26%`.

## 3. Root cause RTL đã xác minh

### VPU control

Sau mỗi Q8 block hai beat, `Matrix_Vector_Multiplication.v` đi qua:

```text
S_RUN
 -> S_WAIT_RESULT
 -> S_RAW_STREAM_HOLD
 -> S_RUN cho block tiếp theo
```

Do đó synchronous read pipeline và PMAU thường xuyên drain rồi restart.

### SPU scale

`SPU_Q8_Scale_Accum.v` xử lý một entry tuần tự qua:

```text
S_IDLE -> S_SCALE -> S_PRODUCT_MUL -> S_PRODUCT_CLAMP
       -> S_RAW_MUL -> S_CONTRIB_Q16 -> S_ACCUM
```

Hai accumulator xử lý một row pair, nhưng initiation interval mỗi entry vẫn lớn. FIFO ngăn drop nhưng không tăng average throughput; khi FIFO đầy, VPU phải stall.

## 4. P0 - Thêm performance counters trước khi đổi datapath

### `Matrix_Vector_Multiplication.v`

Thêm saturating 64-bit counters:

```text
total_busy_cycles
read_request_cycles
pmau_input_fire_cycles
pmau_input_stall_cycles
wait_result_cycles
raw_stream_hold_cycles
spu_backpressure_cycles
result_drain_cycles
row_transition_cycles
block_transition_cycles
```

### `SPU_Top.v`

Thêm:

```text
fifo_empty_cycles
fifo_nonempty_cycles
fifo_full_cycles
scale_read_cycles
accum_active_cycles
accum_wait_cycles
output_write_cycles
entries_accepted
entries_completed
```

### `AXI4_Mapping.v`

Expose snapshot registers. Dùng `PERF_SNAPSHOT` để latch atomically; 64-bit counter đọc low/high từ cùng snapshot. Thêm ABI/capability mới, không tái sử dụng bit P2/P3 cũ.

### Pass

- Counter sum giải thích >=95% busy cycles.
- Không ảnh hưởng functional output.
- Counter saturation/reset/snapshot có XSim riêng.

## 5. P1 - Pipeline SPU scale accumulator đến II <= 2

### Thiết kế khuyến nghị

Không giữ FSM bảy chu kỳ cho từng entry. Tách datapath thành pipeline:

```text
accept metadata
 -> validate + fp16 decode
 -> scale product
 -> raw × combined scale
 -> shift/round/saturate
 -> row accumulation
 -> optional final output
```

### Loại bỏ dependency accumulator

Input order hiện xử lý nhiều block liên tiếp của cùng row pair. Chọn một trong hai thiết kế:

1. Giữ current-row accumulator trong register cho mỗi paired row, chỉ ghi memory ở `last_block`.
2. Dùng nhiều partial accumulators round-robin bằng pipeline latency, rồi reduction ở `last_block`.

Thiết kế 1 đơn giản hơn với row-major order hiện tại. Nếu contribution pipeline có latency lớn hơn II, dùng forwarding hoặc partial accumulators để không tạo RAW hazard.

### Scale representation

P3 đã tách weight và activation scale. Phase tiếp theo nên tạo ABI mới để:

- preconvert weight scale tĩnh sang fixed-point khi pack model;
- convert mỗi activation scale một lần cho mỗi Q8 block;
- broadcast activation scale cho tất cả rows;
- không lặp FP16 decode activation scale theo từng row.

Không đổi rounding mà không có bit-accurate reference.

### Pass

```text
accept một row pair entry mỗi <=2 cycles steady state
no FIFO overflow/drop
Q16 output bit-exact với reference hiện tại hoặc tolerance được duyệt
DSP pipeline DRC giảm, không tăng critical path
```

## 6. P2 - Continuous issue/retire trong VPU

### `Matrix_Vector_Multiplication.v`

Thay stop-wait controller bằng hai luồng độc lập:

1. **Issue pipeline:** tạo ACT/WEIGHT reads và feed PMAU liên tục.
2. **Retire pipeline:** nhận PMAU result, gắn metadata và đẩy result FIFO.

Metadata FIFO cần giữ:

```text
job_id
bank
row0/row1
block
group_blocks
clear_accum
last_block
last_row
```

`S_WAIT_RESULT` không được chặn issue của block độc lập tiếp theo. `S_RAW_STREAM_HOLD` chỉ còn là output FIFO backpressure; input issue dừng khi credit FIFO không đủ, không drain toàn pipeline.

### Credit rule

Trước khi issue block mới, reserve một result slot cho primary row và optional paired row. Không dựa vào “FIFO depth đủ lớn” mà thiếu worst-case proof.

### PMAU

Giữ hai `PMAU_Full` ban đầu. Chỉ thay PMAU nếu counter cho thấy `input_ready` tạo bubble. Pipeline adder tree hiện đã register; không tăng multiplier count ở phase này.

### Pass

```text
tile 256×64 <= 25,000 cycles
pmau_input_fire useful cycles >=75% expected beat cycles
wait_result + raw_hold <=10% total
random SPU stall không mất/đảo metadata
```

Stretch goal cho tile là 20,000 cycles; theoretical minimum là 16,384 cycles.

## 7. P3 - Accumulate xuyên K-chunk

### Vấn đề

FFN down có 216 blocks, vượt 64 blocks/job. Current SPU hoàn thành output sau từng chunk, host đọc bốn partial vectors.

### Thiết kế

Mỗi bank có accumulator context:

```text
valid
context_id
job_id
tensor_id
token_id
row_base
rows
next_k_block
accum[256]
error/overflow
```

Descriptor flags:

```text
FIRST: clear và bind context
CONTINUE: kiểm tra next_k_block rồi cộng tiếp
LAST: cộng chunk cuối và emit
OUTPUT_ENABLE: chỉ hợp lệ cùng LAST
```

Không release context khi VPU done; release sau final SPU output commit và host/next-stage ownership acknowledgment.

### Pass

- Sequence `64+64+64+24` bằng reference một job logic 216 blocks.
- Out-of-order/missing/duplicate chunk bị reject.
- Reset giữa context không rò accumulator.
- Chỉ một final output vector.

## 8. P4 - Ping-pong data plane hoàn chỉnh

### Quy tắc bank

```text
FREE -> DMA_FILLING -> READY -> COMPUTING
     -> OUTPUT_READY/DRAINING -> FREE
```

- DMA không ghi active compute bank.
- Compute không bắt đầu trước descriptor commit.
- P3 scale bank lock phải đi cùng ACT/WEIGHT bank owner.
- Final done chỉ phát sau last output write visible.
- Reset/error trả cả hai bank về state an toàn hoặc fail closed.

### Memory

Giữ `MAX_ROWS=256`. Không tăng 512. Nếu cần logical rows lớn hơn, descriptor engine lặp nhiều 256-row tiles mà không trả quyền điều khiển về CPU.

### Pass

- Random DMA/compute/SPU stall với ít nhất 10,000 job.
- Không bank mismatch, overwrite hoặc stale result.
- Preload bank N+1 overlap compute bank N.

## 9. P5 - Weight streaming path

### Lựa chọn A: giữ ZDMA hiện có

Ưu tiên trước vì reversible và source/destination contract đã chạy production:

- resident packed source;
- descriptor lớn/coalesced;
- inactive-bank preload;
- measured effective bandwidth >=2.4 GB/s.

### Lựa chọn B: PL AXI master

Chỉ triển khai nếu A không đạt bandwidth gate. File/interface chịu ảnh hưởng:

- `MY_IP.v`: AXI master engine hoặc wrapper mới.
- `VPU_Top.v`: expose M_AXI.
- module mới `VPU_Weight_DMA.v`: burst, outstanding, 4-KiB boundary, response/error handling.
- Vivado Block Design: owner kết nối M_AXI tới PS HP/HPC port.

Yêu cầu:

```text
64-bit physical address
INCR burst
4-KiB boundary compliant
bounded outstanding transactions
BRESP/RRESP error propagation
range whitelist
timeout
performance counters
```

Không cho PL đọc arbitrary physical address từ descriptor chưa kiểm tra.

### Dual port

Nếu một port không đạt 2.47 GB/s ổn định, chia pair-row weight trên hai AXI ports. Mỗi port cấp một row parity. Việc này phù hợp với weight memory even/odd leaves hiện tại hơn là thêm PMAU.

## 10. P6 - Khi nào được tăng DSP

Chỉ tăng compute width khi tất cả điều kiện sau đúng:

```text
SPU II <= 2
PM AU useful issue >=75%
weight starvation <5%
memory bandwidth có headroom cho width mới
timing WNS >=0.2 ns và WHS không âm
```

Nếu thêm bốn-row engine, weight demand peak là khoảng 12 GB/s ở 187.5 MHz. Không triển khai khi chỉ có một 128-bit port 3 GB/s.

DSP dư không đồng nghĩa workload có đủ bandwidth để dùng DSP.

## 11. P7 - SPU functions và FFN fusion

Capability SiLU/RMSNorm/RoPE/Softmax hiện bị giữ ở 0 dù module tồn tại. Thứ tự enable:

1. Quantize output Q8_0.
2. SiLU + gate/up multiply.
3. RMSNorm.
4. RoPE.
5. Attention softmax.

Mỗi module cần tensor-level reference, tail/overflow test và end-to-end logits A/B. FFN fusion chỉ bắt đầu sau khi gate, up, SiLU/mul và down riêng lẻ đều pass.

## 12. RTL regression bắt buộc

### VPU

- 1/2/255/256 rows.
- 1/63/64 blocks.
- odd row pair.
- signed extremes.
- result FIFO full.
- randomized SPU ready.
- continuous issue metadata ordering.
- FIRST/CONTINUE/LAST errors.
- final-write visibility.

### SPU

- FP16 zero/subnormal/normal/max finite.
- negative/NaN/Inf reject.
- accumulation overflow policy.
- back-to-back entries tại target II.
- same-row RAW hazard.
- pair + odd tail.
- P2/P3 mode isolation.
- reset khi pipeline đang đầy.

### Gate

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim
.\run_phase2a_vpu_spu_xsim.ps1
```

Functional change chỉ pass khi XSim trả code 0 và log có explicit pass. Sau đó mới dùng owner flow synthesis/implementation.

## 13. Timing/resource gate

Fresh routed report phải đạt:

```text
WNS >= 0
TNS = 0
WHS >= 0
THS = 0
route errors = 0
```

Mục tiêu nội bộ nên giữ WNS >=0.2 ns. Current hold margin 0.009 ns rất nhỏ; mọi pipeline/memory placement change phải kiểm tra hold. 121 DSP pipeline warnings cần phân loại; không được coi warning count giảm là throughput gain nếu counter không cải thiện.

## 14. Hoàn thành PL side

```text
tile 256×64 <=25,000 cycles
IP compute <=160 ms/token
SPU backpressure <=5%
weight starvation <=5%
drop/error=0
cross-K partial output=0
timing closed at 187.5 MHz
```
