#!/bin/bash
set -euo pipefail

log()  { echo "[MTK-FIX] $*"; }
warn() { echo "[MTK-FIX WARN] $*"; }

OPENWRT_ROOT="${OPENWRT_ROOT:-$(pwd)}"
MTK_SDK_DIR="${MTK_SDK_DIR:-${OPENWRT_ROOT}/../mtk-openwrt-feeds}"

log "OPENWRT_ROOT=${OPENWRT_ROOT}"
log "MTK_SDK_DIR=${MTK_SDK_DIR}"

log "Pinning kernel Kconfig symbols..."
cfg="${OPENWRT_ROOT}/target/linux/mediatek/filogic/config-6.12"
if [ -f "$cfg" ]; then
    for symbol in MEDIATEK_2P5GE_PHY NET_MEDIATEK_HNAT MEDIATEK_NETSYS_V3; do
        case "$symbol" in
            MEDIATEK_2P5GE_PHY) val="# CONFIG_${symbol} is not set" ;;
            *) val="CONFIG_${symbol}=y" ;;
        esac
        sed -i "/^CONFIG_${symbol}=/d; /^# CONFIG_${symbol} is not set$/d" "$cfg"
        echo "$val" >> "$cfg"
        log "  ${symbol}: pinned"
    done
else
    warn "config-6.12 not found: ${cfg}"
fi

log "Enabling CMake policy compatibility..."
export CMAKE_POLICY_VERSION_MINIMUM=3.5
echo "CMAKE_POLICY_VERSION_MINIMUM=3.5" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
log "  CMAKE_POLICY_VERSION_MINIMUM=3.5"

