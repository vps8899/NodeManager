#!/usr/bin/env bash
# warp.sh - Cloudflare WARP (Sing-box WireGuard 出站) Google/AI 智能分流与防送中自愈模块

if [[ -z "${WARP_SH_LOADED:-}" ]]; then
WARP_SH_LOADED=1

WARP_DIR="/etc/node-manager/warp"
WARP_CONF="$WARP_DIR/warp.json"
WARP_RULES_DIR="/etc/node-manager/sing-box/rules"
WARP_LOG="/etc/node-manager/logs/warp-checker.log"
WARP_LOCK="/run/node-manager-warp.lock"
WARP_PEER_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# 独立运行时自动加载公共库 (例如 systemd 定时巡检)
if ! declare -F print_info >/dev/null 2>&1; then
    _WARP_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    source "$_WARP_DIR/../lib/ui.sh"
    source "$_WARP_DIR/../lib/system.sh"
    source "$_WARP_DIR/../lib/common.sh"
    source "$_WARP_DIR/../lib/config.sh"
    source "$_WARP_DIR/../protocols/core_singbox.sh"
    unset _WARP_DIR
fi

# 内置 Google / AI 生态兜底域名后缀 (防止远程 .srs 规则滞后或拉取失败导致漏分流)
get_builtin_google_ai_domains_json() {
    cat <<'EOF'
[
  "google.com",
  "google.com.hk",
  "google.com.tw",
  "google.co.jp",
  "google.co.uk",
  "googleapis.com",
  "gstatic.com",
  "googleusercontent.com",
  "googlevideo.com",
  "youtube.com",
  "ytimg.com",
  "ggpht.com",
  "gvt1.com",
  "gvt2.com",
  "gvt3.com",
  "xn--ngstr-lra8j.com",
  "android.com",
  "g.co",
  "goo.gl",
  "withgoogle.com",
  "gmail.com",
  "googlemail.com",
  "appspot.com",
  "firebaseio.com",
  "gemini.google.com",
  "aistudio.google.com",
  "ai.google.dev",
  "makersuite.google.com",
  "generativelanguage.googleapis.com",
  "alkalimakersuite-pa.clients6.google.com",
  "proactivebackend-pa.googleapis.com",
  "labs.google",
  "notebooklm.google.com",
  "jules.google.com",
  "deepmind.com",
  "deepmind.google"
]
EOF
}

# 实测宿主机公网 IPv4 / IPv6 连通性 (兼容仅 IPv4 与双栈 VPS)
detect_vps_stack() {
    VPS_HAS_V4="false"
    VPS_HAS_V6="false"

    if curl -s4 -m 4 "https://1.1.1.1/cdn-cgi/trace" >/dev/null 2>&1 || [[ -n "$(get_ipv4 2>/dev/null)" ]]; then
        VPS_HAS_V4="true"
    fi

    # 必须实测公网 IPv6 可达，避免部分 VPS 仅配置了内网/坏路由 v6 导致误判
    if ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        if curl -s6 -m 4 "https://[2606:4700:4700::1111]/cdn-cgi/trace" >/dev/null 2>&1; then
            VPS_HAS_V6="true"
        fi
    fi

    export VPS_HAS_V4 VPS_HAS_V6
}

# 为本地测试 socks5 入站分配固定且未占用的回环端口
alloc_warp_socks_port() {
    local existing_port=""
    if [[ -f "$WARP_CONF" ]]; then
        existing_port=$(jq -r '.socks_port // empty' "$WARP_CONF" 2>/dev/null)
    fi
    if [[ -n "$existing_port" && "$existing_port" =~ ^[0-9]+$ ]]; then
        echo "$existing_port"
        return 0
    fi

    local p=18080
    while ! check_port "$p"; do
        ((p++))
    done
    echo "$p"
}

# 检查时间偏差，WireGuard 对系统时间敏感
check_time_sync_hint() {
    if command -v timedatectl >/dev/null 2>&1; then
        local synced
        synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
        if [[ "$synced" == "no" ]]; then
            timedatectl set-ntp true >/dev/null 2>&1 || true
        fi
    fi
}

