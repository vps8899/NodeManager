#!/usr/bin/env bash
# install.sh - NodeManager 在线安装/升级脚本

REPO_URL="https://github.com/vps8899/NodeManager"
BRANCH="main"
INSTALL_DIR="/usr/local/NodeManager"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m 请使用 root 用户运行此脚本！"
    exit 1
fi

echo -e "\033[0;34m[INFO]\033[0m 正在安装/升级 Node Manager..."

# 检查系统并安装基础依赖 (git)
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y git >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y git >/dev/null 2>&1
else
    echo -e "\033[0;31m[ERROR]\033[0m 无法识别的包管理器，请手动安装 git"
    exit 1
fi

# 拉取最新代码
if [[ -d "$INSTALL_DIR" ]]; then
    echo -e "\033[0;34m[INFO]\033[0m 发现旧版本，正在拉取最新代码..."
    cd "$INSTALL_DIR" || exit 1
    git fetch --all
    git reset --hard origin/$BRANCH
    git pull origin $BRANCH
else
    echo -e "\033[0;34m[INFO]\033[0m 正在克隆项目代码..."
    git clone -b $BRANCH "$REPO_URL.git" "$INSTALL_DIR"
fi

# 赋予执行权限
chmod +x "$INSTALL_DIR/menu.sh"
chmod +x "$INSTALL_DIR/install.sh"

# 创建全局软链接
if [[ ! -L "/usr/local/bin/node-manager" ]]; then
    ln -sf "$INSTALL_DIR/menu.sh" "/usr/local/bin/node-manager"
fi

echo -e "\033[0;32m[OK]\033[0m 安装完成！"
echo -e "\033[0;33m正在启动菜单...\033[0m"

# 自动进入菜单
/usr/local/bin/node-manager
