#!/bin/bash
# ============================================================================
# diy-mtk-sdk.sh — MTK SDK integration for ImmortalWrt 25.12
# ============================================================================
# 功能:
#   1. 克隆 mediatek/mtk-openwrt-feeds
#   2. 清除 ImmortalWrt 预置的冲突内核补丁
#   3. 注入本地 SFP/PCS 补丁到 MTK SDK 补丁目录
#   4. 复制 MTK SDK 文件覆盖层 → 建立补丁基线（含注入的 SFP 补丁）
#   5. 扫描 patches-base 与基线树冲突
#   6. 安全应用 MTK SDK patches-base（冲突的用 git apply --reject 局部应用）
#   7. 添加 MTK feed 源到 feeds.conf.default
#   （patches-feeds 推迟到 diy-part5.sh 中的 feeds install 之后）
#
# 用法:
#   在 openwrt 源码根目录下运行:
#     GITHUB_WORKSPACE=/path/to/repo \
#     bash $GITHUB_WORKSPACE/immortalwrt/diy-mtk-sdk.sh
#
# 环境变量:
#   MTK_SDK_URL     — MTK SDK 仓库地址 (默认 github.com/mediatek/mtk-openwrt-feeds)
#   MTK_SDK_BRANCH  — MTK SDK 分支 (默认 main)
#   MTK_SDK_DIR     — MTK SDK 克隆目标目录 (默认 ../mtk-openwrt-feeds)
#   SKIP_PATCH_APPLY — 设置为 1 仅做冲突检测，不实际应用
# ============================================================================

set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────────
MTK_SDK_URL="${MTK_SDK_URL:-https://github.com/mediatek/mtk-openwrt-feeds.git}"
MTK_SDK_BRANCH="${MTK_SDK_BRANCH:-main}"
MTK_SDK_DIR="${MTK_SDK_DIR:-${GITHUB_WORKSPACE:-$(pwd)/..}/mtk-openwrt-feeds}"
CONFLICT_LOG="${GITHUB_WORKSPACE:-.}/mtk-sdk-conflict-log.txt"
APPLIED_LOG="${GITHUB_WORKSPACE:-.}/mtk-sdk-applied-log.txt"
SKIPPED_LOG="${GITHUB_WORKSPACE:-.}/mtk-sdk-skipped-log.txt"
OPENWRT_ROOT="${OPENWRT_ROOT:-$(pwd)}"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[MTK-SDK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[MTK-SDK WARN]${NC} $*"; }
log_error() { echo -e "${RED}[MTK-SDK ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[MTK-SDK STEP]${NC} $*"; }

# ── 参数处理 ────────────────────────────────────────────────────────────
DRY_RUN="${SKIP_PATCH_APPLY:-0}"

# ── 第一步：克隆 MTK SDK ────────────────────────────────────────────────
clone_mtk_sdk() {
    if [ -d "$MTK_SDK_DIR/.git" ]; then
        log_info "MTK SDK already exists at $MTK_SDK_DIR, pulling latest..."
        git -C "$MTK_SDK_DIR" fetch origin "$MTK_SDK_BRANCH" --depth=1 2>/dev/null || true
        git -C "$MTK_SDK_DIR" checkout "$MTK_SDK_BRANCH" 2>/dev/null || true
        git -C "$MTK_SDK_DIR" pull --ff-only origin "$MTK_SDK_BRANCH" 2>/dev/null || \
            log_warn "Failed to pull MTK SDK, using existing checkout"
    else
        log_info "Cloning MTK SDK from $MTK_SDK_URL ($MTK_SDK_BRANCH)..."
        git clone --depth=1 --branch "$MTK_SDK_BRANCH" "$MTK_SDK_URL" "$MTK_SDK_DIR" || {
            log_error "Failed to clone MTK SDK"
            return 1
        }
    fi
    log_info "MTK SDK ready at $MTK_SDK_DIR"
    MTK_SDK_25="$MTK_SDK_DIR/25.12"
    if [ ! -d "$MTK_SDK_25" ]; then
        log_error "MTK SDK 25.12 directory not found: $MTK_SDK_25"
        return 1
    fi
}

# ── 第二步：冲突检测引擎 ────────────────────────────────────────────────
# 检测单个 patch 是否可以干净应用到当前树
# 返回: 0=可应用, 1=已应用, 2=冲突
check_patch() {
    local patch_file="$1"
    local patch_name
    patch_name=$(basename "$patch_file")

    # 检查是否已经应用过（反向 apply dry-run）
    if patch -p1 -R --dry-run --force < "$patch_file" >/dev/null 2>&1; then
        echo "already-applied"
        return 1
    fi

    # 正向 dry-run
    if patch -p1 --dry-run --force < "$patch_file" >/dev/null 2>&1; then
        echo "clean"
        return 0
    fi

    # 使用 git apply 作为更精确的检测
    if git apply --check --verbose "$patch_file" 2>/dev/null; then
        echo "clean"
        return 0
    fi

    echo "conflict"
    return 2
}

is_destructive_mtk_patch() {
    local patch_file="$1"
    local label="$2"

    [ "$label" = "patches-base" ] || return 1

    # MTK patches-base 0980/0981 change top-level tools/Makefile for secure
    # boot helpers. On ImmortalWrt this can drop standard tool entries such as
    # ar-tool when applied through --reject. Skip only patches that directly
    # touch tools/Makefile; later steps add the BPI-R4-safe stubs we need.
    if grep -Eq '^(---|\+\+\+) [ab]/tools/Makefile' "$patch_file"; then
        return 0
    fi

    return 1
}

is_unneeded_mtk_patch() {
    local patch_file="$1"
    local label="$2"
    local pname

    [ "$label" = "patches-base" ] || return 1
    pname=$(basename "$patch_file")

    case "$pname" in
        1132-image-mediatek-filogic-add-bananapi-bpi-r4-lite-support.patch)
            # This build targets the full BPI-R4, not R4 Lite. Avoid partial
            # image/upgrade script rejects from a board we do not emit.
            return 0
            ;;
        1133-image-mediatek-filogic-add-bananapi-bpi-r4-support.patch)
            # ImmortalWrt already carries BPI-R4 image support and the MTK file
            # overlay establishes the local baseline.  Do not partially apply
            # another BPI-R4 device block over it; post steps add the one SDK
            # package dependency we actually need.
            return 0
            ;;
        1142-image-mediatek-filogic-mt7987a-rfb-03-add-spidev-overlays.patch|\
        1142-image-mediatek-filogic-mt7987a-rfb-06-add-wifi-gen-dtso.patch|\
        3000-fstools-dual-boot-add-support-to-build-libfstools-bootparam.patch|\
        3602-mediatek-filogic-base-files-remove-dm-devices-before-upgrade.patch|\
        3600-mediatek-filogic-base-files-add-support-for-MediaTek-RBFs-upgrade.patch)
            # MTK RFB/dual-boot support is not needed for BPI-R4 images and is
            # prone to noisy rejects against ImmortalWrt's base-files/fstools.
            return 0
            ;;
        1146-image-mediatek-filogic-enable-kmod-mt798x-2p5g-phy.patch)
            # Replace the broad reference-board patch with a targeted BPI-R4
            # DEVICE_PACKAGES fix in ensure_bpi_r4_mtk_packages().
            return 0
            ;;
        3704-crypto-remove-safexcel-from-default-package.patch)
            # Cosmetic default-package delta for MTK reference targets. If
            # safexcel needs to be removed, do it in config/package defaults
            # instead of partially applying a target Makefile patch.
            return 0
            ;;
    esac

    return 1
}

