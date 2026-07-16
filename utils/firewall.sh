#!/usr/bin/env bash
# firewall.sh - 防火墙管理统一接口

open_port() {
    local port=$1
    local protocol=${2:-"tcp,udp"} # 默认同时开放 tcp 和 udp

    IFS=',' read -ra PROTOS <<< "$protocol"

    for proto in "${PROTOS[@]}"; do
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            ufw allow "$port/$proto" >/dev/null 2>&1
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld | grep -q "^active"; then
            firewall-cmd --zone=public --add-port="$port/$proto" --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        elif command -v iptables >/dev/null 2>&1; then
            if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
                # 保存规则，根据不同系统可能会有所不同，此处仅作简单示例
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service >/dev/null 2>&1 && [ -f /etc/init.d/iptables ]; then
                    service iptables save >/dev/null 2>&1
                fi
            fi
        fi
    done
}

close_port() {
    local port=$1
    local protocol=${2:-"tcp,udp"}

    IFS=',' read -ra PROTOS <<< "$protocol"

    for proto in "${PROTOS[@]}"; do
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            ufw delete allow "$port/$proto" >/dev/null 2>&1
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld | grep -q "^active"; then
            firewall-cmd --zone=public --remove-port="$port/$proto" --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        elif command -v iptables >/dev/null 2>&1; then
            if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
                if command -v netfilter-persistent >/dev/null 2>&1; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service >/dev/null 2>&1 && [ -f /etc/init.d/iptables ]; then
                    service iptables save >/dev/null 2>&1
                fi
            fi
        fi
    done
}
