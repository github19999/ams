# sing-box 服务端一键安装脚本

自动完成 **AnyTLS / VLESS+Reality / Shadowsocks 2022** 三协议 sing-box 服务端的全套部署，包括：系统更新、TLS 证书申请、密钥生成、配置写入及服务启动。

> **系统要求**：Debian 11+ 或 Ubuntu 20.04+，以 **root** 用户运行。

---

## 一键安装命令

```bash
# 方式一：直接传入主域名参数（推荐）
bash <(curl -sSL https://raw.githubusercontent.com/github19999/ams/main/install.sh) example.com

# 方式二：先下载再执行
curl -O https://raw.githubusercontent.com/github19999/ams/main/install.sh
chmod +x install.sh
bash install.sh example.com
```

> 将 `example.com` 替换为你的实际主域名（脚本会自动拼接子域名前缀）。

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `$1` | 主域名，证书子域名将基于此拼接 | `a.b.c` |

脚本顶部提供**用户可修改区**，可在不改动主体逻辑的情况下调整以下参数：

| 变量 | 含义 |
|------|------|
| `BASE_DOMAIN` | 主域名 |
| `CERT_DOMAINS` | 申请证书的完整子域名列表 |
| `ANYTLS_DOMAIN` | AnyTLS / VLESS 使用的 SNI 域名 |
| `PORT_ANYTLS` | AnyTLS 监听端口（默认 48790） |
| `PORT_VLESS` | VLESS 监听端口（默认 47790） |
| `PORT_SS` | Shadowsocks 监听端口（默认 46790） |
| `CERT_DIR` | 证书存放目录（默认 `/etc/ssl/private`） |
| `PRE_INSTALL_SCRIPT` | 前置安装脚本 URL |
| `CERT_SCRIPT` | 证书部署脚本 URL |

---

## 脚本执行步骤

```
[1/7] 更新系统软件包并安装 curl
[2/7] 执行前置安装脚本
[3/7] 申请并部署 TLS 证书（所有子域名）
[4/7] 安装 sing-box（官方 deb 脚本）
[5/7] 生成密钥（UUID / Reality 密钥对 / short_id / SS 密码）
[6/7] 写入 /etc/sing-box/config.json
[7/7] 启动 sing-box 并设置开机自启
```

---

## 客户端配置示例

安装完成后，终端会打印完整的配置摘要。以下为各协议的客户端配置参考。

### AnyTLS

```json
{
  "type": "anytls",
  "tag": "proxy-anytls",
  "server": "<服务器IP>",
  "server_port": 48790,
  "password": "<UUID>",
  "tls": {
    "enabled": true,
    "server_name": "evoxthk1ar.<你的域名>"
  }
}
```

### VLESS + XTLS-RPRX-Vision（Reality）

```json
{
  "type": "vless",
  "tag": "proxy-vless",
  "server": "<服务器IP>",
  "server_port": 47790,
  "uuid": "<UUID>",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "evoxthk1ar.<你的域名>",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "<Reality 公钥>",
      "short_id": "<short_id>"
    }
  }
}
```

> **说明**：Reality 模式无需真实证书，`public_key` 和 `short_id` 均由服务端生成并在安装摘要中打印。

### Shadowsocks 2022-blake3-aes-128-gcm

```json
{
  "type": "shadowsocks",
  "tag": "proxy-ss",
  "server": "<服务器IP>",
  "server_port": 46790,
  "method": "2022-blake3-aes-128-gcm",
  "password": "<SS 密码>"
}
```

### 完整客户端 sing-box config.json 示例（三协议合并 + 自动选择）

```json
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["proxy-vless", "proxy-anytls", "proxy-ss"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m"
    },
    { /* VLESS 配置（见上）*/ },
    { /* AnyTLS 配置（见上）*/ },
    { /* SS 配置（见上）*/ },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      { "geoip": ["cn", "private"], "outbound": "direct" }
    ],
    "final": "auto"
  }
}
```

---

## 常用管理命令

```bash
# 查看服务状态
systemctl status sing-box

# 实时查看日志
journalctl -u sing-box -f

# 重启服务
systemctl restart sing-box

# 校验配置文件
sing-box check -c /etc/sing-box/config.json

# 查看版本
sing-box version
```

---

## 证书说明

证书通过自定义部署脚本申请，默认存放在 `/etc/ssl/private/` 目录：

```
/etc/ssl/private/
├── evoxthk1a.<域名>.crt
├── evoxthk1a.<域名>.key
├── evoxthk1ar.<域名>.crt
├── evoxthk1ar.<域名>.key
├── evoxthk1r.<域名>.crt
├── evoxthk1r.<域名>.key
├── evoxthk1.<域名>.crt
└── evoxthk1.<域名>.key
```

---

## License

MIT
