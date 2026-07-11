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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${GITHUB_WORKSPACE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MTK_SDK_URL="${MTK_SDK_URL:-https://github.com/mediatek/mtk-openwrt-feeds.git}"
MTK_SDK_BRANCH="${MTK_SDK_BRANCH:-main}"
MTK_SDK_DIR="${MTK_SDK_DIR:-${WORKSPACE_ROOT}/mtk-openwrt-feeds}"
CONFLICT_LOG="${WORKSPACE_ROOT}/mtk-sdk-conflict-log.txt"
APPLIED_LOG="${WORKSPACE_ROOT}/mtk-sdk-applied-log.txt"
SKIPPED_LOG="${WORKSPACE_ROOT}/mtk-sdk-skipped-log.txt"
OPENWRT_ROOT="${OPENWRT_ROOT:-$(pwd)}"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[MTK-SDK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[MTK-SDK WARN]${NC} $*"; }
log_error() { echo -e "${RED}[MTK-SDK ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[MTK-SDK STEP]${NC} $*"; }

# ── 规则文件加载 ────────────────────────────────────────────────────────
# 从外部数据文件加载规则列表，跳过空行和注释行。
# 用法: load_rule_file <rule_file> 输出到 stdout
load_rule_file() {
    local rule_file="$1"
    [ -f "$rule_file" ] || return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        printf '%s\n' "$line" 2>/dev/null || true
    done < "$rule_file"
}

# 返回 rule 文件路径，不存在返回空
rule_path() {
    local rule_name="$1"
    local path="${WORKSPACE_ROOT}/immortalwrt/mtk-sdk-rules/${rule_name}"
    [ -f "$path" ] && printf '%s' "$path"
}

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

    local skip_file
    skip_file=$(rule_path "skip-patches.txt")
    [ -f "$skip_file" ] || return 1

    # Format: <patch_basename>|<reason_code>|<description>
    while IFS='|' read -r skip_name reason_code description; do
        [ "$pname" = "$skip_name" ] && return 0
    done < <(load_rule_file "$skip_file")

    return 1
}

mtk_patch_skip_reason() {
    local patch_file="$1"
    local pname

    pname=$(basename "$patch_file")

    local skip_file
    skip_file=$(rule_path "skip-patches.txt")
    [ -f "$skip_file" ] && {
        while IFS='|' read -r skip_name reason_code description; do
            if [ "$pname" = "$skip_name" ]; then
                printf '%s: %s' "$reason_code" "$description"
                return 0
            fi
        done < <(load_rule_file "$skip_file")
    }

    printf 'not needed for BPI-R4 target'
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
    local local_sfp_dir="${WORKSPACE_ROOT}/patches/filogic/sfp/25.12"
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

remove_mtk_fstools_overlay_patches() {
    # Remove MTK SDK files overlay artifacts that conflict with ImmortalWrt.
    # The remove list is maintained in immortalwrt/mtk-sdk-rules/remove-after-overlay.txt
    local rule_file; rule_file=$(rule_path "remove-after-overlay.txt")
    local removed=0

    [ -f "$rule_file" ] || {
        log_info "No remove-after-overlay rule file found, skipping"
        return 0
    }

    log_step "Removing MTK SDK overlay artifacts (from remove-after-overlay.txt)"

    while IFS= read -r overlay_path; do
        overlay_path="${overlay_path%$'\r'}"
        case "$overlay_path" in ''|'#'*) continue ;; esac
        local target="${OPENWRT_ROOT}/${overlay_path}"
        if [ -f "$target" ] || [ -d "$target" ]; then
            rm -rf "$target"
            removed=$((removed + 1))
            log_warn "  Removed (BPI_R4_OVERLAY_CLEANUP): $overlay_path"
        fi
    done < "$rule_file"

    [ "$removed" -gt 0 ] && log_info "  Removed $removed overlay artifact(s)"
    [ "$removed" -eq 0 ] && log_info "  No matching overlay artifacts found"

    return 0
}

remove_mtk_listed_conflicts() {
    # Read MTK's own remove_list-mtwifi.txt as a supplementary conflict source.
    # MTK maintains this list for known-vanilla-OpenWrt conflicts; we apply it
    # on top of our own local rules to catch MTK-acknowledged overlaps.
    # This is additive—it does NOT replace clean_conflicting_immortalwrt_patches().
    local remove_list="${MTK_SDK_DIR}/25.12/remove_list-mtwifi.txt"
    local removed=0

    [ -f "$remove_list" ] || {
        log_info "No MTK remove_list-mtwifi.txt found, skipping"
        return 0
    }

    log_step "Applying MTK remove_list-mtwifi.txt"

    while IFS= read -r rel_path; do
        rel_path="${rel_path%$'\r'}"
        # Skip empty lines and comments
        [ -z "$rel_path" ] && continue
        case "$rel_path" in
            '#'*) continue ;;
        esac

        local target="${OPENWRT_ROOT}/${rel_path}"
        if [ -f "$target" ] || [ -d "$target" ]; then
            rm -rf "$target"
            removed=$((removed + 1))
            log_warn "  Removed (MTK remove-list): $rel_path"
        fi
    done < "$remove_list"

    [ "$removed" -gt 0 ] && log_info "  Removed $removed entries from MTK remove-list"
    [ "$removed" -eq 0 ] && log_info "  No matching entries in MTK remove-list"

    return 0
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

ensure_kernel_config_fixes() {
    # MTK SDK files overlay may introduce kernel-side drivers whose Kconfig
    # symbols are not referenced by the defconfig.  Kernel syncconfig then
    # blocks on interactive input.
    #
    # Keep both the OpenWrt target config and KCONFIG_ALLCONFIG in sync:
    # config-6.12 feeds .config.target, while KCONFIG_ALLCONFIG catches any
    # symbol missed by OpenWrt's config merge before syncconfig can prompt.
    local allconfig="${OPENWRT_ROOT}/target/linux/mediatek/filogic/kconfig-allnoconfig"
    local kernel_config="${OPENWRT_ROOT}/target/linux/mediatek/filogic/config-6.12"
    local kconfig_unset_symbols="
$(load_rule_file "$(rule_path "unset-kconfig.txt")")
"
    local kconfig_builtin_symbols="
$(load_rule_file "$(rule_path "builtin-kconfig.txt")")
"
    local scan_symbols_file="${OPENWRT_ROOT}/tmp/mtk-sdk-kconfig-symbols.txt"
    local auto_unset_file="${OPENWRT_ROOT}/tmp/mtk-sdk-kconfig-auto-unset.txt"
    local review_file="${OPENWRT_ROOT}/tmp/mtk-sdk-kconfig-review.txt"

    ensure_unset_symbol() {
        local config_file="$1"
        local symbol="$2"

        [ -f "$config_file" ] || return 0
        sed -i "/^CONFIG_${symbol}=/d; /^# CONFIG_${symbol} is not set$/d" "$config_file"
        printf '# CONFIG_%s is not set\n' "$symbol" >> "$config_file"
    }

    ensure_builtin_symbol() {
        local config_file="$1"
        local symbol="$2"

        [ -f "$config_file" ] || return 0
        sed -i "/^CONFIG_${symbol}=/d; /^# CONFIG_${symbol} is not set$/d" "$config_file"
        printf 'CONFIG_%s=y\n' "$symbol" >> "$config_file"
    }

    is_symbol_configured() {
        local symbol="$1"

        grep -qsE "^(CONFIG_${symbol}=|# CONFIG_${symbol} is not set$)" \
            "${OPENWRT_ROOT}/target/linux/generic/config-6.12" \
            "${OPENWRT_ROOT}/target/linux/mediatek/filogic/config-6.12" \
            "${OPENWRT_ROOT}/.config" 2>/dev/null
    }

    should_auto_unset_kconfig_symbol() {
        local symbol="$1"
        local pattern_file; pattern_file=$(rule_path "kconfig-patterns.txt")
        local mode=""

        [ -f "$pattern_file" ] || return 1

        while IFS= read -r pattern; do
            pattern="${pattern%$'\r'}"
            case "$pattern" in
                ''|'#'*) continue ;;
                '[keep]')  mode="keep";  continue ;;
                '[unset]') mode="unset"; continue ;;
            esac

            [ -z "$mode" ] && continue

            # Bash glob match: [[ $symbol == $pattern ]] where pattern has *
            if [[ "$symbol" == $pattern ]]; then
                case "$mode" in
                    keep)  return 1 ;;  # BPI-R4 core: don't unset
                    unset) return 0 ;;  # Non-BPI-R4: auto unset
                esac
            fi
        done < "$pattern_file"

        return 1  # Safe default: unknown symbols stay in review list
    }

    scan_mtk_sdk_kconfig_symbols() {
        mkdir -p "${OPENWRT_ROOT}/tmp"
        : > "$scan_symbols_file"
        : > "$auto_unset_file"
        : > "$review_file"

        find \
            "${OPENWRT_ROOT}/target/linux/mediatek" \
            "${OPENWRT_ROOT}/target/linux/generic" \
            -type f \( -name 'Kconfig' -o -name 'Kconfig.*' \) \
            -exec sed -n 's/^[[:space:]]*config[[:space:]]\{1,\}\([A-Za-z0-9_]\{1,\}\).*/\1/p' {} \; \
            >> "$scan_symbols_file" 2>/dev/null || true

        find "${OPENWRT_ROOT}/target/linux/mediatek/patches-6.12" -type f -name '*.patch' \
            -exec sed -n 's/^+[[:space:]]*config[[:space:]]\{1,\}\([A-Za-z0-9_]\{1,\}\).*/\1/p' {} \; \
            >> "$scan_symbols_file" 2>/dev/null || true

        sort -u "$scan_symbols_file" -o "$scan_symbols_file"

        while IFS= read -r symbol; do
            [ -n "$symbol" ] || continue
            is_symbol_configured "$symbol" && continue
            if should_auto_unset_kconfig_symbol "$symbol"; then
                printf '%s\n' "$symbol" >> "$auto_unset_file"
            else
                printf '%s\n' "$symbol" >> "$review_file"
            fi
        done < "$scan_symbols_file"

        if [ -s "$auto_unset_file" ]; then
            log_warn "Auto-unsetting non-BPI-R4 MTK SDK Kconfig symbols: $(tr '\n' ' ' < "$auto_unset_file")"
            kconfig_unset_symbols="$kconfig_unset_symbols
$(cat "$auto_unset_file")
"
        else
            log_info "No extra non-BPI-R4 MTK SDK Kconfig symbols detected"
        fi

        if [ -s "$review_file" ]; then
            local review_count
            review_count=$(wc -l < "$review_file" | tr -d ' ')
            log_warn "Unconfigured MTK SDK Kconfig symbols needing review ($review_count total; first 80): $(head -n 80 "$review_file" | tr '\n' ' ')"
            log_warn "Full review list: $review_file"
        else
            log_info "No unconfigured MTK SDK Kconfig symbols need manual review"
        fi
    }

    for symbol in $kconfig_builtin_symbols; do
        ensure_builtin_symbol "$kernel_config" "$symbol"
    done

    scan_mtk_sdk_kconfig_symbols

    mkdir -p "$(dirname "$allconfig")"
    cat > "$allconfig" <<KCONFEOF
