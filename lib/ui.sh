#!/usr/bin/env bash
# ui.sh - UI 组件，颜色输出与菜单渲染

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# 信息输出
print_ok() { echo -e "${GREEN}[OK]${PLAIN} $1"; }
print_err() { echo -e "${RED}[ERROR]${PLAIN} $1" >&2; }
print_info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }

# 菜单分隔线
print_separator() {
    echo -e "${CYAN}==================================================${PLAIN}"
}

# 输入提示
prompt_input() {
    local prompt_text=$1
    local default_val=$2
    local var_name=$3
    local user_input
    
    if [[ "$AUTO_INSTALL" == "true" ]]; then
        eval $var_name=\"$default_val\"
        echo -e "${YELLOW}${prompt_text}: [自动选取默认值] ${default_val}${PLAIN}"
        return
    fi
    
    if [[ -n "$default_val" ]]; then
        read -p "$(echo -e "${YELLOW}${prompt_text} [默认: ${default_val}]: ${PLAIN}")" user_input
        [[ -z "$user_input" ]] && eval $var_name=\"$default_val\" || eval $var_name=\"$user_input\"
    else
        read -p "$(echo -e "${YELLOW}${prompt_text}: ${PLAIN}")" user_input
        eval $var_name=\"$user_input\"
    fi
}

prompt_confirm() {
    local prompt_text=$1
    local default_val=${2:-"Y"}
    local user_input
    
    if [[ "$default_val" == "Y" || "$default_val" == "y" ]]; then
        read -p "$(echo -e "${YELLOW}${prompt_text} [Y/n]: ${PLAIN}")" user_input
        [[ -z "$user_input" ]] && user_input="Y"
    else
        read -p "$(echo -e "${YELLOW}${prompt_text} [y/N]: ${PLAIN}")" user_input
        [[ -z "$user_input" ]] && user_input="N"
    fi
    
    if [[ "$user_input" == "Y" || "$user_input" == "y" ]]; then
        return 0
    else
        return 1
    fi
}
