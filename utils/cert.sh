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
    print_info "开始为本机申请 ZeroSSL 证书..."
    
    local ip=$(get_ipv4)
    if [[ -z "$ip" ]]; then
        print_err "无法获取本机的公网 IPv4，申请失败。"
        return 1
    fi
    
    # 将 IP 转换为 dash 格式，例如 1.2.3.4 -> 1-2-3-4
    local dash_ip="${ip//./-}"
    # 使用 nip.io 动态解析域名以绕过 ZeroSSL 的 IP 限制
    local domain="${dash_ip}.nip.io"
    
    print_info "本机公网 IP: $ip"
    print_info "动态映射域名: $domain"
    
    # 检查 80 端口是否被占用
    if lsof -i :80 >/dev/null 2>&1 || netstat -tuln | grep -q ":80 "; then
        print_err "您的 80 端口正在被占用，acme.sh standalone 模式需要占用 80 端口。"
        print_warn "请先停止占用 80 端口的程序 (如 nginx, apache2 等) 后再重试。"
        return 1
    fi
    
    open_port 80 tcp
    
    # 安装 acme.sh
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        print_info "正在安装 acme.sh..."
        curl -s https://get.acme.sh | sh >/dev/null 2>&1
    fi
    local acme_cmd="~/.acme.sh/acme.sh"
    
    # 设置默认 CA 为 ZeroSSL 并注册
    local email="node-manager-$(generate_random_string 8)@gmail.com"
    print_info "注册 ZeroSSL 账户: $email"
    eval "$acme_cmd --set-default-ca --server zerossl >/dev/null 2>&1"
    eval "$acme_cmd --register-account -m $email --server zerossl >/dev/null 2>&1"
    
    local cert_dir="/etc/node-manager/certs/zerossl_ip"
    mkdir -p "$cert_dir"
    
    print_info "正在通过 HTTP-01 验证申请证书，请耐心等待 (约 1-3 分钟)..."
    if eval "$acme_cmd --issue -d $domain --standalone --server zerossl"; then
        print_info "证书申请成功！正在安装证书到 $cert_dir..."
        eval "$acme_cmd --install-cert -d $domain \
            --key-file $cert_dir/key.pem \
            --fullchain-file $cert_dir/cert.pem \
            --reloadcmd \"systemctl restart node-manager-sub\"" >/dev/null 2>&1
        
        print_ok "ZeroSSL 证书部署成功！"
        # 保存域名到本地，供 subscription.sh 读取
        echo "$domain" > "$cert_dir/domain.txt"
        
        # 刷新订阅链接
        show_all_nodes >/dev/null 2>&1
        print_info "可以通过主菜单按 6 查看全新的 HTTPS 订阅链接。"
    else
        print_err "证书申请失败！请检查您的 IP 是否被屏蔽或 80 端口被封禁。"
        return 1
    fi
}