# 校验单个 .srs 文件是否为合法非空二进制文件且与当前 sing-box 版本兼容
is_valid_srs_file() {
    local file=$1
    if [[ ! -s "$file" ]]; then
        return 1
    fi
    local size
    size=$(stat -c%s "$file" 2>/dev/null || wc -c < "$file" 2>/dev/null || echo 0)
    if [[ "$size" -lt 100 ]]; then
        return 1
    fi
    local head_chars
    head_chars=$(head -c 16 "$file" 2>/dev/null | tr -d '\0')
    if [[ "$head_chars" == *"<html"* || "$head_chars" == *"<!DOC"* || "$head_chars" == *"404:"* ]]; then
        return 1
    fi
    if [[ -x "${SB_BIN:-/usr/local/bin/sing-box}" ]]; then
        local chk_out
        chk_out=$("${SB_BIN:-/usr/local/bin/sing-box}" rule-set match -f binary "$file" "gemini.google.com" 2>&1 || true)
        if [[ "$chk_out" == *"FATAL"* || "$chk_out" == *"unsupported version"* ]]; then
            return 1
        fi
    fi
    return 0
}

# 下载本地 .srs 规则集 (多源镜像兜底，失败时不覆盖现有有效文件)
download_warp_rulesets() {
    mkdir -p "$WARP_RULES_DIR"
    local curl_flag="-4"
    detect_vps_stack
    if [[ "$VPS_HAS_V4" != "true" && "$VPS_HAS_V6" == "true" ]]; then
        curl_flag="-6"
    fi

    local names=("geosite-google.srs" "geosite-google-gemini.srs")
    local urls_google=(
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"
        "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-google.srs"
        "https://ghproxy.net/https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"
    )
    local urls_gemini=(
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google-gemini.srs"
        "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-google-gemini.srs"
        "https://ghproxy.net/https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google-gemini.srs"
    )

    local ok_count=0
    for idx in 0 1; do
        local name="${names[$idx]}"
        local dest="$WARP_RULES_DIR/$name"
        local tmp_file
        tmp_file=$(mktemp -p "$WARP_RULES_DIR")
        local downloaded=0
        local url_list=()

        if [[ $idx -eq 0 ]]; then
            url_list=("${urls_google[@]}")
        else
            url_list=("${urls_gemini[@]}")
        fi

        for u in "${url_list[@]}"; do
            if curl -fsSL $curl_flag -m 15 -o "$tmp_file" "$u" 2>/dev/null && is_valid_srs_file "$tmp_file"; then
                mv "$tmp_file" "$dest"
                downloaded=1
                break
            fi
        done
        rm -f "$tmp_file"

        if [[ $downloaded -eq 1 ]] || is_valid_srs_file "$dest"; then
            ((ok_count++))
        fi
    done

    if [[ $ok_count -gt 0 ]]; then
        return 0
    fi
    return 1
}

