#!/usr/bin/env bash
# argo_updater.sh - 自动更新 Argo Tunnel 域名

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../utils/subscription.sh"

LOG_FILE="/etc/node-manager/logs/argo.log"

update_argo_domain() {
    # 等待获取最新的 argo_url
    local try=0
    local argo_url=""
    while [[ $try -lt 10 ]]; do
        argo_url=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_FILE" | tail -n 1)
        if [[ -n "$argo_url" ]]; then
            break
        fi
        sleep 5
        ((try++))
    done

    if [[ -n "$argo_url" ]]; then
        local domain=$(echo "$argo_url" | sed 's|https://||')
        
        # 读取当前所有的 node
        local nodes=$(get_all_nodes)
        if [[ -z "$nodes" ]]; then
            exit 0
        fi
        
        # 查找 argo 节点
        local argo_node=$(echo "$nodes" | jq -c 'select(.type == "argo")')
        if [[ -n "$argo_node" ]]; then
            local old_domain=$(echo "$argo_node" | jq -r '.domain')
            if [[ "$old_domain" != "$domain" ]]; then
                # 域名变了，更新 nodes.json
                local temp=$(mktemp)
                jq '(.nodes[] | select(.type == "argo") | .domain) = "'"$domain"'" | (.nodes[] | select(.type == "argo") | .inbound.tls.server_name) = "'"$domain"'"' "/etc/node-manager/database/nodes.json" > "$temp"
                mv "$temp" "/etc/node-manager/database/nodes.json"
                
                # 重新生成 sub.txt
                show_all_nodes >/dev/null 2>&1
            fi
        fi
    fi
}

update_argo_domain
