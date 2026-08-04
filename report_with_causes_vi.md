# Báo cáo các vấn đề hiệu năng hiện tại của FPGA và nguyên nhân

## 1. Hiệu năng tổng thể chưa đạt mục tiêu

### Vấn đề

| Chỉ số | Kết quả hiện tại |
|---|---:|
| Độ trễ khi sinh một token | **3900,50 ms/token** |
| Tốc độ sinh token | **0,256 token/giây** |
| Độ trễ mục tiêu | **400 ms/token** |
| Tốc độ mục tiêu | **2,5 token/giây** |
| Mức cải thiện tổng thể cần đạt | **9,75 lần** |
| Độ trễ xử lý prompt ban đầu | **36,25 giây cho 13 token đầu vào** |
| Số tác vụ VPU | **2210 tác vụ/token** |
| Tần số PL | **187,5 MHz** |

Ba token decode được đo lần lượt là:

```text
3900,439 ms
3900,636 ms
3900,435 ms
```

Kết quả gần như không thay đổi giữa các token, cho thấy hiện tượng chậm có tính ổn định và lặp lại được.

### Nguyên nhân

Độ trễ tổng thể không đến từ một thành phần duy nhất mà là tổng hợp của nhiều vấn đề:

- CPU đóng gói lại trọng số và scale trong mỗi token.
- Mỗi token bị chia thành 2210 tác vụ VPU nhỏ.
- Có hàng nghìn lần truyền DMA và polling.
- Nhiều kết quả trung gian được trả về CPU.
- Phần tính toán trong PL tự nó đã mất khoảng 1284,60 ms/token.
- Preload không được thực hiện đủ sớm để che giấu thời gian truyền.
- FFN chiếm phần lớn thời gian xử lý ma trận.

---

## 2. Trọng số tĩnh vẫn bị CPU đóng gói lại và truyền lại

### Vấn đề

CPU hiện thực hiện lặp lại hai công việc:

1. Đọc trọng số Q8 gốc và sắp xếp lại thành layout pair-interleaved mà VPU2 yêu cầu.
2. Dùng ZDMA truyền các tile trọng số đã đóng gói từ DDR phía PS sang vùng WEIGHT của IP trong PL.

**Đóng gói** là quá trình sắp xếp lại dữ liệu theo đúng thứ tự byte phần cứng yêu cầu.

| Chỉ số liên quan đến trọng số | Kết quả |
|---|---:|
| Thời gian CPU đóng gói trực tiếp trọng số | **1630,22 ms/token** |
| Lượng dữ liệu trọng số được truyền | **697.761.792 byte/token** |
| Số descriptor ZDMA cho trọng số | **11.440/token** |
| Bộ nhớ đệm trọng số | Tắt |
| Cơ chế lưu trú trọng số P2 | Tắt |

### Nguyên nhân

Nguyên nhân trực tiếp là đường chạy production hiện tại không sử dụng weight cache hoặc P2 weight residency:

```text
weight_cache = 0
p2_residency_enabled = 0
```

Do đó, mỗi tile trọng số lại được CPU đọc từ tensor Q8 gốc, chuyển sang layout của FPGA và ghi vào vùng staging DDR.

Trọng số là dữ liệu tĩnh, nhưng kiến trúc hiện tại vẫn xử lý chúng như dữ liệu phải chuẩn bị lại theo từng tác vụ.

Ngoài ra, PL hiện chưa tự đọc trực tiếp trọng số đã đóng gói từ một vùng DDR cố định; host vẫn phải điều phối việc truyền từng tile vào cửa sổ WEIGHT của IP.

---

## 3. Scale bị chuẩn bị lại nhiều lần trên host

### Vấn đề

Mỗi token có:

```text
Thời gian chuẩn bị scale ≈ 631,51 ms
Lượng dữ liệu scale được truyền ≈ 87,22 MB
```

**Scale** là hệ số dùng để diễn giải giá trị số nguyên đã lượng tử hóa.

### Nguyên nhân

Cấu trúc `SPU_PARAM` hiện ghép chung:

- Weight scale, là dữ liệu tĩnh của mô hình.
- Activation scale, là dữ liệu động thay đổi theo token và phép toán.

Vì hai loại scale được đóng chung trong cùng bảng, CPU phải xây dựng lại bảng scale cho mỗi VPU job.

Điều này không có nghĩa phép scale của SPU đang chạy trên CPU. Phép áp dụng scale vẫn chạy trong SPU ở PL. Phần còn nằm trên host là:

- Đọc weight scale.
- Đọc hoặc tạo activation scale.
- Ghép hai scale thành định dạng `SPU_PARAM`.
- Ghi bảng scale vào DDR staging.
- Gửi bảng đó xuống IP.

