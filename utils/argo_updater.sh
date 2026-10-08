#!/usr/bin/env bash
# argo_updater.sh - 自动更新 Argo Tunnel 域名

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/../lib/ui.sh"
source "$SCRIPT_DIR/../lib/system.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../utils/firewall.sh"
source "$SCRIPT_DIR/../utils/subscription.sh"

LOG_FILE="/etc/node-manager/logs/argo.log"

update_argo_domain() {
    # 持续监听 argo 日志，一旦有新的域名生成，立即更新
    tail -F "$LOG_FILE" | grep --line-buffered -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | while read -r argo_url; do
        if [[ -n "$argo_url" ]]; then
            local domain=$(echo "$argo_url" | sed 's|https://||')
            
            # 读取当前所有的 node
            local nodes=$(get_all_nodes)
            if [[ -z "$nodes" ]]; then
                continue
            fi
            
            # 查找 argo 节点
            local argo_node=$(echo "$nodes" | jq -c 'select(.type == "argo")')
            if [[ -n "$argo_node" ]]; then
                local old_domain=$(echo "$argo_node" | jq -r '.domain')
                if [[ "$old_domain" != "$domain" ]]; then
                    # 域名变了，更新 nodes.json
                    local temp=$(mktemp -p "/etc/node-manager/database")
                    if jq '(.nodes[] | select(.type == "argo") | .domain) = "'"$domain"'"' "/etc/node-manager/database/nodes.json" > "$temp"; then
                        mv "$temp" "/etc/node-manager/database/nodes.json"
                    else
                        rm -f "$temp"
                    fi
                    
                    # 重新生成 sub.txt 和 clash.yaml，并重启分发服务
                    show_all_nodes >/dev/null 2>&1
                fi
            fi
        fi
    done
}

update_argo_domain
