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
        if ! curl -L -# -o /tmp/sing-box.tar.gz "$proxy_url"; then
            print_info "加速下载失败，尝试直连下载..."
            if ! curl -L -# -o /tmp/sing-box.tar.gz "$dl_url"; then
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
    "level": "error",
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
    for i in 1 2 3; do
        systemctl stop "argo-tunnel-$i" >/dev/null 2>&1
        systemctl disable "argo-tunnel-$i" >/dev/null 2>&1
        rm -f "/etc/systemd/system/argo-tunnel-$i.service"
    done
    systemctl stop argo-tunnel >/dev/null 2>&1
    systemctl disable argo-tunnel >/dev/null 2>&1
    rm -f /etc/systemd/system/argo-tunnel.service
    systemctl stop node-manager-argo-updater >/dev/null 2>&1
    systemctl disable node-manager-argo-updater >/dev/null 2>&1
    rm -f /etc/systemd/system/node-manager-argo-updater.service
    
    systemctl stop node-manager-sub >/dev/null 2>&1
    systemctl disable node-manager-sub >/dev/null 2>&1
    rm -f /etc/systemd/system/node-manager-sub.service

    systemctl stop node-manager-warp-checker.timer >/dev/null 2>&1 || true
    systemctl disable node-manager-warp-checker.timer >/dev/null 2>&1 || true
    systemctl stop node-manager-warp-checker.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/node-manager-warp-checker.timer /etc/systemd/system/node-manager-warp-checker.service
    
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    
    rm -rf /etc/node-manager
    rm -f "$SB_BIN"
    rm -f /usr/local/bin/cloudflared
    rm -rf /usr/local/NodeManager
    rm -f /usr/local/bin/node-manager
    
    print_ok "Sing-box 及面板已完全卸载。"
    exit 0
}

