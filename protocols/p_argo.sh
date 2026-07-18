#!/usr/bin/env bash
# p_argo.sh - VLESS WS TLS Argo 协议模块

install_cloudflared() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        print_info "正在安装 cloudflared..."
        local arch_suffix="amd64"
        if [[ "$ARCH" == "arm64" ]]; then
            arch_suffix="arm64"
        fi
        local dl_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch_suffix}"
        wget -qO /usr/local/bin/cloudflared "$dl_url"
        chmod +x /usr/local/bin/cloudflared
    fi
}

start_argo_tunnel() {
    local port=$1
    local log_file="/etc/node-manager/logs/argo.log"
    mkdir -p "$(dirname "$log_file")"
    
    cat > /etc/systemd/system/argo-tunnel.service <<EOF
[Unit]
Description=Cloudflare Argo Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStartPre=-/bin/rm -f $log_file
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$port --loglevel info --logfile $log_file
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable argo-tunnel >/dev/null 2>&1
    systemctl restart argo-tunnel
    
    # 注册自动更新域名的服务
    local updater_script="/usr/local/NodeManager/utils/argo_updater.sh"
    if [[ -f "$updater_script" ]]; then
        cat > /etc/systemd/system/node-manager-argo-updater.service <<EOF
[Unit]
Description=Node Manager Argo Domain Updater
After=argo-tunnel.service

[Service]
Type=oneshot
ExecStart=/bin/bash $updater_script
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable node-manager-argo-updater >/dev/null 2>&1
        systemctl restart node-manager-argo-updater >/dev/null 2>&1
    fi
    
    print_info "等待获取 Argo Tunnel 域名..." >&2
    sleep 5
    local try=0
    local argo_url=""
    while [[ $try -lt 5 ]]; do
        argo_url=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$log_file" | tail -n 1)
        if [[ -n "$argo_url" ]]; then
            break
        fi
        sleep 3
        ((try++))
    done
    
    if [[ -z "$argo_url" ]]; then
        print_err "无法获取 Argo Tunnel 域名，请检查 cloudflared 日志: $log_file" >&2
        return 1
    fi
    
    echo "$argo_url"
}

add_argo() {
    print_separator
    print_info "添加 VLESS WS TLS Argo (免域名) 节点"
    
    install_cloudflared
    
    local port=8080
    while ! check_port "$port"; do
        ((port++))
    done
    
    # 删除旧的 Argo 节点
    local existing_nodes=$(get_all_nodes)
    if [[ -n "$existing_nodes" ]]; then
        while read -r node; do
            local ntype=$(echo "$node" | jq -r '.type')
            if [[ "$ntype" == "argo" ]]; then
                local nuuid=$(echo "$node" | jq -r '.id')
                delete_node "$nuuid"
            fi
        done <<< "$existing_nodes"
    fi
    
    local uuid=$(generate_uuid)
    local path="/$(generate_random_string 8)"
    
    print_info "分配本地监听端口: $port"
    print_info "正在启动 Argo Tunnel..."
    local argo_url=$(start_argo_tunnel "$port")
    
    if [[ -z "$argo_url" ]]; then
        return 1
    fi
    
    local domain=$(echo "$argo_url" | sed 's|https://||')
    
    # 构建 inbound JSON
    local inbound_json=$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-argo-$port",
  "listen": "127.0.0.1",
  "listen_port": $port,
  "users": [
    {
      "uuid": "$uuid"
    }
  ],
  "transport": {
    "type": "ws",
    "path": "$path"
  }
}
EOF
)

    # 存入 nodes.json
    local node_id=$(generate_uuid)
    local node_data=$(cat <<EOF
{
  "id": "$node_id",
  "type": "argo",
  "port": $port,
  "uuid": "$uuid",
  "domain": "$domain",
  "path": "$path",
  "inbound": $inbound_json
}
EOF
)
    
    add_node "$node_data"
    
    print_ok "VLESS Argo 节点添加成功！"
    rebuild_config
    
    print_separator
    print_info "节点信息："
    echo -e "Argo 域名: ${GREEN}$domain${PLAIN}"
    echo -e "UUID: ${YELLOW}$uuid${PLAIN}"
    echo -e "路径 (Path): ${YELLOW}$path${PLAIN}"
    print_separator
}
