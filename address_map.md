
================================================================================
ZCU104 / ZYNQ ULTRASCALE+ ADDRESS-RANGE REPORT
================================================================================
Generated: 2026-07-24T11:39:35+00:00
Hostname:  ZCU104-02
Kernel:    Linux ZCU104-02 5.10.0-xilinx-v2021.2 #1 SMP Tue Oct 12 09:30:57 UTC 2021 aarch64 GNU/Linux
User:      root (uid=0)
Machine:   aarch64

================================================================================
BOARD / DEVICE-TREE MODEL
================================================================================
/sys/firmware/devicetree/base/model: ZynqMP ZCU104 RevC
/sys/firmware/devicetree/base/compatible: xlnx,zynqmp-zcu104-revC,xlnx,zynqmp-zcu104,xlnx,zynqmp
/proc/device-tree/model: ZynqMP ZCU104 RevC
/proc/device-tree/compatible: xlnx,zynqmp-zcu104-revC,xlnx,zynqmp-zcu104,xlnx,zynqmp

================================================================================
LINUX PHYSICAL ADDRESS MAP: /proc/iomem
================================================================================
00000000-6fffffff : System RAM
  00200000-0138ffff : Kernel code
  01390000-0159ffff : reserved
  015a0000-0172ffff : Kernel data
  5d000000-5effffff : reserved
  5f8f0000-5fbf0fff : reserved
  5fbf1000-5fc48fff : reserved
  5fc4b000-5fc4cfff : reserved
  5fc4d000-5fc4dfff : reserved
  5fc4e000-5fc51fff : reserved
  5fc52000-6fffffff : reserved
fd0b0000-fd0bffff : fd0b0000.perf-monitor perf-monitor@fd0b0000
fd0c0000-fd0c1fff : fd0c0000.ahci ahci@fd0c0000
fd3d0000-fd3d0fff : fd400000.phy siou
fd400000-fd43ffff : fd400000.phy serdes
fd490000-fd49ffff : fd490000.perf-monitor perf-monitor@fd490000
fd4a0000-fd4a0fff : fd4a0000.display dp
fd4aa000-fd4aafff : fd4a0000.display blend
fd4ab000-fd4abfff : fd4a0000.display av_buf
fd4ac000-fd4acfff : fd4a0000.display aud
fd4c0000-fd4c0fff : fd4c0000.dma-controller dma-controller@fd4c0000
fd4d0000-fd4d0fff : fd4d0000.watchdog watchdog@fd4d0000
fd6e9000-fd6edfff : fd6e9000.pmu pmu@9000
fe200000-fe207fff : dwc3@fe200000
  fe200000-fe207fff : xhci-hcd.1.auto dwc3@fe200000
fe20c100-fe23ffff : fe200000.dwc3 dwc3@fe200000
ff000000-ff000fff : xuartps
ff010000-ff010fff : xuartps
ff030000-ff030fff : ff030000.i2c i2c@ff030000
ff070000-ff070fff : ff070000.can can@ff070000
ff0a0000-ff0a0fff : ff0a0000.gpio gpio@ff0a0000
ff0e0000-ff0e0fff : ff0e0000.ethernet ethernet@ff0e0000
ff0f0000-ff0f0fff : ff0f0000.spi spi@ff0f0000
ff150000-ff150fff : ff150000.watchdog watchdog@ff150000
ff170000-ff170fff : ff170000.mmc mmc@ff170000
ff960000-ff960fff : ff960000.memory-controller memory-controller@ff960000
ff9d0000-ff9d00ff : ff9d0000.usb0 usb0@ff9d0000
ffa00000-ffa0ffff : ffa00000.perf-monitor perf-monitor@ffa00000
ffa10000-ffa1ffff : ffa10000.perf-monitor perf-monitor@ffa10000
ffa50000-ffa507ff : ffa50000.ams ams-base
ffa60000-ffa600ff : ffa60000.rtc rtc@ffa60000
ffa80000-ffa80fff : ffa80000.dma dma@ffa80000
ffa90000-ffa90fff : ffa90000.dma dma@ffa90000
ffaa0000-ffaa0fff : ffaa0000.dma dma@ffaa0000
ffab0000-ffab0fff : ffab0000.dma dma@ffab0000
ffac0000-ffac0fff : ffac0000.dma dma@ffac0000
ffad0000-ffad0fff : ffad0000.dma dma@ffad0000
ffae0000-ffae0fff : ffae0000.dma dma@ffae0000
ffaf0000-ffaf0fff : ffaf0000.dma dma@ffaf0000