# 生成 Sing-box 完整配置到指定文件 (参数1: 是否挂载本地 .srs 规则集 1/0)
_build_singbox_config_to_file() {
    local out_file=$1
    local use_srs=${2:-1}

    # 1. 收集所有节点 inbound 并统一补全 sniff 嗅探，防止域名分流失效
    local inbounds_json="[]"
    local nodes
    nodes=$(get_all_nodes 2>/dev/null)
    if [[ -n "$nodes" ]]; then
        while read -r node; do
            [[ -z "$node" ]] && continue
            local inbound_json
            inbound_json=$(echo "$node" | jq -c '.inbound // empty' 2>/dev/null)
            if [[ -n "$inbound_json" && "$inbound_json" != "null" ]]; then
                inbounds_json=$(echo "$inbounds_json" | jq -c --argjson ib "$inbound_json" '. + [($ib | .sniff = true | .sniff_override_destination = true)]')
            fi
        done <<< "$nodes"
    fi

    # 2. 判断宿主机是仅 IPv4 还是双栈，决定 direct 策略
    local direct_strategy="ipv4_only"
    if declare -F detect_vps_stack >/dev/null 2>&1; then
        detect_vps_stack
        if [[ "$VPS_HAS_V6" == "true" ]]; then
            direct_strategy="prefer_ipv4"
        fi
    elif [[ -n "$(get_ipv6 2>/dev/null)" ]]; then
        direct_strategy="prefer_ipv4"
    fi

    local warp_conf="/etc/node-manager/warp/warp.json"
    local warp_enabled="false"
    if [[ -f "$warp_conf" ]] && [[ "$(jq -r '.enabled // false' "$warp_conf" 2>/dev/null)" == "true" ]]; then
        if jq -e '.private_key and .v4 and .endpoint_ip and .endpoint_port' "$warp_conf" >/dev/null 2>&1; then
            warp_enabled="true"
        fi
    fi

    if [[ "$warp_enabled" != "true" ]]; then
        jq -n \
            --argjson inbounds "$inbounds_json" \
            --arg d_strat "$direct_strategy" \
            '{
              log: {
                disabled: false,
                level: "error",
                output: "/etc/node-manager/logs/sing-box.log",
                timestamp: true
              },
              inbounds: $inbounds,
              outbounds: [
                { type: "direct", tag: "direct", domain_strategy: $d_strat },
                { type: "block", tag: "block" }
              ],
              route: {
                rules: [
                  { protocol: "dns", outbound: "direct" }
                ]
              }
            }' > "$out_file"
        return $?
    fi

    # 3. WARP 已开启：组装本地测速 socks 入站、WireGuard 出站、Split DNS 与 Google/AI 分流规则
    local socks_port ep_ip ep_port warp_stack priv_key peer_pub w_v4 w_v6 reserved_json
    socks_port=$(jq -r '.socks_port // 18080' "$warp_conf")
    ep_ip=$(jq -r '.endpoint_ip' "$warp_conf" | tr -d '[]')
    ep_port=$(jq -r '.endpoint_port // 2408' "$warp_conf")
    warp_stack=$(jq -r '.stack // "ipv4_only"' "$warp_conf")
    priv_key=$(jq -r '.private_key' "$warp_conf")
    peer_pub=$(jq -r '.peer_public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="' "$warp_conf")
    w_v4=$(jq -r '.v4' "$warp_conf")
    w_v6=$(jq -r '.v6 // empty' "$warp_conf")
    reserved_json=$(jq -c '.reserved // [0,0,0]' "$warp_conf")

    local local_addrs_json
    if [[ -n "$w_v6" ]]; then
        local_addrs_json=$(jq -nc --arg v4 "$w_v4" --arg v6 "$w_v6" '[$v4, $v6]')
    else
        local_addrs_json=$(jq -nc --arg v4 "$w_v4" '[$v4]')
    fi

    inbounds_json=$(echo "$inbounds_json" | jq -c --argjson sport "$socks_port" \
        '. + [{ type: "socks", tag: "warp-test-in", listen: "127.0.0.1", listen_port: $sport }]')

    local builtin_domains="[]"
    if declare -F get_builtin_google_ai_domains_json >/dev/null 2>&1; then
        builtin_domains=$(get_builtin_google_ai_domains_json)
    else
        builtin_domains='["google.com","googleapis.com","gstatic.com","googleusercontent.com","googlevideo.com","youtube.com","ytimg.com","ggpht.com","gvt1.com","gvt2.com","xn--ngstr-lra8j.com","gemini.google.com","aistudio.google.com","ai.google.dev","generativelanguage.googleapis.com","labs.google","notebooklm.google.com"]'
    fi

    # 检查本地 .srs 文件是否存在且有效
    local rule_sets_json="[]"
    local rule_set_tags_json="[]"
    if [[ "$use_srs" -eq 1 ]]; then
        local rules_dir="/etc/node-manager/sing-box/rules"
        local srs_items=("geosite-google|geosite-google.srs" "geosite-google-gemini|geosite-google-gemini.srs")
        for item in "${srs_items[@]}"; do
            local rtag="${item%|*}"
            local rfile="${rules_dir}/${item#*|}"
            local valid=0
            if declare -F is_valid_srs_file >/dev/null 2>&1; then
                is_valid_srs_file "$rfile" && valid=1
            elif [[ -s "$rfile" ]]; then
                valid=1
            fi
            if [[ $valid -eq 1 ]]; then
                rule_sets_json=$(echo "$rule_sets_json" | jq -c --arg t "$rtag" --arg p "$rfile" \
                    '. + [{ type: "local", tag: $t, format: "binary", path: $p }]')
                rule_set_tags_json=$(echo "$rule_set_tags_json" | jq -c --arg t "$rtag" '. + [$t]')
            fi
        done
    fi

    local has_srs=0
    if [[ "$(echo "$rule_set_tags_json" | jq 'length')" -gt 0 ]]; then
        has_srs=1
    fi

    local dns_rules_json route_rules_json
    if [[ $has_srs -eq 1 ]]; then
        dns_rules_json=$(jq -nc \
            --argjson rtags "$rule_set_tags_json" \
            --argjson bdoms "$builtin_domains" \
            '[
              { outbound: "any", server: "dns_direct" },
              { inbound: ["warp-test-in"], server: "dns_warp" },
              { rule_set: $rtags, server: "dns_warp" },
              { domain_suffix: $bdoms, server: "dns_warp" }
            ]')
        route_rules_json=$(jq -nc \
            --argjson rtags "$rule_set_tags_json" \
            --argjson bdoms "$builtin_domains" \
            '[
              { protocol: "dns", outbound: "direct" },
              { inbound: ["warp-test-in"], outbound: "warp" },
              { rule_set: $rtags, outbound: "warp" },
              { domain_suffix: $bdoms, outbound: "warp" }
            ]')
    else
        dns_rules_json=$(jq -nc \
            --argjson bdoms "$builtin_domains" \
            '[
              { outbound: "any", server: "dns_direct" },
              { inbound: ["warp-test-in"], server: "dns_warp" },
              { domain_suffix: $bdoms, server: "dns_warp" }
            ]')
        route_rules_json=$(jq -nc \
            --argjson bdoms "$builtin_domains" \
            '[
              { protocol: "dns", outbound: "direct" },
              { inbound: ["warp-test-in"], outbound: "warp" },
              { domain_suffix: $bdoms, outbound: "warp" }
            ]')
    fi

    jq -n \
        --argjson inbounds "$inbounds_json" \
        --arg d_strat "$direct_strategy" \
        --arg w_strat "$warp_stack" \
        --arg ep_ip "$ep_ip" \
        --argjson ep_port "$ep_port" \
        --argjson laddrs "$local_addrs_json" \
        --arg priv "$priv_key" \
        --arg peer "$peer_pub" \
        --argjson reserved "$reserved_json" \
        --argjson dns_rules "$dns_rules_json" \
        --argjson route_sets "$rule_sets_json" \
        --argjson route_rules "$route_rules_json" \
        '{
          log: {
            disabled: false,
            level: "error",
            output: "/etc/node-manager/logs/sing-box.log",
            timestamp: true
          },
          dns: {
            servers: [
              { tag: "dns_direct", address: "local", strategy: $d_strat, detour: "direct" },
              { tag: "dns_warp", address: "1.1.1.1", strategy: $w_strat, detour: "warp" }
            ],
            rules: $dns_rules,
            final: "dns_direct"
          },
          inbounds: $inbounds,
          outbounds: [
            { type: "direct", tag: "direct", domain_strategy: $d_strat },
            {
              type: "wireguard",
              tag: "warp",
              server: $ep_ip,
              server_port: $ep_port,
              local_address: $laddrs,
              private_key: $priv,
              peer_public_key: $peer,
              reserved: $reserved,
              mtu: 1280,
              domain_strategy: $w_strat
            },
            { type: "block", tag: "block" }
          ],
          route: (
            { rules: $route_rules } +
            (if ($route_sets | length) > 0 then { rule_set: $route_sets } else {} end)
          )
        }' > "$out_file"
}

# 动态重构 config.json (先检查合法性再原子替换)
rebuild_config() {
    print_info "正在重构 Sing-box 配置文件..."
    
    mkdir -p "$SB_DIR"
    mkdir -p "/etc/node-manager/logs"

    local temp
    temp=$(mktemp -p "$SB_DIR")

    if ! _build_singbox_config_to_file "$temp" 1; then
        rm -f "$temp"
        print_err "生成 Sing-box 配置失败！"
        return 1
    fi

    if [[ -x "$SB_BIN" ]] && ! "$SB_BIN" check -c "$temp" >/dev/null 2>&1; then
        print_warn "检测到规则集或配置校验异常，正在降级为内置域名兜底规则重试..."
        rm -f /etc/node-manager/sing-box/rules/*.srs 2>/dev/null || true
        if ! _build_singbox_config_to_file "$temp" 0 || ! "$SB_BIN" check -c "$temp" >/dev/null 2>&1; then
            rm -f "$temp"
            print_err "Sing-box 配置校验未通过，已保留原配置以避免服务中断！"
            return 1
        fi
    fi

    mv "$temp" "$SB_CONF"
    reload_singbox
}
