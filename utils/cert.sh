#!/usr/bin/env bash
# cert.sh - 证书生成与管理

generate_self_signed_cert() {
    local cert_dir="/etc/node-manager/certs/self_signed"
    mkdir -p "$cert_dir"
    
    if [[ ! -f "$cert_dir/cert.pem" || ! -f "$cert_dir/key.pem" ]]; then
        print_info "正在生成自签名证书..."
        openssl req -x509 -nodes -days 3650 -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
            -subj "/C=US/ST=California/L=Los Angeles/O=Bing/CN=bing.com" >/dev/null 2>&1
    fi
    echo "$cert_dir"
}