================================================================================
SYSTEM RAM RANGES
================================================================================
00000000-6fffffff : System RAM
  00200000-0138ffff : Kernel code
  01390000-0159ffff : reserved
  015a0000-0172ffff : Kernel data
  5d000000-5effffff : reserved
  5f8f0000-5fbf0fff : reserved
  5fbf1000-5fc48fff : reserved
  5fc4b000-5fc4cfff : reserved
  5fc4d000-5fc4dfff : reserved
  5fc4e000-5fc51fff : reserved
  5fc52000-6fffffff : reserved

================================================================================
DEVICE-TREE MEMORY AND MMIO 'reg' RANGES
================================================================================

Node: /amba_pl@0/CGRA@400000000
  status: okay
  compatible: generic-uio
    0x0000000400000000 - 0x00000004ffffffff  size=0x100000000 (4294967296 bytes)

Node: /axi/ahci@fd0c0000
  status: okay
  compatible: ceva,ahci-1v84
    0x00000000fd0c0000 - 0x00000000fd0c1fff  size=0x2000 (8192 bytes)

Node: /axi/ams@ffa50000/ams_pl@ffa50c00
  status: okay
  compatible: xlnx,zynqmp-ams-pl
    0x00000000ffa50c00 - 0x00000000ffa50fff  size=0x400 (1024 bytes)

Node: /axi/ams@ffa50000/ams_ps@ffa50800
  status: okay
  compatible: xlnx,zynqmp-ams-ps
    0x00000000ffa50800 - 0x00000000ffa50bff  size=0x400 (1024 bytes)

Node: /axi/ams@ffa50000
  status: okay
  compatible: xlnx,zynqmp-ams
    0x00000000ffa50000 - 0x00000000ffa507ff  size=0x800 (2048 bytes)

Node: /axi/can@ff060000
  status: disabled
  compatible: xlnx,zynq-can-1.0
    0x00000000ff060000 - 0x00000000ff060fff  size=0x1000 (4096 bytes)

Node: /axi/can@ff070000
  status: okay
  compatible: xlnx,zynq-can-1.0
    0x00000000ff070000 - 0x00000000ff070fff  size=0x1000 (4096 bytes)

Node: /axi/cci@fd6e0000/pmu@9000
  status: okay
  compatible: arm,cci-400-pmu,r1
    0x0000000000009000 - 0x000000000000dfff  size=0x5000 (20480 bytes)

Node: /axi/cci@fd6e0000
  status: okay
  compatible: arm,cci-400
    0x00000000fd6e0000 - 0x00000000fd6e8fff  size=0x9000 (36864 bytes)

Node: /axi/display@fd4a0000
  status: okay
  compatible: xlnx,zynqmp-dpsub-1.7
    0x00000000fd4a0000 - 0x00000000fd4a0fff  size=0x1000 (4096 bytes)
    0x00000000fd4aa000 - 0x00000000fd4aafff  size=0x1000 (4096 bytes)
    0x00000000fd4ab000 - 0x00000000fd4abfff  size=0x1000 (4096 bytes)
    0x00000000fd4ac000 - 0x00000000fd4acfff  size=0x1000 (4096 bytes)

