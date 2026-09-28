#!/usr/bin/env bash
# cert.sh - 证书生成与管理

generate_self_signed_cert() {
    local cert_dir="/etc/node-manager/certs/self_signed"
    mkdir -p "$cert_dir"
    
    if [[ ! -f "$cert_dir/cert.pem" || ! -f "$cert_dir/key.pem" ]]; then
        print_info "正在生成自签名证书..." >&2
        openssl req -x509 -nodes -days 3650 -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
            -subj "/C=US/ST=California/L=Los Angeles/O=Bing/CN=bing.com" >/dev/null 2>&1
    fi
    echo "$cert_dir"
}

issue_zerossl_ip_cert() {
    print_separator
    print_info "开始为本机申请 Let's Encrypt IP 证书..."
    
    local ip=$(get_ipv4)
    if [[ -z "$ip" ]]; then
        print_err "无法获取本机的公网 IPv4，申请失败。"
        return 1
    fi
    
    print_info "本机公网 IP: $ip"
    
    # 强制释放 80 端口
    if command -v fuser >/dev/null 2>&1; then
        fuser -k 80/tcp >/dev/null 2>&1
    fi
    killall socat >/dev/null 2>&1
    
    # 检查 80 端口是否依然被占用
    if lsof -i :80 >/dev/null 2>&1 || netstat -tuln | grep -q ":80 "; then
        print_err "您的 80 端口正在被占用，且无法自动释放。acme.sh 需要 80 端口。"
        print_warn "请手动停止占用 80 端口的程序 (如 nginx, apache2) 后再重试。"
        return 1
    fi
    
    open_port 80 tcp
    
    # 安装 acme.sh
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        print_info "正在安装 acme.sh..."
        curl -s https://get.acme.sh | sh >/dev/null 2>&1
    fi
    local acme_cmd="~/.acme.sh/acme.sh"
    
    # 设置默认 CA 为 Let's Encrypt 并注册
    local email="node-manager-$(generate_random_string 8)@gmail.com"
    print_info "注册 Let's Encrypt 账户: $email"
    eval "$acme_cmd --set-default-ca --server letsencrypt >/dev/null 2>&1"
    eval "$acme_cmd --register-account -m $email --server letsencrypt >/dev/null 2>&1"
    
    local cert_dir="/etc/node-manager/certs/zerossl_ip"
    mkdir -p "$cert_dir"
    
    print_info "正在通过 HTTP-01 验证申请 Let's Encrypt IP 证书，请耐心等待 (约 1-3 分钟)..."
    if eval "$acme_cmd --issue -d $ip --standalone --server letsencrypt --cert-profile shortlived"; then
        print_info "证书申请成功！正在安装证书到 $cert_dir..."
        eval "$acme_cmd --install-cert -d $ip \
            --key-file $cert_dir/key.pem \
            --fullchain-file $cert_dir/cert.pem \
            --reloadcmd \"systemctl restart node-manager-sub\"" >/dev/null 2>&1
        
        print_ok "Let's Encrypt IP 证书部署成功！(有效期约 6 天，acme.sh 将自动续期)"
        # 删除之前的 domain.txt 确保使用 IP 订阅
        rm -f "$cert_dir/domain.txt"
        
        # 刷新订阅链接
        show_all_nodes >/dev/null 2>&1
        print_info "可以通过主菜单按 6 查看全新的 HTTPS 订阅链接。"
    else
        print_info "使用 Let's Encrypt 申请 IP 证书受阻。自动回退：可以正常使用自签名证书，节点不受影响。"
        return 1
    fi
}