mtk_patch_skip_reason() {
    local patch_file="$1"
    local pname

    pname=$(basename "$patch_file")

    case "$pname" in
        1133-image-mediatek-filogic-add-bananapi-bpi-r4-support.patch)
            echo "BPI-R4 support already provided by ImmortalWrt/SDK overlay; avoid partial duplicate device block"
            ;;
        1146-image-mediatek-filogic-enable-kmod-mt798x-2p5g-phy.patch)
            echo "replaced by targeted ensure_bpi_r4_mtk_packages post-step"
            ;;
        1142-image-mediatek-filogic-mt7987a-rfb-06-add-wifi-gen-dtso.patch|\
        3602-mediatek-filogic-base-files-remove-dm-devices-before-upgrade.patch)
            echo "MTK RFB/DM maintenance patch not needed for BPI-R4 target"
            ;;
        *)
            echo "not needed for BPI-R4 target"
            ;;
    esac
}

# 扫描目录内所有 patch，生成冲突报告
scan_patches() {
    local patch_dir="$1"
    local label="$2"
    local total=0 clean=0 applied=0 conflict=0

    log_step "Scanning $label patches in: $patch_dir"
    [ -d "$patch_dir" ] || { log_warn "Directory not found: $patch_dir"; return 0; }

    for pf in $(find "$patch_dir" -name "*.patch" -type f | sort); do
        total=$((total + 1))
        local pname; pname=$(basename "$pf")

        if is_destructive_mtk_patch "$pf" "$label"; then
            conflict=$((conflict + 1))
            echo "  ${YELLOW}!${NC} $pname - tools/Makefile patch (skip; fixed later)"
            echo "    [SKIP-TOOLS-MAKEFILE] $label: $pname" >> "$CONFLICT_LOG"
            continue
        fi

        if is_unneeded_mtk_patch "$pf" "$label"; then
            applied=$((applied + 1))
            local skip_reason; skip_reason=$(mtk_patch_skip_reason "$pf")
            echo "  ${YELLOW}○${NC} $pname — skip: $skip_reason"
            echo "    [SKIP-unneeded] $label: $pname - $skip_reason" >> "$CONFLICT_LOG"
            continue
        fi

        local result; result=$(check_patch "$pf") || true

        case "$result" in
            clean)
                clean=$((clean + 1))
                echo "  ${GREEN}✓${NC} $pname — clean"
                ;;
            already-applied)
                applied=$((applied + 1))
                echo "  ${YELLOW}○${NC} $pname — already applied (skip)"
                ;;
            conflict)
                conflict=$((conflict + 1))
                echo "  ${RED}✗${NC} $pname — pre-scan conflict"
                echo "    [PRESCAN-CONFLICT] $label: $pname" >> "$CONFLICT_LOG"
                # 显示冲突详情
                patch -p1 --dry-run --force < "$pf" 2>&1 | head -5 | \
                    sed 's/^/    /' || true
                ;;
        esac
    done

    echo ""
    printf "  ${label}: total=%d clean=%d already-applied=%d conflict=%d\n\n" \
        "$total" "$clean" "$applied" "$conflict"

    # 返回冲突数
    return $conflict
}