Node: /axi/dma-controller@fd4c0000
  status: okay
  compatible: xlnx,zynqmp-dpdma
    0x00000000fd4c0000 - 0x00000000fd4c0fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd500000
  status: okay
  compatible: generic-uio
    0x00000000fd500000 - 0x00000000fd500fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd510000
  status: okay
  compatible: generic-uio
    0x00000000fd510000 - 0x00000000fd510fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd520000
  status: okay
  compatible: generic-uio
    0x00000000fd520000 - 0x00000000fd520fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd530000
  status: okay
  compatible: generic-uio
    0x00000000fd530000 - 0x00000000fd530fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd540000
  status: okay
  compatible: generic-uio
    0x00000000fd540000 - 0x00000000fd540fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd550000
  status: okay
  compatible: generic-uio
    0x00000000fd550000 - 0x00000000fd550fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd560000
  status: okay
  compatible: generic-uio
    0x00000000fd560000 - 0x00000000fd560fff  size=0x1000 (4096 bytes)

Node: /axi/dma@fd570000
  status: okay
  compatible: generic-uio
    0x00000000fd570000 - 0x00000000fd570fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffa80000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffa80000 - 0x00000000ffa80fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffa90000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffa90000 - 0x00000000ffa90fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffaa0000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffaa0000 - 0x00000000ffaa0fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffab0000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffab0000 - 0x00000000ffab0fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffac0000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffac0000 - 0x00000000ffac0fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffad0000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffad0000 - 0x00000000ffad0fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffae0000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffae0000 - 0x00000000ffae0fff  size=0x1000 (4096 bytes)

Node: /axi/dma@ffaf0000
  status: okay
  compatible: xlnx,zynqmp-dma-1.0
    0x00000000ffaf0000 - 0x00000000ffaf0fff  size=0x1000 (4096 bytes)

Node: /axi/ethernet@ff0b0000
  status: disabled
  compatible: cdns,zynqmp-gem,cdns,gem
    0x00000000ff0b0000 - 0x00000000ff0b0fff  size=0x1000 (4096 bytes)

Node: /axi/ethernet@ff0c0000
  status: disabled
  compatible: cdns,zynqmp-gem,cdns,gem
    0x00000000ff0c0000 - 0x00000000ff0c0fff  size=0x1000 (4096 bytes)

Node: /axi/ethernet@ff0d0000
  status: disabled
  compatible: cdns,zynqmp-gem,cdns,gem
    0x00000000ff0d0000 - 0x00000000ff0d0fff  size=0x1000 (4096 bytes)

Node: /axi/ethernet@ff0e0000/ethernet-phy@c
  status: okay
    address=0x000000000000000c  size=0

Node: /axi/ethernet@ff0e0000
  status: okay
  compatible: cdns,zynqmp-gem,cdns,gem
    0x00000000ff0e0000 - 0x00000000ff0e0fff  size=0x1000 (4096 bytes)

Node: /axi/gpio@ff0a0000
  status: okay
  compatible: xlnx,zynqmp-gpio-1.0
    0x00000000ff0a0000 - 0x00000000ff0a0fff  size=0x1000 (4096 bytes)

Node: /axi/gpu@fd4b0000
  status: okay
  compatible: arm,mali-400,arm,mali-utgard
    0x00000000fd4b0000 - 0x00000000fd4bffff  size=0x10000 (65536 bytes)

Node: /axi/i2c@ff020000
  status: disabled
  compatible: cdns,i2c-r1p14
    0x00000000ff020000 - 0x00000000ff020fff  size=0x1000 (4096 bytes)

Node: /axi/i2c@ff030000/gpio@20
  status: okay
  compatible: ti,tca6416
    address=0x0000000000000020  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@0/eeprom@54
  status: okay
  compatible: atmel,24c08
    address=0x0000000000000054  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@0
  status: okay
    address=0x0000000000000000  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@1
  status: okay
    address=0x0000000000000001  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@2/irps5401@43
  status: okay
  compatible: infineon,irps5401
    address=0x0000000000000043  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@2/irps5401@44
  status: okay
  compatible: infineon,irps5401
    address=0x0000000000000044  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@2
  status: okay
    address=0x0000000000000002  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@3/ina226@40
  status: okay
  compatible: ti,ina226
    address=0x0000000000000040  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@3
  status: okay
    address=0x0000000000000003  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@5
  status: okay
    address=0x0000000000000005  size=0

