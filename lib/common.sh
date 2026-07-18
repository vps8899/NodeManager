#!/usr/bin/env bash
# common.sh - 通用工具函数

# 生成 UUID
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# 生成随机密码/字符串 (带长度参数)
generate_random_string() {
    local length=${1:-16}
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
}

# 生成随机高位端口
generate_random_port() {
    echo $((RANDOM % 50000 + 10000))
}

# 获取本机公网 IPv4
get_ipv4() {
    local ip
    ip=$(curl -s4 -m 5 ip.sb 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s4 -m 5 api.ipify.org 2>/dev/null)
    fi
    echo "$ip"
}

# 获取本机公网 IPv6
get_ipv6() {
    local ip
    ip=$(curl -s6 -m 5 ip.sb 2>/dev/null)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 -m 5 api6.ipify.org 2>/dev/null)
    fi
    echo "$ip"
}

# 判断字符串是否是合法的 IP
is_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    elif [[ $ip =~ ^[0-9a-fA-F:]+$ ]]; then
        return 0
    else
        return 1
    fi
}
