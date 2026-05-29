#!/usr/bin/env bash
# =============================================================================
# 服务器一键部署脚本 v1.0
# GitHub: https://github.com/{用户名}/{仓库名}/main/setup.sh
# 用法: bash <(curl -sSL https://raw.githubusercontent.com/{用户名}/{仓库名}/main/setup.sh)
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────
# 颜色 & 日志
# ──────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; RESET='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_step()  { echo -e "${PURPLE}[STEP]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
log_sep()   { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
ts()        { date '+%Y%m%d_%H%M%S'; }

# ──────────────────────────────────────────────
# 全局变量（供模块间共享）
# ──────────────────────────────────────────────
DISTRO=""; PKG_MGR=""; SSHD_SERVICE=""
M1_PUBKEY=""; M1_SSH_PORT=43916; M1_IP_PRIORITY="ipv4"; M1_IP_DISABLE="none"
M2_DOMAINS=""; M2_CERT_PATH="/etc/ssl/private/"; M2_WEBSERVER="none"
M4_DOMAIN=""; M4_UUID=""; M4_ANYTLS_PORT=48790; M4_VLESS_PORT=47790
M4_SS_PORT=46790; M4_SS_PASS=""; M4_CERT_DIR="/etc/ssl/private/"

# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || { log_error "必须以 root 身份运行！"; exit 1; }
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    DISTRO="${ID:-unknown}"
  fi
  case "$DISTRO" in
    ubuntu|debian)  PKG_MGR="apt-get" ;;
    centos|rhel|almalinux|rocky|fedora) PKG_MGR="dnf"; command -v dnf &>/dev/null || PKG_MGR="yum" ;;
    *) log_error "不支持的发行版: $DISTRO"; exit 1 ;;
  esac
  log_ok "检测到系统: $DISTRO，包管理器: $PKG_MGR"
}

install_pkgs() {
  local pkgs=("$@")
  log_info "安装: ${pkgs[*]}"
  case "$PKG_MGR" in
    apt-get) apt-get install -y -q "${pkgs[@]}" ;;
    dnf|yum) $PKG_MGR install -y -q "${pkgs[@]}" ;;
  esac
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] && cp "$f" "${f}.bak.$(ts)" && log_info "已备份: ${f}.bak.$(ts)"
}

gen_uuid() {
  python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null \
    || cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || uuidgen
}

gen_ss_pass() {
  sing-box generate rand --base64 16 2>/dev/null \
    || openssl rand -base64 16 | tr -d '=' | head -c 24
}

ask() {
  local prompt="$1" default="${2:-}" var_name="$3"
  local val=""
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}$prompt${RESET} [默认: ${GREEN}$default${RESET}]: ")" val
    val="${val:-$default}"
  else
    while [[ -z "$val" ]]; do
      read -rp "$(echo -e "${BOLD}$prompt${RESET}: ")" val
      [[ -z "$val" ]] && log_warn "此项不能为空"
    done
  fi
  eval "$var_name='$val'"
}

ask_choice() {
  local prompt="$1" default="$2" var_name="$3"; shift 3
  local opts=("$@")
  echo -e "\n${BOLD}$prompt${RESET}"
  for i in "${!opts[@]}"; do
    local marker="  "; [[ "$((i+1))" == "$default" ]] && marker="${GREEN}→${RESET}"
    echo -e "  $marker ${BLUE}$((i+1))${RESET}) ${opts[$i]}"
  done
  local choice=""
  read -rp "请输入选项 [默认 $default]: " choice
  choice="${choice:-$default}"
  eval "$var_name='${opts[$((choice-1))]}'"
}

# ──────────────────────────────────────────────
# 主菜单
# ──────────────────────────────────────────────
show_menu() {
  clear
  echo -e "${BOLD}${BLUE}"
  cat << 'BANNER'
 ╔══════════════════════════════════════════╗
 ║     服务器一键部署工具  v1.0            ║
 ╚══════════════════════════════════════════╝
BANNER
  echo -e "${RESET}"
  echo -e "  ${BOLD}请选择要执行的模块：${RESET}\n"
  local items=(
    "基础安全加固（SSH/fail2ban/BBR）"
    "SSL 证书申请与安装"
    "安装 sing-box"
    "配置 sing-box"
    "sing-box 服务管理"
    "生成节点链接"
    "── 全部执行（1→6）──"
    "退出"
  )
  for i in "${!items[@]}"; do
    local n=$((i+1))
    local color="$RESET"
    [[ $n -eq 7 ]] && color="$GREEN"
    [[ $n -eq 8 ]] && color="$RED"
    echo -e "  ${color}${BOLD}[$n]${RESET} ${items[$i]}"
  done
  echo ""
}