Node: /axi/i2c@ff030000/i2c-mux@74/i2c@7
  status: okay
    address=0x0000000000000007  size=0

Node: /axi/i2c@ff030000/i2c-mux@74
  status: okay
  compatible: nxp,pca9548
    address=0x0000000000000074  size=0

Node: /axi/i2c@ff030000
  status: okay
  compatible: cdns,i2c-r1p14
    0x00000000ff030000 - 0x00000000ff030fff  size=0x1000 (4096 bytes)

Node: /axi/interrupt-controller@f9010000
  status: okay
  compatible: arm,gic-400
    0x00000000f9010000 - 0x00000000f901ffff  size=0x10000 (65536 bytes)
    0x00000000f9020000 - 0x00000000f903ffff  size=0x20000 (131072 bytes)
    0x00000000f9040000 - 0x00000000f905ffff  size=0x20000 (131072 bytes)
    0x00000000f9060000 - 0x00000000f907ffff  size=0x20000 (131072 bytes)

Node: /axi/memory-controller@fd070000
  status: okay
  compatible: xlnx,zynqmp-ddrc-2.40a
    0x00000000fd070000 - 0x00000000fd09ffff  size=0x30000 (196608 bytes)

Node: /axi/memory-controller@ff960000
  status: okay
  compatible: xlnx,zynqmp-ocmc-1.0
    0x00000000ff960000 - 0x00000000ff960fff  size=0x1000 (4096 bytes)

Node: /axi/mmc@ff160000
  status: disabled
  compatible: xlnx,zynqmp-8.9a,arasan,sdhci-8.9a
    0x00000000ff160000 - 0x00000000ff160fff  size=0x1000 (4096 bytes)

Node: /axi/mmc@ff170000
  status: okay
  compatible: xlnx,zynqmp-8.9a,arasan,sdhci-8.9a
    0x00000000ff170000 - 0x00000000ff170fff  size=0x1000 (4096 bytes)

Node: /axi/nand-controller@ff100000
  status: disabled
  compatible: xlnx,zynqmp-nand-controller,arasan,nfc-v3p10
    0x00000000ff100000 - 0x00000000ff100fff  size=0x1000 (4096 bytes)

Node: /axi/pcie@fd0e0000
  status: disabled
  compatible: xlnx,nwl-pcie-2.11
    0x00000000fd0e0000 - 0x00000000fd0e0fff  size=0x1000 (4096 bytes)
    0x00000000fd480000 - 0x00000000fd480fff  size=0x1000 (4096 bytes)
    0x0000008000000000 - 0x0000008000ffffff  size=0x1000000 (16777216 bytes)

Node: /axi/perf-monitor@fd0b0000
  status: okay
  compatible: xlnx,axi-perf-monitor
    0x00000000fd0b0000 - 0x00000000fd0bffff  size=0x10000 (65536 bytes)

Node: /axi/perf-monitor@fd490000
  status: okay
  compatible: xlnx,axi-perf-monitor
    0x00000000fd490000 - 0x00000000fd49ffff  size=0x10000 (65536 bytes)

Node: /axi/perf-monitor@ffa00000
  status: okay
  compatible: xlnx,axi-perf-monitor
    0x00000000ffa00000 - 0x00000000ffa0ffff  size=0x10000 (65536 bytes)

Node: /axi/perf-monitor@ffa10000
  status: okay
  compatible: xlnx,axi-perf-monitor
    0x00000000ffa10000 - 0x00000000ffa1ffff  size=0x10000 (65536 bytes)

Node: /axi/phy@fd400000
  status: okay
  compatible: xlnx,zynqmp-psgtr-v1.1
    0x00000000fd400000 - 0x00000000fd43ffff  size=0x40000 (262144 bytes)
    0x00000000fd3d0000 - 0x00000000fd3d0fff  size=0x1000 (4096 bytes)

Node: /axi/rtc@ffa60000
  status: okay
  compatible: xlnx,zynqmp-rtc
    0x00000000ffa60000 - 0x00000000ffa600ff  size=0x100 (256 bytes)

