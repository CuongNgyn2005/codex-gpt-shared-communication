## Đánh giá sau khi đọc lại repo v88 + RTL

**Verdict:** kế hoạch hiện tại **đúng hướng và có thể dùng làm roadmap**, nhưng **chưa nên triển khai nguyên trạng**. Có 6 điểm cần sửa trước khi bắt đầu để tránh lặp lại sai lầm v89–v93.

| Phase | Verdict | Đánh giá |
|---|---|---|
| Phase 0 | **BẮT BUỘC** | Giữ nguyên |
| Phase 1 | **APPROVE** | Có bằng chứng source rõ ràng |
| Phase 2 | **APPROVE sau sửa** | Benchmark đúng ý tưởng nhưng contract hiện tại còn 3 lỗi |
| Phase 3 | **CONDITIONAL** | Chỉ chạy nhánh được Phase 2 chứng minh |
| Phase 4 | **APPROVE sau sửa nhỏ** | P2_DONE đúng, nhưng counter ownership phải local theo job |
| Phase 5 | **APPROVE để synthesis thử** | 4096-word fixed là bắt buộc |
| Phase 6 | **CHƯA đủ numeric contract** | Cần sửa định nghĩa “bit-exact” |
| Phase 7 | **APPROVE về kiến trúc, chưa approve implementation** | Current SPU SiLU không tương thích |
| Phase 8 | **APPROVE** | Giữ 64→128→256 KiB |
| Phase 9 | **RESEARCH/BLOCKED** | Chưa có memory ownership proof cho arena cần thiết |

### 1. Phase 1 là bước production đầu tiên hợp lý

Source v88 xác nhận:

```cpp id="alhqox"
result_values = rows * group_blocks;
result_words  = ceil(result_values / 4);
scale_bytes   = result_words * 16;
```

fileciteturn119file0

Sau đó P2 thực sự:

```cpp id="n3n8py"
ddr_zero_range32(SPU_PARAM_BASE, job.scale_bytes);

for (row)
    for (gb)
        write packed 32-bit scale entry;
```

fileciteturn116file1

Vì mỗi 128-bit word chứa 4 entry 32-bit, sau các entry thật chỉ có tối đa **0–3 entry padding**.

Do đó Phase 1:

```text id="yaiywy"
zero entire scale buffer
→ REMOVE

write every real entry once
+ zero only final padding
```

là source-proven và không thay ABI.

**Giữ Phase 1 nguyên hướng.**

---

## 2. Phase 2 cần sửa trước khi implement

### Lỗi 1 — không hardcode `2210 jobs` làm workload generator

`2210` là expected workload của baseline hiện tại, nhưng benchmark không nên tự tạo 2210 jobs theo con số này.

Phải làm:

```text id="l97zdb"
production decode
      ↓
capture actual pack operations
      ↓
assert:
job_count == expected baseline count
bytes == expected baseline bytes
      ↓
replay EXACT captured operations
```

Lý do: v88 tự tính số job từ:

```cpp id="fbyedq"
rows
remaining K blocks
packed_q8_group_blocks_for_rows()
```

fileciteturn116file4

Nếu tiler hoặc capability thay đổi, hardcoded `2210` sẽ benchmark một workload không còn giống production.

### Lỗi 2 — standalone trace không đủ để replay actual weight data

Plan hiện nói:

> capture trace một lần, sau đó benchmark actual Q8_0 source.

Một trace chỉ chứa:

```text id="z16xaa"
tensor
row0
rows
k_block0
group_blocks
bytes
```

không thể tự tái tạo `block_q8_0 *` của model ở process khác.

Phase 2 nên triển khai **in-process diagnostic mode**:

```text id="t7aiwy"
llama-cli loads model
        ↓
first selected decode captures actual:
src0 pointer
weight_data_base
row0
rows
k_block0
group_blocks
...
        ↓
STOP before DMA/VPU for benchmark mode
        ↓
replay 1 warm-up
        ↓
5 timed repetitions
```

Hoặc benchmark binary phải tự load model và resolve tensor/source offsets. Không lưu raw pointers sang file rồi dùng ở process khác.

### Lỗi 3 — bỏ threshold `70%` và `50%`

Các rule:

```text id="u3a6jl"
store-bound >= 70%
transform-bound >= 50%
```

**không có cơ sở trong repo hoặc hardware contract.**

Bỏ chúng.

Kết quả Phase 2 chỉ nên báo:

```text id="adho1v"
T_pack_cached
T_store_uio
T_pack_uio

median
min
max
MiB/s
bytes
jobs
```

