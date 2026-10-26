#!/usr/bin/env bash
# argo_updater.sh - 自动更新与保活多端口独立 Argo Tunnel 临时隧道

_UPDATER_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$_UPDATER_DIR/../lib/ui.sh"
source "$_UPDATER_DIR/../lib/system.sh"
source "$_UPDATER_DIR/../lib/common.sh"
source "$_UPDATER_DIR/../lib/config.sh"
source "$_UPDATER_DIR/../utils/firewall.sh"
source "$_UPDATER_DIR/../utils/cert.sh"
source "$_UPDATER_DIR/../utils/subscription.sh"
unset _UPDATER_DIR

NEED_REFRESH_SUB=0

# 从指定隧道的日志中提取最新的合法 trycloudflare 域名
get_latest_domain_for_tunnel() {
    local tid=$1
    local log_file="/etc/node-manager/logs/argo-${tid}.log"
    # 兼容历史单隧道日志路径
    if [[ ! -f "$log_file" && -f "/etc/node-manager/logs/argo.log" && "$tid" -eq 1 ]]; then
        log_file="/etc/node-manager/logs/argo.log"
    fi
    
    if [[ -f "$log_file" ]]; then
        local raw_domain
        raw_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$log_file" 2>/dev/null | tail -n 1 | sed 's|https://||')
        if [[ "$raw_domain" =~ ^[a-zA-Z0-9-]+\.trycloudflare\.com$ ]]; then
            echo "$raw_domain"
        fi
    fi
}

# 同步指定隧道的最新域名到 nodes.json
sync_tunnel_domain() {
    local tid=$1
    local latest_domain
    latest_domain=$(get_latest_domain_for_tunnel "$tid")
    if [[ -z "$latest_domain" ]]; then
        return
    fi
    
    local nodes
    nodes=$(get_all_nodes 2>/dev/null)
    if [[ -z "$nodes" ]]; then
        return
    fi
    
    # 匹配对应 tunnel_id 的节点 (兼容旧版无 tunnel_id 且 tid=1 的情况)
    local target_node
    target_node=$(echo "$nodes" | jq -c 'select(.type == "argo" and ((.tunnel_id == '$tid') or (.tunnel_id == null and '$tid' == 1)))' 2>/dev/null | head -n 1)
    if [[ -n "$target_node" ]]; then
        local old_domain
        old_domain=$(echo "$target_node" | jq -r '.domain' 2>/dev/null)
        local node_id
        node_id=$(echo "$target_node" | jq -r '.id' 2>/dev/null)
        
        if [[ "$old_domain" != "$latest_domain" && -n "$node_id" ]]; then
            local temp
            temp=$(mktemp -p "/etc/node-manager/database")
            if jq '(.nodes[] | select(.id == "'"$node_id"'") | .domain) = "'"$latest_domain"'"' "/etc/node-manager/database/nodes.json" > "$temp" 2>/dev/null; then
                mv "$temp" "/etc/node-manager/database/nodes.json"
                NEED_REFRESH_SUB=1
            else
                rm -f "$temp"
            fi
        fi
    fi
}

# 独立健康检查与自愈重启特定隧道
check_and_heal_tunnel() {
    local tid=$1
    local nodes
    nodes=$(get_all_nodes 2>/dev/null)
    if [[ -z "$nodes" ]]; then
        return
    fi
    
    local target_node
    target_node=$(echo "$nodes" | jq -c 'select(.type == "argo" and ((.tunnel_id == '$tid') or (.tunnel_id == null and '$tid' == 1)))' 2>/dev/null | head -n 1)
    if [[ -z "$target_node" ]]; then
        return
    fi
    
    local current_domain
    current_domain=$(echo "$target_node" | jq -r '.domain' 2>/dev/null)
    if [[ -z "$current_domain" || "$current_domain" == "null" || "$current_domain" =~ ^waiting-tunnel ]]; then
        return
    fi
    
    local service_name="argo-tunnel-${tid}"
    if ! systemctl list-unit-files 2>/dev/null | grep -q "argo-tunnel-${tid}.service"; then
        service_name="argo-tunnel"
    fi
    
    # 1. 检查服务进程是否存活
    if ! systemctl is-active "$service_name" >/dev/null 2>&1; then
        systemctl restart "$service_name" >/dev/null 2>&1
        sleep 5
        sync_tunnel_domain "$tid"
        return
    fi
    
    # 2. 三重防抖判定检测该隧道的临时域名状态
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
    
    # 502 (Bad Gateway), 530 (Cloudflare 1033), 000 (连接超时/断开)
    if [[ "$http_code" == "502" || "$http_code" == "530" || "$http_code" == "000" || "$http_code" == "1033" ]]; then
        sleep 5
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
        if [[ "$http_code" == "502" || "$http_code" == "530" || "$http_code" == "000" || "$http_code" == "1033" ]]; then
            sleep 5
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
            if [[ "$http_code" == "502" || "$http_code" == "530" || "$http_code" == "000" || "$http_code" == "1033" ]]; then
                # 该隧道在 Cloudflare 边缘端已切断，重启该特定隧道重新申请，不影响其他正常运行的隧道
                systemctl restart "$service_name" >/dev/null 2>&1
                sleep 5
                sync_tunnel_domain "$tid"
            fi
        fi
    fi
}

# 日志防膨胀维护
trim_log_if_needed() {
    local tid=$1
    local log_file="/etc/node-manager/logs/argo-${tid}.log"
    if [[ -f "$log_file" ]]; then
        local line_count
        line_count=$(wc -l < "$log_file" 2>/dev/null || echo 0)
        if [[ $line_count -gt 3000 ]]; then
            local tmp_log
            tmp_log=$(mktemp -p "$(dirname "$log_file")")
            tail -n 300 "$log_file" > "$tmp_log" 2>/dev/null && mv "$tmp_log" "$log_file"
        fi
    fi
}

main_loop() {
    local loop_count=0
    while true; do
        NEED_REFRESH_SUB=0
        
        # 1. 尝试同步 3 条隧道各自日志中的新域名 (开机/重启后也能在 10 秒内捕获)
        for tid in 1 2 3; do
            sync_tunnel_domain "$tid"
        done
        
        # 若任何一个隧道的域名发生更新，立即刷新订阅与 Clash 配置
        if [[ $NEED_REFRESH_SUB -eq 1 ]]; then
            show_all_nodes >/dev/null 2>&1
            NEED_REFRESH_SUB=0
        fi
        
        ((loop_count++))
        
        # 2. 每隔 60 秒 (6 * 10s) 执行一次健康检查与自愈
        if [[ $((loop_count % 6)) -eq 0 ]]; then
            for tid in 1 2 3; do
                check_and_heal_tunnel "$tid"
            done
            if [[ $NEED_REFRESH_SUB -eq 1 ]]; then
                show_all_nodes >/dev/null 2>&1
                NEED_REFRESH_SUB=0
            fi
        fi
        
        # 3. 每隔约 15 分钟 (100 * 10s) 检查一次日志体积并维护
        if [[ $loop_count -ge 100 ]]; then
            loop_count=0
            for tid in 1 2 3; do
                trim_log_if_needed "$tid"
            done
        fi
        
        sleep 10
    done
}

main_loop
