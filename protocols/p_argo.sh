#!/usr/bin/env bash
# p_argo.sh - VLESS + VMess 双引擎独立 Argo Tunnel 模块 (2026 最新企业级抗封锁与自愈架构)

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

# 启动单条独立的 Argo 临时隧道服务 (强制 HTTP/2 协议，彻底解决 UDP/QUIC 阻断与超时问题)
start_single_argo_tunnel() {
    local tid=$1
    local local_port=$2
    local log_file="/etc/node-manager/logs/argo-${tid}.log"
    mkdir -p "$(dirname "$log_file")"
    
    cat > "/etc/systemd/system/argo-tunnel-${tid}.service" <<EOF
[Unit]
Description=Cloudflare Argo Tunnel ${tid}
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStartPre=-/bin/rm -f $log_file
ExecStart=/usr/local/bin/cloudflared tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --no-tls-verify --url http://127.0.0.1:$local_port --loglevel info --logfile $log_file
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "argo-tunnel-${tid}" >/dev/null 2>&1
    systemctl restart "argo-tunnel-${tid}"
}

# 注册并启动全局自动更新与健康自愈守护程序
start_argo_updater_service() {
    local updater_script="/usr/local/NodeManager/utils/argo_updater.sh"
    if [[ -f "$updater_script" ]]; then
        cat > /etc/systemd/system/node-manager-argo-updater.service <<EOF
[Unit]
Description=Node Manager Argo Domain Updater
After=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $updater_script
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable node-manager-argo-updater >/dev/null 2>&1
        systemctl restart node-manager-argo-updater >/dev/null 2>&1
    fi
}

add_argo() {
    print_separator
    print_info "正在搭建 2026 最新双引擎 Argo 隧道组合 (VLESS轻量 + VMess-AEAD加密，双隧道独立防封)..."
    
    install_cloudflared
    
    # 清理旧的单/多隧道服务
    systemctl stop argo-tunnel >/dev/null 2>&1 || true
    systemctl disable argo-tunnel >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/argo-tunnel.service
    
    for i in 1 2 3; do
        systemctl stop "argo-tunnel-$i" >/dev/null 2>&1 || true
        systemctl disable "argo-tunnel-$i" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/argo-tunnel-$i.service"
    done
    
    # 删除旧的 Argo 节点数据
    local existing_nodes
    existing_nodes=$(get_all_nodes 2>/dev/null)
    if [[ -n "$existing_nodes" ]]; then
        while read -r node; do
            local ntype
            ntype=$(echo "$node" | jq -r '.type' 2>/dev/null)
            if [[ "$ntype" == "argo" ]]; then
                local nuuid
                nuuid=$(echo "$node" | jq -r '.id' 2>/dev/null)
                delete_node "$nuuid"
            fi
        done <<< "$existing_nodes"
    fi
    
    # 分配 2 个独立本地端口 (8080: VLESS, 8081: VMess)
    local local_ports=()
    local base_port=8080
    for i in 0 1; do
        while ! check_port "$base_port"; do
            ((base_port++))
        done
        local_ports+=("$base_port")
        ((base_port++))
    done
    
    local port_vless=${local_ports[0]}
    local port_vmess=${local_ports[1]}
    
    print_info "正在启动 2 条独立的 Cloudflare 隧道 (VLESS 与 VMess 各自独立)..."
    start_single_argo_tunnel 1 "$port_vless"
    start_single_argo_tunnel 2 "$port_vmess"
    
    # 启动后台守护更新器
    start_argo_updater_service
    
    print_info "等待获取各隧道独立分配的 TryCloudflare 域名 (约 5-8 秒)..."
    local domains=()
    local try=0
    while [[ $try -lt 6 ]]; do
        sleep 3
        domains=()
        local all_found=1
        for i in 0 1; do
            local tid=$((i + 1))
            local log_file="/etc/node-manager/logs/argo-${tid}.log"
            local d=""
            if [[ -f "$log_file" ]]; then
                d=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$log_file" 2>/dev/null | tail -n 1 | sed 's|https://||')
            fi
            if [[ -n "$d" ]]; then
                domains+=("$d")
            else
                domains+=("")
                all_found=0
            fi
        done
        if [[ $all_found -eq 1 ]]; then
            break
        fi
        ((try++))
    done
    
    local domain_vless=${domains[0]}
    local domain_vmess=${domains[1]}
    [[ -z "$domain_vless" ]] && domain_vless="waiting-tunnel-1.trycloudflare.com"
    [[ -z "$domain_vmess" ]] && domain_vmess="waiting-tunnel-2.trycloudflare.com"
    
    # 1. 注入 VLESS + WS 入站配置
    local uuid_vless
    uuid_vless=$(generate_uuid)
    local path_vless="/$(generate_random_string 8)"
    local inbound_vless
    inbound_vless=$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-argo-$port_vless",
  "listen": "127.0.0.1",
  "listen_port": $port_vless,
  "users": [
    {
      "uuid": "$uuid_vless"
    }
  ],
  "transport": {
    "type": "ws",
    "path": "$path_vless",
    "max_early_data": 2560,
    "early_data_header_name": "Sec-WebSocket-Protocol"
  }
}
EOF
)
    local node_vless_data
    node_vless_data=$(cat <<EOF
{
  "id": "$(generate_uuid)",
  "type": "argo",
  "sub_type": "vless",
  "tunnel_id": 1,
  "port": $port_vless,
  "uuid": "$uuid_vless",
  "domain": "$domain_vless",
  "path": "$path_vless",
  "inbound": $inbound_vless
}
EOF
)
    add_node "$node_vless_data"
    
    # 2. 注入 VMess AEAD + WS 入站配置 (内层完整加密，彻底防止 Cloudflare WAF/CDN 检测)
    local uuid_vmess
    uuid_vmess=$(generate_uuid)
    local path_vmess="/$(generate_random_string 8)"
    local inbound_vmess
    inbound_vmess=$(cat <<EOF
{
  "type": "vmess",
  "tag": "vmess-argo-$port_vmess",
  "listen": "127.0.0.1",
  "listen_port": $port_vmess,
  "users": [
    {
      "uuid": "$uuid_vmess",
      "alterId": 0
    }
  ],
  "transport": {
    "type": "ws",
    "path": "$path_vmess",
    "max_early_data": 2560,
    "early_data_header_name": "Sec-WebSocket-Protocol"
  }
}
EOF
)
    local node_vmess_data
    node_vmess_data=$(cat <<EOF
{
  "id": "$(generate_uuid)",
  "type": "argo",
  "sub_type": "vmess",
  "tunnel_id": 2,
  "port": $port_vmess,
  "uuid": "$uuid_vmess",
  "domain": "$domain_vmess",
  "path": "$path_vmess",
  "inbound": $inbound_vmess
}
EOF
)
    add_node "$node_vmess_data"
    
    print_ok "VLESS 与 VMess-AEAD 双协议 Argo 节点搭建完成！"
    rebuild_config
    
    print_separator
    print_info "Argo 双引擎独立节点配置概要："
    echo -e "隧道 1 [VLESS + WS] | 临时域名: ${CYAN}${domain_vless}${PLAIN}"
    echo -e "隧道 2 [VMess-AEAD + WS] | 临时域名: ${CYAN}${domain_vmess}${PLAIN}"
    print_separator
}