Node: /axi/serial@ff000000
  status: okay
  compatible: cdns,uart-r1p12,xlnx,xuartps
    0x00000000ff000000 - 0x00000000ff000fff  size=0x1000 (4096 bytes)

Node: /axi/serial@ff010000
  status: okay
  compatible: cdns,uart-r1p12,xlnx,xuartps
    0x00000000ff010000 - 0x00000000ff010fff  size=0x1000 (4096 bytes)

Node: /axi/smmu@fd800000
  status: disabled
  compatible: arm,mmu-500
    0x00000000fd800000 - 0x00000000fd81ffff  size=0x20000 (131072 bytes)

Node: /axi/spi@ff040000
  status: disabled
  compatible: cdns,spi-r1p6
    0x00000000ff040000 - 0x00000000ff040fff  size=0x1000 (4096 bytes)

Node: /axi/spi@ff050000
  status: disabled
  compatible: cdns,spi-r1p6
    0x00000000ff050000 - 0x00000000ff050fff  size=0x1000 (4096 bytes)

Node: /axi/spi@ff0f0000/flash@0/partition@0
  status: okay
    0x0000000000000000 - 0x00000000000fffff  size=0x100000 (1048576 bytes)

Node: /axi/spi@ff0f0000/flash@0/partition@1
  status: okay
    0x0000000000100000 - 0x000000000013ffff  size=0x40000 (262144 bytes)

Node: /axi/spi@ff0f0000/flash@0/partition@2
  status: okay
    0x0000000000140000 - 0x000000000173ffff  size=0x1600000 (23068672 bytes)

Node: /axi/spi@ff0f0000/flash@0
  status: okay
  compatible: m25p80,jedec,spi-nor
    address=0x0000000000000000  size=0

Node: /axi/spi@ff0f0000
  status: okay
  compatible: xlnx,zynqmp-qspi-1.0
    0x00000000ff0f0000 - 0x00000000ff0f0fff  size=0x1000 (4096 bytes)
    0x00000000c0000000 - 0x00000000c7ffffff  size=0x8000000 (134217728 bytes)

Node: /axi/timer@ff110000
  status: disabled
  compatible: cdns,ttc
    0x00000000ff110000 - 0x00000000ff110fff  size=0x1000 (4096 bytes)

Node: /axi/timer@ff120000
  status: disabled
  compatible: cdns,ttc
    0x00000000ff120000 - 0x00000000ff120fff  size=0x1000 (4096 bytes)

Node: /axi/timer@ff130000
  status: disabled
  compatible: cdns,ttc
    0x00000000ff130000 - 0x00000000ff130fff  size=0x1000 (4096 bytes)

Node: /axi/timer@ff140000
  status: disabled
  compatible: cdns,ttc
    0x00000000ff140000 - 0x00000000ff140fff  size=0x1000 (4096 bytes)

Node: /axi/usb0@ff9d0000/dwc3@fe200000
  status: okay
  compatible: snps,dwc3
    0x00000000fe200000 - 0x00000000fe23ffff  size=0x40000 (262144 bytes)

Node: /axi/usb0@ff9d0000
  status: okay
  compatible: xlnx,zynqmp-dwc3
    0x00000000ff9d0000 - 0x00000000ff9d00ff  size=0x100 (256 bytes)

Node: /axi/usb1@ff9e0000/dwc3@fe300000
  status: disabled
  compatible: snps,dwc3
    0x00000000fe300000 - 0x00000000fe33ffff  size=0x40000 (262144 bytes)

Node: /axi/usb1@ff9e0000
  status: disabled
  compatible: xlnx,zynqmp-dwc3
    0x00000000ff9e0000 - 0x00000000ff9e00ff  size=0x100 (256 bytes)

Node: /axi/watchdog@fd4d0000
  status: okay
  compatible: cdns,wdt-r1p2
    0x00000000fd4d0000 - 0x00000000fd4d0fff  size=0x1000 (4096 bytes)

Node: /axi/watchdog@ff150000
  status: okay
  compatible: cdns,wdt-r1p2
    0x00000000ff150000 - 0x00000000ff150fff  size=0x1000 (4096 bytes)