# 调用 Cloudflare 官方 API 免费注册一个 WARP 设备凭证 (返回 JSON 到 stdout)
register_warp_account() {
    if [[ ! -x "$SB_BIN" ]]; then
        print_err "未找到 Sing-box 核心 ($SB_BIN)，请先安装。"
        return 1
    fi

    local keypair priv_key pub_key
    keypair=$("$SB_BIN" generate wg-keypair 2>/dev/null)
    priv_key=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}')
    pub_key=$(echo "$keypair" | awk '/PublicKey:/ {print $2}')
    if [[ -z "$priv_key" || -z "$pub_key" ]]; then
        print_err "生成 WireGuard 密钥对失败！"
        return 1
    fi

    local install_id fcm_token tos payload resp
    install_id=$(generate_random_string 22)
    fcm_token="${install_id}:APA91b$(generate_random_string 134)"
    tos=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    payload=$(jq -nc \
        --arg key "$pub_key" \
        --arg iid "$install_id" \
        --arg fcm "$fcm_token" \
        --arg tos "$tos" \
        '{key: $key, install_id: $iid, fcm_token: $fcm, tos: $tos, model: "PC", type: "Android", serial_number: $iid, locale: "en_US"}')

    local curl_flag="-4"
    detect_vps_stack
    if [[ "$VPS_HAS_V4" != "true" && "$VPS_HAS_V6" == "true" ]]; then
        curl_flag="-6"
    fi

    resp=$(curl -s $curl_flag -m 15 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" \
        -H "CF-Client-Version: a-6.10-2158" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    if ! echo "$resp" | jq -e '.config.interface.addresses.v4' >/dev/null 2>&1; then
        return 1
    fi

    local v4 v6 peer_pub client_id reserved_json
    v4=$(echo "$resp" | jq -r '.config.interface.addresses.v4')
    v6=$(echo "$resp" | jq -r '.config.interface.addresses.v6 // empty')
    peer_pub=$(echo "$resp" | jq -r '.config.peers[0].public_key // empty')
    client_id=$(echo "$resp" | jq -r '.config.client_id // empty')

    [[ -z "$peer_pub" ]] && peer_pub="$WARP_PEER_PUBKEY"

    if [[ -n "$client_id" ]]; then
        reserved_json=$(python3 -c '
import base64, json, sys
s = sys.argv[1].strip()
s += "=" * ((4 - len(s) % 4) % 4)
raw = base64.b64decode(s)
print(json.dumps(list(raw[:3])))
' "$client_id" 2>/dev/null)
    fi
    if [[ -z "$reserved_json" ]] || ! echo "$reserved_json" | jq -e 'length == 3' >/dev/null 2>&1; then
        reserved_json="[0,0,0]"
    fi

    jq -nc \
        --arg priv "$priv_key" \
        --arg pub "$pub_key" \
        --arg peer "$peer_pub" \
        --arg v4 "${v4}/32" \
        --arg v6 "${v6:+${v6}/128}" \
        --argjson reserved "$reserved_json" \
        '{
            private_key: $priv,
            public_key: $pub,
            peer_public_key: $peer,
            v4: $v4,
            v6: $v6,
            reserved: $reserved
        }'
}

# 生成候选 WARP Endpoint 列表 (格式: ip|port)
get_warp_endpoint_candidates() {
    detect_vps_stack
    local candidates=()
    if [[ "$VPS_HAS_V4" == "true" ]]; then
        candidates+=(
            "162.159.192.1|2408"
            "162.159.193.10|2408"
            "162.159.195.1|2408"
            "188.114.96.1|2408"
            "188.114.97.1|500"
            "188.114.98.1|4500"
            "188.114.99.1|854"
            "162.159.192.6|1701"
            "162.159.193.5|894"
            "188.114.96.5|908"
        )
    fi
    if [[ "$VPS_HAS_V6" == "true" ]]; then
        candidates+=(
            "2606:4700:d0::a29f:c001|2408"
            "2606:4700:d1::a29f:c101|2408"
            "2606:4700:d0::a29f:c005|500"
        )
    fi
    printf '%s\n' "${candidates[@]}"
}

