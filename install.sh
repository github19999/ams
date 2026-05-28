#!/usr/bin/env bash
# =============================================================================
#  sing-box 服务端一键安装脚本
#  支持：AnyTLS / VLESS+Reality / Shadowsocks 2022
#  兼容：Debian / Ubuntu
#  用法：bash install.sh [域名]
#        例：bash install.sh example.com
# =============================================================================

# ─────────────────────────────────────────────
#  ★ 用户可修改区（无需改动脚本主体）
# ─────────────────────────────────────────────

# 主域名（若脚本启动时传入参数则以参数为准）
BASE_DOMAIN="${1:-a.b.c}"

# 证书域名列表（空格分隔）
CERT_DOMAINS="evoxthk1a.${BASE_DOMAIN} evoxthk1r.${BASE_DOMAIN} evoxthk1ar.${BASE_DOMAIN} evoxthk1.${BASE_DOMAIN}"

# AnyTLS 使用的证书域名
ANYTLS_DOMAIN="evoxthk1ar.${BASE_DOMAIN}"

# 各协议端口
PORT_ANYTLS=48790
PORT_VLESS=47790
PORT_SS=46790

# sing-box 配置目录 / 证书目录
SINGBOX_CONF="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/private"

# 前置安装脚本地址
PRE_INSTALL_SCRIPT="https://raw.githubusercontent.com/github19999/mydl/refs/heads/main/msfb46-v1.sh"

# 证书部署脚本地址
CERT_SCRIPT="https://raw.githubusercontent.com/github19999/cert/refs/heads/main/deploy-cert-v2.sh"

# ─────────────────────────────────────────────
#  内部变量（请勿修改）
# ─────────────────────────────────────────────

TOTAL_STEPS=7
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────────
#  辅助函数
# ─────────────────────────────────────────────

