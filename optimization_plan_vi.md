# Kế hoạch tối ưu hệ thống FPGA Gemma-3 Q8

## 1. Mục tiêu

Kế hoạch này dựa trên các số liệu trong báo cáo hiện tại.

| Chỉ số | Hiện tại | Mục tiêu |
|---|---:|---:|
| Độ trễ decode | 3900,50 ms/token | ≤ 400 ms/token |
| Tốc độ decode | 0,256 token/giây | ≥ 2,5 token/giây |
| Chuẩn bị phía host | 2276,66 ms/token | < 100–150 ms/token |
| Tính toán PL | 1284,60 ms/token | khoảng 200–250 ms/token |
| Số tác vụ VPU | 2210/token | giảm xuống vài trăm/token |
| Đường đọc kết quả | 230,38 ms/token | < 30–50 ms/token |
| Tần số PL | 187,5 MHz | giữ nguyên trong giai đoạn đầu |

## 2. Phân chia trách nhiệm mục tiêu

### Host CPU giữ lại

- Nạp mô hình.
- Chuẩn bị dữ liệu tĩnh một lần.
- Điều phối layer và token.
- Gửi descriptor cấp cao.
- Sampling và xử lý token.
- Kiểm tra lỗi và fallback an toàn.

### PL đảm nhiệm

- Đọc trọng số đã đóng gói từ DDR.
- Thực hiện MAC INT8 trong VPU.
- Áp dụng scale trong SPU.
- Tích lũy toàn bộ K-chunk.
- Tạo activation scale động khi activation nằm trong PL.
- Giữ intermediate activation trong PL khi có thể.
- Chỉ trả kết quả hoàn chỉnh về CPU.
- Tự lấy nhiều descriptor từ hàng đợi phần cứng.

**MAC — Multiply–Accumulate** là phép nhân rồi cộng dồn.

---

# 3. Giai đoạn 0 — Giữ baseline kiểm chứng

Trước khi sửa kiến trúc:

- Lưu bitstream, mã host và log hiện tại.
- Dùng cùng model, prompt, nhiệt độ và `-n 4` cho A/B test.
- Tắt log theo từng VPU job khi đo throughput.
- Ghi phiên bản host và bitstream vào đầu log.

Các chỉ số bắt buộc giữ:

```text
token_wall_ms
host_to_ip_dma_ms
ip_compute_sum_ms
ip_to_host_dma_ms
host_result_read_ms
token_read_ms
prep_direct_weight_pack_ms
prep_scale_pack_ms
vpu_runs
weight_bytes
scale_bytes
result_bytes
ZDMA descriptors
PING/PONG timing
```

Điều kiện hoàn thành: baseline chạy lại gần 3900,50 ms/token, sai lệch không quá khoảng 5%.

---

# 4. Giai đoạn 1 — Đóng gói trọng số tĩnh một lần

CPU hiện mất khoảng 1630,22 ms/token để đóng gói lại trọng số.

## Việc cần làm

Tạo định dạng trọng số riêng cho FPGA gồm:

```text
tensor_id
row0
rows
k_block0
group_blocks
layout_version
bitstream_id
P2_ABI
payload_offset
payload_size
weight_scale_offset
CRC
```

Tại lúc nạp model:

1. Đọc tensor Q8 gốc.
2. Chuyển sang layout pair-interleaved của VPU2.
3. Kiểm tra CRC.
4. Lưu trong DDR mà PL truy cập được.
5. Tạo bảng tra cứu theo tensor và tile.
6. Không thay đổi dữ liệu sau khi hoàn tất.

Trong decode, host chỉ tra địa chỉ đã đóng gói; không chạy lại vòng lặp packing.

## Điều kiện hoàn thành

```text
prep_direct_weight_pack_ms gần 0 sau warm-up
tỷ lệ hit gần 100%
không có CRC mismatch
output khớp baseline
```

Residency 16 MiB hiện tại chỉ phù hợp thử nghiệm, không đủ cho khoảng 698 MB trọng số được đọc mỗi token.

---

# 5. Giai đoạn 2 — Tách weight scale tĩnh khỏi activation scale động

CPU hiện mất khoảng 631,51 ms/token để xây dựng bảng scale kết hợp.

## Việc cần làm

- Lưu weight scale cùng trọng số đã đóng gói.
- Không xây lại weight scale mỗi token.
- Chỉ tạo hoặc truyền activation scale động.
- Cho PL đọc weight scale từ địa chỉ cố định.

Descriptor mới nên chứa:

```text
weight_base
weight_scale_base
activation_base
activation_scale
rows
total_k_blocks
```

## Điều kiện hoàn thành

- `prep_scale_pack_ms` giảm mạnh.
- Không còn sao chép weight scale lặp lại.
- Kết quả Q16.16 khớp đường P2 hiện tại.

**Q16.16** là số cố định với 16 bit phần nguyên và 16 bit phần thập phân.

---

# 6. Giai đoạn 3 — Tích lũy toàn bộ K-chunk trong SPU/PL

