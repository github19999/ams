#!/usr/bin/env bash
# =============================================================================
# 服务器一键部署脚本 v2.0
# 用法: bash <(curl -sSL https://raw.githubusercontent.com/{用户名}/{仓库名}/main/setup.sh)
# =============================================================================

set -e

# ──────────────────────────────────────────────
# 颜色 & 日志
# ──────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
RESET='\033[0m'; BOLD='\033[1m'

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
DISTRO_ID=""; DISTRO_VERSION=""; PKG_MANAGER=""; SSHD_SERVICE=""
STOPPED_SERVICES=()
M1_PUBKEY=""; M1_SSH_PORT=43916; M1_IP_PRIORITY="ipv4"; M1_IP_DISABLE="none"
M2_DOMAINS=(); M2_MAIN_DOMAIN=""; M2_CERT_PATH="/etc/ssl/private"; M2_WEBSERVER="none"
M4_DOMAIN=""; M4_UUID=""; M4_ANYTLS_PORT=48790; M4_VLESS_PORT=47790
M4_SS_PORT=46790; M4_SS_PASS=""; M4_CERT_DIR="/etc/ssl/private/"

# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "此脚本需要 root 权限运行"; exit 1
  fi
}

# 检测发行版与包管理器
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID%%.*}"
  else
    log_error "无法识别操作系统，仅支持含 /etc/os-release 的发行版"; exit 1
  fi

  case "$DISTRO_ID" in
    ubuntu|debian|raspbian)
      PKG_MANAGER="apt"
      ;;
    centos|rhel|almalinux|rocky|fedora)
      PKG_MANAGER="yum"
      command -v dnf &>/dev/null && PKG_MANAGER="dnf"
      ;;
    *)
      log_warn "未经测试的发行版: $DISTRO_ID，将尝试使用 apt 继续"
      PKG_MANAGER="apt"
      ;;
  esac
  log_info "检测到系统: ${PRETTY_NAME:-$DISTRO_ID}（包管理器: $PKG_MANAGER）"
}

# 预装基础组件（优先执行，确保后续工具可用）
bootstrap_packages() {
  log_step "预装基础组件..."
  if command -v apt &>/dev/null; then
    apt-get update -y -q
    apt-get install -y -q curl sudo wget git unzip nano vim
  elif command -v dnf &>/dev/null; then
    dnf install -y epel-release 2>/dev/null || true
    dnf install -y curl sudo wget git unzip nano vim
  elif command -v yum &>/dev/null; then
    yum install -y epel-release 2>/dev/null || true
    yum install -y curl sudo wget git unzip nano vim
  else
    log_warn "未检测到已知包管理器，跳过预装"; return
  fi
  log_ok "基础组件预装完成"
}

install_pkgs() {
  local pkgs=("$@")
  log_info "安装: ${pkgs[*]}"
  case "$PKG_MANAGER" in
    apt)     apt-get install -y -q "${pkgs[@]}" ;;
    dnf|yum) $PKG_MANAGER install -y "${pkgs[@]}" ;;
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
    read -rp "$(echo -e "${BOLD}${prompt}${RESET} [默认: ${GREEN}${default}${RESET}]: ")" val
    val="${val:-$default}"
  else
    while [[ -z "$val" ]]; do
      read -rp "$(echo -e "${BOLD}${prompt}${RESET}: ")" val
      [[ -z "$val" ]] && log_warn "此项不能为空"
    done
  fi
  eval "$var_name='$val'"
}

