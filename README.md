# Node Manager

Node Manager 是一个轻量级、高度模块化的 Linux VPS 多协议节点部署与管理工具。采用 Sing-box 作为核心引擎，提供清晰直观的 SSH 交互菜单，专为小白用户设计，一键即可完成主流代理协议的搭建。

## 核心特性

- **高度工程化**：摆脱传统的几千行“面条代码”，项目采用模块化设计，每个协议单独文件，易于维护与扩展。
- **Sing-box 统一核心**：采用最新的 Sing-box 核心驱动，资源占用低，统一管理多种协议（VLESS, Hysteria2, TUIC）。
- **完全解耦**：代码目录 (`/usr/local/NodeManager`) 与 数据目录 (`/etc/node-manager/`) 完全分离。升级脚本不会覆盖您的任何节点数据。
- **动态配置**：使用 `jq` 将所有节点状态持久化为 JSON 数据库，配置生成与订阅导出动态且可靠。
- **自适应环境**：自动安装必要依赖，自动适配 UFW/firewalld/iptables 放行端口。
- **免域名建站 (Argo)**：集成 Cloudflare Argo Tunnel，一键建立 VLESS+WS 隧道，无需购买域名和解析。

## 支持协议

- **VLESS + REALITY + Vision** (推荐，优化线路防封)
- **Hysteria2** (UDP 加速，普通线路起飞)
- **TUIC v5** (UDP 加速，降低延迟)
- **VLESS + WS + TLS + Argo** (免域名快速搭建)

## 安装与升级

只需在您的 Linux VPS (支持 Debian, Ubuntu, CentOS, AlmaLinux, Rocky) 上执行以下命令（需 root 权限）：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/vps8899/NodeManager/main/install.sh)
```

安装完成后，在终端直接输入 `node-manager` 即可呼出交互菜单。

## 目录结构说明

- `/usr/local/NodeManager/`：程序代码所在目录，可随时 `git pull` 更新。
- `/etc/node-manager/database/nodes.json`：节点数据库，记录所有已添加的节点信息。
- `/etc/node-manager/sing-box/config.json`：由程序自动生成的 Sing-box 配置文件。
- `/etc/node-manager/output/sub.txt`：自动生成的 Base64 订阅链接文件。

## 常见问题 (FAQ)

**1. 为什么添加节点后连不上？**
请检查您服务器云提供商（如 AWS, 阿里云, 腾讯云）的网页端安全组是否已放行对应的端口（VLESS 需要 TCP，Hysteria2/TUIC 需要 UDP）。脚本已自动尝试放行系统内部防火墙。

**2. 订阅链接怎么使用？**
在菜单中选择“查看所有节点与订阅链接”，复制 Base64 格式的字符串，或者将对应的文件下载并通过 HTTP 暴露即可。后续会增加内置 Web 订阅分发。

**3. 如何卸载？**
```bash
systemctl stop sing-box
systemctl disable sing-box
rm -rf /etc/node-manager
rm -rf /usr/local/NodeManager
rm -f /usr/local/bin/node-manager
```
**注意：这会删除所有的节点数据和配置！**

## 贡献指南

我们非常欢迎开发者参与贡献。由于本项目采用了高度模块化的设计，您只需：
1. 在 `protocols/` 下新建您的协议脚本 (如 `p_shadowsocks.sh`)。
2. 实现 `add_xxx()` 方法，将 `inbound` JSON 结构写入 `nodes.json` 数据库。
3. 在 `menu.sh` 中注册您的选项。
4. 提交 Pull Request。

## 许可证 (License)

本项目采用 [MIT License](LICENSE) 开源。