# 更新 warp.json 字段
update_warp_conf_fields() {
    local jq_expr=$1
    if [[ ! -f "$WARP_CONF" ]]; then
        return 1
    fi
    local tmp
    tmp=$(mktemp -p "$WARP_DIR")
    if jq "$jq_expr" "$WARP_CONF" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$WARP_CONF"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# 检测当前 Sing-box WARP 出站是否连通、是否被送中、Gemini 是否可用
# 返回值: 0=正常且未送中; 1=连通但送中或Gemini受限; 2=隧道超时/未连通
check_warp_health() {
    local quiet=${1:-0}
    if [[ ! -f "$WARP_CONF" ]] || [[ "$(jq -r '.enabled // false' "$WARP_CONF" 2>/dev/null)" != "true" ]]; then
        [[ $quiet -eq 0 ]] && print_warn "WARP 尚未开启。"
        return 2
    fi

    local socks_port
    socks_port=$(jq -r '.socks_port // 18080' "$WARP_CONF" 2>/dev/null)
    if ! systemctl is-active sing-box >/dev/null 2>&1; then
        [[ $quiet -eq 0 ]] && print_err "Sing-box 服务未运行。"
        return 2
    fi

    local proxy="127.0.0.1:${socks_port}"
    local trace_resp exit_ip cf_loc warp_flag
    trace_resp=$(curl -sL --socks5-hostname "$proxy" -m 8 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
    exit_ip=$(echo "$trace_resp" | awk -F= '/^ip=/{print $2}' | tr -d '\r')
    cf_loc=$(echo "$trace_resp" | awk -F= '/^loc=/{print $2}' | tr -d '\r')
    warp_flag=$(echo "$trace_resp" | awk -F= '/^warp=/{print $2}' | tr -d '\r')

    if [[ -z "$exit_ip" || ( "$warp_flag" != "on" && "$warp_flag" != "plus" ) ]]; then
        update_warp_conf_fields ".last_status = \"TUNNEL_DOWN\" | .last_check = \"$(date '+%Y-%m-%d %H:%M:%S')\""
        [[ $quiet -eq 0 ]] && print_err "WARP 隧道连接失败 (warp=$warp_flag)。"
        return 2
    fi

    # 1. 检测 Google 实际判定的国家/地区 (比第三方 IP 库更准确，直接查 Google 返回的 countryCode)
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    local yt_html google_region
    yt_html=$(curl -sL --socks5-hostname "$proxy" -m 10 -A "$ua" -H "Accept-Language: en-US,en;q=0.9" "https://www.youtube.com/" 2>/dev/null)
    google_region=$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]{2}"' | head -n 1 | cut -d'"' -f4)
    [[ -z "$google_region" ]] && google_region="$cf_loc"

    # 检查 google.com 是否出现 sorry 验证码或重定向到 google.cn
    local g_hdr
    g_hdr=$(curl -sI --socks5-hostname "$proxy" -m 8 -A "$ua" "https://www.google.com/" 2>/dev/null)
    if echo "$g_hdr" | grep -qiE "google\.cn|sorry/index"; then
        google_region="CN"
    fi

    # 2. 直接测试 Gemini 地区可用性
    local hdr_file body_file meta_out gemini_code eff_url gemini_ok=1
    hdr_file=$(mktemp)
    body_file=$(mktemp)
    meta_out=$(curl -sL --socks5-hostname "$proxy" -m 12 -A "$ua" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -D "$hdr_file" -o "$body_file" -w "%{http_code}|%{url_effective}" \
        "https://gemini.google.com/app" 2>/dev/null)
    gemini_code="${meta_out%%|*}"
    eff_url="${meta_out#*|}"

    if [[ "$gemini_code" == "000" || "$gemini_code" == "403" || "$gemini_code" == "429" ]]; then
        gemini_ok=0
    fi
    if [[ "$eff_url" == *"gemini.google.com/faq"* || "$eff_url" == *"unsupported_country"* ]]; then
        gemini_ok=0
    fi
    if grep -qiE "unsupported_country|sorry/index" "$hdr_file" 2>/dev/null; then
        gemini_ok=0
    fi
    if grep -qiE "isn't currently supported in your country|not available in your country|Gemini isn't available" "$body_file" 2>/dev/null; then
        gemini_ok=0
    fi
    rm -f "$hdr_file" "$body_file"

    # 判定是否送中或落入受限地区 (CN / HK / MO / RU / BY / IR / KP / SY / CU 或 Gemini 拒绝)
    local is_blocked=0
    case "$google_region" in
        CN|HK|MO|RU|BY|IR|KP|SY|CU) is_blocked=1 ;;
    esac
    if [[ $gemini_ok -eq 0 ]]; then
        is_blocked=1
    fi

    local now_ts
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ $is_blocked -eq 0 ]]; then
        update_warp_conf_fields ".last_status = \"OK\" | .last_region = \"$google_region\" | .last_exit_ip = \"$exit_ip\" | .last_check = \"$now_ts\""
        [[ $quiet -eq 0 ]] && print_ok "WARP 状态正常！出口 IP: ${exit_ip} | Google 识别地区: ${google_region} | Gemini: 可用"
        return 0
    else
        update_warp_conf_fields ".last_status = \"BLOCKED\" | .last_region = \"$google_region\" | .last_exit_ip = \"$exit_ip\" | .last_check = \"$now_ts\""
        [[ $quiet -eq 0 ]] && print_warn "WARP 出口受限/疑似送中！出口 IP: ${exit_ip} | Google 识别地区: ${google_region} | Gemini可用: $gemini_ok"
        return 1
    fi
}