info()    { echo -e "${CYAN}[信息]${NC} $*"; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*"; }
error()   { echo -e "${RED}[错误]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${GREEN}[$1/${TOTAL_STEPS}]${NC} ${BOLD}$2${NC}"; }

check_root() {
    [[ $EUID -eq 0 ]] || error "此脚本需要以 root 权限运行，请使用 sudo 或切换至 root 用户。"
}

check_cmd() {
    command -v "$1" &>/dev/null || error "命令 '$1' 不存在，请检查安装是否完整。"
}

# ─────────────────────────────────────────────
#  主流程
# ─────────────────────────────────────────────

set -euo pipefail

clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          sing-box 服务端一键安装脚本                    ║"
echo "║  AnyTLS / VLESS+Reality / Shadowsocks 2022              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

check_root

info "基础域名：${BASE_DOMAIN}"
info "证书域名：${CERT_DOMAINS}"
echo ""

# ──────────────────────────────────────────────
#  步骤 1：更新系统 & 安装 curl
# ──────────────────────────────────────────────
step 1 "更新系统软件包并安装 curl"

apt-get update -y  || error "apt-get update 失败，请检查网络或软件源配置。"
apt-get upgrade -y || error "apt-get upgrade 失败。"
apt-get install -y curl || error "安装 curl 失败。"

success "系统更新及 curl 安装完成。"

# ──────────────────────────────────────────────
#  步骤 2：执行前置安装脚本
# ──────────────────────────────────────────────
step 2 "执行前置安装脚本"

bash <(curl -sSL "${PRE_INSTALL_SCRIPT}") || error "前置安装脚本执行失败，请检查脚本地址或网络连接。"

success "前置安装脚本执行完成。"

# ──────────────────────────────────────────────
#  步骤 3：申请并部署 TLS 证书
# ──────────────────────────────────────────────
step 3 "申请并部署 TLS 证书"

info "正在为以下域名申请证书：${CERT_DOMAINS}"

for domain in ${CERT_DOMAINS}; do
    info "  → 处理域名：${domain}"
    bash <(curl -sSL "${CERT_SCRIPT}") "${domain}" \
        || error "域名 ${domain} 的证书申请/部署失败。"
done

success "所有证书部署完成，证书目录：${CERT_DIR}"

# ──────────────────────────────────────────────
#  步骤 4：安装 sing-box
# ──────────────────────────────────────────────
step 4 "安装 sing-box（官方 deb 安装脚本）"

bash <(curl -sSL https://sing-box.app/deb-install.sh) \
    || error "sing-box 安装失败，请检查网络连接或手动安装。"

check_cmd sing-box
SINGBOX_VER=$(sing-box version | head -n1)
success "sing-box 安装完成：${SINGBOX_VER}"

# ──────────────────────────────────────────────
#  步骤 5：生成所需密钥
# ──────────────────────────────────────────────
step 5 "生成密钥材料"

info "生成 UUID..."
UUID=$(sing-box generate uuid) || error "UUID 生成失败。"
success "UUID：${UUID}"

info "生成 Reality 密钥对..."
REALITY_KEYS=$(sing-box generate reality-keypair) || error "Reality 密钥对生成失败。"
REALITY_PRIVATE=$(echo "${REALITY_KEYS}" | awk '/PrivateKey/ {print $2}')
REALITY_PUBLIC=$(echo  "${REALITY_KEYS}" | awk '/PublicKey/  {print $2}')
success "Reality 私钥：${REALITY_PRIVATE}"
success "Reality 公钥：${REALITY_PUBLIC}"

info "生成 short_id（8字节 hex）..."
SHORT_ID=$(sing-box generate rand 8 --hex) || error "short_id 生成失败。"
success "short_id：${SHORT_ID}"

info "生成 Shadowsocks 密码（16字节 base64）..."
SS_PASSWORD=$(sing-box generate rand --base64 16) || error "SS 密码生成失败。"
success "SS 密码：${SS_PASSWORD}"

# ──────────────────────────────────────────────
#  步骤 6：写入 sing-box 配置文件
# ──────────────────────────────────────────────
step 6 "写入 sing-box 配置文件（${SINGBOX_CONF}）"

mkdir -p "$(dirname "${SINGBOX_CONF}")"

cat > "${SINGBOX_CONF}" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${PORT_ANYTLS},
      "users": [
        {
          "name": "default",
          "password": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_DOMAIN}",
        "certificate_path": "${CERT_DIR}/${ANYTLS_DOMAIN}.crt",
        "key_path": "${CERT_DIR}/${ANYTLS_DOMAIN}.key"
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT_VLESS},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${ANYTLS_DOMAIN}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${PORT_SS},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS_PASSWORD}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

success "配置文件写入完成：${SINGBOX_CONF}"

# 验证配置语法
sing-box check -c "${SINGBOX_CONF}" || error "sing-box 配置文件语法校验失败，请检查 ${SINGBOX_CONF}。"
success "配置文件语法校验通过。"

# ──────────────────────────────────────────────
#  步骤 7：启动 sing-box 并设置开机自启
# ──────────────────────────────────────────────
step 7 "启动 sing-box 并设置开机自启"

systemctl daemon-reload       || error "systemctl daemon-reload 失败。"
systemctl enable sing-box     || error "设置 sing-box 开机自启失败。"
systemctl restart sing-box    || error "sing-box 启动失败，请检查日志：journalctl -u sing-box -xe"

sleep 2
SB_STATUS=$(systemctl is-active sing-box)
if [[ "${SB_STATUS}" == "active" ]]; then
    success "sing-box 服务运行正常（状态：${SB_STATUS}）"
else
    error "sing-box 服务未能正常运行（状态：${SB_STATUS}），请执行 journalctl -u sing-box -xe 查看日志。"
fi

echo ""
systemctl status sing-box --no-pager -l | head -20

# ──────────────────────────────────────────────
#  汇总信息
# ──────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                  ✅ 安装完成 — 配置汇总                 ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}服务器信息${NC}"
echo -e "  公网 IP（请自行确认）：$(curl -s4 ifconfig.me 2>/dev/null || echo '获取失败，请手动填写')"
echo ""
echo -e "${BOLD}── AnyTLS ──────────────────────────────────────────────────${NC}"
echo -e "  端口      ：${PORT_ANYTLS}"
echo -e "  密码      ：${UUID}"
echo -e "  域名      ：${ANYTLS_DOMAIN}"
echo -e "  证书路径  ：${CERT_DIR}/${ANYTLS_DOMAIN}.crt"
echo ""
echo -e "${BOLD}── VLESS + XTLS-RPRX-Vision (Reality) ─────────────────────${NC}"
echo -e "  端口      ：${PORT_VLESS}"
echo -e "  UUID      ：${UUID}"
echo -e "  公钥      ：${REALITY_PUBLIC}"
echo -e "  short_id  ：${SHORT_ID}"
echo -e "  SNI       ：${ANYTLS_DOMAIN}"
echo ""
echo -e "${BOLD}── Shadowsocks 2022-blake3-aes-128-gcm ─────────────────────${NC}"
echo -e "  端口      ：${PORT_SS}"
echo -e "  密码      ：${SS_PASSWORD}"
echo ""
echo -e "${BOLD}证书目录${NC}：${CERT_DIR}"
echo -e "${BOLD}配置文件${NC}：${SINGBOX_CONF}"
echo ""
echo -e "${YELLOW}⚠  请妥善保存以上信息，关闭终端后将无法再次查看。${NC}"
echo ""
