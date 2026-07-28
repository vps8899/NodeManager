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
    print_info "��ʼΪ�����Ĺ��� IP ���� ZeroSSL ֤��..."
    
    local ip=$(get_ipv4)
    if [[ -z "$ip" ]]; then
        print_err "�޷���ȡ�����Ĺ��� IPv4������ʧ�ܡ�"
        return 1
    fi
    
    print_info "�������� IP: $ip"
    
    # ��� 80 �˿��Ƿ�ռ��
    if lsof -i :80 >/dev/null 2>&1 || netstat -tuln | grep -q ":80 "; then
        print_err "���� 80 �˿����ڱ�ռ�ã�acme.sh standalone ģʽ��Ҫռ�� 80 �˿ڡ�"
        print_warn "����ֹͣռ�� 80 �˿ڵĳ��� (�� nginx, apache2 ��) �������ԡ�"
        return 1
    fi
    
    open_port 80 tcp
    
    # ��װ acme.sh
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        print_info "���ڰ�װ acme.sh..."
        curl -s https://get.acme.sh | sh >/dev/null 2>&1
    fi
    local acme_cmd="~/.acme.sh/acme.sh"
    
    # ����Ĭ�� CA Ϊ ZeroSSL ��ע��
    local email="node-manager-$(generate_random_string 8)@gmail.com"
    print_info "ע�� ZeroSSL �˻�: $email"
    eval "$acme_cmd --set-default-ca --server zerossl >/dev/null 2>&1"
    eval "$acme_cmd --register-account -m $email --server zerossl >/dev/null 2>&1"
    
    local cert_dir="/etc/node-manager/certs/zerossl_ip"
    mkdir -p "$cert_dir"
    
    print_info "����ͨ�� HTTP-01 ��֤���� IP ֤�飬�����ĵȴ� (Լ 1-3 ����)..."
    if eval "$acme_cmd --issue -d $ip --standalone --server zerossl"; then
        print_info "֤������ɹ������ڰ�װ֤�鵽 $cert_dir..."
        eval "$acme_cmd --install-cert -d $ip \
            --key-file $cert_dir/key.pem \
            --fullchain-file $cert_dir/cert.pem \
            --reloadcmd \"systemctl restart node-manager-sub\"" >/dev/null 2>&1
        
        print_ok "ZeroSSL IP ֤�鲿��ɹ���"
        # ˢ�¶�������
        show_all_nodes >/dev/null 2>&1
        print_info "����ͨ�����˵��� 6 �鿴ȫ�µ� HTTPS �������ӡ�"
    else
        print_err "֤������ʧ�ܣ��������� IP �Ƿ����λ� 80 �˿ڱ������"
        return 1
    fi
}