Do weight scale tĩnh và activation scale động chưa được tách riêng trong giao thức hiện tại, toàn bộ bảng phải được tạo lại.

---

## 4. Chuẩn bị phía host chiếm phần lớn thời gian

### Vấn đề

Tổng thời gian chuẩn bị phía host:

```text
2276,66 ms/token
```

| Thành phần chuẩn bị | Thời gian |
|---|---:|
| Đóng gói trực tiếp trọng số | **1630,22 ms** |
| Đóng gói scale | **631,51 ms** |
| Đóng gói activation | 6,46 ms |
| Chọn trọng số | 0,23 ms |
| Phần chuẩn bị khác | 8,25 ms |

Weight packing và scale packing cộng lại:

```text
1630,22 + 631,51 = 2261,73 ms/token
```

Chiếm khoảng **99,34% thời gian chuẩn bị phía host**.

### Nguyên nhân

Nguyên nhân là host vẫn làm lại phần lớn dữ liệu tĩnh theo từng tile:

- Trọng số được chuyển layout lại.
- Weight scale được ghép lại với activation scale.
- Mỗi tile có một bộ dữ liệu staging riêng.
- Tác vụ quá nhỏ nên chi phí chuẩn bị bị lặp lại 2210 lần trong một token.

Activation packing chỉ mất 6,46 ms, nên activation không phải nguyên nhân chính của thời gian chuẩn bị hiện tại.

---

## 5. Preload hoạt động nhưng phần lớn cơ hội bị bỏ lỡ

### Vấn đề

**Preload** là truyền trước dữ liệu của tác vụ tiếp theo vào bank đang rảnh trong khi bank còn lại đang tính toán.

| Chỉ số preload | Kết quả |
|---|---:|
| Số lần thử preload | 390 |
| Số lần được chấp nhận khi FPGA còn đang chạy | 130 |
| Số lần bị bỏ lỡ vì tác vụ hiện tại đã hoàn thành | 260 |
| Tỷ lệ chấp nhận | **33,33%** |
| Tỷ lệ job được preload trên toàn bộ VPU job | **5,88%** |

Lý do lặp lại trong log:

```text
running_job_terminal_before_preload
```

### Nguyên nhân

Preload không bị lỗi khi đã được chấp nhận. Các preload được chấp nhận gần như chồng lấp hoàn toàn với thời gian PL đang tính toán.

Nguyên nhân chính là dữ liệu cho job kế tiếp được chuẩn bị quá muộn:

1. CPU phải đóng gói trọng số.
2. CPU phải xây bảng scale.
3. CPU phải chuẩn bị descriptor.
4. Đến khi việc chuẩn bị xong, job đang chạy trong PL đã kết thúc.

Vì vậy, preload bị từ chối do không còn thời gian tính toán để che giấu việc truyền.

---

## 6. Số lượng tác vụ VPU quá lớn và mỗi tác vụ quá nhỏ

### Vấn đề

Mỗi token thực hiện:

```text
182 phép toán ma trận
2210 tác vụ VPU
```

| Nhóm phép toán | Số phép toán ma trận | Số tác vụ VPU |
|---|---:|---:|
| Các phép chiếu attention | 104 | 286 |
| FFN gate | 26 | 702 |
| FFN up | 26 | 702 |
| FFN down | 26 | 520 |
| **Tổng cộng** | **182** | **2210** |

### Nguyên nhân

Nguyên nhân là ma trận bị chia theo hai giới hạn phần cứng hiện tại:

- Tối đa khoảng 256 output rows mỗi job.
- Tối đa 64 Q8 blocks theo chiều K mỗi job.

Ví dụ với FFN gate/up:

```text
N = 6912
ceil(6912 / 256) = 27 row tiles
```

Mỗi layer cần 27 job cho gate và 27 job cho up.

Với FFN down:

```text
K = 6912 = 216 Q8 blocks
216 blocks bị chia thành 64 + 64 + 64 + 24
```

Mỗi row tile phải chạy bốn job theo chiều K.

Ngoài ra, host vẫn điều khiển theo từng tile nhỏ thay vì gửi một descriptor cho cả phép toán ma trận.

---

## 7. FFN down trả về nhiều kết quả từng phần

### Vấn đề

FFN down thường có:

```text
K = 6912
N = 1152
```

VPU chỉ hỗ trợ tối đa 64 Q8 blocks mỗi job, nên 216 blocks phải chia thành:

```text
64 + 64 + 64 + 24
```

Sau mỗi K-chunk, PL trả một vector kết quả đã scale về CPU. CPU cộng bốn vector này để tạo kết quả cuối.

### Nguyên nhân

SPU trong PL hiện chỉ tích lũy các block nằm trong phạm vi một VPU job.