# ──────────────────────────────────────────────
# 主菜单
# ──────────────────────────────────────────────
show_menu() {
  clear
  echo -e "${BOLD}${CYAN}"
  cat << 'BANNER'
 ╔══════════════════════════════════════════╗
 ║     服务器一键部署工具  v2.0            ║
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

# ══════════════════════════════════════════════
# 模块 1：基础安全加固
# ══════════════════════════════════════════════
module_1_security() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 1：服务器基础安全加固${RESET}"
  log_sep

  # [1] root 权限
  check_root
  log_step "[1/12] 检查 root 权限 ✓"

  # [2] 预装基础工具
  log_step "[2/12] 预装基础组件..."
  bootstrap_packages

  # [3] 检测发行版
  log_step "[3/12] 检测发行版..."
  detect_distro

  # [4] 收集用户配置（所有交互集中在执行前完成）
  log_step "[4/12] 收集配置参数..."
  echo ""

  # SSH 公钥
  echo -e "${CYAN}请输入你的 SSH 公钥（以 ssh-ed25519 / ssh-rsa / ecdsa-sha2 开头）:${RESET}"
  while true; do
    read -rp "SSH 公钥: " M1_PUBKEY
    if [[ -z "$M1_PUBKEY" ]]; then
      log_warn "公钥不能为空，请重新输入"; continue
    fi
    if [[ ! "$M1_PUBKEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519) ]]; then
      log_warn "公钥格式可能不正确，但继续执行..."
    fi
    break
  done

  # SSH 端口
  echo ""
  echo -e "${CYAN}请输入新的 SSH 端口（建议 10000-65535，默认 43916）:${RESET}"
  read -rp "SSH 端口 [默认: 43916]: " M1_SSH_PORT
  M1_SSH_PORT="${M1_SSH_PORT:-43916}"
  if ! [[ "$M1_SSH_PORT" =~ ^[0-9]+$ ]] || [[ $M1_SSH_PORT -lt 1024 || $M1_SSH_PORT -gt 65535 ]]; then
    log_warn "端口无效，使用默认值 43916"
    M1_SSH_PORT=43916
  fi
  log_info "将使用 SSH 端口: $M1_SSH_PORT"

  # IP 协议优先级
  echo ""
  log_step "配置 IP 协议优先级"
  echo "  1) IPv4 优先（推荐）"
  echo "  2) IPv6 优先"
  echo "  3) 保持不变"
  read -rp "请输入选择 (1-3，默认 1): " _ip_prio
  _ip_prio="${_ip_prio:-1}"
  case "$_ip_prio" in
    1) M1_IP_PRIORITY="ipv4"; log_info "将设置 IPv4 优先" ;;
    2) M1_IP_PRIORITY="ipv6"; log_info "将设置 IPv6 优先" ;;
    3) M1_IP_PRIORITY="none"; log_info "保持 IP 协议优先级不变" ;;
    *) log_warn "无效选择，使用默认 IPv4 优先"; M1_IP_PRIORITY="ipv4" ;;
  esac

  # IP 协议禁用（默认保持不变，防止误操作断连）
  echo ""
  log_step "配置 IP 协议禁用"
  echo "  1) 禁用 IPv6"
  echo "  2) 禁用 IPv4（危险）"
  echo "  3) 保持不变（默认）"
  read -rp "请输入选择 (1-3，默认 3): " _ip_dis
  _ip_dis="${_ip_dis:-3}"
  case "$_ip_dis" in
    1) M1_IP_DISABLE="ipv6"; log_info "将禁用 IPv6" ;;
    2) M1_IP_DISABLE="ipv4"; log_warn "⚠️  禁用 IPv4 可能导致服务器完全无法访问！"
       read -rp "确认要禁用 IPv4 吗？(y/N): " _confirm
       if [[ "${_confirm,,}" != "y" ]]; then
         log_info "已取消禁用 IPv4"; M1_IP_DISABLE="none"
       fi ;;
    3) M1_IP_DISABLE="none"; log_info "保持 IP 协议状态不变" ;;
    *) log_warn "无效选择，保持不变"; M1_IP_DISABLE="none" ;;
  esac

  echo ""
  log_info "参数收集完成，开始执行配置..."
  echo ""

  # [5] 安装 fail2ban
  log_step "[5/12] 安装 fail2ban..."
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get install -y fail2ban || log_warn "fail2ban 安装失败，将在后续步骤重试"
  else
    $PKG_MANAGER install -y fail2ban || log_warn "fail2ban 安装失败，请手动安装"
  fi

  # [6] 启用 BBR
  log_step "[6/12] 启用 BBR 拥塞控制..."
  local current_cc; current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [[ "$current_cc" == "bbr" ]]; then
    log_info "BBR 已启用，跳过"
  else
    local kver; kver=$(uname -r | cut -d. -f1-2 | tr -d '.')
    if [[ "$kver" -lt 49 ]] 2>/dev/null; then
      log_warn "内核版本低于 4.9，BBR 不受支持，跳过"
    else
      # 避免重复写入，写入 sysctl.conf
      grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || \
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
      grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
      sysctl -p > /dev/null 2>&1
      if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        log_ok "BBR 启用成功"
      else
        log_warn "BBR 可能未生效，请确认内核已加载 tcp_bbr 模块"
      fi
    fi
  fi

  # [7] IP 协议优先级
  log_step "[7/12] 设置 IP 协议优先级..."
  if [[ "$M1_IP_PRIORITY" == "none" ]]; then
    log_info "跳过 IP 协议优先级设置"
  elif [[ ! -f /etc/gai.conf ]]; then
    log_warn "/etc/gai.conf 不存在，跳过"
  else
    backup_file /etc/gai.conf
    if [[ "$M1_IP_PRIORITY" == "ipv4" ]]; then
      if grep -q "^#[[:space:]]*precedence ::ffff:0:0/96" /etc/gai.conf; then
        sed -i 's/^#[[:space:]]*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
      elif ! grep -q "^precedence ::ffff:0:0/96" /etc/gai.conf; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
      fi
      log_ok "IPv4 优先已设置"
    else
      sed -i 's/^precedence ::ffff:0:0\/96/#precedence ::ffff:0:0\/96/' /etc/gai.conf
      log_ok "IPv6 优先已设置"
    fi
  fi

  # [8] 禁用 IP 协议
  log_step "[8/12] 处理 IP 协议禁用..."
  if [[ "$M1_IP_DISABLE" == "none" ]]; then
    log_info "跳过 IP 协议禁用"
  else
    mkdir -p /etc/sysctl.d
    if [[ "$M1_IP_DISABLE" == "ipv6" ]]; then
      local ipv6_conf="/etc/sysctl.d/99-disable-ipv6.conf"
      if [[ -f "$ipv6_conf" ]]; then
        log_info "IPv6 禁用配置已存在: $ipv6_conf"
      else
        cat > "$ipv6_conf" << 'EOF'
