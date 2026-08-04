#!/usr/bin/env bash
#
# zcu104_address_map.sh
#
# Reveal address ranges visible to Linux on a ZCU104 / Zynq UltraScale+ MPSoC.
# The script is read-only: it does not access /dev/mem or modify hardware.
#
# Usage:
#   chmod +x zcu104_address_map.sh
#   sudo ./zcu104_address_map.sh
#   sudo ./zcu104_address_map.sh --output zcu104_address_map.txt
#
# Notes:
# - Run as root for the most complete /proc/iomem and debugfs information.
# - PL peripheral addresses depend on the loaded bitstream and device tree.
# - Device-tree "reg" values are decoded using each node's inherited
#   #address-cells and #size-cells settings.

set -uo pipefail

OUTPUT=""
SHOW_ALL_DT=0

usage() {
    cat <<'EOF'
Usage:
  zcu104_address_map.sh [options]

Options:
  -o, --output FILE   Save the report to FILE as well as printing it.
  -a, --all-dt        Include every device-tree node containing a reg property.
  -h, --help          Show this help.

Examples:
  sudo ./zcu104_address_map.sh
  sudo ./zcu104_address_map.sh -o zcu104_address_map.txt
  sudo ./zcu104_address_map.sh --all-dt
EOF
}

while (($#)); do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a filename." >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        -a|--all-dt)
            SHOW_ALL_DT=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    exec > >(tee "$OUTPUT") 2>&1
fi

section() {
    printf '\n================================================================================\n'
    printf '%s\n' "$1"
    printf '================================================================================\n'
}

have() {
    command -v "$1" >/dev/null 2>&1
}

read_be_u32() {
    local file=$1
    [[ -r "$file" ]] || return 1
    od -An -N4 -tu4 --endian=big "$file" 2>/dev/null | tr -d '[:space:]'
}

find_inherited_cells() {
    local node=$1
    local property=$2
    local value=""
    while [[ "$node" == /sys/firmware/devicetree/base* ]]; do
        if [[ -r "$node/$property" ]]; then
            value=$(read_be_u32 "$node/$property") || true
            [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
        fi
        [[ "$node" == "/sys/firmware/devicetree/base" ]] && break
        node=$(dirname "$node")
    done
    return 1
}

node_compatible() {
    local node=$1
    if [[ -r "$node/compatible" ]]; then
        tr '\0' ',' < "$node/compatible" 2>/dev/null | sed 's/,$//'
    fi
}

node_status() {
    local node=$1
    if [[ -r "$node/status" ]]; then
        tr -d '\0' < "$node/status" 2>/dev/null
    else
        printf 'okay'
    fi
}

decode_reg_file() {
    local node=$1
    local reg="$node/reg"
    [[ -r "$reg" ]] || return 0

    local parent
    parent=$(dirname "$node")

    local ac sc
    ac=$(find_inherited_cells "$parent" "#address-cells" || printf '2')
    sc=$(find_inherited_cells "$parent" "#size-cells" || printf '1')

    [[ "$ac" =~ ^[0-9]+$ ]] || ac=2
    [[ "$sc" =~ ^[0-9]+$ ]] || sc=1

    local -a cells=()
    mapfile -t cells < <(od -An -v -tu4 --endian=big "$reg" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')

    local tuple_cells=$((ac + sc))
    (( tuple_cells > 0 )) || return 0

    local i j address size cell end
    for ((i=0; i+tuple_cells<=${#cells[@]}; i+=tuple_cells)); do
        address=0
        size=0

        for ((j=0; j<ac; j++)); do
            cell=${cells[i+j]}
            address=$(( (address << 32) | cell ))
        done

        for ((j=0; j<sc; j++)); do
            cell=${cells[i+ac+j]}
            size=$(( (size << 32) | cell ))
        done

        if (( size > 0 )); then
            end=$((address + size - 1))
            printf '    0x%016x - 0x%016x  size=0x%x (%u bytes)\n' \
                "$address" "$end" "$size" "$size"
        else
            printf '    address=0x%016x  size=0\n' "$address"
        fi
    done
}

print_dt_nodes() {
    local base=/sys/firmware/devicetree/base
    [[ -d "$base" ]] || {
        echo "Device tree is not exposed at $base."
        return
    }

    local node rel compat status
    while IFS= read -r -d '' node; do
        node=${node%/reg}
        rel=${node#"$base"}
        compat=$(node_compatible "$node")
        status=$(node_status "$node")

        if (( SHOW_ALL_DT == 0 )); then
            case "$rel $compat" in
                *amba*|*axi*|*fpga*|*firmware*|*reserved-memory*|*memory@*|*dma*|*uio*|*interrupt-controller*|*serial*|*ethernet*|*usb*|*sdhci*|*gpio*|*i2c*|*spi*|*can*|*watchdog*|*rtc*|*xilinx*)
                    ;;
                *)
                    continue
                    ;;
            esac
        fi

        printf '\nNode: %s\n' "${rel:-/}"
        printf '  status: %s\n' "$status"
        [[ -n "$compat" ]] && printf '  compatible: %s\n' "$compat"
        decode_reg_file "$node"
    done < <(find "$base" -type f -name reg -print0 2>/dev/null | sort -z)
}

print_uio() {
    local found=0 uio map name addr size offset
    for uio in /sys/class/uio/uio*; do
        [[ -e "$uio" ]] || continue
        found=1
        name=$(cat "$uio/name" 2>/dev/null || printf 'unknown')
        printf '\n%s  name=%s\n' "$(basename "$uio")" "$name"

        for map in "$uio"/maps/map*; do
            [[ -e "$map" ]] || continue
            addr=$(cat "$map/addr" 2>/dev/null || printf '?')
            size=$(cat "$map/size" 2>/dev/null || printf '?')
            offset=$(cat "$map/offset" 2>/dev/null || printf '0')
            printf '  %-5s addr=%-18s size=%-18s offset=%s' \
                "$(basename "$map")" "$addr" "$size" "$offset"
            if [[ "$addr" =~ ^0x[0-9a-fA-F]+$ && "$size" =~ ^0x[0-9a-fA-F]+$ ]]; then
                local a=$((addr))
                local s=$((size))
                if ((s > 0)); then
                    printf '  end=0x%x' "$((a+s-1))"
                fi
            fi
            printf '\n'
        done
    done
    (( found )) || echo "No UIO devices found under /sys/class/uio."
}

print_platform_resources() {
    local dev resource driver
    local found=0
    for dev in /sys/bus/platform/devices/*; do
        [[ -e "$dev" ]] || continue
        [[ -r "$dev/resource" ]] || continue
        found=1
        driver="unbound"
        [[ -L "$dev/driver" ]] && driver=$(basename "$(readlink -f "$dev/driver")")
        printf '\nDevice: %-42s driver=%s\n' "$(basename "$dev")" "$driver"
        awk '
            {
                start=strtonum("0x"$1)
                end=strtonum("0x"$2)
                flags=strtonum("0x"$3)
                if (end >= start)
                    printf "  0x%016x - 0x%016x  size=0x%x  flags=0x%x\n",
                           start, end, end-start+1, flags
            }
        ' "$dev/resource" 2>/dev/null || cat "$dev/resource"
    done
    (( found )) || echo "No platform-device resource files were readable."
}

print_reserved_memory() {
    local base=/sys/firmware/devicetree/base/reserved-memory
    [[ -d "$base" ]] || {
        echo "No reserved-memory node found."
        return
    }

    local node
    for node in "$base"/*; do
        [[ -d "$node" && -r "$node/reg" ]] || continue
        printf '\nReserved node: %s\n' "$(basename "$node")"
        decode_reg_file "$node"
        if [[ -e "$node/no-map" ]]; then
            echo "    property: no-map"
        fi
        if [[ -r "$node/compatible" ]]; then
            printf '    compatible: '
            tr '\0' ',' < "$node/compatible" | sed 's/,$//'
            printf '\n'
        fi
    done
}

print_fpga_manager() {
    local mgr state firmware flags
    local found=0
    for mgr in /sys/class/fpga_manager/fpga*; do
        [[ -e "$mgr" ]] || continue
        found=1
        state=$(cat "$mgr/state" 2>/dev/null || printf 'unknown')
        firmware=$(cat "$mgr/firmware" 2>/dev/null || printf 'unknown')
        flags=$(cat "$mgr/flags" 2>/dev/null || printf 'unknown')
        printf '%s: state=%s firmware=%s flags=%s\n' \
            "$(basename "$mgr")" "$state" "$firmware" "$flags"
    done
    (( found )) || echo "No FPGA manager exposed in sysfs."
}

print_dma_heaps() {
    if [[ -d /sys/class/dma_heap ]]; then
        find /sys/class/dma_heap -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null
    else
        echo "No DMA heap class exposed."
    fi

    if [[ -d /sys/class/dma ]]; then
        echo
        echo "DMA channels:"
        find /sys/class/dma -mindepth 1 -maxdepth 1 -printf '  %f\n' 2>/dev/null | sort
    fi
}

section "ZCU104 / ZYNQ ULTRASCALE+ ADDRESS-RANGE REPORT"
printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
printf 'Hostname:  %s\n' "$(hostname)"
printf 'Kernel:    %s\n' "$(uname -a)"
printf 'User:      %s (uid=%s)\n' "$(id -un)" "$(id -u)"
printf 'Machine:   %s\n' "$(uname -m)"
if [[ $(id -u) -ne 0 ]]; then
    echo "WARNING: Run with sudo for a more complete report."
fi

section "BOARD / DEVICE-TREE MODEL"
for f in \
    /sys/firmware/devicetree/base/model \
    /sys/firmware/devicetree/base/compatible \
    /proc/device-tree/model \
    /proc/device-tree/compatible
do
    if [[ -r "$f" ]]; then
        printf '%s: ' "$f"
        tr '\0' ',' < "$f" | sed 's/,$//'
        printf '\n'
    fi
done

section "LINUX PHYSICAL ADDRESS MAP: /proc/iomem"
if [[ -r /proc/iomem ]]; then
    cat /proc/iomem
else
    echo "Cannot read /proc/iomem."
fi

section "SYSTEM RAM RANGES"
if [[ -r /proc/iomem ]]; then
    grep -Ei 'System RAM|reserved|CMA|kernel code|kernel data|kernel bss' /proc/iomem || true
fi

section "DEVICE-TREE MEMORY AND MMIO 'reg' RANGES"
print_dt_nodes

section "RESERVED-MEMORY / CMA / SHARED-DMA RANGES"
print_reserved_memory

section "UIO DEVICES AND MMIO MAPS"
print_uio

section "PLATFORM DEVICE RESOURCE RANGES"
print_platform_resources

section "FPGA MANAGER STATUS"
print_fpga_manager

section "DMA HEAPS AND DMA CHANNELS"
print_dma_heaps

section "LOADED MODULES RELEVANT TO FPGA / UIO / DMA"
if [[ -r /proc/modules ]]; then
    grep -Ei 'xilinx|zynq|fpga|uio|dma|remoteproc|rpmsg' /proc/modules || \
        echo "No matching loaded modules found."
fi

section "INTERRUPTS RELEVANT TO FPGA / AXI / DMA / UIO"
if [[ -r /proc/interrupts ]]; then
    grep -Ei 'xilinx|zynq|fpga|axi|dma|uio|pl-' /proc/interrupts || \
        echo "No matching interrupt names found."
fi

section "IOMMU GROUPS"
if [[ -d /sys/kernel/iommu_groups ]]; then
    find /sys/kernel/iommu_groups -type l -printf '%h: %f -> %l\n' 2>/dev/null | sort || true
else
    echo "No IOMMU groups exposed."
fi

section "DEBUGFS FPGA / REGMAP INFORMATION"
if [[ ! -d /sys/kernel/debug ]]; then
    echo "debugfs directory is unavailable."
elif ! mountpoint -q /sys/kernel/debug 2>/dev/null; then
    echo "debugfs is not mounted."
    echo "As root, mount it with: mount -t debugfs none /sys/kernel/debug"
else
    if [[ -d /sys/kernel/debug/regmap ]]; then
        find /sys/kernel/debug/regmap -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
    else
        echo "No regmap debug information exposed."
    fi
fi

section "SUMMARY NOTES"
cat <<'EOF'
1. /proc/iomem is Linux's consolidated physical-address map.
2. UIO map addresses are normally the ranges used by user-space FPGA drivers.
3. Device-tree reg entries show addresses assigned to PS and PL peripherals.
4. A PL IP appears only when the loaded device tree describes it, or when a
   platform/UIO driver creates a corresponding device.
5. The ZCU104 does not have one universal PL address map. Vivado Address Editor,
   the exported XSA, the device tree, and the loaded bitstream determine it.
6. This report intentionally does not probe /dev/mem because probing arbitrary
   physical addresses can hang or reset the board.
EOF

if [[ -n "$OUTPUT" ]]; then
    printf '\nReport saved to: %s\n' "$OUTPUT"
fi