# ──────────────────────────────────────────────
# 模块 1：基础安全加固
# ──────────────────────────────────────────────
module_1_security() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 1：服务器基础安全加固${RESET}"
  log_sep

  check_root
  log_step "[1/12] 检查 root 权限 ✓"

  log_step "[2/12] 安装基础工具..."
  detect_distro
  install_pkgs curl wget git sudo ca-certificates

  log_step "[3/12] 检测发行版完成: $DISTRO"

  # 收集配置
  log_step "[4/12] 交互式配置收集..."
  echo ""

  # SSH 公钥
  local pubkey=""
  while true; do
    read -rp $'\e[1mSSH 公钥\e[0m (ssh-ed25519 / ssh-rsa ...): ' pubkey
    if echo "$pubkey" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519)'; then
      break
    fi
    log_warn "公钥格式不正确，请重新输入"
  done
  M1_PUBKEY="$pubkey"

  ask "SSH 端口 (1024-65535)" "43916" M1_SSH_PORT
  while ! [[ "$M1_SSH_PORT" =~ ^[0-9]+$ ]] || [[ $M1_SSH_PORT -lt 1024 || $M1_SSH_PORT -gt 65535 ]]; do
    log_warn "端口范围需在 1024–65535 之间"
    ask "SSH 端口" "43916" M1_SSH_PORT
  done

  ask_choice "IP 协议优先级" 1 M1_IP_PRIORITY \
    "IPv4 优先（推荐）" "IPv6 优先" "保持不变"

  ask_choice "IP 协议禁用" 1 M1_IP_DISABLE \
    "保持不变（推荐）" "禁用 IPv6" "禁用 IPv4（危险）"

  if [[ "$M1_IP_DISABLE" == "禁用 IPv4（危险）" ]]; then
    log_warn "⚠️  禁用 IPv4 可能导致服务器断连！"
    read -rp "输入 'CONFIRM' 确认继续: " confirm
    [[ "$confirm" == "CONFIRM" ]] || { log_info "已取消禁用 IPv4"; M1_IP_DISABLE="保持不变（推荐）"; }
  fi

  # fail2ban
  log_step "[5/12] 安装 fail2ban..."
  install_pkgs fail2ban

  # BBR
  log_step "[6/12] 启用 BBR 拥塞控制..."
  local kernel_ver; kernel_ver=$(uname -r | cut -d. -f1-2 | tr -d .)
  if [[ $kernel_ver -ge 49 ]]; then
    local sysctl_conf="/etc/sysctl.d/99-bbr.conf"
    if ! grep -q "tcp_congestion_control=bbr" "$sysctl_conf" 2>/dev/null; then
      cat >> "$sysctl_conf" << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
      sysctl -p "$sysctl_conf" &>/dev/null
      log_ok "BBR 已启用"
    else
      log_info "BBR 已配置，跳过"
    fi
  else
    log_warn "内核版本 < 4.9，跳过 BBR"
  fi

  # IP 优先级
  log_step "[7/12] 设置 IP 协议优先级..."
  backup_file /etc/gai.conf
  case "$M1_IP_PRIORITY" in
    "IPv4 优先（推荐）")
      sed -i 's/^#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null \
        || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
      log_ok "IPv4 优先已配置" ;;
    "IPv6 优先")
      sed -i 's/^precedence ::ffff:0:0\/96  100/#precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null
      log_ok "IPv6 优先已配置" ;;
    *) log_info "保持 IP 优先级不变" ;;
  esac

  # 禁用 IP 协议
  log_step "[8/12] 处理 IP 协议禁用..."
  local disable_conf="/etc/sysctl.d/99-disable-ipv6.conf"
  case "$M1_IP_DISABLE" in
    "禁用 IPv6")
      cat > "$disable_conf" << 'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
      sysctl -p "$disable_conf" &>/dev/null; log_ok "IPv6 已禁用" ;;
    "禁用 IPv4（危险）")
      log_warn "禁用 IPv4 当前不支持通过 sysctl 实现，请手动操作";;
    *) log_info "保持 IP 协议不变" ;;
  esac

  # SSH 密钥
  log_step "[9/12] 配置 SSH 密钥..."
  local auth_keys="$HOME/.ssh/authorized_keys"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if ! grep -qF "$M1_PUBKEY" "$auth_keys" 2>/dev/null; then
    echo "$M1_PUBKEY" >> "$auth_keys"
    chmod 600 "$auth_keys"
    log_ok "SSH 公钥已追加写入（未覆盖已有密钥）"
  else
    log_info "该公钥已存在，跳过"
  fi

  # SSH 安全加固
  log_step "[10/12] SSH 安全加固..."
  local sshd_conf="/etc/ssh/sshd_config"
  backup_file "$sshd_conf"
  # 精确替换或追加
  for setting in \
    "PasswordAuthentication no" \
    "PubkeyAuthentication yes" \
    "PermitRootLogin prohibit-password" \
    "Port $M1_SSH_PORT"; do
    local key; key=$(echo "$setting" | cut -d' ' -f1)
    if grep -qE "^#?${key}" "$sshd_conf"; then
      sed -i "s|^#*${key}.*|${setting}|" "$sshd_conf"
    else
      echo "$setting" >> "$sshd_conf"
    fi
  done

  # 语法检查
  if sshd -t 2>/dev/null; then
    log_ok "sshd 配置语法验证通过"
  else
    log_error "sshd 配置有误，已从备份恢复"
    cp "${sshd_conf}.bak."* "$sshd_conf" 2>/dev/null || true
    exit 1
  fi

  # fail2ban 配置
  log_step "[11/12] 配置 fail2ban..."
  local f2b_backend="auto"
  systemctl is-active systemd &>/dev/null && f2b_backend="systemd"
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = -1
maxretry = 1
backend  = $f2b_backend

