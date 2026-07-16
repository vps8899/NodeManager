#!/usr/bin/env bash
# config.sh - 基于 jq 的 JSON 配置读写库

DB_FILE="/etc/node-manager/database/nodes.json"
SETTINGS_FILE="/etc/node-manager/database/settings.json"

init_db() {
    if [[ ! -f "$DB_FILE" ]]; then
        mkdir -p "$(dirname "$DB_FILE")"
        echo '{"nodes": []}' > "$DB_FILE"
    fi
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        mkdir -p "$(dirname "$SETTINGS_FILE")"
        echo '{"version": "1.0.0"}' > "$SETTINGS_FILE"
    fi
}

# 读取设置
get_setting() {
    local key=$1
    if [[ -f "$SETTINGS_FILE" ]]; then
        jq -r ".$key" "$SETTINGS_FILE" 2>/dev/null | grep -v "^null$"
    fi
}

# 写入设置
set_setting() {
    local key=$1
    local value=$2
    if [[ -f "$SETTINGS_FILE" ]]; then
        local temp=$(mktemp)
        # 区分数字/布尔值和字符串
        if [[ "$value" == "true" || "$value" == "false" || "$value" =~ ^[0-9]+$ ]]; then
            jq ".$key = $value" "$SETTINGS_FILE" > "$temp"
        else
            jq ".$key = \"$value\"" "$SETTINGS_FILE" > "$temp"
        fi
        mv "$temp" "$SETTINGS_FILE"
    fi
}

# 添加节点到数据库
add_node() {
    local node_json=$1
    if [[ -f "$DB_FILE" ]]; then
        local temp=$(mktemp)
        jq ".nodes += [$node_json]" "$DB_FILE" > "$temp"
        mv "$temp" "$DB_FILE"
    fi
}

# 删除节点
delete_node() {
    local uuid=$1
    if [[ -f "$DB_FILE" ]]; then
        local temp=$(mktemp)
        jq "del(.nodes[] | select(.id == \"$uuid\"))" "$DB_FILE" > "$temp"
        mv "$temp" "$DB_FILE"
    fi
}

# 查找节点列表
get_all_nodes() {
    if [[ -f "$DB_FILE" ]]; then
        jq -c '.nodes[]' "$DB_FILE" 2>/dev/null
    fi
}
