#!/bin/bash
#
# diy-part5.sh — ImmortalWrt 25.12 feeds & community packages
#   (runs AFTER diy-mtk-sdk.sh which sets up MTK SDK patches + feed)
#

# ── MTK SDK feed guard ────────────────────────────────────────────────
# Ensure MTK feed is registered (idempotent — diy-mtk-sdk.sh may
# have already added it; if not, add it now from the cloned SDK dir).
MTK_SDK_DIR="${MTK_SDK_DIR:-${GITHUB_WORKSPACE}/mtk-openwrt-feeds}"
if [ -d "$MTK_SDK_DIR/feed/kernel" ] && ! grep -q "mtk_openwrt_feed" feeds.conf.default 2>/dev/null; then
    echo "src-link mtk_openwrt_feed ${MTK_SDK_DIR}/feed" >> feeds.conf.default
    echo "[MTK-SDK] Added MTK feed to feeds.conf.default"
fi

merge_package(){
    repo=`echo $1 | rev | cut -d'/' -f 1 | rev`
    pkg=`echo $2 | rev | cut -d'/' -f 1 | rev`
    git clone --depth=1 --single-branch $1
    [ -d package/openwrt-packages ] || mkdir -p package/openwrt-packages
    mv $2 package/openwrt-packages/
    rm -rf $repo
}

patch_makefile_dep() {
    local file_path="$1"
    local old_text="$2"
    local new_text="$3"
    local perl_status

    [ -f "$file_path" ] || return 0
    grep -qF "$old_text" "$file_path" || return 0

    PATCH_OLD_TEXT="$old_text" PATCH_NEW_TEXT="$new_text" \
        perl -0pi -e 'BEGIN { $old = $ENV{"PATCH_OLD_TEXT"}; $new = $ENV{"PATCH_NEW_TEXT"}; }
            $count = s/\Q$old\E/$new/g;
            END { exit($count > 0 ? 0 : 2); }' "$file_path"
    perl_status=$?

    [ "$perl_status" -eq 0 ] || {
        echo "Failed to apply literal patch to $file_path" >&2
        return "$perl_status"
    }
}

apply_workspace_patch() {
    local patch_file="$1"

    [ -f "$patch_file" ] || return 0

    if git apply --recount --ignore-space-change --ignore-whitespace --reverse --check "$patch_file" >/dev/null 2>&1; then
        return 0
    fi

    git apply --recount --ignore-space-change --ignore-whitespace "$patch_file"
}

fix_mtk_flowtable_dependency() {
    # MTK flowtable feed may depend on kmod-nf-flow-netlink, which is not
    # present in ImmortalWrt 25.12. Drop the stale dependency in the SDK
    # source, generated feed metadata (both per-feed indices and per-package
    # info files), and the installed package copy.
    for flowtable_mk in \
        "${MTK_SDK_DIR}/feed/flowtable/Makefile" \
        feeds/mtk_openwrt_feed/flowtable/Makefile \
        package/feeds/mtk_openwrt_feed/flowtable/Makefile; do
        [ -f "$flowtable_mk" ] && sed -i 's/[[:space:]]*+kmod-nf-flow-netlink//g' "$flowtable_mk"
    done

    # Per-feed metadata (e.g. tmp/info/mtk_openwrt_feed.index)
    find tmp/info -type f -name '*mtk_openwrt_feed*' -exec \
        sed -i 's/[[:space:]]*+kmod-nf-flow-netlink//g' {} \; 2>/dev/null || true
    # Per-package metadata (e.g. tmp/info/flowtable.* — named by package, not feed)
    find tmp/info -type f -name 'flowtable*' -exec \
        sed -i 's/[[:space:]]*+kmod-nf-flow-netlink//g' {} \; 2>/dev/null || true
}

# Remove upstream feeds replaced by community clones below
rm -rf feeds/luci/themes/luci-theme-argon
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/luci/applications/luci-app-modemband
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}

