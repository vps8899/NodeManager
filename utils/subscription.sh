#!/usr/bin/env bash
# subscription.sh - 订阅与节点分享链接生成

_SUB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$_SUB_DIR/../lib/common.sh"
source "$_SUB_DIR/../utils/cert.sh"
unset _SUB_DIR

ARGO_ISP_ENTRIES=(
    "电信优化:ct.386638.xyz"
    "移动优化:cm.386638.xyz"
    "联通优化:cu.386638.xyz"
)

# 构造单个 VMess-Argo URI
build_vmess_uri() {
    local ps=$1
    local add=$2
    local uuid=$3
    local domain=$4
    local path=$5
    local json_str="{\"v\":\"2\",\"ps\":\"${ps}\",\"add\":\"${add}\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${domain}\",\"path\":\"${path}\",\"tls\":\"tls\",\"sni\":\"${domain}\",\"alpn\":\"http/1.1\",\"fp\":\"chrome\"}"
    local b64
    b64=$(echo -n "$json_str" | base64 -w 0 2>/dev/null || echo -n "$json_str" | base64 | tr -d '\r\n')
    echo "vmess://${b64}"
}

get_node_uri() {
    local node_json=$1
    local type=$(echo "$node_json" | jq -r '.type')
    
    local ip=$(get_ipv4)
    if [[ -z "$ip" ]]; then
        ip=$(get_ipv6)
    fi
    
    local uri=""
    
    if [[ "$type" == "vless-reality" ]]; then
        local uuid=$(echo "$node_json" | jq -r '.uuid')
        local port=$(echo "$node_json" | jq -r '.port')
        local server_name=$(echo "$node_json" | jq -r '.server_names[0]')
        local public_key=$(echo "$node_json" | jq -r '.public_key')
        local short_id=$(echo "$node_json" | jq -r '.short_id')
        
        uri="vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${public_key}&fp=ios&type=tcp&flow=xtls-rprx-vision&sni=${server_name}&sid=${short_id}#VLESS-Reality"
    
    elif [[ "$type" == "hysteria2" ]]; then
        local password=$(echo "$node_json" | jq -r '.password')
        local port=$(echo "$node_json" | jq -r '.port')
        local cert_pin=$(get_self_signed_cert_sha256)
        local pin_arg=""
        if [[ -n "$cert_pin" ]]; then
            pin_arg="&pinSHA256=${cert_pin}&pinnedPeerCertSha256=${cert_pin}"
        fi
        
        uri="hysteria2://${password}@${ip}:${port}/?insecure=1${pin_arg}&sni=bing.com#Hysteria2"
    
    elif [[ "$type" == "tuic" ]]; then
        local uuid=$(echo "$node_json" | jq -r '.uuid')
        local password=$(echo "$node_json" | jq -r '.password')
        local port=$(echo "$node_json" | jq -r '.port')
        local cert_pin=$(get_self_signed_cert_sha256)
        local pin_arg=""
        if [[ -n "$cert_pin" ]]; then
            pin_arg="&pinSHA256=${cert_pin}&pinnedPeerCertSha256=${cert_pin}"
        fi
        
        uri="tuic://${uuid}:${password}@${ip}:${port}/?sni=bing.com&alpn=h3&allow_insecure=1${pin_arg}#TUIC"
        
    elif [[ "$type" == "argo" ]]; then
        local uuid=$(echo "$node_json" | jq -r '.uuid')
        local domain=$(echo "$node_json" | jq -r '.domain')
        local path=$(echo "$node_json" | jq -r '.path')
        local sub_type=$(echo "$node_json" | jq -r '.sub_type // "vless"')
        
        local lines=""
        for entry in "${ARGO_ISP_ENTRIES[@]}"; do
            local label="${entry%%:*}"
            local cdn_host="${entry#*:}"
            local line_uri=""
            if [[ "$sub_type" == "vmess" ]]; then
                line_uri=$(build_vmess_uri "VMESS-Argo-${label}" "$cdn_host" "$uuid" "$domain" "$path")
            else
                line_uri="vless://${uuid}@${cdn_host}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&alpn=http%2F1.1&type=ws&host=${domain}&path=${path}#VLESS-Argo-${label}"
            fi
            if [[ -z "$lines" ]]; then
                lines="$line_uri"
            else
                lines="${lines}"$'\n'"${line_uri}"
            fi
        done
        uri="$lines"
    fi
    
    echo "$uri"
}