# IPv6 disabled by deploy script
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
      fi
      sysctl -p "$ipv6_conf" > /dev/null 2>&1
      if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "1" ]]; then
        log_ok "IPv6 已成功禁用"
      else
        log_warn "IPv6 禁用需重启后完全生效"
      fi
    elif [[ "$M1_IP_DISABLE" == "ipv4" ]]; then
      local ipv4_conf="/etc/sysctl.d/99-disable-ipv4.conf"
      if [[ ! -f "$ipv4_conf" ]]; then
        cat > "$ipv4_conf" << 'EOF'
# IPv4 disabled by deploy script
net.ipv4.conf.all.disable_ipv4=1
net.ipv4.conf.default.disable_ipv4=1
EOF
      fi
      log_warn "IPv4 禁用配置已写入，重启后生效（请确保有 IPv6 连接方式）"
    fi
  fi

  # [9] 配置 SSH 密钥
  log_step "[9/12] 配置 SSH 密钥登录..."
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  chown root:root /root/.ssh
  if ! grep -qF "$M1_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "$M1_PUBKEY" >> /root/.ssh/authorized_keys
    log_ok "SSH 公钥已追加写入（未覆盖已有密钥）"
  else
    log_info "该公钥已存在，跳过"
  fi
  chmod 600 /root/.ssh/authorized_keys
  chown root:root /root/.ssh/authorized_keys
  # 修复 SELinux 上下文（CentOS/RHEL）
  if command -v restorecon &>/dev/null; then
    restorecon -Rv /root/.ssh/ > /dev/null 2>&1
    log_info "SELinux 上下文已修复"
  fi

  # [10] SSH 安全加固
  log_step "[10/12] SSH 安全加固..."
  local sshd_conf="/etc/ssh/sshd_config"
  backup_file "$sshd_conf"

  # 辅助：精确替换或追加 sshd_config 参数（无论是否被注释）
  sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "$sshd_conf"; then
      sed -i "s|^#\?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$sshd_conf"
    else
      echo "${key} ${val}" >> "$sshd_conf"
    fi
  }

  # 显式启用公钥认证（很多系统默认不写此行）
  sshd_set "PubkeyAuthentication" "yes"
  # 显式指定 authorized_keys 路径
  sshd_set "AuthorizedKeysFile" ".ssh/authorized_keys"
  # 允许 root 密钥登录，禁止密码登录 root
  sshd_set "PermitRootLogin" "prohibit-password"
  # 禁用密码登录（三项全禁，封堵旁路）
  sshd_set "PasswordAuthentication" "no"
  sshd_set "ChallengeResponseAuthentication" "no"
  sshd_set "KbdInteractiveAuthentication" "no"
  # 修改 SSH 端口（注释旧端口，追加新端口）
  sed -i 's/^Port[[:space:]]/#Port /' "$sshd_conf"
  grep -q "^Port $M1_SSH_PORT" "$sshd_conf" || echo "Port $M1_SSH_PORT" >> "$sshd_conf"

  log_info "SSH 配置完成（端口: $M1_SSH_PORT，已禁用密码登录，已启用公钥认证）"
  log_warn "如果密码登录仍可用，请检查 UsePAM 设置（部分系统需手动设为 no）"

  # [11] 配置 fail2ban
  log_step "[11/12] 配置 fail2ban..."
  if ! command -v fail2ban-server &>/dev/null; then
    log_warn "fail2ban 未安装，再次尝试..."
    if [[ "$PKG_MANAGER" == "apt" ]]; then
      apt-get install -y fail2ban || { log_error "fail2ban 安装失败，跳过"; }
    else
      $PKG_MANAGER install -y fail2ban || { log_error "fail2ban 安装失败，跳过"; }
    fi
  fi

  if command -v fail2ban-server &>/dev/null; then
    # 检测日志后端
    local f2b_backend="auto"
    local f2b_logpath=""
    if systemctl is-active --quiet systemd-journald 2>/dev/null; then
      f2b_backend="systemd"
    else
      for lp in /var/log/auth.log /var/log/secure; do
        if [[ -f "$lp" ]]; then f2b_logpath="logpath = $lp"; break; fi
      done
      [[ -z "$f2b_logpath" ]] && f2b_logpath="logpath = /var/log/auth.log"
    fi
    # 先停止服务再写配置，避免文件锁冲突
    systemctl stop fail2ban 2>/dev/null || true
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = -1
findtime = 300
maxretry = 1

