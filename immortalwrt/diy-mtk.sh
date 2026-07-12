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

# ── 3. CMake compatibility for mt76-vendor ────────────────────────────
# mt76-vendor's CMakeLists.txt declares cmake_minimum_required(VERSION 2.8).
# Modern CMake (≥3.5) rejects this.  Set the policy variable so CMake
# accepts the legacy declaration without modifying upstream source.
log "Enabling CMake policy compatibility..."

export CMAKE_POLICY_VERSION_MINIMUM=3.5
echo "CMAKE_POLICY_VERSION_MINIMUM=3.5" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
log "  CMAKE_POLICY_VERSION_MINIMUM=3.5 (set for all subsequent steps)"

# ── 4. Extract mtk_eth_reset.h from autobuild patch ───────────────────
log "Extracting mtk_eth_reset.h..."

patch_src="${MTK_SDK_DIR}/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/patches-6.12"
patch="${patch_src}/999-eth-93-mtk_eth_soc-add-internal-SER-notify-event.patch"
hdr="${OPENWRT_ROOT}/target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_eth_reset.h"

if [ -f "$patch" ]; then
    mkdir -p "$(dirname "$hdr")"
    sed -n '/^diff.*mtk_eth_reset\.h$/,/^diff.*mtk_eth_soc\.c$/{/^+++/!s/^+//;/^diff.*mtk_eth_soc\.c$/d;p}' "$patch" | \
        sed '1,/^@@/d' > "$hdr"
    if [ -s "$hdr" ] && grep -q 'MTK_FE_START_RESET' "$hdr"; then
        log "  Extracted ($(wc -l < "$hdr") lines)"
    else
        warn "Extraction produced empty or invalid file"
    fi
else
    warn "999-eth-93 patch not found"
fi

log "All fixups complete."