[sshd]
enabled = true
port    = $M1_SSH_PORT
EOF
  systemctl enable fail2ban &>/dev/null
  systemctl restart fail2ban
  log_ok "fail2ban 配置完成（maxretry=1, bantime=-1 永久封禁）"

  # 重启 SSH
  log_step "[12/12] 重启 SSH 服务..."
  if systemctl list-units --type=service | grep -q "^  sshd.service"; then
    SSHD_SERVICE="sshd"
  else
    SSHD_SERVICE="ssh"
  fi
  systemctl restart "$SSHD_SERVICE"
  log_ok "SSH 服务已重启"

  log_sep
  log_ok "✅ 模块 1 完成！请使用新端口 ${M1_SSH_PORT} 连接服务器"
  log_sep
}

# ──────────────────────────────────────────────
# 模块 2：SSL 证书
# ──────────────────────────────────────────────
module_2_ssl() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 2：SSL 证书申请与安装${RESET}"
  log_sep

  check_root
  detect_distro

  # 安装依赖
  log_step "[1/11] 安装依赖..."
  install_pkgs curl wget socat openssl ca-certificates
  # 按系统分别启动对应 cron 服务，避免混用报错（Debian 只有 cron，CentOS 只有 crond）
  case "$PKG_MGR" in
    apt-get)
      install_pkgs cron
      systemctl enable cron &>/dev/null && systemctl start cron &>/dev/null || true
      ;;
    dnf|yum)
      install_pkgs cronie
      systemctl enable crond &>/dev/null && systemctl start crond &>/dev/null || true
      ;;
  esac

  # 安装/更新 acme.sh
  log_step "[2/11] 安装/更新 acme.sh..."
  if [[ -f ~/.acme.sh/acme.sh ]]; then
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade &>/dev/null || true
    log_info "acme.sh 已更新"
  else
    if curl https://get.acme.sh | sh; then
      log_ok "acme.sh 安装完成"
    else
      log_warn "主要安装方法失败，尝试备用方法..."
      wget -O- https://get.acme.sh | sh || {
        log_error "acme.sh 安装失败"
        exit 1
      }
    fi
    source ~/.bashrc 2>/dev/null || true
  fi
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  # 收集域名
  log_step "[3/11] 配置域名..."
  echo ""
  ask "请输入域名（多个用空格分隔）" "" M2_DOMAINS
  read -ra DOMAIN_ARR <<< "$M2_DOMAINS"

  # 证书路径
  ask_choice "证书存放路径" 1 M2_CERT_PATH \
    "/etc/ssl/private/" "/etc/nginx/ssl/" "/etc/apache2/ssl/" "/usr/local/ssl/" "自定义"
  [[ "$M2_CERT_PATH" == "自定义" ]] && ask "输入自定义路径" "/etc/ssl/private/" M2_CERT_PATH
  M2_CERT_PATH="${M2_CERT_PATH%/}/"
  mkdir -p "$M2_CERT_PATH"; chmod 755 "$M2_CERT_PATH"

  # Web 服务
  ask_choice "当前 Web 服务（80端口）" 1 M2_WEBSERVER \
    "无（端口空闲）" "nginx" "apache2" "httpd" "lighttpd"

  # DNS 检测
  log_step "[4/11] 检测 DNS 解析..."
  for domain in "${DOMAIN_ARR[@]}"; do
    local resolved=""
    resolved=$(dig +short "$domain" 2>/dev/null | head -1) || \
    resolved=$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2}' | head -1) || true
    if [[ -n "$resolved" ]]; then
      log_ok "$domain → $resolved"
    else
      log_warn "$domain 解析未检测到，请确认 DNS 已正确指向本服务器"
    fi
  done

  # 停止 Web 服务（首次申请需占用 80 端口）
  log_step "[5/11] 处理 80 端口..."
  if [[ "$M2_WEBSERVER" != "无（端口空闲）" ]]; then
    systemctl stop "$M2_WEBSERVER" 2>/dev/null && log_ok "已停止 $M2_WEBSERVER" || \
      log_warn "停止 $M2_WEBSERVER 失败，将继续尝试"
  fi

  # 申请证书（去掉 --force，避免消耗 Let's Encrypt 每周颁发限额）
  log_step "[6/11] 申请证书（standalone 模式）..."
  local domain_args=""
  for d in "${DOMAIN_ARR[@]}"; do domain_args="$domain_args -d $d"; done
  if ! ~/.acme.sh/acme.sh --issue --standalone $domain_args; then
    log_error "证书申请失败，请检查："
    log_error "  • 域名是否正确解析到本服务器"
    log_error "  • 防火墙是否开放 80 端口"
    # 失败后恢复 Web 服务
    [[ "$M2_WEBSERVER" != "无（端口空闲）" ]] && \
      systemctl start "$M2_WEBSERVER" 2>/dev/null || true
    exit 1
  fi

  # 安装证书
  log_step "[7/11] 安装证书到 $M2_CERT_PATH..."
  local main_domain="${DOMAIN_ARR[0]}"
  ~/.acme.sh/acme.sh --install-cert -d "$main_domain" \
    --key-file       "${M2_CERT_PATH}private.key" \
    --fullchain-file "${M2_CERT_PATH}fullchain.cer" \
    --ca-file        "${M2_CERT_PATH}ca.cer" \
    --reloadcmd      "echo 'cert installed'"
  # 设置安全权限
  chmod 600 "${M2_CERT_PATH}private.key"
  chmod 644 "${M2_CERT_PATH}fullchain.cer" "${M2_CERT_PATH}ca.cer"
  log_ok "证书文件已安装"

  # Pre/Post Hook：写入 acme.sh 域名配置文件，解决续期时 80 端口冲突
  # 续期时 acme.sh 自动执行: PreHook(停服) → standalone续期 → PostHook(启服)
  log_step "[8/11] 配置续期 Hook..."
  if [[ "$M2_WEBSERVER" != "无（端口空闲）" ]]; then
    local conf_file="/root/.acme.sh/${main_domain}/${main_domain}.conf"
    if [[ -f "$conf_file" ]]; then
      if ! grep -q "Le_PreHook" "$conf_file"; then
        echo "Le_PreHook='systemctl stop ${M2_WEBSERVER}'" >> "$conf_file"
        echo "Le_PostHook='systemctl start ${M2_WEBSERVER}'" >> "$conf_file"
        log_ok "Pre/Post Hook 写入完成（续期自动停启 $M2_WEBSERVER）"
      else
        log_info "Hook 已存在，跳过写入"
      fi
    else
      log_warn "未找到配置文件: $conf_file，请手动添加："
      log_warn "  Le_PreHook='systemctl stop ${M2_WEBSERVER}'"
      log_warn "  Le_PostHook='systemctl start ${M2_WEBSERVER}'"
    fi
  else
    log_info "无 Web 服务，续期直接使用 standalone 模式，无需 Hook"
  fi

  # Cron 自动续期（检查是否已存在，避免重复添加）
  log_step "[9/11] 设置 cron 自动续期..."
  local log_file="/var/log/acme-renew.log"
  local cron_job="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $log_file 2>&1"
  if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
    log_info "续期 cron 已存在，跳过"
  else
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    log_ok "cron 已配置：每天 02:00 续期，日志写入 $log_file"
  fi

  # 重启 Web 服务
  log_step "[10/11] 重启 Web 服务..."
  if [[ "$M2_WEBSERVER" != "无（端口空闲）" ]]; then
    systemctl start "$M2_WEBSERVER" && log_ok "$M2_WEBSERVER 已重启" || \
      log_warn "$M2_WEBSERVER 启动失败，请手动检查: systemctl status $M2_WEBSERVER"
  fi

  # 展示证书信息（用 --list 替代 --force 测试，无副作用）
  log_step "[11/11] 证书信息..."
  openssl x509 -in "${M2_CERT_PATH}fullchain.cer" -noout -dates 2>/dev/null || true
  log_info "当前证书列表："
  ~/.acme.sh/acme.sh --list

  log_sep
  log_ok "✅ 模块 2 完成！证书已安装至 $M2_CERT_PATH"
  log_info "  私钥: ${M2_CERT_PATH}private.key"
  log_info "  证书: ${M2_CERT_PATH}fullchain.cer"
  log_info "  续期日志: $log_file"
  log_sep
}

