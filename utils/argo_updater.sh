#!/usr/bin/env bash
# argo_updater.sh - 自动更新与保活多协议独立 Argo Tunnel 临时隧道

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
MAX_LOG_BYTES=20971520 # 20 MB

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

# 检测特定状态码是否属于隧道失效
is_tunnel_error_code() {
    local code=$1
    [[ "$code" == "502" || "$code" == "530" || "$code" == "000" || "$code" == "1033" ]]
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
    
    local current_domain
    current_domain=$(echo "$target_node" | jq -r '.domain' 2>/dev/null)
    
    # 2. 修复启动时处于 waiting-tunnel 占位状态但长期未拿到域名的问题
    if [[ -z "$current_domain" || "$current_domain" == "null" || "$current_domain" =~ ^waiting-tunnel ]]; then
        local fresh_domain
        fresh_domain=$(get_latest_domain_for_tunnel "$tid")
        if [[ -n "$fresh_domain" ]]; then
            sync_tunnel_domain "$tid"
        else
            systemctl restart "$service_name" >/dev/null 2>&1
            sleep 6
            sync_tunnel_domain "$tid"
        fi
        return
    fi
    
    # 确保底层 sing-box 运行正常，防止 sing-box 挂掉误判为 Argo 失效
    if ! systemctl is-active sing-box >/dev/null 2>&1; then
        systemctl restart sing-box >/dev/null 2>&1
        sleep 2
    fi
    
    # 适配纯 IPv4 / 纯 IPv6 VPS，避免坏掉的 IPv6 导致 curl 误判超时 000
    local curl_ip_flag="-4"
    if [[ -z "$(get_ipv4)" ]]; then
        curl_ip_flag="-6"
    fi
    
    # 3. 三重防抖判定检测该隧道的临时域名状态
    local http_code
    http_code=$(curl -s $curl_ip_flag -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
    if is_tunnel_error_code "$http_code"; then
        sleep 5
        http_code=$(curl -s $curl_ip_flag -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
        if is_tunnel_error_code "$http_code"; then
            sleep 5
            http_code=$(curl -s $curl_ip_flag -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
            if is_tunnel_error_code "$http_code"; then
                # 若三次均为 000，先确认本机外网是否畅通，避免短时断网造成无谓换域名
                if [[ "$http_code" == "000" ]] && ! curl -sI $curl_ip_flag -m 5 "https://www.cloudflare.com" >/dev/null 2>&1; then
                    return
                fi
                # 确认该隧道在 Cloudflare 边缘端已切断，重启该特定隧道重新申请
                systemctl restart "$service_name" >/dev/null 2>&1
                sleep 6
                sync_tunnel_domain "$tid"
            fi
        fi
    fi
}

# 日志防膨胀维护 (仅在异常暴涨超 20MB 时通过安全重启重建日志，避免破坏文件句柄或丢失域名)
trim_log_if_needed() {
    local tid=$1
    local log_file="/etc/node-manager/logs/argo-${tid}.log"
    if [[ -f "$log_file" ]]; then
        local file_bytes
        file_bytes=$(stat -c%s "$log_file" 2>/dev/null || wc -c < "$log_file" 2>/dev/null || echo 0)
        if [[ $file_bytes -gt $MAX_LOG_BYTES ]]; then
            local service_name="argo-tunnel-${tid}"
            if systemctl list-unit-files 2>/dev/null | grep -q "argo-tunnel-${tid}.service"; then
                systemctl restart "$service_name" >/dev/null 2>&1
                sleep 6
                sync_tunnel_domain "$tid"
            fi
        fi
    fi
}

main_loop() {
    local loop_count=0
    while true; do
        NEED_REFRESH_SUB=0
        
        # 1. 尝试同步各自日志中的新域名 (开机/重启后也能在 10 秒内捕获)
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
            if [[ $NEED_REFRESH_SUB -eq 1 ]]; then
                show_all_nodes >/dev/null 2>&1
                NEED_REFRESH_SUB=0
            fi
        fi
        
        sleep 10
    done
}

main_loop