[sshd]
enabled  = true
port     = $M1_SSH_PORT
backend  = $f2b_backend
${f2b_logpath}
maxretry = 1
findtime = 300
bantime  = -1
ignoreip = 127.0.0.1/8 ::1
EOF
    sleep 1
    systemctl enable fail2ban
    systemctl start fail2ban
    if systemctl is-active --quiet fail2ban; then
      log_ok "fail2ban 启动成功（maxretry=1, bantime=-1 永久封禁）"
    else
      log_warn "fail2ban 启动失败，查看日志: journalctl -u fail2ban --no-pager -n 30"
    fi
  fi

  # [12] 重启 SSH
  log_step "[12/12] 重启 SSH 服务..."
  if ! sshd -t 2>&1; then
    log_error "SSH 配置语法错误，请检查 /etc/ssh/sshd_config"
    log_error "备份文件在: /etc/ssh/sshd_config.bak.*"
    exit 1
  fi
  # 兼容 sshd / ssh 两种服务名
  if systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl restart sshd
  elif systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl restart ssh
  else
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || \
      { log_error "无法重启 SSH 服务"; exit 1; }
  fi
  log_ok "SSH 服务已重启"

  log_sep
  echo -e "${GREEN}"
  echo "  配置总结："
  echo "    SSH 端口      : $M1_SSH_PORT"
  echo "    密码登录      : 已禁用"
  echo "    公钥登录      : 已启用"
  echo "    BBR 加速      : 已启用"
  echo "    fail2ban      : 已启用（1次失败永久封禁）"
  echo ""
  echo "  重要提醒："
  echo "    1. 新连接命令: ssh -p $M1_SSH_PORT root@<服务器IP>"
  echo "    2. 【请先开新终端测试连接，确认成功后再断开当前会话！】"
  echo "    3. 防火墙未配置，请确保 $M1_SSH_PORT 端口已放行"
  echo ""
  echo "  排查命令："
  echo "    fail2ban-client status sshd"
  echo "    journalctl -u sshd --no-pager -n 50"
  echo -e "${RESET}"
  log_ok "✅ 模块 1 完成！"
  log_sep
}