setup_subscription_server() {
    local sub_info_file="/etc/node-manager/database/sub_info.json"
    local port
    local token
    
    if [[ -f "$sub_info_file" ]]; then
        port=$(jq -r '.port' "$sub_info_file")
        token=$(jq -r '.token' "$sub_info_file")
    else
        port=$(generate_random_port)
        token=$(generate_random_string 32)
        mkdir -p "$(dirname "$sub_info_file")"
        cat > "$sub_info_file" <<EOF
{
  "port": $port,
  "token": "$token"
}
EOF
        open_port "$port" "tcp"
    fi
    
    local sub_file="/etc/node-manager/output/sub.txt"
    local script_file="/usr/local/NodeManager/utils/sub_server.py"
    
    local cert_dir="/etc/node-manager/certs/zerossl_ip"
    local cert_arg=""
    if [[ -f "$cert_dir/cert.pem" && -f "$cert_dir/key.pem" ]]; then
        cert_arg="$cert_dir/cert.pem $cert_dir/key.pem"
    fi
    
    local service_file="/etc/systemd/system/node-manager-sub.service"
    local desired_unit
    desired_unit=$(cat <<EOF
[Unit]
Description=Node Manager Subscription Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $script_file $port $token $sub_file $cert_arg
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
)
    local need_restart=0
    if [[ ! -f "$service_file" ]] || [[ "$(cat "$service_file" 2>/dev/null)" != "$desired_unit" ]]; then
        printf '%s\n' "$desired_unit" > "$service_file"
        systemctl daemon-reload
        systemctl enable node-manager-sub >/dev/null 2>&1
        need_restart=1
    elif ! systemctl is-active node-manager-sub >/dev/null 2>&1; then
        need_restart=1
    fi
    
    if [[ $need_restart -eq 1 ]]; then
        systemctl restart node-manager-sub >/dev/null 2>&1
    fi
}

