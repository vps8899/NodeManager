#!/usr/bin/env bash
# menu.sh - 交互式菜单入口

# 获取当前脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# 引入基础库
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/system.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"

# 引入功能模块
source "$SCRIPT_DIR/utils/firewall.sh"
source "$SCRIPT_DIR/utils/cert.sh"
source "$SCRIPT_DIR/utils/subscription.sh"

# 引入协议模块
source "$SCRIPT_DIR/protocols/core_singbox.sh"
source "$SCRIPT_DIR/protocols/p_vless_reality.sh"
source "$SCRIPT_DIR/protocols/p_hysteria2.sh"
source "$SCRIPT_DIR/protocols/p_tuic.sh"
source "$SCRIPT_DIR/protocols/p_argo.sh"

show_menu() {
    clear
    print_separator
    echo -e "${CYAN}       Node Manager - 多协议节点一键管理工具${PLAIN}"
    print_separator
    echo -e " ${GREEN}1.${PLAIN} 添加 VLESS + Reality 节点 (推荐)"
    echo -e " ${GREEN}2.${PLAIN} 添加 Hysteria2 节点"
    echo -e " ${GREEN}3.${PLAIN} 添加 TUIC v5 节点"
    echo -e " ${GREEN}4.${PLAIN} 添加 VLESS WS TLS Argo (免域名)"
    echo -e " ${GREEN}5.${PLAIN} 查看所有节点与订阅链接"
    echo -e " ${GREEN}6.${PLAIN} 重载 Sing-box 服务"
    echo -e " ${GREEN}7.${PLAIN} 查看 Sing-box 日志"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    print_separator
    
    local choice
    read -p "请输入选项 [0-7]: " choice
    
    case "$choice" in
        1)
            add_vless_reality
            read -p "按回车键继续..."
            ;;
        2)
            add_hysteria2
            read -p "按回车键继续..."
            ;;
        3)
            add_tuic
            read -p "按回车键继续..."
            ;;
        4)
            add_argo
            read -p "按回车键继续..."
            ;;
        5)
            show_all_nodes
            read -p "按回车键继续..."
            ;;
        6)
            reload_singbox
            read -p "按回车键继续..."
            ;;
        7)
            journalctl -u sing-box --no-pager -n 50
            read -p "按回车键继续..."
            ;;
        0)
            exit 0
            ;;
        *)
            print_err "无效的选项，请重新输入"
            sleep 1
            ;;
    esac
}

main() {
    check_sys
    init_db
    # 首次运行检查 singbox 是否安装
    if [[ ! -f "$SB_BIN" ]]; then
        install_dependencies
        install_singbox
    fi

    while true; do
        show_menu
    done
}

main "$@"
