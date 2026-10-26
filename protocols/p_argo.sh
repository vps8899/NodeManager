#!/usr/bin/env bash
# p_argo.sh - VLESS WS TLS Argo 协议模块 (支持多端口与独立多隧道冗余)

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

# 启动单条独立的 Argo 临时隧道服务
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
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$local_port --loglevel info --logfile $log_file
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
    print_info "正在创建多端口独立 Argo 隧道组合 (443 / 8443 / 2053，多隧道独立防失效)..."
    
    install_cloudflared
    
    # 清理旧的单/多隧道服务
    systemctl stop argo-tunnel >/dev/null 2>&1 || true
    systemctl disable argo-tunnel >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/argo-tunnel.service
    
    for i in 1 2 3; do
        systemctl stop "argo-tunnel-$i" >/dev/null 2>&1 || true
        systemctl disable "argo-tunnel-$i" >/dev/null 2>&1 || true
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
    
    # 规划 3 个独立隧道：本地端口与外部 CDN 优选端口
    local cdn_ports=(443 8443 2053)
    local local_ports=()
    local base_port=8080
    
    for i in 0 1 2; do
        while ! check_port "$base_port"; do
            ((base_port++))
        done
        local_ports+=("$base_port")
        ((base_port++))
    done
    
    print_info "启动 3 条独立 Cloudflare Argo 隧道进程..."
    for i in 0 1 2; do
        local tid=$((i + 1))
        local lport=${local_ports[$i]}
        start_single_argo_tunnel "$tid" "$lport"
    done
    
    # 启动后台守护更新器
    start_argo_updater_service
    
    print_info "等待获取各隧道独立分配的 TryCloudflare 域名 (约 5-8 秒)..."
    local domains=()
    local try=0
    while [[ $try -lt 6 ]]; do
        sleep 3
        domains=()
        local all_found=1
        for i in 0 1 2; do
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
    
    local added_count=0
    for i in 0 1 2; do
        local tid=$((i + 1))
        local cdn_port=${cdn_ports[$i]}
        local lport=${local_ports[$i]}
        local domain=${domains[$i]}
        
        # 如果当前未能成功抓取到域名，预设一个占位，后台 updater 会在几秒内自动抓取填补
        if [[ -z "$domain" ]]; then
            domain="waiting-tunnel-${tid}.trycloudflare.com"
        fi
        
        local uuid
        uuid=$(generate_uuid)
        local path="/$(generate_random_string 8)"
        local inbound_json
        inbound_json=$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-argo-$lport",
  "listen": "127.0.0.1",
  "listen_port": $lport,
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
        local node_id
        node_id=$(generate_uuid)
        local node_data
        node_data=$(cat <<EOF
{
  "id": "$node_id",
  "type": "argo",
  "tunnel_id": $tid,
  "port": $lport,
  "cdn_port": $cdn_port,
  "uuid": "$uuid",
  "domain": "$domain",
  "path": "$path",
  "inbound": $inbound_json
}
EOF
)
        add_node "$node_data"
        ((added_count++))
    done
    
    print_ok "已成功创建 $added_count 个多端口独立 Argo 节点！"
    rebuild_config
    
    print_separator
    print_info "Argo 多端口独立节点配置概要 (优选域名: saas.sin.fan)："
    for i in 0 1 2; do
        local tid=$((i + 1))
        local cdn_port=${cdn_ports[$i]}
        local lport=${local_ports[$i]}
        local domain=${domains[$i]}
        echo -e "隧道 ${tid} [CDN端口 ${GREEN}${cdn_port}${PLAIN} -> 本地 ${lport}] | 临时域名: ${CYAN}${domain:-获取中}${PLAIN}"
    done
    print_separator
}