Sau đó chỉ kết luận bottleneck nếu kết quả ổn định qua repetitions.

Quan trọng hơn:

```text id="cdj6gn"
T_pack_uio
!=
T_pack_cached + T_store_uio
```

vì transform và store chung một memory pipeline/cache/bus environment. Không được cộng microbenchmark rồi coi đó là decomposition tuyệt đối.

---

## 3. Phase 2 cache condition cũng nên sửa

`cached RAM ring >= 64 MiB` hiện là một con số được chọn, không phải source-derived requirement.

Tốt hơn:

```text id="a1rflp"
read actual CPU cache size from Linux sysfs
```

và bắt buộc synthetic source working set lớn hơn last-level cache.

Benchmark **quan trọng nhất vẫn phải là actual captured model source**, không phải RAM ring.

RAM ring chỉ dùng cho `store-uio` isolation.

---

## 4. Phase 4: P2_DONE đúng, nhưng counter design cần thay

Repo xác nhận `core_done` chỉ là GEMV completion. `REG_STATUS` và `REG_DONE_JOB` expose `core_done`/`core_done_job_id`. fileciteturn128file0

Trong khi host P2 còn đợi:

```text id="3v4wyr"
raw count
stream done
SPU outputs
last_job
last_bank
stream quiescent
```

trước khi coi job hoàn tất. fileciteturn116file0

Vì vậy:

```text id="7i3hkh"
START → CORE_DONE → P2_DONE
```

là đúng.

Current SPU cũng đã có đúng các building blocks:

```text id="vzrkt9"
vpu_stream_count
vpu_stream_done_count
vpu_stream_entry_done_count
vpu_stream_final_write_count
last_job
last_bank
stream_status
```

và pair transport tăng count thêm 2 entries khi companion row hợp lệ. fileciteturn127file0

Nhưng tôi sẽ sửa Phase 4 thành **per-job local counters**, không dùng global counter delta làm hardware authority:

```text id="tq2r6e"
on accepted START:
    job_expected_entries = rows * group_blocks
    job_entries          = 0
    job_final_writes     = 0
    job_raw_done_seen    = 0

during job:
    increment local counters

P2_DONE when:
    job_entries == expected
    job_final_writes == rows
    raw_done_seen
    FIFO empty
    accum idle
    no output write
    job/bank match
    no error
```

Global counters hiện tại vẫn giữ cho telemetry.

Cách này tránh:

```text id="boks2s"
32-bit wrap
previous-job contamination
baseline subtraction
```

### Register block

`0x0220+` là vùng hợp lý: register map hiện tại kết thúc ở `0x021C`, sau đó `default`. fileciteturn129file0

Do đó proposal:

```text id="pkdcgu"
0x0220 PERF_ABI
...
0x0244 P2_DONE_HI
```

không conflict với source RTL hiện tại.

---

## 5. Phase 5 là đúng và sửa một bug thiết kế tiềm ẩn rất quan trọng

Current RTL advertise result capacity qua:

```verilog id="otofbu"
REG_CAPS[31:16] = RESULT_WORD_DEPTH
```

fileciteturn128file0

Current physical contract:

```text id="48iix1"
RESULT window = 0x00200000–0x00210000
              = 64 KiB

128-bit/word
→ 4096 words
→ 16384 INT32 values
```

Do đó constraint:

```text id="qc3vhz"
rows × group_blocks <= 16384
```

phải là invariant.

Plan đúng khi yêu cầu không để:

```verilog id="ysy6td"
RESULT_WORD_DEPTH =
    MAX_ROWS * MAX_GROUP_Q8_BLOCKS / 4
```

tăng theo `MAX_ROWS`.

Host hiện cũng sử dụng `g_packed_q8_result_words` để giới hạn `group_blocks`. fileciteturn116file4

**448×36 và 288×56 chỉ nên giữ tên là synthesis candidates.**

Không đưa chúng vào production config cho tới khi có:

```text id="675kwc"
Vivado utilization PASS
timing PASS
BRAM/URAM capacity PASS
RTL testbench PASS
board functional PASS
```

---

## 6. Phase 6: sửa lại “bit-exact v88”

Repo xác nhận P2 output hiện được host xử lý như sau:

```cpp id="81zm2f"
accum_col[row] += (float) q16 * (1.0f / 65536.0f);
```

fileciteturn116file0

Vậy Option A hiện viết:

> IEEE FP32, round-to-nearest-even = bit-exact

vẫn chưa đủ.

**Authority phải là output của deployed ARM host**, không phải mô tả toán học.