Giao thức hiện tại xem mỗi K-chunk là một job hoàn chỉnh và yêu cầu:

- Báo hoàn thành riêng.
- Ghi `SPU_OUT` riêng.
- DMA kết quả riêng.
- CPU đọc riêng.
- CPU cộng vào accumulator phía host.

PL chưa giữ accumulator xuyên suốt nhiều K-chunk của cùng một row tile. Vì vậy, CPU vẫn phải làm final accumulation giữa các job.

---

## 8. Bản thân phần tính toán trong PL còn quá chậm

### Vấn đề

Thời gian PL compute:

```text
1284,60 ms/token
```

Tần số PL:

```text
187,5 MHz
```

Tương đương:

```text
≈ 240,86 triệu chu kỳ/token
```

Trong khi toàn bộ mục tiêu 400 ms chỉ có:

```text
75 triệu chu kỳ
```

Ngay cả khi bỏ toàn bộ CPU và DMA, PL hiện chỉ đạt tối đa khoảng:

```text
0,78 token/giây
```

### Nguyên nhân đã xác minh

- Khối lượng tính toán FFN rất lớn.
- FFN gate, up và down chiếm phần lớn thời gian compute.
- Có 2210 job nhỏ, làm pipeline thường xuyên bị dừng và khởi động lại.
- Dữ liệu được cấp theo từng tile thay vì một luồng dài liên tục.
- Kết quả phải hoàn tất và retire theo từng job.

### Nguyên nhân chưa thể xác minh chính xác

Host log không quan sát được chi tiết bên trong RTL, nên chưa thể kết luận chính xác tỷ lệ thời gian do:

- MAC thực sự tính toán.
- Chờ trọng số.
- Chờ activation.
- Chờ output.
- Pipeline bubble.
- BRAM/URAM contention.
- AXI stall.
- Control idle.

**Pipeline bubble** là chu kỳ mà pipeline không thực hiện phép tính hữu ích.

Vì chưa có counter RTL, nguyên nhân nội bộ chính xác của 240,86 triệu chu kỳ vẫn chưa được phân tách.

---

## 9. FFN chiếm phần lớn thời gian xử lý ma trận

### Vấn đề

| Nhóm phép toán | Thời gian thực tế | Tỷ lệ |
|---|---:|---:|
| Các phép chiếu attention | 459,92 ms | 12,17% |
| FFN gate | 1202,03 ms | 31,80% |
| FFN up | 1202,02 ms | 31,80% |
| FFN down | 916,21 ms | 24,24% |
| **Tổng FFN** | **3320,26 ms** | **87,83%** |

### Nguyên nhân

FFN của mỗi layer gồm ba phép chiếu lớn:

- Gate projection.
- Up projection.
- Down projection.

Gate và up có số output rows lớn:

```text
N = 6912
```

nên mỗi phép toán bị chia thành 27 row tiles.

Down có chiều K lớn:

```text
K = 6912
```

nên bị chia thành bốn K-chunk cho mỗi row tile.

Ngoài phép tính, mỗi phần còn lặp lại:

- Weight packing.
- Scale packing.
- DMA.
- Descriptor.
- Polling.
- Result handling.

Vì vậy, FFN chiếm cả phần lớn thời gian chuẩn bị lẫn thời gian PL compute.

---

## 10. Số lượng descriptor ZDMA quá lớn

### Vấn đề

| Chỉ số ZDMA | Kết quả |
|---|---:|
| Tổng số descriptor | **18.070/token** |
| Descriptor trọng số | **11.440/token** |
| Descriptor activation | 2.210/token |
| Descriptor scale | 2.210/token |
| Descriptor kết quả | 2.210/token |
| Tổng dữ liệu truyền | **796,60 MB/token** |
| Tổng thời gian descriptor | **310,72 ms/token** |
| Thời gian trung bình mỗi descriptor | **17,20 µs** |
| Số vòng polling | Khoảng **588.000/token** |

### Nguyên nhân

Kích thước mỗi descriptor hiện bị giới hạn ở 64 KiB.

Lượng trọng số gần 698 MB/token phải bị chia thành hàng nghìn lần truyền nhỏ.

Mỗi descriptor lại cần:

- Ghi địa chỉ nguồn và đích.
- Ghi kích thước.
- Clear ISR.
- Start DMA.
- Poll trạng thái.
- Xác nhận completion.
- Clear total-byte counter.

Ngoài ra, mỗi VPU job còn có descriptor riêng cho activation, scale và result. Vì có 2210 VPU job, các loại descriptor này cũng xuất hiện 2210 lần/token.

---

## 11. Đường đọc và xử lý kết quả tốn nhiều thời gian

