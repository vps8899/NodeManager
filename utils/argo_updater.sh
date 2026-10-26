#!/usr/bin/env bash
# argo_updater.sh - 自动更新与保活 Argo Tunnel 临时隧道

_UPDATER_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$_UPDATER_DIR/../lib/ui.sh"
source "$_UPDATER_DIR/../lib/system.sh"
source "$_UPDATER_DIR/../lib/common.sh"
source "$_UPDATER_DIR/../lib/config.sh"
source "$_UPDATER_DIR/../utils/firewall.sh"
source "$_UPDATER_DIR/../utils/cert.sh"
source "$_UPDATER_DIR/../utils/subscription.sh"
unset _UPDATER_DIR

LOG_FILE="/etc/node-manager/logs/argo.log"

# 从日志中提取最新的合法 trycloudflare 域名
get_latest_domain_from_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local raw_domain
        raw_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_FILE" 2>/dev/null | tail -n 1 | sed 's|https://||')
        if [[ "$raw_domain" =~ ^[a-zA-Z0-9-]+\.trycloudflare\.com$ ]]; then
            echo "$raw_domain"
        fi
    fi
}

# 检查当前 Argo 节点的健康状况并在失效时重启自愈
check_and_heal_argo() {
    local argo_node
    argo_node=$(get_all_nodes 2>/dev/null | jq -c 'select(.type == "argo")' 2>/dev/null)
    if [[ -z "$argo_node" ]]; then
        return
    fi
    
    local current_domain
    current_domain=$(echo "$argo_node" | jq -r '.domain' 2>/dev/null)
    if [[ -z "$current_domain" || "$current_domain" == "null" ]]; then
        return
    fi
    
    # 1. 检查 cloudflared 服务进程是否在运行
    if ! systemctl is-active argo-tunnel >/dev/null 2>&1; then
        systemctl restart argo-tunnel >/dev/null 2>&1
        sleep 5
        sync_argo_domain
        return
    fi
    
    # 2. 检查 trycloudflare 临时隧道是否存活 (连续三次失败判定防抖动)
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
    
    # 502 (Bad Gateway), 530 (Cloudflare 1033), 000 (连接超时/断开)
    if [[ "$http_code" == "502" || "$http_code" == "530" || "$http_code" == "000" || "$http_code" == "1033" ]]; then
        # 第一次异常，等待 5 秒进行第二次复测
        sleep 5
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
        if [[ "$http_code" == "502" || "$http_code" == "530" || "$http_code" == "000" || "$http_code" == "1033" ]]; then
            # 第二次异常，再等待 5 秒进行第三次确认，彻底排除网络瞬间颠簸
            sleep 5
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 6 "https://${current_domain}" 2>/dev/null)
            if [[ "$http_code" == "502" || "$http_code" == "530" || "$http_code" == "000" || "$http_code" == "1033" ]]; then
                # 连续三次探测均异常，确认隧道已在 Cloudflare 端被切断，重启服务重新申请
                systemctl restart argo-tunnel >/dev/null 2>&1
                sleep 5
                sync_argo_domain
            fi
        fi
    fi
}

# 同步最新的域名到 nodes.json 并刷新订阅文件
sync_argo_domain() {
    local latest_domain
    latest_domain=$(get_latest_domain_from_log)
    if [[ -z "$latest_domain" ]]; then
        return
    fi
    
    local nodes
    nodes=$(get_all_nodes 2>/dev/null)
    if [[ -z "$nodes" ]]; then
        return
    fi
    
    local argo_node
    argo_node=$(echo "$nodes" | jq -c 'select(.type == "argo")' 2>/dev/null)
    if [[ -n "$argo_node" ]]; then
        local old_domain
        old_domain=$(echo "$argo_node" | jq -r '.domain' 2>/dev/null)
        if [[ "$old_domain" != "$latest_domain" ]]; then
            # 域名发生变化，原子写入 nodes.json
            local temp
            temp=$(mktemp -p "/etc/node-manager/database")
            if jq '(.nodes[] | select(.type == "argo") | .domain) = "'"$latest_domain"'"' "/etc/node-manager/database/nodes.json" > "$temp" 2>/dev/null; then
                mv "$temp" "/etc/node-manager/database/nodes.json"
                # 重新生成 sub.txt 和 clash.yaml，并刷新订阅分发服务
                show_all_nodes >/dev/null 2>&1
            else
                rm -f "$temp"
            fi
        fi
    fi
}

# 日志防膨胀维护 (保证长期运行不爆磁盘)
trim_log_if_needed() {
    if [[ -f "$LOG_FILE" ]]; then
        local line_count
        line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $line_count -gt 3000 ]]; then
            local tmp_log
            tmp_log=$(mktemp -p "$(dirname "$LOG_FILE")")
            tail -n 300 "$LOG_FILE" > "$tmp_log" 2>/dev/null && mv "$tmp_log" "$LOG_FILE"
        fi
    fi
}

main_loop() {
    local loop_count=0
    while true; do
        # 1. 尝试同步日志中的新域名 (开机/重启后也能在 10 秒内捕获)
        sync_argo_domain
        
        ((loop_count++))
        
        # 2. 每隔 60 秒 (6 * 10s) 执行一次健康检查与自愈
        if [[ $((loop_count % 6)) -eq 0 ]]; then
            check_and_heal_argo
        fi
        
        # 3. 每隔约 15 分钟 (100 * 10s) 检查一次日志体积并维护
        if [[ $loop_count -ge 100 ]]; then
            loop_count=0
            trim_log_if_needed
        fi
        
        sleep 10
    done
}

main_loop
