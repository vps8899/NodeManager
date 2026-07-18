#!/usr/bin/env bash
# p_vless_reality.sh - VLESS + Reality 协议模块

add_vless_reality() {
    print_separator
    print_info "添加 VLESS + Reality 节点"
    
    local default_port=$(generate_random_port)
    local dest="icloud.com:443"
    local server_names='["icloud.com", "www.icloud.com"]'
    local uuid=$(generate_uuid)
    local short_id=$(openssl rand -hex 8)
    local key_pair
    
    # 交互输入
    prompt_input "请输入监听端口" "$default_port" "port"
    if ! check_port "$port"; then
        print_err "端口 $port 被占用，请更换。"
        return 1
    fi
    
    prompt_input "请输入目标伪装域名 (dest)" "$dest" "dest"
    
    print_info "正在生成 Reality 密钥对..."
    key_pair=$($SB_BIN generate reality-keypair)
    local private_key=$(echo "$key_pair" | grep PrivateKey | awk '{print $2}')
    local public_key=$(echo "$key_pair" | grep PublicKey | awk '{print $2}')
    
    # 构建 inbound JSON
    local inbound_json=$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-in-$port",
  "listen": "::",
  "listen_port": $port,
  "sniff": true,
  "sniff_override_destination": true,
  "users": [
    {
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$(echo $server_names | jq -r '.[0]')",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "$(echo $server_names | jq -r '.[0]')",
        "server_port": 443
      },
      "private_key": "$private_key",
      "short_id": ["$short_id"]
    }
  }
}
EOF
)

    # 存入 nodes.json
    local node_id=$(generate_uuid)
    local node_data=$(cat <<EOF
{
  "id": "$node_id",
  "type": "vless-reality",
  "port": $port,
  "uuid": "$uuid",
  "dest": "$dest",
  "server_names": $server_names,
  "private_key": "$private_key",
  "public_key": "$public_key",
  "short_id": "$short_id",
  "inbound": $inbound_json
}
EOF
)
    
    add_node "$node_data"
    open_port "$port" "tcp,udp"
    
    print_ok "VLESS + Reality 节点添加成功！"
    rebuild_config
    
    print_separator
    print_info "节点信息："
    echo -e "端口: ${YELLOW}$port${PLAIN}"
    echo -e "UUID: ${YELLOW}$uuid${PLAIN}"
    echo -e "Dest: ${YELLOW}$dest${PLAIN}"
    echo -e "Public Key: ${YELLOW}$public_key${PLAIN}"
    echo -e "Short ID: ${YELLOW}$short_id${PLAIN}"
    print_separator
}
