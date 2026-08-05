# Review kế hoạch tối ưu hiện tại

## 1. Phạm vi và kết luận

Tài liệu này đánh giá `optimization_plan_vi.md` theo source và bằng chứng ngày 02/08/2026. Không coi số liệu từ một run cũ là bằng chứng cho production run mới.

**Decision:** giữ hướng tối ưu tổng thể, nhưng thay đổi thứ tự triển khai và loại bỏ giả định rằng tăng kích thước row tile hoặc thêm DSP sẽ tự động tăng throughput.

**Confidence:** cao đối với bottleneck host packing và SPU/VPU stop-wait; trung bình đối với bandwidth cuối cùng vì chưa có counter AXI bên trong PL và chưa có A/B run P3 production.

## 2. Baseline đã xác minh

Primary run mới nhất:

- Host: `zcu104-gemma3-q8-v86-bottleneck-summary`.
- Bitstream: protocol `2`, ID `0x56505532`, P2 ABI `0x50320003`, P3 ABI `0x50330001`.
- Output: ngôn ngữ tiếng Anh hợp lệ trong 715 decode token.
- Decode: `3907.37 ms/token`, khoảng `0.26 token/s`.
- Vocab projection: CPU (`vocab_cpu_bypass=1`).
- P2 PL-scale: bật.
- Ping-pong scheduler: bật.
- Input preload: tắt.
- Weight cache/residency: tắt.

Một decode token hoàn chỉnh được parse trực tiếp từ `fpga_debug.log`:

| Thành phần | Giá trị |
|---|---:|
| Q8 GEMV | 182 |
| VPU runs | 2210 |
| Tổng STAGE wall | khoảng 3755 ms |
| Host preparation | khoảng 2275 ms |
| IP compute | khoảng 1283 ms |
| Host result read | khoảng 193 ms |
| Weight | 697,761,792 byte |
| Scale | 87,220,224 byte |
| Result | 8,785,920 byte |

Source RTL canonical khớp hash với source IP active trong `project_1`. Implementation mới nhất đạt `WNS +0.417 ns`, `WHS +0.009 ns` ở 187.5 MHz. Tài nguyên: 19,277 LUT, 23,853 FF, 104.5 BRAM, 64 URAM và 124 DSP.

## 3. Phần phù hợp trong kế hoạch cũ

Các hướng sau đúng và nên giữ:

1. Pack weight tĩnh một lần thay vì pack mỗi token.
2. Tách weight scale tĩnh khỏi activation scale động.
3. Tích lũy toàn bộ K-chunk trong PL và chỉ trả final row output.
4. Giảm descriptor, polling và MMIO theo từng tile.
5. Thêm counter để phân biệt MAC, starvation, stall và bubble.
6. Chuẩn bị job tiếp theo đủ sớm để ping-pong có dữ liệu hợp lệ.
7. Dùng GEMM cho prefill sau khi decode đạt đúng số học.
8. Chỉ fuse FFN sau khi từng phép toán đã có numerical contract.

## 4. Phần phải sửa

### 4.1 Baseline preload trong báo cáo không phải primary run mới

`report_with_causes_vi.md` nêu 390 preload attempt và 130 admission. Primary run mới ghi rõ `input_preload=0`, và từng STAGE ghi `p1_input_preload=0`. Vì vậy số preload cũ chỉ là bằng chứng của một experiment khác. Cần đo lại bằng exact artifact và biến môi trường được ghi trong manifest.

### 4.2 P3 split-scale đã tồn tại

Host, RTL, XSim và deployed bitstream đã có P3 ABI. Công việc tiếp theo không phải “bắt đầu implement split scale”, mà là:

1. Chạy P3 qualification.
2. So sánh logits/tensor với P2.
3. Đo scale bytes và latency.
4. Sau khi pass, tích hợp P3 với preload/residency.

Hiện host cấm đồng thời `FPGA_P3_SPLIT_SCALE=1` với `FPGA_P2_INPUT_PRELOAD=1` và P2 residency. Đây là dependency chưa được kế hoạch cũ giải quyết.

### 4.3 Không tăng `MAX_ROWS` từ 256 lên 512 ở phase đầu

Weight memory hiện dùng 64/96 URAM. Hai bank PING/PONG, hai row parity và bốn 32-bit weight leaf đã tiêu thụ phần lớn URAM. Tăng row capacity gấp đôi có khả năng vượt 96 URAM và làm routing xấu hơn. Giảm logical job phải dùng descriptor chaining/streaming rows, không nhân đôi local weight store.