# Clone community packages
mkdir -p package/community
pushd package/community
git clone --depth=1 -b dev https://github.com/fw876/helloworld
git clone --depth=1 -b main https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git
[ -f openwrt-passwall-packages/haproxy/Makefile ] && sed -i '/^[[:space:]]*ADDON+=USE_QUIC=1$/d' openwrt-passwall-packages/haproxy/Makefile
git clone --depth=1 -b main https://github.com/Openwrt-Passwall/openwrt-passwall.git
git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki
git clone --depth=1 https://github.com/1522042029/luci-app-socat
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config
merge_package https://github.com/MedyMa/luci-app luci-app/Luci-app/luci-app-fan
merge_package https://github.com/MedyMa/luci-app luci-app/Luci-app/luci-app-sfp-status
merge_package https://github.com/MedyMa/luci-app luci-app/Luci-app/luci-app-adguardhome
merge_package https://github.com/MedyMa/luci-app luci-app/Luci-app/luci-app-modemband
merge_package https://github.com/kenzok8/jell jell/wrtbwmon
merge_package "-b main https://github.com/linkease/ddnsto-openwrt-package" ddnsto-openwrt-package/ddnsto
merge_package "-b main https://github.com/linkease/ddnsto-openwrt-package" ddnsto-openwrt-package/luci-app-ddnsto
popd

# luci-app-mosdns
rm -rf feeds/packages/lang/golang
git clone --depth=1 https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
rm -rf feeds/packages/net/mosdns
git clone --depth=1 https://github.com/sbwml/luci-app-mosdns -b v5 package/mosdns

# luci-app-OpenClash
mkdir -p package/OpenClash
pushd package/OpenClash
git clone --depth=1 https://github.com/vernesong/OpenClash
popd

# Fix non-deterministic PKG_MIRROR_HASH in helloworld/shadowsocks-libev
patch_makefile_dep \
    package/community/helloworld/shadowsocks-libev/Makefile \
    'PKG_MIRROR_HASH:=b3898ad0a557bc8b0bbb2f3888101d461944239b0b7d4d4c6f164d73694a4595' \
    'PKG_MIRROR_HASH:=skip'

# shadowsocksr-libev: replace brittle LTO with no-lto
[ -f package/community/openwrt-passwall-packages/shadowsocksr-libev/Makefile ] && {
    sed -i '/^[[:space:]]*TARGET_CFLAGS += -flto$/c\PKG_BUILD_FLAGS+=no-lto' \
        package/community/openwrt-passwall-packages/shadowsocksr-libev/Makefile
    patch_makefile_dep \
        package/community/openwrt-passwall-packages/shadowsocksr-libev/Makefile \
        '146fa4511a52da2aaa1e11ea0294cfb450e62643156c5da3b10e037ef43961f6' \
        'skip'
}

# GCC 14 + musl fortify workaround for mbedtls
if ! grep -q '_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile; then
    if grep -q '\$(if \$(findstring cortex-a53,\$(CONFIG_CPU_TYPE)),-march=armv8-a)' package/libs/mbedtls/Makefile; then
        sed -i '/$(if $(findstring cortex-a53,$(CONFIG_CPU_TYPE)),-march=armv8-a)/a TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile
  else
    echo 'TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' >> package/libs/mbedtls/Makefile
  fi
fi

# Drop onionshare-cli (unresolved metadata, not in our config)
rm -rf feeds/packages/net/onionshare-cli