# ──────────────────────────────────────────────
# 模块 3：安装 sing-box
# ──────────────────────────────────────────────
module_3_install_singbox() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 3：安装 sing-box${RESET}"
  log_sep
  check_root
  log_step "执行官方安装脚本..."
  bash <(curl -fsSL https://sing-box.app/deb-install.sh)
  log_step "重启 sing-box 服务..."
  systemctl restart sing-box
  log_step "检查服务状态..."
  systemctl status sing-box --no-pager
  log_sep
  log_ok "✅ 模块 3 完成！sing-box 已安装并启动"
  log_sep
}

# ──────────────────────────────────────────────
# 模块 4：配置 sing-box
# ──────────────────────────────────────────────
module_4_config_singbox() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 4：配置 sing-box${RESET}"
  log_sep
  check_root

  ask "服务器域名或 IP" "" M4_DOMAIN

  local default_uuid; default_uuid=$(gen_uuid)
  ask "UUID（留空自动生成）" "$default_uuid" M4_UUID

  ask "anytls 端口" "48790" M4_ANYTLS_PORT
  ask "vless 端口"  "47790" M4_VLESS_PORT
  ask "shadowsocks 端口" "46790" M4_SS_PORT

  local default_ss; default_ss=$(gen_ss_pass)
  ask "SS 密码（留空自动生成）" "$default_ss" M4_SS_PASS

  ask "证书目录路径" "/etc/ssl/private/" M4_CERT_DIR
  M4_CERT_DIR="${M4_CERT_DIR%/}/"

  log_step "备份旧配置..."
  backup_file /etc/sing-box/config.json

  log_step "写入 /etc/sing-box/config.json..."
  mkdir -p /etc/sing-box
  cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "evoxt(hk1)-sb-anytls",
      "listen": "::",
      "listen_port": ${M4_ANYTLS_PORT},
      "users": [
        { "password": "${M4_UUID}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${M4_DOMAIN}",
        "certificate_path": "${M4_CERT_DIR}fullchain.cer",
        "key_path": "${M4_CERT_DIR}private.key"
      }
    },
    {
      "type": "vless",
      "tag": "evoxt(hk1)-sb-vision",
      "listen": "::",
      "listen_port": ${M4_VLESS_PORT},
      "users": [
        { "uuid": "${M4_UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${M4_DOMAIN}",
        "certificate_path": "${M4_CERT_DIR}fullchain.cer",
        "key_path": "${M4_CERT_DIR}private.key"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "evoxt(hk1)-sb-ss",
      "listen": "::",
      "listen_port": ${M4_SS_PORT},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${M4_SS_PASS}"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

  log_ok "配置文件已写入"
  sing-box check -c /etc/sing-box/config.json && log_ok "配置语法检查通过" || log_warn "配置语法检查失败，请检查参数"

  log_sep
  log_ok "✅ 模块 4 完成！"
  log_sep
}

# ──────────────────────────────────────────────
# 模块 5：服务管理
# ──────────────────────────────────────────────
module_5_service() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 5：sing-box 服务管理${RESET}"
  log_sep
  check_root
  log_step "重启 sing-box..."
  systemctl restart sing-box
  log_step "查看状态..."
  systemctl status sing-box --no-pager
  log_step "设置开机自启..."
  systemctl enable sing-box
  log_ok "开机自启: $(systemctl is-enabled sing-box)"
  log_sep
  log_ok "✅ 模块 5 完成！"
  log_sep
}

# ──────────────────────────────────────────────
# 模块 6：生成节点链接
# ──────────────────────────────────────────────
module_6_links() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 6：生成节点链接${RESET}"
  log_sep

  # 如果模块 4 已运行，使用已有参数
  [[ -z "$M4_DOMAIN" ]]    && ask "服务器域名/IP" "" M4_DOMAIN
  [[ -z "$M4_UUID" ]]      && ask "UUID" "" M4_UUID
  [[ -z "$M4_SS_PASS" ]]   && ask "SS 密码" "" M4_SS_PASS
  [[ $M4_ANYTLS_PORT -eq 0 ]] && ask "anytls 端口" "48790" M4_ANYTLS_PORT
  [[ $M4_VLESS_PORT -eq 0 ]]  && ask "vless 端口"  "47790" M4_VLESS_PORT
  [[ $M4_SS_PORT -eq 0 ]]     && ask "SS 端口"      "46790" M4_SS_PORT

  local SS_METHOD="2022-blake3-aes-128-gcm"
  local SS_B64; SS_B64=$(echo -n "${SS_METHOD}:${M4_SS_PASS}" | base64 -w 0)
  local TAG_ANYTLS="evoxt%28hk1%29-sb-anytls"
  local TAG_VLESS="evoxt%28hk1%29-sb-vision"
  local TAG_SS="evoxt%28hk1%29-sb-ss"

  LINK_ANYTLS="anytls://${M4_UUID}@${M4_DOMAIN}:${M4_ANYTLS_PORT}?security=tls&sni=${M4_DOMAIN}&type=tcp#${TAG_ANYTLS}"
  LINK_VLESS="vless://${M4_UUID}@${M4_DOMAIN}:${M4_VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${M4_DOMAIN}&fp=chrome&type=tcp&headerType=none#${TAG_VLESS}"
  LINK_SS="ss://${SS_B64}@${M4_DOMAIN}:${M4_SS_PORT}#${TAG_SS}"

  log_sep
  echo -e "\n${BOLD}${GREEN}✅ 节点链接生成完成${RESET}\n"

  echo -e "${PURPLE}【anytls】${RESET}"
  echo -e "${BLUE}$LINK_ANYTLS${RESET}\n"

  echo -e "${PURPLE}【vless】${RESET}"
  echo -e "${BLUE}$LINK_VLESS${RESET}\n"

  echo -e "${PURPLE}【shadowsocks】${RESET}"
  echo -e "${BLUE}$LINK_SS${RESET}\n"

  # 写入文件
  local outfile="/root/singbox_links_$(ts).txt"
  cat > "$outfile" << EOF
=== sing-box 节点链接 $(date) ===

[anytls]
$LINK_ANYTLS

[vless]
$LINK_VLESS

[shadowsocks]
$LINK_SS
EOF
  log_ok "链接已保存至: $outfile"
  log_sep
}

# ──────────────────────────────────────────────
# 主入口
# ──────────────────────────────────────────────
main() {
  check_root
  while true; do
    show_menu
    read -rp "$(echo -e "${BOLD}请选择 [1-8]${RESET}: ")" choice
    case "$choice" in
      1) module_1_security ;;
      2) module_2_ssl ;;
      3) module_3_install_singbox ;;
      4) module_4_config_singbox ;;
      5) module_5_service ;;
      6) module_6_links ;;
      7)
        module_1_security
        module_2_ssl
        module_3_install_singbox
        module_4_config_singbox
        module_5_service
        module_6_links
        log_ok "🎉 全部模块执行完毕！"
        break ;;
      8) echo -e "${GREEN}Bye!${RESET}"; exit 0 ;;
      *) log_warn "无效选项，请重新输入" ;;
    esac
    echo ""
    read -rp "按 Enter 返回菜单..." _
  done
}

main "$@"