# Auto-generated by diy-mtk-sdk.sh: default all unknown Kconfig symbols
# to 'n' so kernel syncconfig never blocks in CI.
KCONFEOF

    for symbol in $kconfig_builtin_symbols; do
        ensure_builtin_symbol "$allconfig" "$symbol"
        ensure_builtin_symbol "$kernel_config" "$symbol"
    done

    for symbol in $kconfig_unset_symbols; do
        ensure_unset_symbol "$allconfig" "$symbol"
        ensure_unset_symbol "$kernel_config" "$symbol"
    done

    log_info "Created kconfig-allnoconfig and ensured MTK SDK Kconfig symbols are pinned"

    inject_kconfig_allconfig() {
        local target_mk="$1"

        [ -f "$target_mk" ] || return 0
        grep -q 'KCONFIG_ALLCONFIG' "$target_mk" 2>/dev/null && return 0

        cat >> "$target_mk" <<TARGETEOF

# Injected by diy-mtk-sdk.sh ensure_kernel_config_fixes()
export KCONFIG_ALLCONFIG := \$(TOPDIR)/target/linux/mediatek/filogic/kconfig-allnoconfig
TARGETEOF
        log_info "Injected KCONFIG_ALLCONFIG into $target_mk"
    }

    inject_kconfig_allconfig "${OPENWRT_ROOT}/target/linux/mediatek/filogic/target.mk"
    inject_kconfig_allconfig "${OPENWRT_ROOT}/target/linux/mediatek/filogic_a73/target.mk"
}