# ── 第三步：安全应用补丁 ────────────────────────────────────────────────
# 对于冲突补丁：使用 git apply --reject 尽可能应用匹配的 hunks，
# 失败的 hunks 保存为 .rej 文件供后续审查。
apply_patches_safe() {
    local patch_dir="$1"
    local label="$2"
    local total=0 ok=0 partial=0 skipped=0 failed=0

    log_step "Applying $label patches from: $patch_dir"
    [ -d "$patch_dir" ] || { log_warn "Directory not found: $patch_dir"; return 0; }

    for pf in $(find "$patch_dir" -name "*.patch" -type f | sort); do
        total=$((total + 1))
        local pname; pname=$(basename "$pf")

        if is_destructive_mtk_patch "$pf" "$label"; then
            log_warn "  Skip tools/Makefile patch: $pname"
            skipped=$((skipped + 1))
            echo "  [SKIP-tools-makefile] $label/$pname - handled by verify_critical_tools and fdt stub" >> "$SKIPPED_LOG"
            continue
        fi

        if is_unneeded_mtk_patch "$pf" "$label"; then
            local skip_reason; skip_reason=$(mtk_patch_skip_reason "$pf")
            log_warn "  Skip BPI-R4-handled patch: $pname ($skip_reason)"
            skipped=$((skipped + 1))
            echo "  [SKIP-unneeded] $label/$pname - $skip_reason" >> "$SKIPPED_LOG"
            continue
        fi

        local result; result=$(check_patch "$pf") || true

        case "$result" in
            already-applied)
                log_info "  Skip (already applied): $pname"
                skipped=$((skipped + 1))
                echo "  [SKIP-already] $label/$pname" >> "$SKIPPED_LOG"
                ;;
            clean)
                if [ "$DRY_RUN" = "1" ]; then
                    log_info "  [DRY-RUN] Would apply: $pname"
                    ok=$((ok + 1))
                elif patch -p1 --force --no-backup-if-mismatch < "$pf" 2>&1; then
                    log_info "  Applied: $pname"
                    ok=$((ok + 1))
                    echo "  [APPLIED] $label/$pname" >> "$APPLIED_LOG"
                else
                    log_error "  FAILED to apply: $pname"
                    failed=$((failed + 1))
                    echo "  [FAILED] $label/$pname" >> "$SKIPPED_LOG"
                fi
                ;;
            conflict)
                # 冲突补丁：用 git apply --reject 尽可能应用匹配的 hunks
                if [ "$DRY_RUN" = "1" ]; then
                    log_warn "  [DRY-RUN] Would try partial apply: $pname"
                    partial=$((partial + 1))
                elif git apply --reject --whitespace=fix "$pf" 2>/dev/null; then
                    log_info "  Partial apply OK: $pname"
                    partial=$((partial + 1))
                    echo "  [PARTIAL] $label/$pname" >> "$APPLIED_LOG"
                elif git apply --reject --whitespace=fix -3 "$pf" 2>/dev/null; then
                    log_info "  Partial apply (3-way): $pname"
                    partial=$((partial + 1))
                    echo "  [PARTIAL-3way] $label/$pname" >> "$APPLIED_LOG"
                else
                    log_warn "  PARTIAL (hunks rejected): $pname"
                    partial=$((partial + 1))
                    echo "  [REJECTS] $label/$pname — check *.rej files" >> "$SKIPPED_LOG"
                    # 清理 .rej 文件到专门目录便于审查
                    local rej_dir="${OPENWRT_ROOT}/.mtk-sdk-rejects"
                    mkdir -p "$rej_dir"
                    find "${OPENWRT_ROOT}" -name "*.rej" -newer "${OPENWRT_ROOT}/.timestamp" \
                        -exec mv {} "$rej_dir/" \; 2>/dev/null || true
                fi
                ;;
        esac
    done

    printf "  ${label}: total=%d applied=%d partial=%d skipped=%d failed=%d\n\n" \
        "$total" "$ok" "$partial" "$skipped" "$failed"
}

