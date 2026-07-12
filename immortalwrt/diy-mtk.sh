#!/bin/bash
set -euo pipefail

log()  { echo "[MTK-FIX] $*"; }
warn() { echo "[MTK-FIX WARN] $*"; }

OPENWRT_ROOT="${OPENWRT_ROOT:-$(pwd)}"
MTK_SDK_DIR="${MTK_SDK_DIR:-${OPENWRT_ROOT}/../mtk-openwrt-feeds}"

log "Pinning kernel Kconfig symbols..."
cfg="${OPENWRT_ROOT}/target/linux/mediatek/filogic/config-6.12"
if [ -f "$cfg" ]; then
    for symbol in MEDIATEK_2P5GE_PHY; do
        sed -i "/^CONFIG_${symbol}=/d; /^# CONFIG_${symbol} is not set$/d" "$cfg"
        echo "# CONFIG_${symbol} is not set" >> "$cfg"
        log "  ${symbol}: pinned to n"
    done
else
    warn "config-6.12 not found"
fi

log "Enabling CMake policy compatibility..."
export CMAKE_POLICY_VERSION_MINIMUM=3.5
echo "CMAKE_POLICY_VERSION_MINIMUM=3.5" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
log "  CMAKE_POLICY_VERSION_MINIMUM=3.5"

log "Overlaying HNAT/NPU kernel files..."
files_src="${MTK_SDK_DIR}/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/files-6.12"
files_dst="${OPENWRT_ROOT}/target/linux/mediatek/files-6.12"
if [ -d "$files_src" ]; then
    mkdir -p "$files_dst"
    tmp_dst=$(mktemp -d)
    trap "rm -rf '$tmp_dst'" EXIT
    if cp -af "$files_src"/. "$tmp_dst/" 2>/dev/null; then
        find "$tmp_dst" -type f \( -name 'Makefile' -o -name 'Kbuild' -o -name 'Kconfig' \) -print0 2>/dev/null | \
            while IFS= read -r -d '' mf; do
                case "$mf" in
                    */drivers/net/ethernet/mediatek/mtk_hnat/Makefile) ;;
                    *) rm -f "$mf" ;;
                esac
            done
        for dir in "$tmp_dst"/*/; do
            [ -d "$dir" ] || continue
            case "$(basename "${dir%/}")" in
                drivers|include|arch) ;;
                *) rm -rf "$dir" ;;
            esac
        done
        cp -af "$tmp_dst"/. "$files_dst/"
        log "  HNAT/NPU kernel files overlaid"
    else
        warn "Copy from logan_common failed"
    fi
    rm -rf "$tmp_dst"
    trap - EXIT
else
    warn "logan_common files-6.12 not found"
    exit 1
fi

log "Extracting mtk_eth_reset.h..."
hdr="${files_dst}/drivers/net/ethernet/mediatek/mtk_eth_reset.h"

# 策略1: 从 MTK SDK 原始 patch 提取
patch_sdk="${MTK_SDK_DIR}/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/patches-6.12"
patch="${patch_sdk}/999-eth-93-mtk_eth_soc-add-internal-SER-notify-event.patch"

# 策略2: autobuild 已将 patch 应用到 OpenWrt 树
patch_owrt="${OPENWRT_ROOT}/target/linux/mediatek/patches-6.12/999-eth-93"*

found=""
if [ -f "$patch" ]; then
    found="$patch"
    log "  Found in MTK SDK"
elif [ -n "$(ls $patch_owrt 2>/dev/null)" ]; then
    found="$(ls $patch_owrt 2>/dev/null | head -1)"
    log "  Found in OpenWrt tree: $(basename "$found")"
fi

if [ -n "$found" ]; then
    mkdir -p "$(dirname "$hdr")"
    sed -n '/^diff.*mtk_eth_reset\.h$/,/^diff --git /{/^+++/!s/^+//;/^diff --git /d;p}' "$found" | \
        sed '1,/^@@/d' > "$hdr"
    if [ -s "$hdr" ] && grep -q 'MTK_FE_START_RESET' "$hdr"; then
        log "  Extracted ($(wc -l < "$hdr") lines)"
    else
        warn "Extraction produced empty or invalid file, header may be missing"
    fi
else
    warn "999-eth-93 patch not found in SDK or OpenWrt tree - NPU build may fail"
fi

log "All fixups complete."