log "Overlaying HNAT kernel files..."
files_src="${MTK_SDK_DIR}/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/files-6.12"
files_dst="${OPENWRT_ROOT}/target/linux/mediatek/files-6.12"
log "  source: ${files_src}"
if [ -d "$files_src" ]; then
    mkdir -p "$files_dst"
    tmp_dst=$(mktemp -d)
    log "  staging: ${tmp_dst}"
    trap "rm -rf '$tmp_dst'" EXIT
    if cp -af "$files_src"/. "$tmp_dst/" 2>/dev/null; then
        before=$(find "$tmp_dst" -type f 2>/dev/null | wc -l)
        log "  copied ${before} files to staging"
        find "$tmp_dst" -type f \( -name 'Makefile' -o -name 'Kbuild' -o -name 'Kconfig' \) -print0 2>/dev/null | \
            while IFS= read -r -d '' mf; do
                case "$mf" in
                    */drivers/net/ethernet/mediatek/mtk_hnat/Makefile)
                        log "    keep: $(echo "$mf" | sed "s|${tmp_dst}/||")"
                        ;;
                    *)
                        log "    drop: $(echo "$mf" | sed "s|${tmp_dst}/||")"
                        rm -f "$mf"
                        ;;
                esac
            done
        for dir in "$tmp_dst"/*/; do
            [ -d "$dir" ] || continue
            case "$(basename "${dir%/}")" in
                drivers|include|arch) ;;
                *) rm -rf "$dir" ;;
            esac
        done
        after=$(find "$tmp_dst" -type f 2>/dev/null | wc -l)
        log "  after cleanup: ${after} files"
        cp -af "$tmp_dst"/. "$files_dst/"
        log "  overlaid to: ${files_dst}"

        # 999-eth-91 provides HNAT Kconfig, Makefile, and soc hooks.
        # autobuild.sh does NOT apply logan_common patches-6.12.
        #
        # Split into two trimmed patches to avoid PPE guard hunk failures:
        #   1) Kconfig + Makefile  (required for compilation)
        #   2) include + rx hooks  (safe additive hunks, no PPE guards)
        # The 5 PPE guard hunks (#if !defined wrappers) are excluded —
        # they fail on linux-6.12.94 due to PPE function context changes.
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        mtk_patches="${script_dir}/../patches/filogic/mtk"
        owrt_patches="${OPENWRT_ROOT}/target/linux/mediatek/patches-6.12"
        mkdir -p "$owrt_patches"

        # Stage trimmed 999-eth-91: Kconfig + Makefile only.
        local_patch="${mtk_patches}/mtk-999-eth-91-hnat-kconfig-makefile.patch"
        if [ -f "$local_patch" ]; then
            cp -f "$local_patch" "$owrt_patches/"
            log "  staged mtk-999-eth-91 (Kconfig+Makefile)"
        else
            warn "mtk-999-eth-91 (Kconfig+Makefile) not found: ${local_patch}"
        fi

        # Stage soc hooks: include + rx processing, no PPE guards.
        soc_patch="${mtk_patches}/mtk-999-eth-91-hnat-soc-hooks.patch"
        if [ -f "$soc_patch" ]; then
            cp -f "$soc_patch" "$owrt_patches/"
            log "  staged mtk-999-eth-91 (soc hooks: include + rx)"
        else
            warn "mtk-999-eth-91 (soc hooks) not found: ${soc_patch}"
        fi
    else
        warn "Copy from logan_common failed"
        rm -rf "$tmp_dst"
        trap - EXIT
        exit 1
    fi
    rm -rf "$tmp_dst"
    trap - EXIT
else
    warn "logan_common files-6.12 not found: ${files_src}"
    exit 1
fi

log "Patching NPU Makefile for CONFIG_MEDIATEK_NETSYS_V3..."
# NPU package Makefile passes EXTRA_CFLAGS on cmdline → overrides Kbuild ccflags-y.
# Must inject -DCONFIG_MEDIATEK_NETSYS_V3 into EXTRA_CFLAGS here, not in Kbuild.
npu_makefile="${MTK_SDK_DIR}/feed/kernel/mtk_npu/Makefile"
if [ -f "$npu_makefile" ]; then
    if grep -q 'CONFIG_MEDIATEK_NETSYS_V3' "$npu_makefile"; then
        log "  already patched"
    else
        sed -i '/EXTRA_KCONFIG))))$/a\EXTRA_CFLAGS+= -DCONFIG_MEDIATEK_NETSYS_V3' "$npu_makefile"
        log "  added NETSYS_V3 to EXTRA_CFLAGS"
    fi
else
    warn "NPU Makefile not found: ${npu_makefile}"
fi

log "Patching NPU Kbuild for include path..."
npu_kbuild="${MTK_SDK_DIR}/feed/kernel/mtk_npu/src/Makefile"
if [ -f "$npu_kbuild" ]; then
    if grep -q 'srctree.*mediatek' "$npu_kbuild"; then
        log "  already patched"
    else
        sed -i '/^ccflags-y += -I\$(src)\/protocol\/inc$/a\ccflags-y += -I$(srctree)/drivers/net/ethernet/mediatek' "$npu_kbuild"
        log "  added include path"
    fi
else
    warn "NPU Kbuild not found: ${npu_kbuild}"
fi

log "Extracting mtk_eth_reset.h..."
hdr="${files_dst}/drivers/net/ethernet/mediatek/mtk_eth_reset.h"
log "  target: ${hdr}"

patch_sdk="${MTK_SDK_DIR}/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/patches-6.12"
patch="${patch_sdk}/999-eth-93-mtk_eth_soc-add-internal-SER-notify-event.patch"
shopt -s nullglob
patch_owrt_candidates=("${OPENWRT_ROOT}"/target/linux/mediatek/patches-6.12/999-eth-93*)
shopt -u nullglob

found=""
if [ -f "$patch" ]; then
    found="$patch"
    log "  strategy1: found in SDK (${patch})"
elif [ "${#patch_owrt_candidates[@]}" -gt 0 ]; then
    found="${patch_owrt_candidates[0]}"
    log "  strategy2: found in OpenWrt tree (${found})"
else
    log "  strategy1: not found (${patch})"
    log "  strategy2: no candidates in OpenWrt tree"
fi

if [ -n "$found" ]; then
    mkdir -p "$(dirname "$hdr")"
    sed -n '/^diff.*mtk_eth_reset\.h$/{n; :a; /^diff --git /b; /^+++/!s/^+//; p; n; ba}' "$found" | \
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