# ── 第四步：安全复制文件覆盖层 ──────────────────────────────────────────
copy_files_safe() {
    local src_dir="$1"
    local label="$2"

    log_step "Copying $label files from: $src_dir"
    [ -d "$src_dir" ] || { log_warn "Directory not found: $src_dir"; return 0; }

    # 先列出会被覆盖的已有文件
    local overrides
    overrides=$(cd "$src_dir" && find . -type f | while read -r f; do
        local target="${OPENWRT_ROOT}/${f}"
        if [ -f "$target" ]; then
            echo "  [OVERRIDE] $f (existing file will be replaced)"
        fi
    done)
    
    if [ -n "$overrides" ]; then
        log_warn "Files that will be overridden by $label:"
        echo "$overrides"
        echo "$overrides" >> "$SKIPPED_LOG"
    fi

    if [ "$DRY_RUN" != "1" ]; then
        cp -af "$src_dir"/* "$OPENWRT_ROOT/" 2>/dev/null || log_warn "Some files may not have copied cleanly"
        log_info "  Copied $label files to OpenWrt tree"
    else
        log_info "  [DRY-RUN] Would copy $label files"
    fi
}

remove_broken_sfp_612_patches() {
    # Remove MTK SDK SFP quirk-table patches that no longer match
    # linux 6.12.94 after our own sfp.c modifications (2777/2778).
    # These add extra ETU/TNBY/JESS-LINK RollBall quirks, while
    # BPI-R4's OEM SFP-10G-T path is covered by the RTL8261BE probe fix.
    local rel_patches=(
        "target/linux/mediatek/patches-6.12/999-2753-net-phy-sfp-support-additional-RollBall-modules.patch"
        "target/linux/mediatek/patches-6.12/999-sfp-01-add-additional-RollBall-modules.patch"
    )
    local removed=0

    for rel_patch in "${rel_patches[@]}"; do
        for patch_file in \
            "$MTK_SDK_DIR/25.12/files/$rel_patch" \
            "$MTK_SDK_DIR/autobuild/unified/filogic/25.12/files/$rel_patch" \
            "$OPENWRT_ROOT/$rel_patch"; do
            if [ -f "$patch_file" ]; then
                rm -f "$patch_file"
                removed=$((removed + 1))
            fi
        done
    done

    [ "$removed" -gt 0 ] && log_warn "Removed $removed broken/broken-order 6.12 SFP patch instance(s)"
    true
}

remove_stale_pcs_lynxi_612_patches() {
    # 999-2780 sorted before MTK SDK's own 999-pcs-01..07 chain and could
    # modify pcs-mtk-lynxi.c too early.  The fixed guard is renamed to
    # 999-pcs-99-* so it applies after the SDK PCS chain; remove stale copies
    # left by older CI workspaces or SDK overlays.
    local rel_patch="target/linux/mediatek/patches-6.12/999-2780-pcs-mtk-lynxi-hold-link-down-invalid-speed.patch"
    local removed=0

    for patch_file in \
        "$MTK_SDK_DIR/25.12/files/$rel_patch" \
        "$MTK_SDK_DIR/autobuild/unified/filogic/25.12/files/$rel_patch" \
        "$OPENWRT_ROOT/$rel_patch"; do
        if [ -f "$patch_file" ]; then
            rm -f "$patch_file"
            removed=$((removed + 1))
        fi
    done

    [ "$removed" -gt 0 ] && log_warn "Removed stale early PCS Lynxi patch 999-2780 from $removed location(s)"
    true
}

sync_local_sfp_612_patches() {
    # Keep the final 6.12 SFP patch set deterministic.  MTK SDK overlays can
    # carry older local experiments or CRLF-normalized copies from previous CI
    # runs; always overwrite the SDK overlay and OpenWrt target patch directory
    # from this repository's 25.12 SFP patch source.
    local local_sfp_dir="${GITHUB_WORKSPACE}/patches/filogic/sfp/25.12"
    local target_patch_dir="${OPENWRT_ROOT}/target/linux/mediatek/patches-6.12"
    local mtk_patch_dir="$MTK_SDK_DIR/25.12/files/target/linux/mediatek/patches-6.12"
    local copied=0 skipped=0

    [ -d "$local_sfp_dir" ] || return 0

    mkdir -p "$mtk_patch_dir"
    [ -d "$target_patch_dir" ] && mkdir -p "$target_patch_dir"

    for sfp_patch in "$local_sfp_dir"/*.patch; do
        [ -f "$sfp_patch" ] || continue
        local sfp_name; sfp_name=$(basename "$sfp_patch")

        case "$sfp_name" in
            *-6.6.patch|999-27[5-6][0-9]-*)
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        # Normalize line endings while copying. The kernel patch stage prints
        # "Stripping trailing CRs" and can expose stale context failures when
        # CRLF files slip into the overlay.
        sed 's/\r$//' "$sfp_patch" > "$mtk_patch_dir/$sfp_name"
        if [ -d "$target_patch_dir" ]; then
            sed 's/\r$//' "$sfp_patch" > "$target_patch_dir/$sfp_name"
        fi
        copied=$((copied + 1))
    done

    log_info "Synced $copied local 6.12 SFP patches (skipped $skipped legacy/6.6 patches)"
}

verify_local_sfp_612_patches() {
    local patch_dir="${OPENWRT_ROOT}/target/linux/mediatek/patches-6.12"
    local struct_patch="$patch_dir/999-2778.1-sfp-reprobe-struct.patch"
    local watchdog_patch="$patch_dir/999-2779-sfp-rtl8261be-1g-reprobe-watchdog.patch"

    [ -d "$patch_dir" ] || return 0

    if [ ! -f "$struct_patch" ]; then
        log_error "Missing split SFP struct patch: $struct_patch"
        return 1
    fi

    if [ ! -f "$watchdog_patch" ]; then
        log_error "Missing SFP reprobe watchdog patch: $watchdog_patch"
        return 1
    fi

    if grep -q "$(printf '\r')" "$struct_patch" "$watchdog_patch" 2>/dev/null; then
        log_error "CRLF detected in synced 6.12 SFP patches"
        return 1
    fi

    local watchdog_hunks
    watchdog_hunks=$(grep -c '^@@' "$watchdog_patch" || true)
    if [ "$watchdog_hunks" -ne 11 ]; then
        log_error "Unexpected 2779 hunk count: $watchdog_hunks (expected 11 after struct split)"
        return 1
    fi

    log_info "Verified local 6.12 SFP patch split: 2778.1 present, 2779 has 11 hunks, LF-only"
}

ensure_bpi_r4_mtk_packages() {
    local filogic_mk="${OPENWRT_ROOT}/target/linux/mediatek/image/filogic.mk"

    [ -f "$filogic_mk" ] || return 0

    if grep -A80 -E '^define Device/.*bananapi.*bpi-r4' "$filogic_mk" | \
        sed '/^endef$/q' | grep -q 'kmod-mt798x-2p5g-phy'; then
        log_info "BPI-R4 already has kmod-mt798x-2p5g-phy in DEVICE_PACKAGES"
        return 0
    fi

    FILOGIC_MK="$filogic_mk" perl -0pi -e '
        my $pkg = " kmod-mt798x-2p5g-phy";
        s{
            (^define[ \t]+Device/[^\n]*bananapi[^\n]*bpi-r4[^\n]*\n)
            (.*?)
            (^endef$)
        }{
            my ($head, $body, $end) = ($1, $2, $3);
            if ($body !~ /kmod-mt798x-2p5g-phy/) {
                if ($body =~ s/^(DEVICE_PACKAGES[ \t]*(?::=|\+=)[^\n]*)$/$1$pkg/m) {
                    # appended to existing DEVICE_PACKAGES
                } else {
                    $body .= "  DEVICE_PACKAGES +=$pkg\n";
                }
            }
            "$head$body$end";
        }egmsx;
    ' "$filogic_mk"

    if grep -A80 -E '^define Device/.*bananapi.*bpi-r4' "$filogic_mk" | \
        sed '/^endef$/q' | grep -q 'kmod-mt798x-2p5g-phy'; then
        log_info "Ensured BPI-R4 DEVICE_PACKAGES includes kmod-mt798x-2p5g-phy"
    else
        log_warn "Could not find BPI-R4 device block to add kmod-mt798x-2p5g-phy"
    fi
}

# ── 第五步：添加 MTK feed 源 ────────────────────────────────────────────
add_mtk_feed() {
    local feeds_conf="${OPENWRT_ROOT}/feeds.conf.default"
    
    log_step "Adding MTK feed to feeds.conf.default"
    
    if grep -q "mtk_openwrt_feed" "$feeds_conf" 2>/dev/null; then
        log_info "MTK feed already present in feeds.conf.default"
        return 0
    fi

    echo "src-link mtk_openwrt_feed ${MTK_SDK_DIR}/feed" >> "$feeds_conf"
    log_info "Added: src-link mtk_openwrt_feed ${MTK_SDK_DIR}/feed"
}

# ── 第六步：清理 ImmortalWrt 预置的冲突补丁 ─────────────────────────────
clean_conflicting_immortalwrt_patches() {
    log_step "Cleaning ImmortalWrt patches that conflict with MTK SDK..."

    local patch_dir="${OPENWRT_ROOT}/target/linux/mediatek/patches-6.12"
    [ -d "$patch_dir" ] || { log_warn "patches-6.12 not found, skipping"; return 0; }

    # ── 已知冲突补丁清单 ────────────────────────────────────────────
    # 这些是 ImmortalWrt/openwrt-25.12 中可能与 MTK SDK 重叠的补丁
    # 格式: "文件名前缀|冲突原因"
    local known_conflicts=(
        # MTK SDK 提供了自己的 BPI-R4 支持（patches-base/1133-*）
        "bananapi_bpi-r4|MTK SDK provides BPI-R4 image support (patches-base/1133)"
        # MTK SDK 提供自己的 eth/net 补丁链
        "999-eth-|MTK SDK provides ethernet patches"
        "999-net-|MTK SDK provides network patches"
        # MTK SDK 提供自己的 HNAT 包（feed/kernel/mtkhnat）
        # 注意: "hnat" 前缀匹配所有含 hnat 的补丁文件名
        "hnat|MTK SDK provides HNAT via feed"
        "999-2741-mtkhnat|MTK SDK provides HNAT via feed"
        "999-2742-mtkhnat|MTK SDK provides HNAT via feed"
        "999-2743-mtkhnat|MTK SDK provides HNAT via feed"
        "999-2744-mtk|MTK SDK provides GSO fix via feed"
        "999-2745-mtkhnat|MTK SDK provides HNAT driver via feed"
        "9991-dsa-hnat|MTK SDK provides DSA HNAT via feed"
        "9992-dsa-exthnat|MTK SDK provides ext HNAT via feed"
        "9996-ext-hnat|MTK SDK provides ext HNAT via feed"
        "9999-reset|MTK SDK provides reset via feed"
        "99999-hnat|MTK SDK provides extdevice fix via feed"
        # MTK SDK 提供自己的 flow offload / PPE 补丁
        "999-2735-netfilter|MTK SDK provides flow offload"
        "999-2736-net-8021q|MTK SDK provides 8021q offload"
        "999-2737-net-bridge|MTK SDK provides bridge offload"
        "999-2738-net-pppoe|MTK SDK provides PPPoE offload"
        "999-2739-net-dsa|MTK SDK provides DSA offload"
        "999-2740-net-macvlan|MTK SDK provides macvlan offload"
        "999-3000|MTK SDK provides flow offload bridging"
        "999-3001|MTK SDK provides PPE debugfs"
        "999-3002|MTK SDK provides PPE info1"
        "999-3003|MTK SDK provides PPE QoS"
        "999-3004|MTK SDK provides DSCP flow"
        "999-3005|MTK SDK provides WDMA path"
        "999-3006|MTK SDK provides ftnetlink"
        "999-3007|MTK SDK provides PPE roaming"
        "999-3008|MTK SDK provides CS0_PIPE"
        "999-3009|MTK SDK provides MIB cache"
        "999-3010|MTK SDK provides short packet dispatch"
        "999-3011|MTK SDK provides TCP/UDP aging"
        "999-3012|MTK SDK provides ib2 mcast"
        "999-3013|MTK SDK provides PPE cache line"
        "999-3014|MTK SDK provides nft bridge offload"
        "999-3015|MTK SDK provides nft WDMA path"
        "999-3016|MTK SDK provides nft DSCP"
        "999-3017|MTK SDK provides xt_FLOWOFFLOAD fix"
        "999-3018|MTK SDK provides nft_flow_offload fix"
        "999-3019|MTK SDK provides adaptive PPPQ"
        "999-3020|MTK SDK provides macvlan support"
        "999-3021|MTK SDK provides tport_idx"
        "999-3022|MTK SDK provides keep dscp"
        # MTK SDK 提供自己的 crypto inline
        "999-2747-crypto|MTK SDK provides crypto inline via feed"
        # MTK SDK 提供自己的 2.5G EEE backport
        "999-1700-v6.8-net-phy-2p5g|MTK SDK may provide newer phy backports"
        "999-1701-v6.8|MTK SDK may provide newer phy backports"
        "999-1702-v6.8|MTK SDK may provide newer phy backports"
        "999-1703-v6.9|MTK SDK may provide newer phy backports"
        "999-1704-v6.9|MTK SDK may provide newer phy backports"
        "999-1705-v6.9|MTK SDK may provide newer phy backports"
        "999-1706-v6.9|MTK SDK may provide newer phy backports"
        "999-1707-v6.9|MTK SDK may provide newer phy backports"
        "999-1708-v6.9|MTK SDK may provide newer phy backports"
        "999-1709-v6.9|MTK SDK may provide newer phy backports"
        "999-1710-v6.9|MTK SDK may provide newer phy backports"
        "999-1711-v6.9|MTK SDK may provide newer phy backports"
        "999-1712-v6.13|MTK SDK may provide newer phy backports"
        "999-1713-v6.13|MTK SDK may provide newer phy backports"
        "999-1714-v6.13|MTK SDK may provide newer phy backports"
        "999-1715-v6.13|MTK SDK may provide newer phy backports"
        "999-1716-v6.13|MTK SDK may provide newer phy backports"
        "999-1717-v6.9|MTK SDK may provide newer phy backports"
        "999-1718-v6.12|MTK SDK may provide newer phy backports"
        "999-1719-v6.12|MTK SDK may provide newer phy backports"
        "999-1720-v6.13|MTK SDK may provide newer phy backports"
        "999-1721-v6.13|MTK SDK may provide newer phy backports"
        "999-1722-v6.14|MTK SDK may provide newer phy backports"
        "999-1723-v6.10|MTK SDK may provide newer phy backports"
        # MTK SDK 通过 feed 提供 SFP 支持，不需要 base 里的重复 patch
        "997-sfp-rtl8672|MTK SDK may have updated SFP support"
        "998-sfp-rtl8672|MTK SDK may have updated SFP support"
        "999-2753-net-phy-sfp|MTK SDK provides SFP support"
        "999-2754-net-phy-sfp|MTK SDK provides shared MOD_DEF0"
    )

    local removed=0
    for conflict in "${known_conflicts[@]}"; do
        local prefix="${conflict%%|*}"
        local reason="${conflict#*|}"
        # 查找匹配的补丁文件
        while IFS= read -r -d '' matched; do
            local bname; bname=$(basename "$matched")
            log_warn "  Removing conflicting ImmortalWrt patch: $bname"
            log_warn "    Reason: $reason"
            rm -f "$matched"
            removed=$((removed + 1))
        done < <(find "$patch_dir" -maxdepth 1 -name "*${prefix}*" -type f -print0 2>/dev/null || true)
    done

    if [ "$removed" -gt 0 ]; then
        log_info "  Removed $removed conflicting ImmortalWrt patches from patches-6.12/"
    else
        log_info "  No conflicting ImmortalWrt patches found to remove"
    fi
}

# ── 第七步：验证关键构建工具完整性 ──────────────────────────────────────
# MTK SDK 的 25.12/files/ 覆盖或 patches-base 的 --reject 局部应用
# 可能损坏 tools/Makefile 或删除标准工具目录。
verify_critical_tools() {
    log_step "Verifying critical build tools after SDK overlay..."

    local tools_makefile="${OPENWRT_ROOT}/tools/Makefile"
    local restored=0

    restore_tool_dir() {
        local tool="$1"

        if [ ! -d "${OPENWRT_ROOT}/tools/${tool}" ] || \
           [ ! -f "${OPENWRT_ROOT}/tools/${tool}/Makefile" ]; then
            log_error "  tools/${tool} directory or Makefile missing — restoring"
            if git -C "$OPENWRT_ROOT" checkout -- "tools/${tool}" 2>/dev/null; then
                log_info "  Restored tools/${tool}/ from git"
            else
                log_warn "  git checkout failed, creating minimal stub for tools/${tool}"
                mkdir -p "${OPENWRT_ROOT}/tools/${tool}"
                cat > "${OPENWRT_ROOT}/tools/${tool}/Makefile" <<MKEOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=${tool}
PKG_RELEASE:=1

include \$(INCLUDE_DIR)/host-build.mk

define Host/Compile
endef

define Host/Install
	\$(INSTALL_DIR) \$(STAGING_DIR_HOST)/bin
	touch \$(STAGING_DIR_HOST)/bin/${tool}
	chmod +x \$(STAGING_DIR_HOST)/bin/${tool}
endef

\$(eval \$(call HostBuild))
MKEOF
                log_info "  Created stub tools/${tool}/Makefile"
            fi
            restored=$((restored + 1))
        fi
    }

    ensure_tool_makefile_entry() {
        local tool="$1"

        [ -f "$tools_makefile" ] || return 0
        grep -qw "$tool" "$tools_makefile" && return 0

        log_warn "  tools/Makefile missing '${tool}' — adding minimal tools-y entry"
        printf '\n# Restored by diy-mtk-sdk.sh after MTK SDK overlay\n' >> "$tools_makefile"
        printf 'tools-y += %s\n' "$tool" >> "$tools_makefile"
        restored=$((restored + 1))
    }

    # 检查 ar-tool 目录 — 本次 CI 报错 "No such file or directory"
    restore_tool_dir "ar-tool"

    # 不整文件恢复 tools/Makefile，避免抹掉 MTK SDK patches-base 的新增工具。
    ensure_tool_makefile_entry "ar-tool"

    # 通用检查：确保 tools/ 下核心目录存在
    for tool in padjffs2 firmware-utils; do
        restore_tool_dir "$tool"
    done

    [ "$restored" -gt 0 ] && log_warn "  Restored or stubbed $restored critical tool item(s)"
    [ "$restored" -eq 0 ] && log_info "  All critical tools present"
    true  # prevent set -e from seeing "restored>0 -> [ -eq 0 ] returns 1" as failure
}

# ── 主流程 ──────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "============================================================================"
    echo "  MTK SDK Integration for ImmortalWrt 25.12"
    echo "  SDK: $MTK_SDK_URL ($MTK_SDK_BRANCH)"
    echo "  Target: $OPENWRT_ROOT"
    echo "  Mode: $([ "$DRY_RUN" = "1" ] && echo 'DRY-RUN (no changes)' || echo 'LIVE')"
    echo "============================================================================"
    echo ""

    # 初始化日志
    echo "# MTK SDK Integration Log — $(date)" > "$CONFLICT_LOG"
    echo "# MTK SDK Applied Patches — $(date)" > "$APPLIED_LOG"
    echo "# MTK SDK Skipped Patches — $(date)" > "$SKIPPED_LOG"
    echo "MTK_SDK_DIR=$MTK_SDK_DIR" >> "$APPLIED_LOG"
    echo "MTK_SDK_BRANCH=$MTK_SDK_BRANCH" >> "$APPLIED_LOG"

    # 1. 克隆 SDK
    clone_mtk_sdk || exit 1

    # 2. 清理冲突
    clean_conflicting_immortalwrt_patches

    # 2.5. 移除已知不兼容 linux 6.12.94 的旧 SFP quirk 补丁
    remove_broken_sfp_612_patches
    remove_stale_pcs_lynxi_612_patches

    # 3. 注入本地 SFP/PCS 补丁到 MTK SDK 的 patches-6.12 目录
    #    参考 woziwrt: 在 autobuild/文件覆盖之前注入，确保补丁作为
    #    MTK SDK 基线的一部分被复制到 OpenWrt 树。
    sync_local_sfp_612_patches

    # 4. 复制 MTK SDK 文件覆盖层 — 必须在打补丁之前！
    #    将 MTK SDK 的 25.12/files/（含步骤 3 注入的 SFP 补丁）复制到
    #    OpenWrt 树，建立 MTK 基线。patches-base 预期修改的是这些
    #    基线文件（如 filogic.mk, platform.sh, 02_network 等）。
    copy_files_safe "$MTK_SDK_DIR/25.12/files" "25.12/files"
    remove_broken_sfp_612_patches
    remove_stale_pcs_lynxi_612_patches
    sync_local_sfp_612_patches

    # 5. 复制 filogic 特定文件
    local filogic_files="$MTK_SDK_DIR/autobuild/unified/filogic/25.12/files"
    if [ -d "$filogic_files" ]; then
        copy_files_safe "$filogic_files" "filogic/25.12/files"
    fi
    remove_broken_sfp_612_patches
    remove_stale_pcs_lynxi_612_patches
    sync_local_sfp_612_patches
    verify_local_sfp_612_patches

    # 6. 创建时间戳标记
    touch "${OPENWRT_ROOT}/.timestamp"

    # 7. 扫描 patches-base
    scan_patches "$MTK_SDK_DIR/25.12/patches-base" "patches-base" || true

    # 8. 应用 patches-base
    apply_patches_safe "$MTK_SDK_DIR/25.12/patches-base" "patches-base"

    # 8.2. 用目标板后处理替代会产生 rejects 的宽泛 MTK RFB 补丁
    ensure_bpi_r4_mtk_packages

    # 8.5. 验证关键构建工具完整性
    #       MTK SDK 的文件覆盖和补丁可能破坏标准工具链。
    verify_critical_tools

    # 9. 注册 MTK feed 源
    add_mtk_feed

    # 10. MTK SDK patches-base 0980 添加了 fdt-patch-dm-verify 工具依赖，
    #     但该工具源文件在 autobuild 框架中，未随 25.12/files/ 提供。
    #     BPI-R4 不使用 DM-verity secure boot，创建最小 stub 绕过构建。
    local stub_tool="${OPENWRT_ROOT}/tools/fdt-patch-dm-verify"
    if [ ! -f "$stub_tool/Makefile" ]; then
        mkdir -p "$stub_tool"
        cat > "$stub_tool/Makefile" <<'MKEOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=fdt-patch-dm-verify
PKG_RELEASE:=1

include $(INCLUDE_DIR)/host-build.mk

define Host/Compile
endef

define Host/Install
	$(INSTALL_DIR) $(STAGING_DIR_HOST)/bin
	touch $(STAGING_DIR_HOST)/bin/fdt-patch-dm-verify
	chmod +x $(STAGING_DIR_HOST)/bin/fdt-patch-dm-verify
endef

$(eval $(call HostBuild))
MKEOF
        log_info "Created stub for fdt-patch-dm-verify (not needed for BPI-R4)"
    fi

    if ! grep -qw 'fdt-patch-dm-verify' "${OPENWRT_ROOT}/tools/Makefile" 2>/dev/null; then
        {
            echo ""
            echo "# Added by diy-mtk-sdk.sh for MTK SDK secure-boot tool dependency"
            echo "tools-y += fdt-patch-dm-verify"
        } >> "${OPENWRT_ROOT}/tools/Makefile"
        log_info "Added fdt-patch-dm-verify to tools/Makefile"
    fi

    # ── 总结 ─────────────────────────────────────────────────────────
    echo ""
    echo "============================================================================"
    echo "  MTK SDK Integration Summary"
    echo "============================================================================"
    echo "  Conflict log:     $CONFLICT_LOG"
    echo "  Applied patches:  $APPLIED_LOG"
    echo "  Skipped patches:  $SKIPPED_LOG"
    echo ""
    local prescan_conflict_count reject_count
    prescan_conflict_count=$(grep -c '\[PRESCAN-CONFLICT\]' "$CONFLICT_LOG" 2>/dev/null || true)
    reject_count=$(grep -c '\[REJECTS\]' "$SKIPPED_LOG" 2>/dev/null || true)

    if [ "$prescan_conflict_count" -gt 0 ]; then
        log_warn "  $prescan_conflict_count patches conflicted during pre-scan (many apply after earlier SDK patches)"
    else
        log_info "  No pre-scan patch conflicts detected"
    fi

    if [ "$reject_count" -gt 0 ]; then
        log_warn "  $reject_count patches still had rejected hunks; check .mtk-sdk-rejects/"
    else
        log_info "  No rejected hunks after patch application"
    fi
    echo "============================================================================"
    echo ""

    # 预扫描冲突是预期的（ImmortalWrt 与 OpenWrt 基线差异），不应阻断构建。
    # 真正需要关注的是应用阶段是否仍产生 [REJECTS]。
    return 0
}

main "$@"
