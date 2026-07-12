#!/bin/bash
# diy-mtk-fixup.sh - Post-autobuild fixups for BPI-R4 vendor-wifi build.
# Run after "autobuild.sh filogic prepare", from within the openwrt/ directory.

set -euo pipefail

log()  { echo "[MTK-FIX] $*"; }
warn() { echo "[MTK-FIX WARN] $*"; }

OPENWRT_ROOT="${OPENWRT_ROOT:-$(pwd)}"
MTK_SDK_DIR="${MTK_SDK_DIR:-${OPENWRT_ROOT}/../mtk-openwrt-feeds}"

# ── 1. Pin kernel Kconfig symbols not yet in our defconfig ──────────────
log "Pinning kernel Kconfig symbols..."

cfg="${OPENWRT_ROOT}/target/linux/mediatek/filogic/config-6.12"
if [ -f "$cfg" ]; then
    for symbol in MEDIATEK_2P5GE_PHY; do
        if grep -q "^# CONFIG_${symbol} is not set$" "$cfg"; then
            log "  ${symbol}: already pinned"
        else
            echo "# CONFIG_${symbol} is not set" >> "$cfg"
            log "  ${symbol}: pinned to n"
        fi
    done
else
    warn "config-6.12 not found at $cfg"
fi

# ── 2. KCONFIG_ALLCONFIG — default all unknown symbols to 'n' ──────────
log "Setting up KCONFIG_ALLCONFIG safety net..."

allconfig="${OPENWRT_ROOT}/target/linux/mediatek/filogic/kconfig-allnoconfig"
if [ ! -f "$allconfig" ]; then
    : > "$allconfig"
    log "  Created empty kconfig-allnoconfig"
else
    log "  kconfig-allnoconfig already exists"
fi

for mk in "${OPENWRT_ROOT}/target/linux/mediatek/filogic/target.mk" \
          "${OPENWRT_ROOT}/target/linux/mediatek/filogic_a73/target.mk"; do
    if [ -f "$mk" ] && ! grep -q 'KCONFIG_ALLCONFIG' "$mk"; then
        echo 'export KCONFIG_ALLCONFIG := $(TOPDIR)/target/linux/mediatek/filogic/kconfig-allnoconfig' >> "$mk"
        log "  Injected KCONFIG_ALLCONFIG into $(basename "$mk")"
    else
        log "  $(basename "$mk"): KCONFIG_ALLCONFIG already present"
    fi
done

# ── 3. CMake fix for mt76-vendor ───────────────────────────────────────
log "Fixing mt76-vendor CMake compatibility..."

cmake_list="${MTK_SDK_DIR}/feed/app/mt76-vendor/CMakeLists.txt"
if [ -f "$cmake_list" ]; then
    if grep -q 'VERSION 2\.8' "$cmake_list"; then
        sed -i 's/cmake_minimum_required(VERSION 2\.8)/cmake_minimum_required(VERSION 3.5)/' "$cmake_list"
        log "  Patched cmake_minimum_required: 2.8 → 3.5"
    else
        log "  CMake version already ≥ 3.5"
    fi
else
    warn "CMakeLists.txt not found: $cmake_list"
fi

log "All fixups complete."