[ -f feeds/luci/applications/luci-app-package-manager/root/usr/libexec/package-manager-call ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/1004-luci-package-manager-apk-upload-untrusted-master.patch"

# vpnc: add -p to mkdir for idempotency
if grep -q 'mkdir $(PKG_BUILD_DIR)/bin' feeds/packages/net/vpnc/Makefile 2>/dev/null; then
    sed -i '/mkdir $(PKG_BUILD_DIR)\/bin/s/mkdir /mkdir -p /' feeds/packages/net/vpnc/Makefile
fi

fix_mtk_flowtable_dependency
./scripts/feeds update mtk_openwrt_feed >/dev/null 2>&1 || true
fix_mtk_flowtable_dependency
./scripts/feeds install -a

# ── MTK SDK patches-feeds ─────────────────────────────────────────────
# patches-feeds 必须在 feeds install 之后应用，因为它修改的是 feed 包
# （cryptsetup, libaio, lvm2, dm, strongswan）的 Makefile 和配置。
apply_mtk_patches_feeds() {
    local mtk_dir="${MTK_SDK_DIR:-${GITHUB_WORKSPACE}/mtk-openwrt-feeds}"
    local pf_dir="$mtk_dir/25.12/patches-feeds"

    [ -d "$pf_dir" ] || return 0
    echo "[MTK-SDK] Applying patches-feeds (feed package patches)..."
    local ok=0 fail=0
    for pf in $(find "$pf_dir" -name "*.patch" -type f | sort); do
        local pname; pname=$(basename "$pf")
        if patch -p1 --force --no-backup-if-mismatch < "$pf" 2>/dev/null; then
            ok=$((ok + 1))
        else
            echo "[MTK-SDK]   WARN: patches-feeds/$pname did not apply cleanly"
            fail=$((fail + 1))
        fi
    done
    echo "[MTK-SDK] patches-feeds: $ok applied, $fail skipped"
}
apply_mtk_patches_feeds

fix_mtk_flowtable_dependency

# Feed deps needed by community clones (pcre2 is in main tree since 25.12)
./scripts/feeds install c-ares udns



# Remove kiddin9 APK repo (triggers broken video/ sub-repo)
for f in \
    package/base-files/files/etc/apk/repositories \
    package/base-files/files/etc/apk/repositories.d/* \
    package/utils/alpine-repositories/files/repositories; do
    [ -f "$f" ] && grep -q 'kiddin9' "$f" 2>/dev/null && sed -i '/kiddin9/d' "$f" 2>/dev/null || true
done

# APK runtime fixes: allow local unsigned APK uploads and disable broken feed entries
rm -f package/base-files/files/etc/uci-defaults/99-apk-untrusted
[ -d package/base-files/files/etc/uci-defaults ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/1005-base-files-apk-manager-fixes-master.patch"

# Verify libmbedtls presence (required by shadowsocks-libev)
if [ ! -f package/libs/mbedtls/Makefile ]; then
  echo "WARNING: package/libs/mbedtls/Makefile not found" >&2
elif ! grep -q 'define Package/libmbedtls' package/libs/mbedtls/Makefile; then
  echo "WARNING: package/libs/mbedtls/Makefile does not define libmbedtls" >&2
fi

# GO proxy for sing-box
export GOEXPERIMENT=
export GOPROXY=https://proxy.golang.org,direct

# Compatibility fixes for floating feeds metadata
patch_makefile_dep \
    feeds/packages/lang/python/python-ubus/Makefile \
    'PKG_BUILD_DEPENDS:=python-setuptools/host' \
    'PKG_BUILD_DEPENDS:=python3/host'
patch_makefile_dep \
    package/feeds/packages/python-ubus/Makefile \
    'PKG_BUILD_DEPENDS:=python-setuptools/host' \
    'PKG_BUILD_DEPENDS:=python3/host'

patch_makefile_dep \
    feeds/packages/admin/zabbix/Makefile \
    'libnetsnmp-ssl' \
    'libnetsnmp'
patch_makefile_dep \
    package/feeds/packages/zabbix/Makefile \
    'libnetsnmp-ssl' \
    'libnetsnmp'

# Reduce BPI-R4 U-Boot bootdelay
patch_makefile_dep \
    package/boot/uboot-mediatek/patches/450-add-bpi-r4.patch \
    'CONFIG_BOOTDELAY=30' \
    'CONFIG_BOOTDELAY=10'

# Apply LuCI patches for master/25.12 (regenerated 2026-07-03 against openwrt-25.12).
# Each call is guarded with || true: if the luci feed has moved past the patch's
# base commit the apply fails silently rather than aborting the build.

# RPCD: add getWifiStationHints ubus method + helper functions
[ -f feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/1000-luci-rpcd-getWifiStationHints-master.patch" || true

# 60_wifi.js: wifi7/MLO station hints + mhz_hi support (merged 1000+1002)
[ -f feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/60_wifi.js ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/1000-luci-status-60wifi-master.patch" || true

# wireless.js: station hints + mtk mode matrix + MLO OFDMA (merged 1001+999+1003)
[ -f feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/view/network/wireless.js ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/1001-luci-wireless-combined-master.patch" || true