# ── 第五步：添加 MTK feed 源 ────────────────────────────────────────────
patch_mtk_feed_build_fixes() {
    local npu_hnat_mk="$MTK_SDK_DIR/feed/kernel/mtk_npu/npu-nf_hnat.mk"
    local npu_mk="$MTK_SDK_DIR/feed/kernel/mtk_npu/Makefile"
    local target_mk="$npu_hnat_mk"
    local mt76_cmake="$MTK_SDK_DIR/feed/app/mt76-vendor/src/CMakeLists.txt"

    log_step "Patching MTK feed build fixups"

    [ -f "$target_mk" ] || target_mk="$npu_mk"
    if [ -f "$target_mk" ]; then
        grep -q 'CONFIG_MEDIATEK_NETSYS_V3=y' "$target_mk" || \
            printf '\nEXTRA_KCONFIG += CONFIG_MEDIATEK_NETSYS_V3=y\n' >> "$target_mk"
        log_info "Ensured mtk_npu NETSYS_V3 flag in $target_mk"
    else
        log_warn "mtk_npu Makefile not found, skipping NETSYS_V3 flag"
    fi

    if [ -f "$npu_mk" ] && grep -q 'define Build/Compile' "$npu_mk" && \
       ! grep -q 'LINUX_DIR)/Module.symvers' "$npu_mk"; then
        sed -i '/^define Build\/Compile/,/^endef$/{
            /M="\$(PKG_BUILD_DIR)"/a\\		KBUILD_EXTRA_SYMBOLS="\$(KBUILD_EXTRA_SYMBOLS) \$(LINUX_DIR)/Module.symvers" \\
        }' "$npu_mk"
        log_info "Injected kernel Module.symvers into mtk_npu Build/Compile"
    elif [ -f "$npu_mk" ]; then
        log_info "mtk_npu Module.symvers injection already present or not needed"
    else
        log_warn "mtk_npu Makefile not found, skipping Module.symvers injection"
    fi

    if [ -f "$mt76_cmake" ]; then
        sed -i 's/cmake_minimum_required(VERSION 2\.8)/cmake_minimum_required(VERSION 3.5)/' "$mt76_cmake"
        log_info "Ensured mt76-vendor CMake minimum version compatibility"
    fi

    # ndo_flow_offload_stats64_add is provided by the autobuild 999-net-04
    # netdevice patch copied in overlay_autobuild_kernel_files().
}

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

