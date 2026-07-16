#!/usr/bin/env bash
# p_hysteria2.sh - Hysteria2 协议模块


add_hysteria2() {
    print_separator
    print_info "添加 Hysteria2 节点"
    
    local port
    local password=$(generate_random_string 12)
    
    prompt_input "请输入监听端口 (UDP)" "443" "port"
    if ! check_port "$port"; then
        print_err "端口 $port 被占用，请更换。"
        return 1
    fi
    
    local cert_dir=$(generate_self_signed_cert)
    
    # 构建 inbound JSON
    local inbound_json=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "hy2-in-$port",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {
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
  "type": "hysteria2",
  "port": $port,
  "password": "$password",
  "cert": "$cert_dir/cert.pem",
  "inbound": $inbound_json
}
EOF
)
    
    add_node "$node_data"
    open_port "$port" "udp"
    
    print_ok "Hysteria2 节点添加成功！"
    rebuild_config
    
    print_separator
    print_info "节点信息："
    echo -e "端口: ${YELLOW}$port${PLAIN}"
    echo -e "密码: ${YELLOW}$password${PLAIN}"
    print_separator
}