FFN down hiện chia 216 Q8 block thành:

```text
64 + 64 + 64 + 24
```

Hiện tại, PL trả bốn partial vector và CPU cộng lại.

## Luồng mục tiêu

```text
chunk 0 ┐
chunk 1 ├→ accumulator trong SPU/PL
chunk 2 ┤
chunk 3 ┘
       ↓
một vector hoàn chỉnh
       ↓
CPU
```

## Thay đổi RTL

Thêm accumulator riêng cho PING và PONG:

```text
2 bank × 256 hàng × 64 bit = 4096 byte
```

Mỗi context cần:

```text
valid
context_id
tensor_id
token_id
row0
rows
expected_k_block
accumulated_blocks
overflow
error
```

Thêm cờ descriptor:

```text
FIRST
CONTINUE
LAST
OUTPUT_ENABLE
```

- `FIRST`: xóa accumulator và bắt đầu context.
- `CONTINUE`: cộng chunk tiếp theo, không xuất kết quả.
- `LAST`: cộng chunk cuối và ghi `SPU_OUT`.
- Chỉ `LAST` mới tạo `OUTPUT_READY`.

## Thay đổi host

- Không đọc `SPU_OUT` ở chunk trung gian.
- Không cộng partial trên CPU.
- Chỉ ghi tensor đích sau chunk cuối.

## Kết quả mong đợi

```text
ffn_down logical jobs: 520 → 130/token
ffn_down result transfers: giảm 75%
CPU partial accumulation: gần 0
```

---

# 7. Giai đoạn 4 — Cho PL đọc trọng số trực tiếp từ DDR

Hiện CPU điều khiển khoảng 11.440 ZDMA descriptor trọng số/token.

## Luồng mục tiêu

```text
trọng số đã pack trong DDR
          ↓
PL AXI master đọc trực tiếp
          ↓
buffer PING/PONG trong PL
          ↓
VPU
```

**AXI burst** là một chuỗi truyền dữ liệu liên tiếp với một lần thiết lập địa chỉ.

## Thay đổi PL

- Thêm AXI master đọc weight và weight scale.
- Dùng burst dài.
- Thêm FIFO hoặc BRAM PING/PONG.
- Thêm counter số burst, số byte, chu kỳ chờ DDR và chu kỳ starvation.

## Thay đổi host

Descriptor chỉ gửi:

```text
weight_base
weight_stride
weight_scale_base
rows
total_k_blocks
```

## Điều kiện hoàn thành

- Weight descriptor phía CPU giảm gần về 0.
- `weight_dma_ms` phía host giảm mạnh.
- Dữ liệu khớp đường ZDMA cũ.

---

# 8. Giai đoạn 5 — Giảm số tác vụ VPU

## 8.1 Tăng số hàng trong một logical job

Hiện giới hạn 256 hàng. Với FFN gate/up:

```text
ceil(6912 / 256) = 27 jobs/matrix
ceil(6912 / 512) = 14 jobs/matrix
```

## 8.2 Một descriptor cho toàn bộ K

Với FFN down, descriptor mô tả:

```text
total_k_blocks = 216
```

PL tự lặp qua các chunk bên trong.

## 8.3 Descriptor ring

**Descriptor ring** là hàng đợi vòng để PL tự lấy nhiều lệnh mà không chờ CPU ghi thanh ghi cho từng tile.

Host chuẩn bị trước nhiều descriptor; PL thực thi liên tục và ghi completion queue.

## Điều kiện hoàn thành

- Số logical job giảm xuống vài trăm/token.
- Số lần ghi thanh ghi và polling giảm mạnh.
- `retire_to_next_launch_ms` giảm rõ rệt.

---

# 9. Giai đoạn 6 — Giữ activation trung gian trong PL

Luồng mục tiêu:

```text
VPU raw accumulator
        ↓
SPU scale + K accumulation
        ↓
activation function
        ↓
quantize INT8 + activation scale
        ↓
buffer activation trong PL
        ↓
VPU tiếp theo
```

Các chức năng nên đưa vào SPU theo thứ tự:

1. Tích lũy toàn bộ K.
2. Quantize đầu ra INT8.
3. Tạo activation scale.
4. SiLU.
5. Gate × Up.
6. RMSNorm.
7. RoPE.
8. Softmax khi tài nguyên phù hợp.

**SiLU** là hàm kích hoạt của FFN.  
**RMSNorm** là phép chuẩn hóa vector.  
**RoPE** là phép mã hóa vị trí trong attention.

Điều kiện hoàn thành:

- Intermediate FFN không quay lại CPU.
- CPU không requantize intermediate FFN.
- Dữ liệu IP-to-host giảm mạnh.

---

# 10. Giai đoạn 7 — Fuse FFN

FFN chiếm khoảng 87,83% thời gian matrix.

Luồng mục tiêu:

```text
activation
   ├→ gate VPU → SiLU ┐
   └→ up VPU ─────────┤ multiply
                       ↓
                   down VPU
                       ↓
                output hoàn chỉnh
```