Phase 6 nên yêu cầu:

```text id="srwm4d"
capture golden per-chunk q16
capture golden accum_col FP32 bits
```

rồi RTL implementation phải match bit pattern sau từng chunk.

Contract tốt hơn:

```text id="ky30yg"
chunk0:
golden float bits == PL float bits

chunk1:
golden float accumulator bits == PL

...

final:
exact 32-bit float match
```

Nếu không match bitwise thì đó là numeric ABI mới, không được gọi là bit-exact.

---

## 7. Phase 7 cần sửa definition của “exact SiLU”

Plan đúng khi **không dùng `SPU_SiLU_Mul` hiện tại**.

Current RTL thậm chí cố tình giữ:

```verilog id="aul9lz"
silu_supported = 0
rmsnorm_supported = 0
rope_supported = 0
softmax_supported = 0
```

vì chưa end-to-end validated. fileciteturn127file0

Host graph v88 thực sự làm:

```text id="h8ruvx"
up
gate
SiLU(gate) × up
down
```

fileciteturn88file0

Nhưng Phase 7 không nên định nghĩa correctness bằng câu:

```text id="xwq7hw"
"F32-compatible SiLU"
```

quá mơ hồ.

Contract mạnh và trực tiếp hơn là:

```text id="59xq6h"
PL gate/up
      ↓
PL SwiGLU
      ↓
PL Q8_0 quantizer
      ↓
COMPARE WITH HOST:

block_q8_0.d  exact FP16 bits
block_q8_0.qs exact 32 bytes
```

Nếu **Q8_0 fused activation byte-for-byte giống canonical host `quantize_row_q8_0()`**, down projection nhận đúng input mà v88 nhận.

Đây nên là acceptance boundary của Phase 7A.

Không cần tranh luận một approximation SiLU có "gần đủ" hay không.

---

## 8. Phase 8 giữ nguyên

Source v88 ghi rõ lý do 64 KiB:

> hardware nhận descriptor lớn hơn, nhưng 512-KiB WEIGHT transfer từng gây normal-run staging corruption, nên production được giới hạn 64 KiB. fileciteturn116file0

Vì vậy:

```text id="d4jvyd"
64 KiB baseline
→ 128 KiB
→ 256 KiB
```

với integrity qualification riêng là đúng.

**Không thêm 512 KiB vào production qualification cho đến khi nguyên nhân corruption được xác định.**

---

## 9. Phase 9 phải được đánh dấu BLOCKED, không phải phase implementation bình thường

Host hiện chỉ chứng minh vùng:

```text id="eeg5w3"
DDR_BASE = 0x70000000
SIZE     = 0x10000000
END      = 0x80000000
```

tức 256 MiB reserved DDR. fileciteturn116file0

Do đó trước Phase 9 phải có riêng:

```text id="6b330p"
MEMORY-PREFLIGHT
```

chứng minh:

```text id="z9stxh"
required packed model bytes
physical/DMA arena size
Linux exclusion
device ownership
cache attributes
DMA address contract
```

Nếu chưa có proof đó:

> **không implement full persistent-weight arena.**

Phase 9 hiện chỉ nên được coi là architectural research target.

---

# Roadmap tôi chấp nhận sau review

```text id="b4lurh"
Phase 0
Freeze exact host + RTL + bitstream provenance
        ↓
Phase 1
One-pass SPU_PARAM
        ↓
A/B full inference
        ↓
Phase 2
In-process exact weight-path benchmark
NO arbitrary 70/50 thresholds
        ↓
Phase 3A or 3B
ONLY branch proven by Phase 2
        ↓
Phase 4
per-job START / CORE_DONE / P2_DONE hardware counters
        ↓
Phase 5
fixed 4096-word result capacity
+ synthesis-qualified adaptive tiling
        ↓
Phase 6
cross-K with captured FP32-bit golden contract
        ↓
Phase 7A
GGML SwiGLU → Q8_0 byte-exact bridge
        ↓
Phase 7B
gate/up/SwiGLU/down fusion
        ↓
Phase 8
ZDMA 64 → 128 → 256 qualification
        ↓
MEMORY-PREFLIGHT
        ↓
Phase 9
persistent PL-readable weight architecture
```

**Tôi approve Phase 1 để bắt đầu. Tôi chưa approve Phase 2 implementation cho đến khi sửa benchmark thành in-process actual-model replay và bỏ hai threshold 70%/50%.** Đây là hai thay đổi quan trọng nhất cần đưa vào optimization plan hiện tại. memcite