# FPGA Timing Handoff

Source: owner-provided terminal summary.

## Sampler timing

| Metric | Value |
| --- | ---: |
| Sampling time | 7.54 ms / 17 runs |
| Sampling time per token | 0.44 ms/token |
| Sampling speed | 2254.94 tokens/s |

## FPGA decode summary

| Metric | Value |
| --- | ---: |
| Decode tokens | 3 |
| End-to-end decode speed | 0.38 tokens/s |
| End-to-end decode time | 7996.58 ms |
| FPGA matmul hooks | 546 |
| VPU runs | 6630 |
| IP-only compute time | 1421.01 ms |
| IP-only compute speed | 2.11 tokens/s |
| H2IP DMA time | 1034.67 ms |
| Output transfer time | 703.65 ms |
| IP + transfer time | 3159.33 ms |
| IP + transfer speed | 0.95 tokens/s |
| CPU preparation time | 5327.91 ms |
| Direct weight packing | 4325.44 ms (81.2%) |
| Scale-table packing | 951.13 ms |
| Preloaded input DMA | 0.00 ms; 0 overlap jobs |
| ZDMA descriptors | 54210; 2279.08 MiB |
| FPGA GEMV coverage | 910 completed; 0 fallback; 0 reject |
| SPU stream status | 0 drop; 0 error |
| Weight residency | 106/128 slots; 1802 hit; 36910 miss |

## llama.cpp context timing

| Metric | Value |
| --- | ---: |
| Load time | 69019.92 ms |
| Prompt evaluation time | 29017.59 ms / 13 tokens |
| Prompt evaluation time per token | 2232.12 ms/token |
| Prompt evaluation speed | 0.45 tokens/s |
| Decode evaluation time | 8004.87 ms / 3 runs |
| Decode evaluation time per token | 2668.29 ms/token |
| Decode evaluation speed | 0.37 tokens/s |
| Total time | 37147.13 ms / 16 tokens |
| Graphs reused | 2 |