# ── 阶段 0: 初始化 ────────────────────────────────────────────────────
overlay_autobuild_kernel_files() {
    local dest="$OPENWRT_ROOT/target/linux/mediatek/files-6.12"
    local src="$MTK_SDK_DIR/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/files-6.12"
    local patch_src="$MTK_SDK_DIR/autobuild/unified/global/logan_common/25.12/files/target/linux/mediatek/patches-6.12"
    local patch_dst="$OPENWRT_ROOT/target/linux/mediatek/patches-6.12"
    local patch hdr copied

    log_step "Overlaying autobuild HNAT/NPU kernel files"

    if [ -d "$src" ]; then
        mkdir -p "$dest"
        cp -af "$src"/. "$dest/" 2>/dev/null || true

        # Autobuild files-6.12 may include build-system files designed for
        # MTK's own kernel tree. Keep the HNAT subdir Makefile, which is
        # required by the 999-eth-91 parent Makefile patch, and strip any
        # other copied Kbuild/Kconfig files that could override ImmortalWrt.
        local cleaned=0
        while IFS= read -r -d '' mf; do
            case "$mf" in
                */drivers/net/ethernet/mediatek/mtk_hnat/Makefile)
                    continue
                    ;;
            esac
            rm -f "$mf"
            cleaned=$((cleaned + 1))
        done < <(find "$dest" -type f \( -name 'Makefile' -o -name 'Kbuild' -o -name 'Kconfig' \) -print0 2>/dev/null || true)
        [ "$cleaned" -gt 0 ] && log_warn "Removed $cleaned non-HNAT Makefile/Kbuild/Kconfig files from autobuild files-6.12 overlay"

        log_info "Autobuild kernel files overlaid to $dest"
    else
        log_warn "Autobuild files-6.12 directory missing: $src"
    fi

    if [ -d "$patch_src" ]; then
        mkdir -p "$patch_dst"
        copied=0
        local patches_file; patches_file=$(rule_path "autobuild-patches.txt")
        if [ -f "$patches_file" ]; then
            while IFS= read -r patch; do
                if [ -f "$patch_src/$patch" ]; then
                    cp -f "$patch_src/$patch" "$patch_dst/$patch"
                    copied=$((copied + 1))
                else
                    log_warn "Autobuild patch missing: $patch"
                fi
            done < <(load_rule_file "$patches_file")
        else
            log_warn "Autobuild patch whitelist not found: autobuild-patches.txt"
        fi

        cat > "$patch_dst/999-net-03-netdevice-add-tnl-device-path-type.patch" <<'PATCH'
