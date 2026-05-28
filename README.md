# 服务器一键部署工具

交互式图形菜单脚本，覆盖从零开始的服务器全套初始化：安全加固 → SSL 证书 → sing-box 安装与配置 → 节点链接生成。

## 快速开始

```bash
bash <(curl -sSL https://raw.githubusercontent.com/github19999/ams/main/setup.sh)
```

> 必须以 root 身份运行。

## 功能模块

| # | 模块 | 说明 |
|---|------|------|
| 1 | 基础安全加固 | SSH 密钥、端口修改、fail2ban（maxretry=1 永久封禁）、BBR、IP 协议配置 |
| 2 | SSL 证书 | acme.sh + Let's Encrypt，standalone 模式，自动续期 cron |
| 3 | 安装 sing-box | 官方脚本安装，自动重启并展示状态 |
| 4 | 配置 sing-box | 交互式生成 anytls + vless + shadowsocks 三协议配置 |
| 5 | 服务管理 | 重启、enable、验证服务状态 |
| 6 | 生成节点链接 | 自动生成三条分享链接，保存至文件 |

## 兼容系统

- Ubuntu 18 / 20 / 22 / 24
- Debian 10 / 11 / 12
- CentOS 7 / 8 / 9
- RHEL / AlmaLinux / Rocky Linux 8 / 9

## 仓库结构

```
.
├── setup.sh          # 主入口脚本（TUI 菜单）
├── setup-ui.html     # Web UI 版本（本地预览/生成脚本）
└── README.md
```

## 配置默认值

| 参数 | 默认值 |
|------|--------|
| SSH 端口 | 43916 |
| IP 优先级 | IPv4 优先 |
| 证书路径 | /etc/ssl/private/ |
| anytls 端口 | 48790 |
| vless 端口 | 47790 |
| shadowsocks 端口 | 46790 |
| SS 加密方式 | 2022-blake3-aes-128-gcm |

## 安全特性

- 所有修改的配置文件自动生成带时间戳备份（`.bak.YYYYMMDD_HHMMSS`）
- SSH 配置修改后自动语法检查，失败则回滚
- 公钥为追加写入，不覆盖已有密钥
- BBR 启用前检测内核版本（需 ≥ 4.9），避免重复写入
- fail2ban 永久封禁（bantime=-1），首次尝试即封（maxretry=1）