# 静默应用新参数并测试是否干净可用
apply_and_test_warp_candidate() {
    local ep_ip=$1
    local ep_port=$2
    local stack=$3

    update_warp_conf_fields ".enabled = true | .endpoint_ip = \"$ep_ip\" | .endpoint_port = $ep_port | .stack = \"$stack\""
    rebuild_config >/dev/null 2>&1
    sleep 3
    local rc=0
    check_warp_health 1 || rc=$?
    # 新注册密钥或刚建连时 Cloudflare 边缘生效偶有 3-6 秒延迟，隧道未通时补测一次
    if [[ $rc -eq 2 ]]; then
        sleep 5
        rc=0
        check_warp_health 1 || rc=$?
    fi
    return $rc
}

# 智能寻找可用且未送中的 WARP 出口 (先切栈 -> 再轮换 Endpoint -> 必要时换号)
select_best_warp_config() {
    local force_rotate=${1:-0}
    local cur_ep_ip cur_ep_port cur_stack
    cur_ep_ip=$(jq -r '.endpoint_ip // "162.159.192.1"' "$WARP_CONF")
    cur_ep_port=$(jq -r '.endpoint_port // 2408' "$WARP_CONF")
    cur_stack=$(jq -r '.stack // "ipv4_only"' "$WARP_CONF")

    local backup_conf
    backup_conf=$(cat "$WARP_CONF")

    # 1. 若非强制换 IP，先试当前节点与另一协议栈
    local stacks_to_try=("ipv4_only" "ipv6_only")
    if [[ "$cur_stack" == "ipv6_only" ]]; then
        stacks_to_try=("ipv6_only" "ipv4_only")
    fi

    if [[ $force_rotate -eq 0 ]]; then
        for st in "${stacks_to_try[@]}"; do
            print_info "正在检测 WARP 出口 (${cur_ep_ip}:${cur_ep_port} / ${st})..."
            if apply_and_test_warp_candidate "$cur_ep_ip" "$cur_ep_port" "$st"; then
                return 0
            fi
        done
    else
        # 强制刷新时，先尝试切换当前节点的另一协议栈
        local alt_stack="ipv6_only"
        [[ "$cur_stack" == "ipv6_only" ]] && alt_stack="ipv4_only"
        print_info "尝试切换 WARP 协议栈 (${cur_ep_ip}:${cur_ep_port} / ${alt_stack})..."
        if apply_and_test_warp_candidate "$cur_ep_ip" "$cur_ep_port" "$alt_stack"; then
            return 0
        fi
    fi

    # 2. 轮换 Cloudflare WARP Endpoint (最多试 6 组不同段)
    local tried=0
    local cand ep_ip ep_port
    while IFS= read -r cand; do
        [[ -z "$cand" ]] && continue
        ep_ip="${cand%|*}"
        ep_port="${cand#*|}"
        if [[ "$ep_ip" == "$cur_ep_ip" && "$ep_port" == "$cur_ep_port" ]]; then
            continue
        fi
        ((tried++))
        [[ $tried -gt 6 ]] && break

        for st in "ipv4_only" "ipv6_only"; do
            print_info "轮换 WARP 入口测试 [${tried}/6]: ${ep_ip}:${ep_port} (${st})..."
            if apply_and_test_warp_candidate "$ep_ip" "$ep_port" "$st"; then
                return 0
            fi
        done
    done < <(get_warp_endpoint_candidates)

    # 3. 仍未找到时，重新注册一个新 WARP 账户再试前 2 个入口
    print_info "尝试重新注册 Cloudflare WARP 设备凭证以获取新出口..."
    local new_acct
    new_acct=$(register_warp_account)
    if [[ -n "$new_acct" ]]; then
        local np_priv np_pub np_peer np_v4 np_v6 np_res
        np_priv=$(echo "$new_acct" | jq -r '.private_key')
        np_pub=$(echo "$new_acct" | jq -r '.public_key')
        np_peer=$(echo "$new_acct" | jq -r '.peer_public_key')
        np_v4=$(echo "$new_acct" | jq -r '.v4')
        np_v6=$(echo "$new_acct" | jq -r '.v6')
        np_res=$(echo "$new_acct" | jq -c '.reserved')
        update_warp_conf_fields ".private_key = \"$np_priv\" | .public_key = \"$np_pub\" | .peer_public_key = \"$np_peer\" | .v4 = \"$np_v4\" | .v6 = \"$np_v6\" | .reserved = $np_res"
        sleep 4

        local retry_ep=0
        while IFS= read -r cand; do
            [[ -z "$cand" ]] && continue
            ((retry_ep++))
            [[ $retry_ep -gt 2 ]] && break
            ep_ip="${cand%|*}"
            ep_port="${cand#*|}"
            for st in "ipv4_only" "ipv6_only"; do
                print_info "使用新凭证测试: ${ep_ip}:${ep_port} (${st})..."
                if apply_and_test_warp_candidate "$ep_ip" "$ep_port" "$st"; then
                    return 0
                fi
            done
        done < <(get_warp_endpoint_candidates)
    fi

    # 若全部尝试失败且隧道本身断了，回滚旧配置避免丢失连通性
    local rc=0
    check_warp_health 1 || rc=$?
    if [[ $rc -eq 2 ]]; then
        echo "$backup_conf" > "$WARP_CONF"
        rebuild_config >/dev/null 2>&1
        sleep 4
        check_warp_health 1 >/dev/null 2>&1 || true
    fi
    return 1
}

