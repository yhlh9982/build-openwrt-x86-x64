#!/bin/bash

# ============================================
# 打包toolchain目录 (编译阶段调用)
# ============================================
if [[ "$REBUILD_TOOLCHAIN" = 'true' ]]; then
    cd "$OPENWRT_PATH"
    sed -i 's/ $(tool.*\/stamp-compile)//' Makefile
    if [[ -d ".ccache" && $(du -s .ccache | cut -f1) -gt 0 ]]; then
        echo "🔍 缓存目录大小:"
        du -h --max-depth=1 .ccache
        ccache_dir=".ccache"
    fi
    echo "📦 工具链目录大小:"
    du -h --max-depth=1 staging_dir
    tar -I zstdmt -cf "$GITHUB_WORKSPACE/output/$CACHE_NAME.tzst" staging_dir/host* staging_dir/tool* $ccache_dir
    echo "📁 输出目录内容:"
    ls -lh "$GITHUB_WORKSPACE/output"
    if [[ ! -e "$GITHUB_WORKSPACE/output/$CACHE_NAME.tzst" ]]; then
        echo "❌ 工具链打包失败!"
        exit 1
    fi
    echo "✅ 工具链打包完成"
    exit 0
fi

# ============================================
# 全局变量与初始化
# ============================================

# 创建toolchain缓存保存目录
[ -d "$GITHUB_WORKSPACE/output" ] || mkdir "$GITHUB_WORKSPACE/output"

# 额外插件默认存放目录
destination_dir="package/custom"

# ============================================
# 通用工具函数
# ============================================

# 颜色输出
color() {
    case "$1" in
        cr) echo -e "\e[1;31m${2}\e[0m" ;;  # 红色
        cg) echo -e "\e[1;32m${2}\e[0m" ;;  # 绿色
        cy) echo -e "\e[1;33m${2}\e[0m" ;;  # 黄色
        cb) echo -e "\e[1;34m${2}\e[0m" ;;  # 蓝色
        cp) echo -e "\e[1;35m${2}\e[0m" ;;  # 紫色
        cc) echo -e "\e[1;36m${2}\e[0m" ;;  # 青色
        cw) echo -e "\e[1;37m${2}\e[0m" ;;  # 白色
    esac
}

# 状态显示和时间统计
status_info() {
    local task_name="$1" begin_time=$(date +%s) exit_code time_info
    shift
    "$@"
    exit_code=$?
    [[ "$exit_code" -eq 99 ]] && return 0
    time_info="==> 用时 $(($(date +%s) - begin_time)) 秒"
    if [[ "$exit_code" -eq 0 ]]; then
        printf "%-64s [ %s ] %s\n" \
            "$(color cy "⏳ $task_name")" "$(color cg ✔)" "$(color cw "$time_info")"
    else
        printf "%-64s [ %s ] %s\n" \
            "$(color cy "⏳ $task_name")" "$(color cr ✖)" "$(color cw "$time_info")"
    fi
}

# 查找目录 (注意: $1 故意不加引号以支持多路径)
find_dir() {
    find $1 -maxdepth 3 -type d -name "$2" -print -quit 2>/dev/null
}

# 打印信息
print_info() {
    printf "%-6s %-40s %s %s %s\n" "$1" "$2" "$3" "$4" "$5"
}

# ============================================
# Git 操作辅助函数
# ============================================

# 添加整个源仓库(git clone)
git_clone() {
    local repo_url branch target_dir current_dir
    if [[ "$1" == */* ]]; then
        repo_url="$1"
        shift
    else
        branch="-b $1 --single-branch"
        repo_url="$2"
        shift 2
    fi
    target_dir="${1:-${repo_url##*/}}"
    git clone -q $branch --depth=1 "$repo_url" "$target_dir" 2>/dev/null || {
        print_info "$(color cr 拉取)" "$repo_url" "[" "$(color cr ✖)" "]"
        return 1
    }
    rm -rf "$target_dir"/{.git*,README*.md,LICENSE}
    current_dir=$(find_dir "package/ feeds/ target/" "$target_dir")
    if [[ -d "$current_dir" ]]; then
        rm -rf "$current_dir"
        mv -f "$target_dir" "${current_dir%/*}"
        print_info "$(color cg 替换)" "$target_dir" "[" "$(color cg ✔)" "]"
    else
        mv -f "$target_dir" "$destination_dir"
        print_info "$(color cb 添加)" "$target_dir" "[" "$(color cb ✔)" "]"
    fi
}

