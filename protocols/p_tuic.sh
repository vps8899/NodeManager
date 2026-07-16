#!/usr/bin/env bash
# p_tuic.sh - TUIC v5 协议模块

add_tuic() {
    print_separator
    print_info "添加 TUIC v5 节点"
    
    local port
    local uuid=$(generate_uuid)
    local password=$(generate_random_string 12)
    
    prompt_input "请输入监听端口 (UDP)" "8443" "port"
    if ! check_port "$port"; then
        print_err "端口 $port 被占用，请更换。"
        return 1
    fi
    
    local cert_dir=$(generate_self_signed_cert)
    
    # 构建 inbound JSON
    local inbound_json=$(cat <<EOF
{
  "type": "tuic",
  "tag": "tuic-in-$port",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
      "uuid": "$uuid",
      "password": "$password"
    }
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "$cert_dir/cert.pem",
    "key_path": "$cert_dir/key.pem"
  }
}
EOF
)

    # 存入 nodes.json
    local node_id=$(generate_uuid)
    local node_data=$(cat <<EOF
{
  "id": "$node_id",
  "type": "tuic",
  "port": $port,
  "uuid": "$uuid",
  "password": "$password",
  "cert": "$cert_dir/cert.pem",
  "inbound": $inbound_json
}
EOF
)
    
    add_node "$node_data"
    open_port "$port" "udp"
    
    print_ok "TUIC v5 节点添加成功！"
    rebuild_config
    
    print_separator
    print_info "节点信息："
    echo -e "端口: ${YELLOW}$port${PLAIN}"
    echo -e "UUID: ${YELLOW}$uuid${PLAIN}"
    echo -e "密码: ${YELLOW}$password${PLAIN}"
    print_separator
}
