#!/bin/bash
# diy-mtk.sh - Post-autobuild fixups for BPI-R4 vendor-wifi build.
# Run after "autobuild.sh filogic prepare", from within the openwrt/ directory.

set -euo pipefail

log()  { echo "[MTK-FIX] $*"; }
warn() { echo "[MTK-FIX WARN] $*"; }

OPENWRT_ROOT="${OPENWRT_ROOT:-$(pwd)}"
MTK_SDK_DIR="${MTK_SDK_DIR:-${OPENWRT_ROOT}/../mtk-openwrt-feeds}"

# ── 1. Pin kernel Kconfig symbols ─────────────────────────────────────
log "Pinning kernel Kconfig symbols..."

cfg="${OPENWRT_ROOT}/target/linux/mediatek/filogic/config-6.12"
if [ -f "$cfg" ]; then
    for symbol in MEDIATEK_2P5GE_PHY; do
        sed -i "/^CONFIG_${symbol}=/d; /^# CONFIG_${symbol} is not set$/d" "$cfg"
        echo "# CONFIG_${symbol} is not set" >> "$cfg"
        log "  ${symbol}: pinned to n"
    done
else
    warn "config-6.12 not found at $cfg"
fi

# ── 2. CMake compatibility for mt76-vendor ────────────────────────────
log "Enabling CMake policy compatibility..."

export CMAKE_POLICY_VERSION_MINIMUM=3.5
echo "CMAKE_POLICY_VERSION_MINIMUM=3.5" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
log "  CMAKE_POLICY_VERSION_MINIMUM=3.5"

# ── 3. Overlay HNAT/NPU kernel files from autobuild logan_common ──────
log "Overlaying HNAT/NPU kernel files..."

files_src="${MTK_SDK_DIR}/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/files-6.12"
files_dst="${OPENWRT_ROOT}/target/linux/mediatek/files-6.12"

if [ -d "$files_src" ]; then
    mkdir -p "$files_dst"

    # Stage to a tmp dir, clean there, then merge.
    tmp_dst=$(mktemp -d)
    trap "rm -rf '$tmp_dst'" EXIT

    if cp -af "$files_src"/. "$tmp_dst/" 2>/dev/null; then
        # Prune Makefile/Kbuild/Kconfig except mtk_hnat/Makefile.
        find "$tmp_dst" -type f \( -name 'Makefile' -o -name 'Kbuild' -o -name 'Kconfig' \) -print0 2>/dev/null | \
            while IFS= read -r -d '' mf; do
                case "$mf" in
                    */drivers/net/ethernet/mediatek/mtk_hnat/Makefile) ;;
                    *) rm -f "$mf" ;;
                esac
            done

        # Prune non-driver/include/arch top-level subtrees.
        for dir in "$tmp_dst"/*/; do
            [ -d "$dir" ] || continue
            case "$(basename "${dir%/}")" in
                drivers|include|arch) ;;
                *) rm -rf "$dir" ;;
            esac
        done

        cp -af "$tmp_dst"/. "$files_dst/" 2>/dev/null
        log "  HNAT/NPU kernel files overlaid"
    else
        warn "Copy from logan_common failed"
    fi

    rm -rf "$tmp_dst"
    trap - EXIT
else
    warn "logan_common files-6.12 not found"
fi

# ── 4. Extract mtk_eth_reset.h from autobuild patch ───────────────────
log "Extracting mtk_eth_reset.h..."

patch_src="${MTK_SDK_DIR}/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/patches-6.12"
patch="${patch_src}/999-eth-93-mtk_eth_soc-add-internal-SER-notify-event.patch"
hdr="${files_dst}/drivers/net/ethernet/mediatek/mtk_eth_reset.h"

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