# 添加源仓库内的指定目录
clone_dir() {
    local repo_url branch temp_dir=$(mktemp -d)
    if [[ "$1" == */* ]]; then
        repo_url="$1"
        shift
    else
        branch="-b $1 --single-branch"
        repo_url="$2"
        shift 2
    fi
    git clone -q $branch --depth=1 "$repo_url" "$temp_dir" 2>/dev/null || {
        print_info "$(color cr 拉取)" "$repo_url" "[" "$(color cr ✖)" "]"
        rm -rf "$temp_dir"
        return 1
    }
    local target_dir source_dir current_dir
    for target_dir in "$@"; do
        source_dir=$(find_dir "$temp_dir" "$target_dir")
        if [[ ! -d "$source_dir" ]]; then
            source_dir=$(find "$temp_dir" -maxdepth 4 -type d -name "$target_dir" -print -quit)
        fi
        if [[ ! -d "$source_dir" ]]; then
            print_info "$(color cr 查找)" "$target_dir" "[" "$(color cr ✖)" "]"
            continue
        fi
        current_dir=$(find_dir "package/ feeds/ target/" "$target_dir")
        if [[ -d "$current_dir" ]]; then
            rm -rf "$current_dir"
            mv -f "$source_dir" "${current_dir%/*}"
            print_info "$(color cg 替换)" "$target_dir" "[" "$(color cg ✔)" "]"
        else
            mv -f "$source_dir" "$destination_dir"
            print_info "$(color cb 添加)" "$target_dir" "[" "$(color cb ✔)" "]"
        fi
    done
    rm -rf "$temp_dir"
}

# 添加源仓库内的所有子目录
clone_all() {
    local repo_url branch temp_dir=$(mktemp -d)
    if [[ "$1" == */* ]]; then
        repo_url="$1"
        shift
    else
        branch="-b $1 --single-branch"
        repo_url="$2"
        shift 2
    fi
    git clone -q $branch --depth=1 "$repo_url" "$temp_dir" 2>/dev/null || {
        print_info "$(color cr 拉取)" "$repo_url" "[" "$(color cr ✖)" "]"
        rm -rf "$temp_dir"
        return 1
    }
    process_dir() {
        while IFS= read -r source_dir; do
            local target_dir=$(basename "$source_dir")
            local current_dir=$(find_dir "package/ feeds/ target/" "$target_dir")
            if [[ -d "$current_dir" ]]; then
                rm -rf "$current_dir"
                mv -f "$source_dir" "${current_dir%/*}"
                print_info "$(color cg 替换)" "$target_dir" "[" "$(color cg ✔)" "]"
            else
                mv -f "$source_dir" "$destination_dir"
                print_info "$(color cb 添加)" "$target_dir" "[" "$(color cb ✔)" "]"
            fi
        done < <(find "$1" -maxdepth 1 -mindepth 1 -type d ! -name '.*')
    }
    if [[ $# -eq 0 ]]; then
        process_dir "$temp_dir"
    else
        for dir_name in "$@"; do
            if [[ -d "$temp_dir/$dir_name" ]]; then
                process_dir "$temp_dir/$dir_name"
            else
                print_info "$(color cr 目录)" "$dir_name" "[" "$(color cr ✖)" "]"
            fi
        done
    fi
    rm -rf "$temp_dir"
}

# ============================================
# 主流程
# ============================================
main() {
    echo "$(color cp "🚀 开始运行自定义脚本")"
    echo "========================================"

    # 拉取编译源码
    status_info "拉取编译源码" clone_source_code

    # 设置环境变量
    status_info "设置环境变量" set_variable_values

    # 下载部署toolchain缓存
    status_info "下载部署toolchain缓存" download_toolchain

    # 更新&安装插件
    status_info "更新&安装插件" update_install_feeds

    # 添加额外插件
    status_info "添加额外插件" add_custom_packages

    # 加载个人设置
    status_info "加载个人设置" apply_custom_settings

    # 更新配置文件
    status_info "更新配置文件" update_config_file

    # 下载zsh终端工具
    status_info "下载zsh终端工具" preset_shell_tools

    # 显示编译信息
    show_build_info

    echo "$(color cp "✅ 自定义脚本运行完成")"
    echo "========================================"
}

# ============================================
# 任务函数
# ============================================

# 拉取编译源码
clone_source_code() {
    # 设置编译源码与分支
    REPO_URL="https://github.com/coolsnowwolf/lede"
    echo "REPO_URL=$REPO_URL" >> "$GITHUB_ENV"
    REPO_BRANCH="master"
    echo "REPO_BRANCH=$REPO_BRANCH" >> "$GITHUB_ENV"

    # 拉取编译源码
    cd /workdir
    git clone -q -b "$REPO_BRANCH" --single-branch "$REPO_URL" openwrt
    ln -sf /workdir/openwrt "$GITHUB_WORKSPACE/openwrt"
    [ -d openwrt ] && cd openwrt || exit
    echo "OPENWRT_PATH=$PWD" >> "$GITHUB_ENV"
}

# 设置环境变量
set_variable_values() {
    local TARGET_NAME SUBTARGET_NAME KERNEL TOOLS_HASH

    # 源仓库与分支
    SOURCE_REPO=$(basename "$REPO_URL")
    echo "SOURCE_REPO=$SOURCE_REPO" >> "$GITHUB_ENV"
    echo "LITE_BRANCH=${REPO_BRANCH#*-}" >> "$GITHUB_ENV"

    # 平台架构
    TARGET_NAME=$(grep -oP "^CONFIG_TARGET_\K[a-z0-9]+(?==y)" "$GITHUB_WORKSPACE/$CONFIG_FILE")
    SUBTARGET_NAME=$(grep -oP "^CONFIG_TARGET_${TARGET_NAME}_\K[a-z0-9]+(?==y)" "$GITHUB_WORKSPACE/$CONFIG_FILE")
    DEVICE_TARGET="$TARGET_NAME-$SUBTARGET_NAME"
    echo "DEVICE_TARGET=$DEVICE_TARGET" >> "$GITHUB_ENV"

    # 内核版本
    KERNEL=$(grep -oP 'KERNEL_PATCHVER:=\K[\d\.]+' "target/linux/$TARGET_NAME/Makefile")
    KERNEL_VERSION=$(grep -oP 'LINUX_KERNEL_HASH-\K[\d\.]+' "include/kernel-$KERNEL")
    echo "KERNEL_VERSION=$KERNEL_VERSION" >> "$GITHUB_ENV"

    # toolchain缓存文件名
    TOOLS_HASH=$(git log -1 --pretty=format:"%h" tools toolchain)
    CACHE_NAME="$SOURCE_REPO-${REPO_BRANCH#*-}-$DEVICE_TARGET-cache-$TOOLS_HASH"
    echo "CACHE_NAME=$CACHE_NAME" >> "$GITHUB_ENV"

    # 源码更新信息
    echo "COMMIT_AUTHOR=$(git show -s --date=short --format="作者: %an")" >> "$GITHUB_ENV"
    echo "COMMIT_DATE=$(git show -s --date=short --format="时间: %ci")" >> "$GITHUB_ENV"
    echo "COMMIT_MESSAGE=$(git show -s --date=short --format="内容: %s")" >> "$GITHUB_ENV"
    echo "COMMIT_HASH=$(git show -s --date=short --format="hash: %H")" >> "$GITHUB_ENV"

    # 检测编译架构
    CPU_ARCH=$(detect_openwrt_arch "$GITHUB_WORKSPACE/$CONFIG_FILE")
    echo "CPU_ARCH=$CPU_ARCH" >> "$GITHUB_ENV"
}

# 下载部署toolchain缓存
download_toolchain() {
    local cache_xa cache_xc tzst_file
    if [[ "$TOOLCHAIN" = 'true' ]]; then
        cache_xa=$(curl -sL "https://api.github.com/repos/$GITHUB_REPOSITORY/releases" | awk -F '"' '/download_url/{print $4}' | grep "$CACHE_NAME")
        cache_xc=$(curl -sL "https://api.github.com/repos/haiibo/toolchain-cache/releases" | awk -F '"' '/download_url/{print $4}' | grep "$CACHE_NAME")
        if [[ "$cache_xa" || "$cache_xc" ]]; then
            wget -qc -t=3 "${cache_xa:-$cache_xc}"
            tzst_file=$(ls *.tzst 2>/dev/null | head -1)
            if [[ -n "$tzst_file" ]]; then
                tar -I unzstd -xf "$tzst_file" || tar -xf "$tzst_file"
                [[ "$cache_xa" ]] || (cp "$tzst_file" "$GITHUB_WORKSPACE/output" && echo "OUTPUT_RELEASE=true" >> "$GITHUB_ENV")
                [[ -d staging_dir ]] && sed -i 's/ $(tool.*\/stamp-compile)//' Makefile
            fi
        else
            echo "REBUILD_TOOLCHAIN=true" >> "$GITHUB_ENV"
            echo "⚠️ 未找到最新工具链"
            return 99
        fi
    else
        echo "REBUILD_TOOLCHAIN=true" >> "$GITHUB_ENV"
        return 99
    fi
}

# 更新&安装插件
update_install_feeds() {
    ./scripts/feeds update -a 1>/dev/null 2>&1
    ./scripts/feeds install -a 1>/dev/null 2>&1
}

# 添加额外插件
add_custom_packages() {
    echo "📦 添加额外插件..."
    mkdir -p "$destination_dir"

    # ------------------------------------------
    # 统一清理源码自带的冲突包
    # ------------------------------------------
    # 清理 feeds 中与科学插件/mosdns 冲突的包
    rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
    rm -rf feeds/luci/applications/{luci-app-passwall,luci-app-openclash}

    # 清理 mosdns 残留 (feeds install 可能在 package/feeds/ 下产生副本)
    find ./ \( -path "*/mosdns/Makefile" -o -path "*/v2ray-geodata/Makefile" \) -delete 2>/dev/null

    # ------------------------------------------
    # 科学插件
    # ------------------------------------------
    # Passwall
    git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git "$destination_dir/passwall-packages"
    git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall.git "$destination_dir/passwall"
    git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2.git "$destination_dir/passwall2"

    # OpenClash
    git clone --depth=1 -b dev https://github.com/vernesong/OpenClash.git "$destination_dir/openclash"

    # Nikki / Momo
    git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki.git "$destination_dir/nikki"
    git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-momo.git "$destination_dir/momo"

    # Daed + vmlinux-btf
    git clone --depth=1 -b kix https://github.com/QiuSimons/luci-app-daed.git "$destination_dir/daed"
    # git clone --depth=1 -b master https://github.com/QiuSimons/luci-app-daed.git "$destination_dir/daed"
    git clone --depth=1 https://github.com/QiuSimons/vmlinux-btf.git "$destination_dir/vmlinux-btf"

    # SSR+
    git clone --depth=1 https://github.com/fw876/helloworld.git "$destination_dir/ssrp"

    # ------------------------------------------
    # 功能插件
    # ------------------------------------------
    git clone --depth=1 https://github.com/sirpdboy/luci-app-poweroffdevice.git "$destination_dir/poweroffdevice"
    git clone --depth=1 https://github.com/isalikai/luci-app-owq-wol.git "$destination_dir/owq-wol"
    git clone --depth=1 https://github.com/gdy666/luci-app-lucky.git "$destination_dir/lucky"
    git clone --depth=1 https://github.com/sbwml/luci-app-openlist2.git "$destination_dir/openlist2"
    git clone --depth=1 https://github.com/stackia/rtp2httpd.git "$destination_dir/rtp2httpd"
    git clone --depth=1 https://github.com/sirpdboy/luci-app-watchdog.git "$destination_dir/watchdog"
    git clone --depth=1 https://github.com/sirpdboy/luci-app-taskplan.git "$destination_dir/taskplan"
    git clone --depth=1 https://github.com/iv7777/luci-app-authshield.git "$destination_dir/authshield"
    git clone --depth=1 https://github.com/destan19/OpenAppFilter.git "$destination_dir/OpenAppFilter"
    git clone --depth=1 https://github.com/janvanstiphout/luci-app-accesscontrol.git "$destination_dir/accesscontrol"

    # ------------------------------------------
    # MosDNS & v2ray-geodata (升级替换)
    # ------------------------------------------
    git clone --depth=1 -b v5 https://github.com/sbwml/luci-app-mosdns.git "$destination_dir/mosdns"
    git clone --depth=1 https://github.com/sbwml/v2ray-geodata.git "$destination_dir/v2ray-geodata"

    # ------------------------------------------
    # Golang 工具链 (升级替换)
    # ------------------------------------------
    rm -rf feeds/packages/lang/golang
    git clone --depth=1 -b 26.x https://github.com/sbwml/packages_lang_golang.git feeds/packages/lang/golang

    # ------------------------------------------
    # SmartDNS (升级替换)
    # ------------------------------------------
    local WORKINGDIR LUCIBRANCH

    WORKINGDIR="$(pwd)/feeds/packages/net/smartdns"
    mkdir -p "$WORKINGDIR"
    rm -rf "$WORKINGDIR"/*
    wget -q https://github.com/pymumu/openwrt-smartdns/archive/master.zip -O "$WORKINGDIR/master.zip"
    unzip -q "$WORKINGDIR/master.zip" -d "$WORKINGDIR"
    mv "$WORKINGDIR"/openwrt-smartdns-master/* "$WORKINGDIR"/
    rmdir "$WORKINGDIR/openwrt-smartdns-master"
    rm -f "$WORKINGDIR/master.zip"

    LUCIBRANCH="master"
    WORKINGDIR="$(pwd)/feeds/luci/applications/luci-app-smartdns"
    mkdir -p "$WORKINGDIR"
    rm -rf "$WORKINGDIR"/*
    wget -q "https://github.com/pymumu/luci-app-smartdns/archive/${LUCIBRANCH}.zip" -O "$WORKINGDIR/${LUCIBRANCH}.zip"
    unzip -q "$WORKINGDIR/${LUCIBRANCH}.zip" -d "$WORKINGDIR"
    mv "$WORKINGDIR"/luci-app-smartdns-${LUCIBRANCH}/* "$WORKINGDIR"/
    rmdir "$WORKINGDIR/luci-app-smartdns-${LUCIBRANCH}"
    rm -f "$WORKINGDIR/${LUCIBRANCH}.zip"

    # ------------------------------------------
    # VPN
    # ------------------------------------------
    git clone --depth=1 https://github.com/EasyTier/luci-app-easytier.git "$destination_dir/easytier"
    git clone --depth=1 https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community.git "$destination_dir/tailscale-community"

    # ------------------------------------------
    # 主题
    # ------------------------------------------
    git clone --depth=1 -b openwrt-25.12 https://github.com/sbwml/luci-theme-argon.git "$destination_dir/luci-theme-argon"
    git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora.git "$destination_dir/luci-theme-aurora"
    git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config.git "$destination_dir/luci-app-aurora-config"
    git clone --depth=1 https://github.com/sirpdboy/luci-theme-kucat.git "$destination_dir/luci-theme-kucat"
    git clone --depth=1 https://github.com/sirpdboy/luci-app-kucat-config.git "$destination_dir/luci-app-kucat-config"

    # ------------------------------------------
    # 晶晨宝盒
    # ------------------------------------------
    clone_all https://github.com/ophub/luci-app-amlogic
    sed -i "s|firmware_repo.*|firmware_repo 'https://github.com/$GITHUB_REPOSITORY'|g" "$destination_dir/luci-app-amlogic/root/etc/config/amlogic"
    # sed -i "s|kernel_path.*|kernel_path 'https://github.com/ophub/kernel'|g" "$destination_dir/luci-app-amlogic/root/etc/config/amlogic"
    sed -i "s|ARMv8|$RELEASE_TAG|g" "$destination_dir/luci-app-amlogic/root/etc/config/amlogic"

    # ------------------------------------------
    # 修复 Makefile 路径引用
    # ------------------------------------------
    find "$destination_dir" -type f -name "Makefile" | xargs sed -i \
        -e 's?\.\./\.\./\(lang\|devel\)?$(TOPDIR)/feeds/packages/\1?' \
        -e 's?\.\./\.\./luci.mk?$(TOPDIR)/feeds/luci/luci.mk?'

    # ------------------------------------------
    # 修复 Rust 本地编译 LLVM
    # ------------------------------------------
    local RUST_FILE="feeds/packages/lang/rust/Makefile"
    if [[ ! -f "$RUST_FILE" ]]; then
        RUST_FILE=$(find feeds/ -type f -name "Makefile" -path "*/lang/rust/*" | head -1)
    fi
    if [[ -n "$RUST_FILE" && -f "$RUST_FILE" ]]; then
        sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$RUST_FILE"
        echo "✅ Rust 已设置为本地编译 LLVM (路径: $RUST_FILE)"
    else
        echo "⚠️ 未找到 Rust Makefile，跳过"
    fi

    # ------------------------------------------
    # 转换插件语言翻译 (zh-cn ↔ zh_Hans)
    # ------------------------------------------
    for e in $(ls -d "$destination_dir"/luci-*/po feeds/luci/applications/luci-*/po 2>/dev/null); do
        if [[ -d "$e/zh-cn" && ! -d "$e/zh_Hans" ]]; then
            ln -s zh-cn "$e/zh_Hans" 2>/dev/null
        elif [[ -d "$e/zh_Hans" && ! -d "$e/zh-cn" ]]; then
            ln -s zh_Hans "$e/zh-cn" 2>/dev/null
        fi
    done
}

# 加载个人设置
apply_custom_settings() {
    [ -e "$GITHUB_WORKSPACE/files" ] && mv "$GITHUB_WORKSPACE/files" files

    # 设置固件rootfs大小
    if [ "$PART_SIZE" ]; then
        sed -i '/ROOTFS_PARTSIZE/d' "$GITHUB_WORKSPACE/$CONFIG_FILE"
        echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$PART_SIZE" >> "$GITHUB_WORKSPACE/$CONFIG_FILE"
    fi

    # 修改默认ip地址
    [ "$IP_ADDRESS" ] && sed -i '/lan) ipad/s/".*"/"'"$IP_ADDRESS"'"/' package/base-files/*/bin/config_generate

    # 更改默认shell为zsh
    sed -i 's/\/bin\/ash/\/usr\/bin\/zsh/g' package/base-files/files/etc/passwd

    # ttyd免登录
    # sed -i 's|/bin/login|/bin/login -f root|g' feeds/packages/utils/ttyd/files/ttyd.config

    # 设置root用户密码为空
    # sed -i '/CYXluq4wUazHjmCDBCqXF/d' package/lean/default-settings/files/zzz-default-settings

    # 更改argon主题背景
    # cp -f $GITHUB_WORKSPACE/images/bg1.jpg feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/img/bg1.jpg

    # x86型号只显示cpu型号
    sed -i 's/${g}.*/${a}${b}${c}${d}${e}${f}${hydrid}/g' package/lean/autocore/files/x86/autocore
    sed -i "s/'C'/'Core '/g; s/'T '/'Thread '/g" package/lean/autocore/files/x86/autocore

    # 切换 6.18内核
    # sed -i 's/^KERNEL_PATCHVER:=.*/KERNEL_PATCHVER:=6.18/' target/linux/x86/Makefile
    
    # 删除主题默认设置
    # find "$destination_dir"/luci-theme-*/ -type f -name '*luci-theme-*' -exec sed -i '/set luci.main.mediaurlbase/d' {} +

    # 调整docker到"服务"菜单
    # sed -i 's/"admin"/"admin", "services"/g' feeds/luci/applications/luci-app-dockerman/luasrc/controller/*.lua
    # sed -i 's/"admin"/"admin", "services"/g; s/admin\//admin\/services\//g' feeds/luci/applications/luci-app-dockerman/luasrc/model/cbi/dockerman/*.lua
    # sed -i 's/admin\//admin\/services\//g' feeds/luci/applications/luci-app-dockerman/luasrc/view/dockerman/*.htm
    # sed -i 's|admin\\|admin\\/services\\|g' feeds/luci/applications/luci-app-dockerman/luasrc/view/dockerman/container.htm

    # 取消对samba4的菜单调整
    # sed -i '/samba4/s/^/#/' package/lean/default-settings/files/zzz-default-settings
}

# 更新配置文件
update_config_file() {
    [ -e "$GITHUB_WORKSPACE/$CONFIG_FILE" ] && cp -f "$GITHUB_WORKSPACE/$CONFIG_FILE" .config
    make defconfig 1>/dev/null 2>&1
}

# 检测指令集架构
detect_openwrt_arch() {
    local config="${1:-.config}"
    local arch_pkgs=$(grep '^CONFIG_TARGET_ARCH_PACKAGES=' "$config" | cut -d'"' -f2)
    [ -n "$arch_pkgs" ] || return 1
    case "$arch_pkgs" in
        x86_64) echo "amd64" ;; i386*) echo "386" ;; aarch64*) echo "arm64" ;;
        arm_cortex-a*) echo "armv7" ;; arm_arm1176*|arm_mpcore*) echo "armv6" ;;
        arm_arm926*|arm_fa526|arm*xscale) echo "armv5" ;;
        mips64el_*) echo "mips64le" ;; mips64_*) echo "mips64" ;;
        mipsel_*) echo "mipsle" ;; mips_*) echo "mips" ;;
        riscv64*) echo "riscv64" ;; loongarch64*) echo "loong64" ;;
        powerpc64_*) echo "ppc64" ;; powerpc_*) echo "ppc" ;;
        arc_*) echo "arc" ;; *) echo "unknown" ;;
    esac
}

# 下载zsh终端工具
preset_shell_tools() {
    if grep -q "zsh=y" .config; then
        chmod +x "$GITHUB_WORKSPACE/scripts/preset-terminal-tools.sh"
        "$GITHUB_WORKSPACE/scripts/preset-terminal-tools.sh"
    else
        return 99
    fi
}

# 显示编译信息
show_build_info() {
    echo -e "$(color cy "📊 当前编译信息")"
    echo "========================================"
    echo "🔷 固件源码: $(color cc "$SOURCE_REPO")"
    echo "🔷 源码分支: $(color cc "$REPO_BRANCH")"
    echo "🔷 目标设备: $(color cc "$DEVICE_TARGET")"
    echo "🔷 内核版本: $(color cc "$KERNEL_VERSION")"
    echo "🔷 编译架构: $(color cc "$CPU_ARCH")"
    echo "========================================"
}

# ============================================
# 入口
# ============================================
main "$@"
