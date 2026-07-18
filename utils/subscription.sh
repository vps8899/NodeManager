#!/usr/bin/env bash
# subscription.sh - 订阅与节点分享链接生成

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
        local dest=$(echo "$node_json" | jq -r '.dest')
        local server_name=$(echo "$node_json" | jq -r '.server_names[0]')
        local public_key=$(echo "$node_json" | jq -r '.public_key')
        local short_id=$(echo "$node_json" | jq -r '.short_id')
        
        uri="vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${public_key}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${server_name}&sid=${short_id}#VLESS-Reality"
    
    elif [[ "$type" == "hysteria2" ]]; then
        local password=$(echo "$node_json" | jq -r '.password')
        local port=$(echo "$node_json" | jq -r '.port')
        
        uri="hysteria2://${password}@${ip}:${port}/?insecure=1&sni=bing.com#Hysteria2"
    
    elif [[ "$type" == "tuic" ]]; then
        local uuid=$(echo "$node_json" | jq -r '.uuid')
        local password=$(echo "$node_json" | jq -r '.password')
        local port=$(echo "$node_json" | jq -r '.port')
        
        uri="tuic://${uuid}:${password}@${ip}:${port}/?sni=bing.com&alpn=h3&allow_insecure=1#TUIC"
        
    elif [[ "$type" == "argo" ]]; then
        local uuid=$(echo "$node_json" | jq -r '.uuid')
        local domain=$(echo "$node_json" | jq -r '.domain')
        local path=$(echo "$node_json" | jq -r '.path')
        local preferred_domain="yg1.ygkkk.dpdns.org"
        
        uri="vless://${uuid}@${preferred_domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${path}#VLESS-Argo"
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
    
    cat > /etc/systemd/system/node-manager-sub.service <<EOF
[Unit]
Description=Node Manager Subscription Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $script_file $port $token $sub_file
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable node-manager-sub >/dev/null 2>&1
    systemctl start node-manager-sub >/dev/null 2>&1
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
    
    print_separator
    
    # 生成 Base64 订阅
    local base64_sub=$(echo -ne "$sub_content" | base64 -w 0)
    local sub_file="/etc/node-manager/output/sub.txt"
    mkdir -p "$(dirname "$sub_file")"
    echo "$base64_sub" > "$sub_file"
    
    print_info "订阅内容已保存至: $sub_file"
    echo -e "Base64 格式订阅 (可直接导入客户端):\n${YELLOW}${base64_sub}${PLAIN}"
    print_separator
    
    # 启动/刷新订阅分发服务
    setup_subscription_server
    local sub_info_file="/etc/node-manager/database/sub_info.json"
    if [[ -f "$sub_info_file" ]]; then
        local port=$(jq -r '.port' "$sub_info_file")
        local token=$(jq -r '.token' "$sub_info_file")
        local ip=$(get_ipv4)
        if [[ -z "$ip" ]]; then
            ip=$(get_ipv6)
        fi
        local sub_url="http://${ip}:${port}/${token}"
        print_info "【全新功能】专属私密自动订阅链接："
        echo -e "${GREEN}${sub_url}${PLAIN}"
        echo -e "请将上方链接导入到 Clash / V2rayN / Shadowrocket 中，即可实现节点自动更新！"
        print_separator
    fi
}