Node: /ddr_high@000800000000
  status: okay
  compatible: generic-uio
    0x0000000800000000 - 0x000000087fffffff  size=0x80000000 (2147483648 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_chash@50
  status: okay
    0x0000000000000050 - 0x0000000000000053  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_dna@c
  status: okay
    0x000000000000000c - 0x0000000000000017  size=0xc (12 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_miscusr@40
  status: okay
    0x0000000000000040 - 0x0000000000000043  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_ppk0hash@a0
  status: okay
    0x00000000000000a0 - 0x00000000000000cf  size=0x30 (48 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_ppk1hash@d0
  status: okay
    0x00000000000000d0 - 0x00000000000000ff  size=0x30 (48 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_pufmisc@54
  status: okay
    0x0000000000000054 - 0x0000000000000057  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_sec@58
  status: okay
    0x0000000000000058 - 0x000000000000005b  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_spkid@5c
  status: okay
    0x000000000000005c - 0x000000000000005f  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr0@20
  status: okay
    0x0000000000000020 - 0x0000000000000023  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr1@24
  status: okay
    0x0000000000000024 - 0x0000000000000027  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr2@28
  status: okay
    0x0000000000000028 - 0x000000000000002b  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr3@2c
  status: okay
    0x000000000000002c - 0x000000000000002f  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr4@30
  status: okay
    0x0000000000000030 - 0x0000000000000033  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr5@34
  status: okay
    0x0000000000000034 - 0x0000000000000037  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr6@38
  status: okay
    0x0000000000000038 - 0x000000000000003b  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/efuse_usr7@3c
  status: okay
    0x000000000000003c - 0x000000000000003f  size=0x4 (4 bytes)

Node: /firmware/zynqmp-firmware/nvmem_firmware/soc_revision@0
  status: okay
    0x0000000000000000 - 0x0000000000000003  size=0x4 (4 bytes)

Node: /reserved-memory/buffer@0
  status: okay
    0x0000000800000000 - 0x000000087fffffff  size=0x80000000 (2147483648 bytes)

================================================================================
RESERVED-MEMORY / CMA / SHARED-DMA RANGES
================================================================================

Reserved node: buffer@0
    0x0000000800000000 - 0x000000087fffffff  size=0x80000000 (2147483648 bytes)
    property: no-map

================================================================================
UIO DEVICES AND MMIO MAPS
================================================================================

uio0  name=axi-pmon
  map0  addr=0x00000000ffa00000 size=0x0000000000010000 offset=0x0  end=0xffa0ffff
  map1  addr=0xffff000001b6d000 size=0x0000000000001000 offset=0x0  end=0xffff000001b6dfff

uio1  name=axi-pmon
  map0  addr=0x00000000fd0b0000 size=0x0000000000010000 offset=0x0  end=0xfd0bffff
  map1  addr=0xffff000001b6f000 size=0x0000000000001000 offset=0x0  end=0xffff000001b6ffff

uio10  name=dma
  map0  addr=0x00000000fd560000 size=0x0000000000001000 offset=0x0  end=0xfd560fff

uio11  name=dma
  map0  addr=0x00000000fd570000 size=0x0000000000001000 offset=0x0  end=0xfd570fff

uio12  name=CGRA
  map0  addr=0x0000000400000000 size=0x0000000100000000 offset=0x0  end=0x4ffffffff

uio13  name=ddr_high
  map0  addr=0x0000000800000000 size=0x0000000080000000 offset=0x0  end=0x87fffffff

uio2  name=axi-pmon
  map0  addr=0x00000000fd490000 size=0x0000000000010000 offset=0x0  end=0xfd49ffff
  map1  addr=0xffff00000201e000 size=0x0000000000001000 offset=0x0  end=0xffff00000201efff

uio3  name=axi-pmon
  map0  addr=0x00000000ffa10000 size=0x0000000000010000 offset=0x0  end=0xffa1ffff
  map1  addr=0xffff00000213b000 size=0x0000000000001000 offset=0x0  end=0xffff00000213bfff

uio4  name=dma
  map0  addr=0x00000000fd500000 size=0x0000000000001000 offset=0x0  end=0xfd500fff

uio5  name=dma
  map0  addr=0x00000000fd510000 size=0x0000000000001000 offset=0x0  end=0xfd510fff

uio6  name=dma
  map0  addr=0x00000000fd520000 size=0x0000000000001000 offset=0x0  end=0xfd520fff

uio7  name=dma
  map0  addr=0x00000000fd530000 size=0x0000000000001000 offset=0x0  end=0xfd530fff

uio8  name=dma
  map0  addr=0x00000000fd540000 size=0x0000000000001000 offset=0x0  end=0xfd540fff

uio9  name=dma
  map0  addr=0x00000000fd550000 size=0x0000000000001000 offset=0x0  end=0xfd550fff

================================================================================
PLATFORM DEVICE RESOURCE RANGES
================================================================================
No platform-device resource files were readable.

================================================================================
FPGA MANAGER STATUS
================================================================================
fpga0: state=operating firmware=unknown flags=0

================================================================================
DMA HEAPS AND DMA CHANNELS
================================================================================
No DMA heap class exposed.

DMA channels:
  dma0chan0
  dma1chan0
  dma2chan0
  dma3chan0
  dma4chan0
  dma5chan0
  dma6chan0
  dma7chan0
  dma8chan0
  dma8chan1
  dma8chan2
  dma8chan3
  dma8chan4
  dma8chan5

================================================================================
LOADED MODULES RELEVANT TO FPGA / UIO / DMA
================================================================================
uio_pdrv_genirq 16384 0 - Live 0xffff800008db0000

================================================================================
INTERRUPTS RELEVANT TO FPGA / AXI / DMA / UIO
================================================================================
 14:          0          0          0          0     GICv2  67 Level     zynqmp_ipi
 20:          0          0          0          0     GICv2 156 Level     dma
 21:          0          0          0          0     GICv2 157 Level     dma
 22:          0          0          0          0     GICv2 158 Level     dma
 23:          0          0          0          0     GICv2 159 Level     dma
 24:          0          0          0          0     GICv2 160 Level     dma
 25:          0          0          0          0     GICv2 161 Level     dma
 26:          0          0          0          0     GICv2 162 Level     dma
 27:          0          0          0          0     GICv2 163 Level     dma
 29:          0          0          0          0     GICv2 109 Level     zynqmp-dma
 30:          0          0          0          0     GICv2 110 Level     zynqmp-dma
 31:          0          0          0          0     GICv2 111 Level     zynqmp-dma
 32:          0          0          0          0     GICv2 112 Level     zynqmp-dma
 33:          0          0          0          0     GICv2 113 Level     zynqmp-dma
 34:          0          0          0          0     GICv2 114 Level     zynqmp-dma
 35:          0          0          0          0     GICv2 115 Level     zynqmp-dma
 36:          0          0          0          0     GICv2 116 Level     zynqmp-dma
 42:          0          0          0          0     GICv2  57 Level     axi-pmon, axi-pmon
 43:          0          0          0          0     GICv2 155 Level     axi-pmon, axi-pmon
 54:         22          0          0          0     GICv2 154 Level     fd4c0000.dma-controller

================================================================================
IOMMU GROUPS
================================================================================

================================================================================
DEBUGFS FPGA / REGMAP INFORMATION
================================================================================
5-0040

================================================================================
SUMMARY NOTES
================================================================================
1. /proc/iomem is Linux's consolidated physical-address map.
2. UIO map addresses are normally the ranges used by user-space FPGA drivers.
3. Device-tree reg entries show addresses assigned to PS and PL peripherals.
4. A PL IP appears only when the loaded device tree describes it, or when a
   platform/UIO driver creates a corresponding device.
5. The ZCU104 does not have one universal PL address map. Vivado Address Editor,
   the exported XSA, the device tree, and the loaded bitstream determine it.
6. This report intentionally does not probe /dev/mem because probing arbitrary
   physical addresses can hang or reset the board.

Report saved to: zcu104_address_map.txt