# 安装或启用每小时定期自动检测送中定时器
install_warp_timer() {
    local script_path="/usr/local/NodeManager/utils/warp.sh"
    [[ ! -f "$script_path" ]] && script_path="$(readlink -f "${BASH_SOURCE[0]}")"

    cat > /etc/systemd/system/node-manager-warp-checker.service <<EOF
[Unit]
Description=Node Manager WARP GeoIP & Gemini Health Checker
After=network-online.target sing-box.service

[Service]
Type=oneshot
ExecStart=/bin/bash $script_path auto-check
EOF

    cat > /etc/systemd/system/node-manager-warp-checker.timer <<EOF
[Unit]
Description=Hourly Node Manager WARP Health Check

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now node-manager-warp-checker.timer >/dev/null 2>&1
    update_warp_conf_fields ".auto_check = true"
}

remove_warp_timer() {
    systemctl stop node-manager-warp-checker.timer >/dev/null 2>&1 || true
    systemctl disable node-manager-warp-checker.timer >/dev/null 2>&1 || true
    systemctl stop node-manager-warp-checker.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/node-manager-warp-checker.timer /etc/systemd/system/node-manager-warp-checker.service
    systemctl daemon-reload
    if [[ -f "$WARP_CONF" ]]; then
        update_warp_conf_fields ".auto_check = false"
    fi
}

# 一键开启 / 重装 WARP Google/AI 智能分流
enable_warp() {
    print_separator
    print_info "正在配置 WARP (Sing-box WireGuard 出站) 解锁 Google / Gemini..."
    mkdir -p "$WARP_DIR"
    check_time_sync_hint
    detect_vps_stack
    print_info "检测到 VPS 网络环境: IPv4=${VPS_HAS_V4}, IPv6=${VPS_HAS_V6}"

    local socks_port
    socks_port=$(alloc_warp_socks_port)

    if [[ ! -f "$WARP_CONF" ]] || ! jq -e '.private_key and .v4' "$WARP_CONF" >/dev/null 2>&1; then
        print_info "正在向 Cloudflare 免费申请 WARP 设备凭证..."
        local acct
        acct=$(register_warp_account)
        if [[ -z "$acct" ]]; then
            print_err "申请 WARP 凭证失败，请检查 VPS 网络能否访问 api.cloudflareclient.com。"
            return 1
        fi
        local default_ep="162.159.192.1"
        if [[ "$VPS_HAS_V4" != "true" && "$VPS_HAS_V6" == "true" ]]; then
            default_ep="2606:4700:d0::a29f:c001"
        fi
        echo "$acct" | jq \
            --arg ep "$default_ep" \
            --argjson port 2408 \
            --argjson sport "$socks_port" \
            '. + {
                enabled: true,
                endpoint_ip: $ep,
                endpoint_port: $port,
                stack: "ipv4_only",
                socks_port: $sport,
                auto_check: true,
                last_status: "INIT",
                last_region: "",
                last_exit_ip: "",
                last_check: ""
            }' > "$WARP_CONF"
        print_ok "WARP 设备凭证申请成功！等待 Cloudflare 边缘节点同步密钥 (5 秒)..."
        sleep 5
    else
        update_warp_conf_fields ".enabled = true | .socks_port = $socks_port"
    fi

    print_info "正在下载/更新 Google & Gemini 本地分流规则集 (.srs)..."
    if download_warp_rulesets; then
        print_ok "规则集已就绪 (本地规则集 + 内置兜底域名双保障)。"
    else
        print_warn "远程 .srs 规则集下载失败，已自动降级为内置 Google/AI 域名列表兜底，不影响启动。"
    fi

    print_info "正在优选未送中且可解锁 Gemini 的 WARP 出口..."
    if select_best_warp_config 0; then
        print_ok "WARP 已成功启用并验证通过！"
    else
        print_warn "WARP 已启用，但当前机房 Cloudflare 出口暂时均提示受限，已保留连通配置并开启自动巡检。"
    fi

    install_warp_timer
    print_ok "已开启每小时自动检测送中服务 (node-manager-warp-checker.timer)。"
    show_warp_status
}