**Fusion** là gộp nhiều phép toán liên tiếp thành một pipeline phần cứng để tránh ghi và đọc lại dữ liệu trung gian.

Điều kiện hoàn thành:

- Output fused khớp đường gate/up/down tách rời.
- Intermediate gate/up không trở về CPU.
- FFN wall time giảm rõ rệt.

---

# 11. Giai đoạn 8 — Tối ưu datapath PL tại 187,5 MHz

Hiện PL dùng khoảng:

```text
1284,60 ms/token
240,86 triệu chu kỳ/token
```

Mục tiêu PL:

```text
200–250 ms/token
37,5–46,9 triệu chu kỳ/token
```

Thêm counter RTL:

```text
total_cycles
active_mac_cycles
input_starvation_cycles
weight_wait_cycles
output_stall_cycles
pipeline_bubble_cycles
accumulator_wait_cycles
idle_cycles
jobs_completed
rows_completed
k_blocks_completed
```

Dựa trên counter:

- Active MAC quá lớn: tăng lane hoặc compute unit.
- Weight wait lớn: tăng độ rộng AXI, burst và FIFO.
- Output stall lớn: tăng băng thông SPU/accumulator.
- Pipeline bubble lớn: chuyển control loop vào PL và dùng descriptor ring.

Điều kiện hoàn thành: PL compute khoảng 200–250 ms/token, không có lỗi dữ liệu hoặc timing closure.

---

# 12. Giai đoạn 9 — Tối ưu preload và PING–PONG

Chỉ khoảng 5,88% VPU job hiện được preload.

Sau khi loại bỏ packing lặp lại:

- Chuẩn bị descriptor N+1 và N+2.
- Duy trì ready queue cho PING và PONG.
- Preload activation, activation scale và metadata.
- Không preload lại weight đã resident.
- Cho PL tự đổi bank khi descriptor kế tiếp sẵn sàng.

Điều kiện hoàn thành:

```text
preload admission > 90% job đủ điều kiện
running_job_terminal_before_preload gần 0
compute utilization tăng rõ rệt
```

---

# 13. Giai đoạn 10 — Prefill bằng batch GEMM

Prefill hiện mất 36,25 giây cho 13 token và truyền khoảng 8,78 GB trọng số.

**GEMV** là nhân ma trận với một vector.  
**GEMM** là nhân ma trận với nhiều vector hoặc nhiều hàng cùng lúc.

Mục tiêu:

- Xử lý nhiều token prompt trong một GEMM.
- Đọc một weight tile một lần.
- Tái sử dụng weight tile cho nhiều activation row.
- Xuất kết quả theo batch.

Điều kiện hoàn thành:

- Weight bytes trong prefill không tăng gần tuyến tính theo số token prompt.
- TTFT giảm xuống vài giây.
- Output khớp đường prefill cũ.

---

# 14. Kiểm thử bắt buộc

Mỗi giai đoạn phải có:

```text
legacy
new_feature
A/B compare
```

Kiểm thử số học:

- Output từng tile.
- Output từng matrix.
- Logits.
- Token được sinh.
- Tail rows và tail K blocks.
- PING/PONG xen kẽ.
- Nhiều token liên tiếp.

Dùng `-n 4` để chẩn đoán nhanh. Sau khi đúng số học, dùng `-n 32` hoặc `-n 64` để đo throughput.

Kiểm thử độ bền:

- Chạy vài trăm token.
- Không có ZDMA error.
- Không có SPU stream drop.
- Không có bank mismatch.
- Không có context hoặc CRC mismatch.
- Không có fallback ngoài dự kiến.

---

# 15. Thứ tự triển khai

| Thứ tự | Hạng mục |
|---:|---|
| 1 | Đóng gói trọng số tĩnh một lần |
| 2 | Tách weight scale khỏi activation scale |
| 3 | Tích lũy toàn bộ K trong SPU/PL |
| 4 | Chỉ trả kết quả cuối về CPU |
| 5 | PL đọc trọng số trực tiếp từ DDR |
| 6 | Descriptor ring và logical job lớn |
| 7 | Tăng row tile hoặc streaming rows |
| 8 | Giữ activation trung gian trong PL |
| 9 | Fuse gate/up/SiLU/down |
| 10 | Tối ưu MAC và pipeline theo counter |
| 11 | Tối ưu preload sau khi dữ liệu sẵn sàng sớm |
| 12 | Prefill bằng batch GEMM |

# 16. Mốc nghiệm thu cuối

```text
decode latency ≤ 400 ms/token
throughput ≥ 2,5 token/giây
PL compute ≈ 200–250 ms/token
host preparation < 100–150 ms/token
result path < 30–50 ms/token
không còn CPU partial accumulation cho FFN down
không đóng gói lại trọng số tĩnh trong decode
không còn hàng nghìn weight ZDMA descriptor mỗi token
kết quả số học và logits đạt yêu cầu
không có lỗi PING/PONG, SPU, ZDMA hoặc context
```