--- a/include/linux/netdevice.h
+++ b/include/linux/netdevice.h
@@ -838,2 +838,5 @@ enum net_device_path_type {
 	DEV_PATH_MACVLAN,
+	DEV_PATH_DSLITE,
+	DEV_PATH_6RD,
+	DEV_PATH_TNL,
 	DEV_PATH_MTK_WDMA,
PATCH
        log_info "Autobuild HNAT/NPU kernel patches overlaid to $patch_dst ($copied copied + local netdevice fix)"
    else
        log_warn "Autobuild patches-6.12 directory missing: $patch_src"
    fi

    patch="$patch_src/999-eth-93-mtk_eth_soc-add-internal-SER-notify-event.patch"
    hdr="$dest/drivers/net/ethernet/mediatek/mtk_eth_reset.h"
    if [ -f "$patch" ]; then
        mkdir -p "$(dirname "$hdr")"
        sed -n '/^diff.*mtk_eth_reset\.h$/,/^diff.*mtk_eth_soc\.c$/{/^+++/!s/^+//;/^diff.*mtk_eth_soc\.c$/d;p}' "$patch" | \
            sed '1,/^@@/d' > "$hdr"
        test -s "$hdr"
        grep -q '^#define MTK_FE_START_RESET' "$hdr"
        grep -q '^#define MTK_TOPS_DUMP_DONE' "$hdr"
        log_info "Extracted mtk_eth_reset.h ($(wc -l < "$hdr") lines)"
    else
        log_warn "Cannot extract mtk_eth_reset.h; patch missing: $patch"
    fi
}