# 关闭 WARP 分流 (保留凭证方便下次秒开)
disable_warp() {
    remove_warp_timer
    if [[ -f "$WARP_CONF" ]]; then
        update_warp_conf_fields ".enabled = false"
    fi
    rebuild_config
    print_ok "已关闭 WARP 分流，所有节点恢复原始直连状态。"
}

# 手动刷新 WARP 出口 IP
refresh_warp_ip() {
    if [[ ! -f "$WARP_CONF" ]] || [[ "$(jq -r '.enabled // false' "$WARP_CONF" 2>/dev/null)" != "true" ]]; then
        print_warn "WARP 尚未启用，请先开启 WARP。"
        return 1
    fi
    print_info "正在刷新 WARP 出口 IP 并自动测试 Gemini 解锁状态..."
    if select_best_warp_config 1; then
        print_ok "WARP 出口刷新成功！"
    else
        print_warn "尝试轮换多个入口后暂未找到更优出口，已保持当前可用连接。"
    fi
    show_warp_status
}

# 查看当前 WARP 状态
show_warp_status() {
    print_separator
    echo -e "${CYAN}WARP Google / Gemini 智能分流状态${PLAIN}"
    print_separator
    if [[ ! -f "$WARP_CONF" ]]; then
        echo -e "状态: ${YELLOW}未安装/未启用${PLAIN}"
        print_separator
        return
    fi

    local enabled ep_ip ep_port stack auto_check last_status last_region last_exit_ip last_check
    enabled=$(jq -r '.enabled // false' "$WARP_CONF")
    ep_ip=$(jq -r '.endpoint_ip // "-"' "$WARP_CONF")
    ep_port=$(jq -r '.endpoint_port // "-"' "$WARP_CONF")
    stack=$(jq -r '.stack // "-"' "$WARP_CONF")
    auto_check=$(jq -r '.auto_check // false' "$WARP_CONF")
    last_status=$(jq -r '.last_status // "-"' "$WARP_CONF")
    last_region=$(jq -r '.last_region // "-"' "$WARP_CONF")
    last_exit_ip=$(jq -r '.last_exit_ip // "-"' "$WARP_CONF")
    last_check=$(jq -r '.last_check // "-"' "$WARP_CONF")

    echo -e "分流开关: $([[ "$enabled" == "true" ]] && echo -e "${GREEN}已开启${PLAIN}" || echo -e "${RED}已关闭${PLAIN}")"
    echo -e "分流范围: ${CYAN}仅 Google 全家桶 (搜索/Play商店/账号) + Gemini / Google AI${PLAIN}"
    echo -e "WARP 入口: ${YELLOW}${ep_ip}:${ep_port}${PLAIN} | 锁定出站栈: ${YELLOW}${stack}${PLAIN}"
    echo -e "定期自检: $([[ "$auto_check" == "true" ]] && echo -e "${GREEN}已开启 (每小时)${PLAIN}" || echo -e "${YELLOW}已关闭${PLAIN}")"
    echo -e "最近出口 IP: ${CYAN}${last_exit_ip}${PLAIN} | Google 判定地区: ${CYAN}${last_region}${PLAIN}"
    echo -e "最近检查结果: ${YELLOW}${last_status}${PLAIN} (${last_check})"
    print_separator
}

