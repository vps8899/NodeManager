#!/usr/bin/env bash
# core_singbox.sh - Sing-box 核心进程与基础配置管理

SB_VERSION="1.9.3"
SB_DIR="/etc/node-manager/sing-box"
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="$SB_DIR/config.json"

install_singbox() {
    print_info "正在安装 Sing-box 核心..."
    mkdir -p "$SB_DIR"
    mkdir -p "/etc/node-manager/logs"
    
    if [[ ! -f "$SB_BIN" ]] || ! "$SB_BIN" version >/dev/null 2>&1; then
        local arch_suffix="amd64"
        if [[ "$ARCH" == "arm64" ]]; then
            arch_suffix="arm64"
        fi
        
        local dl_url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-${arch_suffix}.tar.gz"
        local proxy_url="https://ghproxy.net/$dl_url"
        
        print_info "正在下载 Sing-box (使用加速节点)..."
        if ! curl -sL -o /tmp/sing-box.tar.gz "$proxy_url"; then
            print_info "加速下载失败，尝试直连下载..."
            if ! curl -sL -o /tmp/sing-box.tar.gz "$dl_url"; then
                print_err "下载失败，请检查网络！"
                exit 1
            fi
        fi
        
        tar -xzf /tmp/sing-box.tar.gz -C /tmp/
        mv "/tmp/sing-box-${SB_VERSION}-linux-${arch_suffix}/sing-box" "$SB_BIN"
        chmod +x "$SB_BIN"
        rm -rf /tmp/sing-box*
        
        if ! "$SB_BIN" version >/dev/null 2>&1; then
            print_err "Sing-box 内核安装失败：二进制文件损坏或架构不匹配！"
            rm -f "$SB_BIN"
            exit 1
        fi
    fi
    
    # 写入基础配置模板
    if [[ ! -f "$SB_CONF" ]]; then
        cat > "$SB_CONF" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "/etc/node-manager/logs/sing-box.log",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "direct"
      }
    ]
  }
}
EOF
    fi

    # systemd 服务
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_BIN run -c $SB_CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    print_ok "Sing-box 安装完成。"
}

reload_singbox() {
    print_info "重新加载 Sing-box 配置..."
    if systemctl is-active sing-box >/dev/null 2>&1; then
        systemctl restart sing-box
    else
        systemctl start sing-box
    fi
    sleep 1
    if systemctl is-active sing-box >/dev/null 2>&1; then
        print_ok "Sing-box 运行中。"
    else
        print_err "Sing-box 启动失败，请查看日志。"
    fi
}

uninstall_singbox() {
    print_info "正在卸载 Sing-box 及所有节点数据..."
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    
    rm -rf /etc/node-manager
    rm -f "$SB_BIN"
    rm -rf /usr/local/NodeManager
    rm -f /usr/local/bin/node-manager
    
    print_ok "Sing-box 及面板已完全卸载。"
    exit 0
}

# 动态重构 config.json
rebuild_config() {
    print_info "正在重构 Sing-box 配置文件..."
    
    mkdir -p "$SB_DIR"
    mkdir -p "/etc/node-manager/logs"
    if [[ ! -f "$SB_CONF" ]] || ! jq -e . "$SB_CONF" >/dev/null 2>&1; then
        cat > "$SB_CONF" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "/etc/node-manager/logs/sing-box.log",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "direct"
      }
    ]
  }
}
EOF
    fi
    
    # 清空当前的 inbounds
    local temp=$(mktemp)
    jq '.inbounds = []' "$SB_CONF" > "$temp"
    mv "$temp" "$SB_CONF"
    
    # 从 database 遍历节点并注入 inbound
    local nodes=$(get_all_nodes)
    if [[ -n "$nodes" ]]; then
        while read -r node; do
            local protocol=$(echo "$node" | jq -r '.protocol')
            local inbound_json=$(echo "$node" | jq -c '.inbound')
            
            if [[ "$inbound_json" != "null" ]]; then
                jq ".inbounds += [$inbound_json]" "$SB_CONF" > "$temp"
                mv "$temp" "$SB_CONF"
            fi
        done <<< "$nodes"
    fi
    reload_singbox
}
