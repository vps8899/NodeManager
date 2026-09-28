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
    if [[ -n "$GLOBAL_IPV4" ]]; then
        echo "$GLOBAL_IPV4"
        return
    fi
    
    local ip_file="/etc/node-manager/database/ipv4.txt"
    if [[ -f "$ip_file" ]]; then
        local cached_ip=$(cat "$ip_file")
        if [[ -n "$cached_ip" ]]; then
            export GLOBAL_IPV4="$cached_ip"
            echo "$cached_ip"
            return
        fi
    fi
    
    local ip
    ip=$(curl -s4 -m 5 ip.sb 2>/dev/null)
    if [[ -z "$ip" || "$ip" == *html* || "$ip" == *HTML* ]]; then
        ip=$(curl -s4 -m 5 api.ipify.org 2>/dev/null)
    fi
    if [[ -n "$ip" && "$ip" != *html* && "$ip" != *HTML* ]]; then
        export GLOBAL_IPV4="$ip"
        mkdir -p "$(dirname "$ip_file")"
        echo "$ip" > "$ip_file"
    fi
    echo "$ip"
}

# 获取本机公网 IPv6
get_ipv6() {
    if [[ -n "$GLOBAL_IPV6" ]]; then
        echo "$GLOBAL_IPV6"
        return
    fi
    
    local ip_file="/etc/node-manager/database/ipv6.txt"
    if [[ -f "$ip_file" ]]; then
        local cached_ip=$(cat "$ip_file")
        if [[ -n "$cached_ip" ]]; then
            export GLOBAL_IPV6="$cached_ip"
            echo "$cached_ip"
            return
        fi
    fi
    
    local ip
    ip=$(curl -s6 -m 5 ip.sb 2>/dev/null)
    if [[ -z "$ip" || "$ip" == *html* || "$ip" == *HTML* ]]; then
        ip=$(curl -s6 -m 5 api6.ipify.org 2>/dev/null)
    fi
    if [[ -n "$ip" && "$ip" != *html* && "$ip" != *HTML* ]]; then
        export GLOBAL_IPV6="$ip"
        mkdir -p "$(dirname "$ip_file")"
        echo "$ip" > "$ip_file"
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