### Vấn đề

| Thành phần | Thời gian |
|---|---:|
| DMA từ FPGA về host | 37,42 ms/token |
| CPU đọc kết quả | 192,96 ms/token |
| Tổng đường kết quả | **230,38 ms/token** |
| Dữ liệu kết quả | **8,79 MB/token** |

### Nguyên nhân

PL đang trả kết quả theo từng VPU tile nhỏ.

Đối với mỗi job, host phải:

1. Chờ SPU finality.
2. DMA `SPU_OUT` về DDR phía host.
3. Đọc từng giá trị Q16.16.
4. Chuyển sang float.
5. Cộng vào output accumulator.
6. Retire job và giải phóng bank.

Với FFN down, cùng một row tile còn trả bốn partial vector tương ứng bốn K-chunk.

Do đó, chi phí đọc kết quả bị lặp lại nhiều lần thay vì chỉ thực hiện sau khi một phép toán logic hoàn chỉnh kết thúc.

---

## 12. Mức sử dụng tính toán trong decode thấp

### Vấn đề

```text
Device span ≈ 3807,30 ms/token
PL compute ≈ 1284,60 ms/token
Compute utilization ≈ 33,74%
```

### Nguyên nhân

Trong khoảng hai phần ba device span, compute engine không được ghi nhận là đang tính toán.

Thời gian còn lại bị chiếm bởi:

- CPU chuẩn bị trọng số và scale.
- Truyền activation, weight và scale.
- Lập descriptor.
- Polling ZDMA và VPU.
- Chờ giữa các job.
- Truyền kết quả về.
- CPU đọc và tích lũy kết quả.
- Retire job.
- Chuyển trạng thái PING/PONG.

PING–PONG bank đã tồn tại, nhưng job tiếp theo thường chưa sẵn sàng trước khi job hiện tại kết thúc. Do đó, hai bank không đủ để giữ compute engine hoạt động liên tục.

---

## 13. TTFT và prefill rất lớn

### Vấn đề

Prompt 13 token mất khoảng:

```text
36,25 giây
```

Trong prefill:

```text
8,78 GB dữ liệu trọng số
26,61 giây chuẩn bị phía host
25,65 giây tính toán PL
227.542 descriptor ZDMA
```

**TTFT — Time to First Token** là thời gian từ khi gửi prompt đến khi token trả lời đầu tiên xuất hiện.

### Nguyên nhân

Prefill hiện xử lý prompt gần giống nhiều phép GEMV tuần tự.

**GEMV** là phép nhân ma trận với một vector.

Mỗi token prompt lại kích hoạt phần lớn quy trình:

- Đóng gói trọng số.
- Chuẩn bị scale.
- Truyền trọng số.
- Gửi nhiều VPU job.
- Đọc kết quả.

Weight tile chưa được tái sử dụng hiệu quả cho nhiều token prompt trong một lần xử lý.

Vì vậy, khối lượng truyền trọng số và số descriptor tăng gần theo số token của prompt, làm TTFT tăng rất lớn.

---

# Tóm tắt quan hệ vấn đề và nguyên nhân

| Vấn đề | Nguyên nhân chính |
|---|---|
| Decode 3900,50 ms/token | Tổng hợp host prep, DMA, nhiều job nhỏ, result handling và PL compute chậm |
| Weight packing 1630,22 ms/token | Weight cache/residency tắt; CPU chuyển layout lại theo từng tile |
| Scale packing 631,51 ms/token | Weight scale tĩnh bị ghép với activation scale động trong cùng bảng |
| Preload chỉ đạt 5,88% job | Job tiếp theo được chuẩn bị sau khi job đang chạy đã kết thúc |
| 2210 VPU job/token | Giới hạn 256 rows và 64 Q8 blocks mỗi job |
| FFN down trả partial | SPU chưa giữ accumulator xuyên qua nhiều K-chunk |
| PL compute 1284,60 ms/token | FFN lớn, nhiều job nhỏ; nguyên nhân stall nội bộ chưa có RTL counter để xác định |
| 18.070 ZDMA descriptor/token | Transfer 64 KiB và một bộ ACT/WEIGHT/SCALE/RESULT cho từng job |
| Result path 230,38 ms/token | Kết quả được trả và CPU xử lý theo từng tile/chunk |
| Compute utilization 33,74% | Compute phải chờ host preparation, DMA, result read và retirement |
| Prefill 36,25 giây | Prompt được xử lý gần như nhiều GEMV tuần tự, ít tái sử dụng weight tile |

Báo cáo này chỉ mô tả các vấn đề hiện tại và nguyên nhân dẫn đến từng vấn đề. Báo cáo không bao gồm kế hoạch hoặc lộ trình tối ưu.
