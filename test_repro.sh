#!/usr/bin/env bash

# Mock functions
print_info() { echo "[INFO] $1"; }
print_ok() { echo "[OK] $1"; }

SB_VERSION="1.9.3"
SB_DIR="/tmp/test/node-manager/sing-box"
SB_BIN="/tmp/test/bin/sing-box"
SB_CONF="$SB_DIR/config.json"

mkdir -p /tmp/test/bin
touch "$SB_BIN" # Mock that binary already exists

install_singbox() {
    print_info "正在安装 Sing-box 核心..."
    mkdir -p "$SB_DIR"
    
    if [[ ! -f "$SB_BIN" ]]; then
        echo "Downloading... (should be skipped)"
    fi
    
    # 写入基础配置模板
    if [[ ! -f "$SB_CONF" ]]; then
        cat > "$SB_CONF" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": []
}
EOF
    fi

    cat > /tmp/test/sing-box.service <<EOF
[Unit]
Description=sing-box service
EOF

    print_ok "Sing-box 安装完成。"
}

install_singbox

ls -la /tmp/test/node-manager/sing-box