stage_init() {
    echo "# MTK SDK Integration Log — $(date)" > "$CONFLICT_LOG"
    echo "# MTK SDK Applied Patches — $(date)" > "$APPLIED_LOG"
    echo "# MTK SDK Skipped Patches — $(date)" > "$SKIPPED_LOG"
    echo "MTK_SDK_DIR=$MTK_SDK_DIR" >> "$APPLIED_LOG"
    echo "MTK_SDK_BRANCH=$MTK_SDK_BRANCH" >> "$APPLIED_LOG"
}

# ── 阶段 1: SDK 覆盖层同步 ──────────────────────────────────────────────
stage_overlay() {
    # 克隆 SDK
    clone_mtk_sdk || exit 1

    # 清理 ImmortalWrt 预置冲突补丁
    clean_conflicting_immortalwrt_patches

    # 移除不兼容的旧 SFP quirk 补丁，注入本地 SFP/PCS 补丁
    remove_broken_sfp_612_patches
    remove_stale_pcs_lynxi_612_patches
    sync_local_sfp_612_patches

    # 复制 MTK SDK 25.12 文件覆盖层
    copy_files_safe "$MTK_SDK_DIR/25.12/files" "25.12/files"

    # 复制 filogic 特定文件
    local filogic_files="$MTK_SDK_DIR/autobuild/unified/filogic/25.12/files"
    if [ -d "$filogic_files" ]; then
        copy_files_safe "$filogic_files" "filogic/25.12/files"
    fi

    # 复写后归一化 SFP 补丁
    remove_broken_sfp_612_patches
    remove_stale_pcs_lynxi_612_patches
    sync_local_sfp_612_patches
}

# ── 阶段 2: 覆盖后清理 ──────────────────────────────────────────────────
stage_cleanup() {
    # 移除不适用于 BPI-R4 的 MTK SDK overlay 产物
    remove_mtk_fstools_overlay_patches
    remove_mtk_listed_conflicts

    overlay_autobuild_kernel_files

    # 复写后归一化 + 验证 SFP 补丁
    remove_broken_sfp_612_patches
    remove_stale_pcs_lynxi_612_patches
    sync_local_sfp_612_patches
    verify_local_sfp_612_patches

    touch "${OPENWRT_ROOT}/.timestamp"
}

# ── 阶段 3: 补丁应用 ────────────────────────────────────────────────────
stage_patches() {
    scan_patches "$MTK_SDK_DIR/25.12/patches-base" "patches-base" || true
    apply_patches_safe "$MTK_SDK_DIR/25.12/patches-base" "patches-base"
}

# ── 阶段 4: 内核配置与工具修正 ──────────────────────────────────────────
stage_fixups() {
    ensure_bpi_r4_mtk_packages
    ensure_kernel_config_fixes
    verify_critical_tools
}

# ── 阶段 5: Feed 注册与收尾 ─────────────────────────────────────────────
stage_finalize() {
    add_mtk_feed
    patch_mtk_feed_build_fixes

    # fdt-patch-dm-verify stub（BPI-R4 不使用 DM-verity secure boot）
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
}

# ── 阶段 6: 总结报告 ────────────────────────────────────────────────────
stage_summary() {
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

    stage_init
    log_step "Stage 1/6 — SDK overlay sync"
    stage_overlay
    log_step "Stage 2/6 — Post-overlay cleanup"
    stage_cleanup
    log_step "Stage 3/6 — Patch application"
    stage_patches
    log_step "Stage 4/6 — Kernel config & tool fixups"
    stage_fixups
    log_step "Stage 5/6 — Feed registration & finalization"
    stage_finalize
    log_step "Stage 6/6 — Summary"
    stage_summary

    # 预扫描冲突是预期的（ImmortalWrt 与 OpenWrt 基线差异），不应阻断构建。
    # 真正需要关注的是应用阶段是否仍产生 [REJECTS]。
    return 0
}

main "$@"