### 4.4 Không thêm DSP trước khi sửa initiation interval

RTL đã có hai PMAU, tổng 32 INT8 multiplier cho một row pair. XSim ghi:

```text
256 rows × 64 Q8 blocks: 176,882 cycles
minimum useful two-row MAC issue: 128 row-pairs × 64 blocks × 2 beats = 16,384 cycles
```

Hiệu suất issue chỉ khoảng `9.26%`. `SPU_Q8_Scale_Accum.v` xử lý một entry qua bảy state nối tiếp, còn VPU chuyển `S_RUN -> S_WAIT_RESULT -> S_RAW_STREAM_HOLD` sau mỗi Q8 block. Thêm PMAU sẽ làm nhiều multiplier chờ hơn nếu hai điểm này chưa được sửa.

### 4.5 Direct PL DDR master không phải thay đổi nhỏ

Top hiện tại là AXI slave; ZDMA chuyển DDR vào local ACT/WEIGHT window. Direct DDR read cần:

- thêm M_AXI master interface vào `MY_IP.v`/`VPU_Top.v`;
- burst engine, outstanding tracking và error handling;
- kết nối PS HP/HPC port trong Vivado Block Design;
- address protection và cache/coherency contract mới.

Nên A/B trước bằng packed-weight residency + ZDMA hiện có. Chỉ thêm AXI master nếu bandwidth hoặc descriptor overhead vẫn không đạt gate.

### 4.6 Full packed residency chưa có vùng nhớ đủ lớn

Run hiện tại map 4 MiB staging trong vùng reserved thấp; P2 residency experiment chỉ có budget tối đa 16 MiB. Chỉ riêng weight được offload đã là khoảng 665.4 MiB. Full non-vocab packed store cần tối thiểu khoảng 768 MiB sau khi cộng scale, header và alignment. Không được bật full residency trước khi device tree/UIO cung cấp vùng riêng đủ lớn và không chồng System RAM.

### 4.7 Budget 400 ms phải được viết theo critical path

Không thể cộng độc lập `host prep 150 + PL 250 + result 50 + CPU outside`. Các phase phải tạo overlap. Budget đề xuất:

| Critical-path component | Gate |
|---|---:|
| Accelerator graph span | <= 290 ms |
| CPU work ngoài accelerator | <= 90 ms |
| Safety/jitter margin | 20 ms |
| Token p95 | <= 400 ms |

Weight + split scale còn khoảng 741 MB/token. Để hoàn thành stream trong 290-300 ms cần effective bandwidth khoảng 2.47-2.56 GB/s. Nếu một cổng 128-bit ở 187.5 MHz không duy trì mức này, phải dùng port thứ hai hoặc thay đổi kiến trúc memory path.

## 5. Thứ tự thay thế được chấp nhận

1. Khóa baseline và thêm RTL counters.
2. Qualify P3 split-scale; không bật production nếu logits chưa pass.
3. Thiết kế vùng packed-weight đủ dung lượng; pack một lần.
4. Tích hợp P3 với preload/resident source và descriptor lớn.
5. Pipeline SPU scale accumulator đến `II <= 2`.
6. Cho VPU issue/retire liên tục, bỏ stop-wait theo block.
7. Giữ accumulator qua K-chunk và giảm result traffic.
8. Đo lại; chỉ khi cần mới thêm AXI master/port hoặc nhiều row PE hơn.
9. Sau khi decode đạt mục tiêu, triển khai FFN fusion và prefill GEMM.

## 6. Phương án bị bác bỏ ở thời điểm hiện tại

- **Tăng clock:** timing đã đạt nhưng hold margin chỉ 9 ps; không chữa utilization 9.26%.
- **Tăng `MAX_ROWS=512`:** tốn URAM, không giảm số byte weight/token.
- **Thêm nhiều DSP ngay:** datapath hiện bị control/SPU/bandwidth giới hạn.
- **Đưa toàn bộ model vào on-chip memory:** model khoảng 1 GiB, trong khi BRAM+URAM raw capacity chỉ vài MiB.
- **Fuse toàn graph ngay:** làm phạm vi debug số học quá lớn và khó rollback.

## 7. Next gate

Gate nhỏ nhất an toàn là chạy một A/B P3 có contract, đồng thời bổ sung counter RTL cho tile `256×64`. Không thay đổi memory architecture trước khi có hai bằng chứng này.