# 定时巡检入口 (带文件锁防重入 + 二次防抖防误切)
auto_check_warp() {
    mkdir -p "$(dirname "$WARP_LOG")"
    exec 9>"$WARP_LOCK"
    if ! flock -n 9; then
        return 0
    fi

    if [[ ! -f "$WARP_CONF" ]] || [[ "$(jq -r '.enabled // false' "$WARP_CONF" 2>/dev/null)" != "true" ]]; then
        return 0
    fi

    # 限制日志大小不超过 5MB
    if [[ -f "$WARP_LOG" ]]; then
        local sz
        sz=$(stat -c%s "$WARP_LOG" 2>/dev/null || wc -c < "$WARP_LOG" 2>/dev/null || echo 0)
        if [[ $sz -gt 5242880 ]]; then
            tail -n 200 "$WARP_LOG" > "${WARP_LOG}.tmp" && mv "${WARP_LOG}.tmp" "$WARP_LOG"
        fi
    fi

    # 先更新一次本地 .srs 规则集 (静默)
    download_warp_rulesets >/dev/null 2>&1 || true

    if check_warp_health 1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK region=$(jq -r '.last_region' "$WARP_CONF") ip=$(jq -r '.last_exit_ip' "$WARP_CONF")" >> "$WARP_LOG"
        return 0
    fi

    # 二次防抖确认，避免瞬时网络抖动误切换
    sleep 8
    if check_warp_health 1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK after retry" >> "$WARP_LOG"
        return 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] BLOCKED/DOWN detected, rotating WARP exit..." >> "$WARP_LOG"
    if select_best_warp_config 1 >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] HEALED region=$(jq -r '.last_region' "$WARP_CONF") ip=$(jq -r '.last_exit_ip' "$WARP_CONF")" >> "$WARP_LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN no cleaner exit found this round" >> "$WARP_LOG"
    fi
}

# WARP 交互子菜单
warp_menu() {
    while true; do
        clear
        show_warp_status
        echo -e " ${GREEN}1.${PLAIN} 一键开启 / 重新初始化 WARP 解锁 (Google + Gemini)"
        echo -e " ${GREEN}2.${PLAIN} 立即检测当前 WARP 是否送中 & Gemini 可用性"
        echo -e " ${GREEN}3.${PLAIN} 手动刷新 WARP 出口 IP (切换单栈 / 轮换入口)"
        echo -e " ${GREEN}4.${PLAIN} 开启 / 关闭 定期自动检查送中 (每小时巡检)"
        echo -e " ${RED}5.${PLAIN} 关闭 WARP 分流 (恢复纯直连)"
        echo -e " ${GREEN}0.${PLAIN} 返回主菜单"
        print_separator

        local choice
        read -p "请输入选项 [0-5]: " choice
        case "$choice" in
            1)
                enable_warp
                read -p "按回车键继续..."
                ;;
            2)
                print_info "正在通过 WARP 出口实测 Google 地区与 Gemini 连通性..."
                check_warp_health 0 || true
                read -p "按回车键继续..."
                ;;
            3)
                refresh_warp_ip
                read -p "按回车键继续..."
                ;;
            4)
                if [[ ! -f "$WARP_CONF" ]] || [[ "$(jq -r '.enabled // false' "$WARP_CONF" 2>/dev/null)" != "true" ]]; then
                    print_warn "请先通过选项 1 开启 WARP。"
                elif [[ "$(jq -r '.auto_check // false' "$WARP_CONF")" == "true" ]]; then
                    remove_warp_timer
                    print_ok "已关闭 WARP 定期自动巡检。"
                else
                    install_warp_timer
                    print_ok "已开启 WARP 每小时自动检测送中服务。"
                fi
                read -p "按回车键继续..."
                ;;
            5)
                if prompt_confirm "确定要关闭 WARP 分流并恢复纯直连吗？" "N"; then
                    disable_warp
                fi
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                print_err "无效的选项，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# 直接执行时支持 CLI 子命令 (供 systemd timer 调用)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        auto-check)
            auto_check_warp
            ;;
        refresh)
            refresh_warp_ip
            ;;
        status)
            show_warp_status
            ;;
        check)
            check_warp_health 0
            ;;
        *)
            echo "Usage: $0 {auto-check|refresh|status|check}"
            exit 1
            ;;
    esac
fi

fi
