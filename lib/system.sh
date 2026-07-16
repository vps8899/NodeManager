#!/usr/bin/env bash
# system.sh - 系统环境检测与依赖管理

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_err "请使用 root 用户运行此脚本！"
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        print_err "未知的操作系统"
        exit 1
    fi
    
    if [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        PKG_MANAGER="apt"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update"
    elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update"
    else
        print_err "不支持的操作系统: $OS"
        exit 1
    fi
}

check_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            print_err "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
}

install_dependencies() {
    print_info "正在检查并安装必要的依赖项..."
    local deps="curl wget jq openssl unzip qrencode cron socat tar gzip bc git"
    
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        eval $PKG_UPDATE >/dev/null 2>&1
    fi
    
    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            print_info "正在安装 $dep ..."
            eval "$PKG_INSTALL $dep" >/dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                print_err "安装 $dep 失败，请检查网络或软件源。"
            fi
        fi
    done
    print_ok "依赖项检查完成。"
}

check_port() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        if ss -tulpn | grep -q ":$port "; then
            return 1 # 端口被占用
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tulpn | grep -q ":$port "; then
            return 1
        fi
    fi
    return 0 # 端口空闲
}

check_bbr() {
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ "$bbr_status" == "bbr" ]]; then
        print_ok "BBR 拥塞控制已开启。"
    else
        print_warn "当前未使用 BBR，建议开启以优化网络速度。"
    fi
}

check_sys() {
    check_root
    check_os
    check_arch
}