show_all_nodes() {
    local nodes=$(get_all_nodes)
    if [[ -z "$nodes" ]]; then
        print_warn "当前没有任何节点，请先添加。"
        return
    fi
    
    print_separator
    print_info "所有节点分享链接："
    echo ""
    
    local sub_content=""
    
    while read -r node; do
        local uri=$(get_node_uri "$node")
        if [[ -n "$uri" ]]; then
            echo -e "${GREEN}${uri}${PLAIN}"
            sub_content="${sub_content}${uri}\n"
        fi
    done <<< "$nodes"
    
    # 原子写入 Clash YAML，防止读取到半成品文件
    local clash_file="/etc/node-manager/output/clash.yaml"
    mkdir -p "$(dirname "$clash_file")"
    local clash_tmp
    clash_tmp=$(mktemp -p "$(dirname "$clash_file")")
    cat > "$clash_tmp" <<EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  default-nameserver:
    - 223.5.5.5
    - 114.114.114.114
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query

proxies:
EOF
    local proxy_names=""
    local ip=$(get_ipv4)
    if [[ -z "$ip" ]]; then
        ip=$(get_ipv6)
    fi
    while read -r node; do
        local type=$(echo "$node" | jq -r '.type')
        if [[ "$type" == "vless-reality" ]]; then
            local uuid=$(echo "$node" | jq -r '.uuid')
            local port=$(echo "$node" | jq -r '.port')
            local server_name=$(echo "$node" | jq -r '.server_names[0]')
            local public_key=$(echo "$node" | jq -r '.public_key')
            local short_id=$(echo "$node" | jq -r '.short_id')
            cat >> "$clash_tmp" <<EOF
  - name: "VLESS-Reality-$port"
    type: vless
    server: $ip
    port: $port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $server_name
    client-fingerprint: ios
    reality-opts:
      public-key: $public_key
      short-id: $short_id
EOF
            proxy_names="${proxy_names}\n      - \"VLESS-Reality-$port\""
        elif [[ "$type" == "hysteria2" ]]; then
            local password=$(echo "$node" | jq -r '.password')
            local port=$(echo "$node" | jq -r '.port')
            local cert_pin=$(get_self_signed_cert_sha256)
            cat >> "$clash_tmp" <<EOF
  - name: "Hysteria2-$port"
    type: hysteria2
    server: $ip
    port: $port
    password: $password
    sni: bing.com
    skip-cert-verify: true
EOF
            if [[ -n "$cert_pin" ]]; then
                echo "    ca-fingerprint: $cert_pin" >> "$clash_tmp"
            fi
            proxy_names="${proxy_names}\n      - \"Hysteria2-$port\""
        elif [[ "$type" == "tuic" ]]; then
            local uuid=$(echo "$node" | jq -r '.uuid')
            local password=$(echo "$node" | jq -r '.password')
            local port=$(echo "$node" | jq -r '.port')
            local cert_pin=$(get_self_signed_cert_sha256)
            cat >> "$clash_tmp" <<EOF
  - name: "TUIC-$port"
    type: tuic
    server: $ip
    port: $port
    uuid: $uuid
    password: $password
    sni: bing.com
    alpn: [h3]
    skip-cert-verify: true
EOF
            if [[ -n "$cert_pin" ]]; then
                echo "    ca-fingerprint: $cert_pin" >> "$clash_tmp"
            fi
            proxy_names="${proxy_names}\n      - \"TUIC-$port\""
        elif [[ "$type" == "argo" ]]; then
            local uuid=$(echo "$node" | jq -r '.uuid')
            local domain=$(echo "$node" | jq -r '.domain')
            local path=$(echo "$node" | jq -r '.path')
            local sub_type=$(echo "$node" | jq -r '.sub_type // "vless"')
            
            for entry in "${ARGO_ISP_ENTRIES[@]}"; do
                local label="${entry%%:*}"
                local cdn_host="${entry#*:}"
                if [[ "$sub_type" == "vmess" ]]; then
                    local pname="VMESS-Argo-${label}"
                    cat >> "$clash_tmp" <<EOF
  - name: "$pname"
    type: vmess
    server: $cdn_host
    port: 443
    uuid: $uuid
    alterId: 0
    cipher: auto
    network: ws
    tls: true
    udp: true
    servername: $domain
    alpn:
      - http/1.1
    client-fingerprint: chrome
    ws-opts:
      path: "$path"
      headers:
        Host: $domain
EOF
                    proxy_names="${proxy_names}\n      - \"$pname\""
                else
                    local pname="VLESS-Argo-${label}"
                    cat >> "$clash_tmp" <<EOF
  - name: "$pname"
    type: vless
    server: $cdn_host
    port: 443
    uuid: $uuid
    network: ws
    tls: true
    udp: true
    servername: $domain
    alpn:
      - http/1.1
    client-fingerprint: chrome
    ws-opts:
      path: "$path"
      headers:
        Host: $domain
EOF
                    proxy_names="${proxy_names}\n      - \"$pname\""
                fi
            done
        fi
    done <<< "$nodes"
    
    cat >> "$clash_tmp" <<EOF

proxy-groups:
  - name: PROXY
    type: select
    proxies:$(echo -e "$proxy_names")

rules:
  - GEOSITE,CN,DIRECT
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
    mv "$clash_tmp" "$clash_file"
    
    print_separator
    
    # 原子写入 Base64 订阅
    local base64_sub
    base64_sub=$(echo -ne "$sub_content" | base64 -w 0 2>/dev/null || echo -ne "$sub_content" | base64 | tr -d '\r\n')
    local sub_file="/etc/node-manager/output/sub.txt"
    mkdir -p "$(dirname "$sub_file")"
    local sub_tmp
    sub_tmp=$(mktemp -p "$(dirname "$sub_file")")
    echo "$base64_sub" > "$sub_tmp"
    mv "$sub_tmp" "$sub_file"
    
    print_info "订阅内容已保存至: $sub_file"
    echo -e "Base64 格式订阅 (可直接导入客户端):\n${YELLOW}${base64_sub}${PLAIN}"
    print_separator
    
    # 确保订阅分发服务在线 (配置未变化时不重复重启)
    setup_subscription_server
    local sub_info_file="/etc/node-manager/database/sub_info.json"
    if [[ -f "$sub_info_file" ]]; then
        local port=$(jq -r '.port' "$sub_info_file")
        local token=$(jq -r '.token' "$sub_info_file")
        local ip=$(get_ipv4)
        if [[ -z "$ip" ]]; then
            ip=$(get_ipv6)
        fi
        local protocol="http"
        local host="$ip"
        local cert_dir="/etc/node-manager/certs/zerossl_ip"
        if [[ -f "$cert_dir/cert.pem" && -f "$cert_dir/key.pem" ]]; then
            protocol="https"
            if [[ -f "$cert_dir/domain.txt" ]]; then
                host=$(cat "$cert_dir/domain.txt")
            fi
        fi
        local sub_url="${protocol}://${host}:${port}/${token}"
        print_info "【全新功能】专属私密自动订阅链接："
        echo -e "${GREEN}${sub_url}${PLAIN}"
        echo -e "请将上方链接导入到 Clash / V2rayN / Shadowrocket 中，即可实现节点自动更新！"
        
        if command -v qrencode >/dev/null 2>&1; then
            echo ""
            print_info "手机客户端 (小火箭/NekoBox) 可直接扫描下方二维码导入订阅："
            qrencode -t ANSIUTF8 "$sub_url"
        fi
        
        print_separator
    fi
}