# ══════════════════════════════════════════════
# 模块 2：SSL 证书申请与安装
# ══════════════════════════════════════════════
module_2_ssl() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 2：SSL 证书申请与安装${RESET}"
  log_sep

  check_root
  detect_distro

  # [1] 安装依赖（按系统区分 cron 服务名）
  log_step "[1/11] 安装系统依赖..."
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get update -q
    apt-get install -y -q curl wget socat cron openssl ca-certificates
    systemctl enable cron  &>/dev/null && systemctl start cron  &>/dev/null || true
  else
    $PKG_MANAGER install -y curl wget socat cronie openssl ca-certificates
    systemctl enable crond &>/dev/null && systemctl start crond &>/dev/null || true
  fi
  log_ok "依赖安装完成"

  # [2] 安装/更新 acme.sh（不传邮箱，与参考脚本一致）
  log_step "[2/11] 安装/更新 acme.sh..."
  if [[ -f /root/.acme.sh/acme.sh ]]; then
    /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
    log_ok "acme.sh 已更新"
  else
    if curl https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1; then
      log_ok "acme.sh 安装成功"
    else
      log_warn "主要安装方法失败，尝试备用方法..."
      wget -O- https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1 || \
        { log_error "acme.sh 安装失败"; exit 1; }
      log_ok "acme.sh 安装成功（备用方法）"
    fi
  fi
  # 创建软链接，方便命令行直接调用
  ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true
  # 设置默认 CA
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  log_ok "ACME 客户端配置完成（CA: Let's Encrypt）"

  # [3] 交互式配置域名
  log_step "[3/11] 配置域名..."
  echo ""
  echo -e "${CYAN}请配置要申请 SSL 证书的域名:${RESET}"
  echo "  • 支持多个域名，空格分隔"
  echo "  • 确保域名已正确解析到本服务器"
  echo "  • 示例: example.com www.example.com"
  echo ""
  while true; do
    read -rp "请输入域名: " _domains_input
    if [[ -z "$_domains_input" ]]; then
      log_warn "域名不能为空，请重新输入"; continue
    fi
    read -ra M2_DOMAINS <<< "$_domains_input"
    M2_MAIN_DOMAIN="${M2_DOMAINS[0]}"
    # 域名格式检查 + DNS 解析检测
    for domain in "${M2_DOMAINS[@]}"; do
      if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
        log_warn "域名格式可能不正确: $domain"
      fi
      echo -n "  检查 DNS 解析: $domain ... "
      if nslookup "$domain" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${RESET}"
      else
        echo -e "${YELLOW}! (解析失败，但将继续)${RESET}"
      fi
    done
    echo ""
    echo -e "${GREEN}域名配置:${RESET}"
    echo "  主域名  : $M2_MAIN_DOMAIN"
    echo "  所有域名: ${M2_DOMAINS[*]}"
    echo ""
    echo "确认域名配置正确?"
    echo "  1) 确认 [默认]"
    echo "  2) 重新输入"
    read -rp "请选择 (1-2) [默认 1]: " _confirm
    _confirm="${_confirm:-1}"
    [[ "$_confirm" == "1" ]] && break
    echo ""
  done

  # [3续] 证书存放路径
  echo ""
  echo -e "${CYAN}请选择证书安装位置:${RESET}"
  echo "  1) /etc/ssl/private/  [默认]"
  echo "  2) /etc/nginx/ssl/"
  echo "  3) /etc/apache2/ssl/"
  echo "  4) /home/ssl/"
  echo "  5) 自定义路径"
  read -rp "请选择 (1-5) [默认 1]: " _path_choice
  _path_choice="${_path_choice:-1}"
  case "$_path_choice" in
    1) M2_CERT_PATH="/etc/ssl/private" ;;
    2) M2_CERT_PATH="/etc/nginx/ssl" ;;
    3) M2_CERT_PATH="/etc/apache2/ssl" ;;
    4) M2_CERT_PATH="/home/ssl" ;;
    5) while true; do
         read -rp "请输入自定义路径: " M2_CERT_PATH
         [[ -n "$M2_CERT_PATH" ]] && break
         log_warn "路径不能为空"
       done ;;
    *) log_warn "无效选择，使用默认路径"; M2_CERT_PATH="/etc/ssl/private" ;;
  esac
  mkdir -p "$M2_CERT_PATH" && chmod 755 "$M2_CERT_PATH"
  log_ok "证书目录: $M2_CERT_PATH"

  # [4] DNS 解析检测（已在域名配置时完成，此处仅打印）
  log_step "[4/11] DNS 解析已检测完毕"

  # [5] 检测并管理 80 端口（智能检测运行中的 Web 服务）
  log_step "[5/11] 检测并管理 Web 服务（80 端口）..."
  STOPPED_SERVICES=()
  local port_info=""
  command -v ss      &>/dev/null && port_info=$(ss -tlnp      | grep ":80 " || true)
  command -v netstat &>/dev/null && [[ -z "$port_info" ]] && \
    port_info=$(netstat -tlnp | grep ":80 " || true)

  if [[ -n "$port_info" ]]; then
    log_warn "检测到端口 80 被占用: $port_info"
    local found_services=()
    for svc in nginx apache2 httpd lighttpd caddy; do
      systemctl is-active --quiet "$svc" 2>/dev/null && found_services+=("$svc")
    done
    if [[ ${#found_services[@]} -gt 0 ]]; then
      echo -e "${YELLOW}发现运行中的 Web 服务: ${found_services[*]}${RESET}"
      echo -e "${CYAN}[说明] 首次申请证书需临时停止 Web 服务以占用 80 端口完成验证。"
      echo -e "       证书申请完成后将立即自动重启，后续自动续期无需手动干预。${RESET}"
      echo "  1) 停止并继续 [默认]"
      echo "  2) 不停止（证书申请可能失败）"
      read -rp "请选择 (1-2) [默认 1]: " _stop_choice
      _stop_choice="${_stop_choice:-1}"
      if [[ "$_stop_choice" == "1" ]]; then
        for svc in "${found_services[@]}"; do
          if systemctl stop "$svc"; then
            STOPPED_SERVICES+=("$svc")
            log_ok "已停止 $svc"
          else
            log_warn "停止 $svc 失败"
          fi
        done
        # 记录 Web 服务供 Hook 使用
        M2_WEBSERVER="${STOPPED_SERVICES[0]:-none}"
      else
        log_warn "用户选择不停止服务，证书申请可能失败"
        M2_WEBSERVER="none"
      fi
    else
      log_warn "端口 80 被占用，但未找到已知 Web 服务，将继续尝试"
      M2_WEBSERVER="none"
    fi
  else
    log_ok "端口 80 未被占用"
    M2_WEBSERVER="none"
  fi

  # [6] 申请证书（不使用 --force，避免消耗颁发限额）
  log_step "[6/11] 申请证书（standalone 模式）..."
  local domain_args=""
  for d in "${M2_DOMAINS[@]}"; do domain_args="$domain_args -d $d"; done
  echo -e "${YELLOW}域名: ${M2_DOMAINS[*]}${RESET}"
  echo "正在申请证书，请耐心等待..."
  if /root/.acme.sh/acme.sh --issue $domain_args --standalone; then
    log_ok "SSL 证书申请成功！"
  else
    log_error "SSL 证书申请失败，可能原因："
    log_error "  • 域名未正确解析到本服务器"
    log_error "  • 防火墙阻止 80 端口访问"
    log_error "  • Let's Encrypt 服务暂时不可用"
    # 恢复 Web 服务后退出
    for svc in "${STOPPED_SERVICES[@]}"; do
      systemctl start "$svc" 2>/dev/null || true
    done
    exit 1
  fi

  # [7] 安装证书到指定目录
  log_step "[7/11] 安装证书到 $M2_CERT_PATH..."
  local key_file="$M2_CERT_PATH/private.key"
  local cert_file="$M2_CERT_PATH/fullchain.cer"
  local ca_file="$M2_CERT_PATH/ca.cer"
  local reload_cmd="echo 'cert installed'"
  [[ "$M2_WEBSERVER" != "none" ]] && reload_cmd="systemctl reload $M2_WEBSERVER"

  if /root/.acme.sh/acme.sh --install-cert -d "$M2_MAIN_DOMAIN" \
      --key-file       "$key_file"  \
      --fullchain-file "$cert_file" \
      --ca-file        "$ca_file"   \
      --reloadcmd      "$reload_cmd"; then
    log_ok "证书文件已安装"
    # 设置安全权限
    chmod 600 "$key_file"  2>/dev/null || log_warn "设置私钥权限失败"
    chmod 644 "$cert_file" 2>/dev/null || log_warn "设置证书权限失败"
    chmod 644 "$ca_file"   2>/dev/null || log_warn "设置 CA 证书权限失败"
    chown root:root "$key_file" "$cert_file" "$ca_file" 2>/dev/null || true
    log_info "  私钥: $key_file"
    log_info "  证书: $cert_file"
    log_info "  CA  : $ca_file"
  else
    log_error "证书安装失败"; exit 1
  fi

  # [8] 配置 Pre/Post Hook（写入 acme.sh 域名配置文件，解决续期 80 端口冲突）
  log_step "[8/11] 配置续期 Pre/Post Hook..."
  if [[ "$M2_WEBSERVER" != "none" ]]; then
    local conf_file="/root/.acme.sh/${M2_MAIN_DOMAIN}/${M2_MAIN_DOMAIN}.conf"
    if [[ -f "$conf_file" ]]; then
      if ! grep -q "Le_PreHook" "$conf_file"; then
        echo "Le_PreHook='systemctl stop ${M2_WEBSERVER}'"  >> "$conf_file"
        echo "Le_PostHook='systemctl start ${M2_WEBSERVER}'" >> "$conf_file"
        log_ok "Pre/Post Hook 写入完成（续期自动停启 $M2_WEBSERVER）"
        log_info "  续期前: systemctl stop $M2_WEBSERVER"
        log_info "  续期后: systemctl start $M2_WEBSERVER"
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

  # [9] 设置 cron 自动续期（检查是否已存在，避免重复添加；检查旧版日志丢弃问题）
  log_step "[9/11] 设置 cron 自动续期..."
  local log_file="/var/log/acme-renew.log"
  local cron_job="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $log_file 2>&1"
  if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
    log_info "自动续期 cron 已存在，跳过"
    # 检查旧任务是否丢弃了日志
    if crontab -l 2>/dev/null | grep "acme.sh.*--cron" | grep -q "/dev/null"; then
      log_warn "检测到旧版续期任务日志被丢弃，建议手动更新 crontab："
      log_warn "  $cron_job"
    fi
  else
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab - 2>/dev/null
    if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
      log_ok "cron 已配置：每天 02:00 续期"
      log_info "续期日志: $log_file（可用 tail -f $log_file 实时查看）"
    else
      log_warn "cron 任务设置失败，请手动执行："
      log_warn "  (crontab -l 2>/dev/null; echo \"$cron_job\") | crontab -"
    fi
  fi

  # [10] 重启 Web 服务
  log_step "[10/11] 重启 Web 服务..."
  for svc in "${STOPPED_SERVICES[@]}"; do
    if systemctl start "$svc"; then
      sleep 2
      if systemctl is-active --quiet "$svc"; then
        log_ok "$svc 已重启并运行正常"
      else
        log_warn "$svc 状态异常，请检查: systemctl status $svc"
      fi
    else
      log_error "$svc 启动失败，请手动检查: systemctl status $svc"
    fi
  done
  [[ ${#STOPPED_SERVICES[@]} -eq 0 ]] && log_info "无需重启 Web 服务"

  # [11] 展示证书信息（--list 无副作用，替代 --force 测试）
  log_step "[11/11] 证书信息..."
  if [[ -f "$cert_file" ]]; then
    local expire_date; expire_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -n "$expire_date" ]] && log_info "证书有效期至: $expire_date"
  fi
  log_info "当前证书列表："
  /root/.acme.sh/acme.sh --list

  log_sep
  echo -e "${GREEN}"
  echo "  证书信息:"
  echo "    主域名: $M2_MAIN_DOMAIN"
  echo "    证书目录: $M2_CERT_PATH"
  echo "    私钥: $key_file"
  echo "    证书: $cert_file"
  echo ""
  echo "  Nginx 配置参考:"
  echo "    ssl_certificate     $cert_file;"
  echo "    ssl_certificate_key $key_file;"
  echo ""
  echo "  管理命令:"
  echo "    查看证书列表: acme.sh --list"
  echo "    手动续期:     acme.sh --renew -d $M2_MAIN_DOMAIN --force"
  echo "    查看续期日志: tail -f $log_file"
  echo -e "${RESET}"
  log_ok "✅ 模块 2 完成！"
  log_sep
}

# ══════════════════════════════════════════════
# 模块 3：安装 sing-box
# ══════════════════════════════════════════════
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

# ══════════════════════════════════════════════
# 模块 4：配置 sing-box
# ══════════════════════════════════════════════
module_4_config_singbox() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 4：配置 sing-box${RESET}"
  log_sep
  check_root

  ask "服务器域名或 IP" "" M4_DOMAIN

  local default_uuid; default_uuid=$(gen_uuid)
  ask "UUID（留空自动生成）" "$default_uuid" M4_UUID

  ask "anytls 端口"        "48790" M4_ANYTLS_PORT
  ask "vless 端口"         "47790" M4_VLESS_PORT
  ask "shadowsocks 端口"   "46790" M4_SS_PORT

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
  sing-box check -c /etc/sing-box/config.json && log_ok "配置语法检查通过" || \
    log_warn "配置语法检查失败，请检查参数"

  log_sep
  log_ok "✅ 模块 4 完成！"
  log_sep
}

# ══════════════════════════════════════════════
# 模块 5：服务管理
# ══════════════════════════════════════════════
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

# ══════════════════════════════════════════════
# 模块 6：生成节点链接
# ══════════════════════════════════════════════
module_6_links() {
  log_sep
  echo -e "${BOLD}${PURPLE}模块 6：生成节点链接${RESET}"
  log_sep

  [[ -z "$M4_DOMAIN" ]]       && ask "服务器域名/IP" ""      M4_DOMAIN
  [[ -z "$M4_UUID" ]]         && ask "UUID"           ""      M4_UUID
  [[ -z "$M4_SS_PASS" ]]      && ask "SS 密码"        ""      M4_SS_PASS
  [[ $M4_ANYTLS_PORT -eq 0 ]] && ask "anytls 端口"    "48790" M4_ANYTLS_PORT
  [[ $M4_VLESS_PORT  -eq 0 ]] && ask "vless 端口"     "47790" M4_VLESS_PORT
  [[ $M4_SS_PORT     -eq 0 ]] && ask "SS 端口"        "46790" M4_SS_PORT

  local SS_METHOD="2022-blake3-aes-128-gcm"
  local SS_B64; SS_B64=$(echo -n "${SS_METHOD}:${M4_SS_PASS}" | base64 -w 0)
  local TAG_ANYTLS="evoxt%28hk1%29-sb-anytls"
  local TAG_VLESS="evoxt%28hk1%29-sb-vision"
  local TAG_SS="evoxt%28hk1%29-sb-ss"

  local LINK_ANYTLS="anytls://${M4_UUID}@${M4_DOMAIN}:${M4_ANYTLS_PORT}?security=tls&sni=${M4_DOMAIN}&type=tcp#${TAG_ANYTLS}"
  local LINK_VLESS="vless://${M4_UUID}@${M4_DOMAIN}:${M4_VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${M4_DOMAIN}&fp=chrome&type=tcp&headerType=none#${TAG_VLESS}"
  local LINK_SS="ss://${SS_B64}@${M4_DOMAIN}:${M4_SS_PORT}#${TAG_SS}"

  log_sep
  echo -e "\n${BOLD}${GREEN}✅ 节点链接生成完成${RESET}\n"
  echo -e "${PURPLE}【anytls】${RESET}\n${BLUE}${LINK_ANYTLS}${RESET}\n"
  echo -e "${PURPLE}【vless】${RESET}\n${BLUE}${LINK_VLESS}${RESET}\n"
  echo -e "${PURPLE}【shadowsocks】${RESET}\n${BLUE}${LINK_SS}${RESET}\n"

  local outfile="/root/singbox_links_$(ts).txt"
  cat > "$outfile" << EOF
=== sing-box 节点链接 $(date) ===

[anytls]
${LINK_ANYTLS}

[vless]
${LINK_VLESS}

[shadowsocks]
${LINK_SS}
EOF
  log_ok "链接已保存至: $outfile"
  log_sep
}

# ══════════════════════════════════════════════
# 主入口
# ══════════════════════════════════════════════
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
