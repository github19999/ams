#!/usr/bin/env bash
# =============================================================================
# 服务器一键部署脚本 v4
# 用法: bash <(curl -sSL https://raw.githubusercontent.com/{用户名}/{仓库名}/main/setup.sh)
#
# ==============================================================================
# 本次优化内容 (v3 -> v4)
# ==============================================================================
#
# 【优化1 - UI 架构全面对齐 VPSBox】
#   参考来源: https://github.com/vmenzo/VPSBox
#   v3版: 日志、菜单、确认提示风格不统一，无居中标题，无等待回车设计
#   v4版: 完全移植 VPSBox UI 工具函数体系：
#         · clear_screen      —— 清屏兼容 dumb 终端
#         · get_term_width    —— 动态获取终端宽度（40~100 列）
#         · print_divider     —— 全宽 === 分隔线
#         · print_center      —— 文字居中输出（自动剥离 ANSI 颜色计算宽度）
#         · confirm_action    —— 统一二次确认提示，支持默认 y/n 可配置
#         · pause_for_enter   —— 操作完成后等待回车返回菜单
#
# 【优化2 - 服务管理函数统一，兼容 Alpine/apk 环境】
#   参考来源: VPSBox _svc_* 系列函数
#   v3版: 直接调用 systemctl，Alpine/OpenWRT 下失败
#   v4版: 引入 _svc_restart / _svc_start / _svc_stop / _svc_enable /
#         _svc_is_active / _svc_daemon_reload，
#         自动检测 apk 环境并回退到 service / rc-update 命令
#
# 【优化3 - 证书申请统一走 acquire_cert 函数（对齐 VPSBox）】
#   参考来源: VPSBox acquire_cert 函数（修复版 v1.3）
#   v3版: 模块2 使用独立申请逻辑；acme.sh 安装时传了禁止邮箱导致报错
#   v4版: 引入与 VPSBox 完全一致的 acquire_cert 函数：
#         · 按域名隔离证书目录 /etc/deploy-cert/{domain}/
#         · 支持 Cloudflare API 模式（dns_cf）和 standalone 80端口模式
#         · 申请前检测本地有效证书复用（物理文件 + SAN 双重校验）
#         · 失败后彻底清理残留，防止后续无限复用错误记录
#         · 证书文件统一为 fullchain.pem / privkey.pem
#         · acme.sh 安装不传邮箱，彻底规避 example.com 禁止域名问题
#
# 【优化4 - 模块4 证书路径智能同步，零重复交互】
#   v3版: 模块4 单独询问证书路径，与模块2填写的路径相互独立
#   v4版: 三级优先级静默同步：
#         1. 优先用模块2执行后的 M2_CERT_PATH（传统路径模式）
#         2. 次用 acquire_cert 写入的全局 CERT_DIR（VPSBox 路径模式）
#         3. 两者均无时才手动输入
#         · 模块4 不重新申请证书，只引用路径写入 config.json
#
# 【优化5 - 主菜单 Banner 和入口对齐 VPSBox curl|bash 兼容模式】
#   v3版: 主菜单简单，无 ASCII Logo，stdin 处理不完整
#   v4版: 新增 ASCII Logo，颜色定义提前，
#         结尾使用 VPSBox 同款 stdin 重定向逻辑兼容 curl|bash 管道模式
#
# 【优化6 - 模块6 节点链接输出增加 qrencode 二维码（需安装 qrencode）】
#   v3版: 仅文字输出链接和保存到文件
#   v4版: 每条节点链接额外用 qrencode -t UTF8 输出终端二维码，
#         手机扫码即可导入，对齐 VPSBox output_node_result 体验
#
# ==============================================================================

set -e

# ──────────────────────────────────────────────
# 颜色定义（对齐 VPSBox）
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# ──────────────────────────────────────────────
# 全局变量（供模块间共享）
# ──────────────────────────────────────────────
DISTRO_ID=""; DISTRO_VERSION=""; PKG_MANAGER=""
STOPPED_SERVICES=()
# 模块1
M1_PUBKEY=""; M1_SSH_PORT=43916; M1_IP_PRIORITY="ipv4"; M1_IP_DISABLE="none"
# 模块2（证书）
M2_DOMAINS=(); M2_MAIN_DOMAIN=""; M2_CERT_PATH=""; M2_WEBSERVER="none"
# 模块4（各协议独立变量）
M4_ANYTLS_PORT=48790; M4_ANYTLS_DOMAIN=""; M4_ANYTLS_UUID=""
M4_VLESS_PORT=47790;  M4_VLESS_DOMAIN="";  M4_VLESS_UUID=""
M4_SS_PORT=46790;     M4_SS_DOMAIN="";     M4_SS_PASS=""
M4_CERT_DIR=""

# ──────────────────────────────────────────────
# VPSBox 风格 UI 工具函数
# ──────────────────────────────────────────────
clear_screen() { [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ] && clear || printf '\n'; }

get_term_width() {
  local cols; cols=$(tput cols 2>/dev/null || echo 80)
  if [ "$cols" -gt 100 ]; then echo 100
  elif [ "$cols" -lt 40 ]; then echo 40
  else echo "$cols"; fi
}

print_divider() {
  local w; w=$(get_term_width)
  echo -e "${CYAN}$(printf '%*s' "$w" '' | tr ' ' '=')${NC}"
}

print_center() {
  local text="$1" color="$2" term_width plain_text text_len padding
  term_width=$(get_term_width)
  plain_text=$(printf '%b' "$text" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
  text_len=${#plain_text}
  padding=$(( (term_width - text_len) / 2 ))
  [ "$padding" -lt 0 ] && padding=0
  printf "%${padding}s" ""
  echo -e "${color}${text}${NC}"
}

pause_for_enter() {
  echo ""
  print_divider
  echo -ne "${YELLOW}> 操作已完成，请按 [回车键] 返回主菜单...${NC}"
  read -r
}

confirm_action() {
  local action_name="$1" default="${2:-y}" hint
  if [[ "$default" =~ ^[yY]$ ]]; then hint="Y/n"; else hint="y/N"; fi
  echo ""
  read -r -p "> 是否确认执行 [${action_name}]？(${hint}): " confirm
  confirm="${confirm// /}"
  [ -z "$confirm" ] && confirm="$default"
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo -e "\n${YELLOW}已取消 [${action_name}] 操作。${NC}"
    return 1
  fi
  return 0
}

ts() { date '+%Y%m%d_%H%M%S'; }

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_step()  { echo -e "${PURPLE}[STEP]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }

# ──────────────────────────────────────────────
# VPSBox 风格服务管理函数（兼容 apk/Alpine）
# ──────────────────────────────────────────────
_svc_restart() {
  if command -v apk &>/dev/null; then service "$1" restart
  else /bin/systemctl restart "$1"; fi
}
_svc_start() {
  if command -v apk &>/dev/null; then service "$1" start
  else /bin/systemctl start "$1"; fi
}
_svc_stop() {
  if command -v apk &>/dev/null; then service "$1" stop
  else /bin/systemctl stop "$1"; fi
}
_svc_enable() {
  if command -v apk &>/dev/null; then rc-update add "$1" default
  else /bin/systemctl enable "$1"; fi
}
_svc_is_active() {
  if command -v apk &>/dev/null; then timeout 5 service "$1" status &>/dev/null
  else timeout 5 /bin/systemctl is-active --quiet "$1" 2>/dev/null; fi
}
_svc_daemon_reload() {
  command -v apk &>/dev/null || /bin/systemctl daemon-reload 2>/dev/null
}

# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "\n${RED}[错误] 权限不足！请使用 root 用户运行。${NC}\n"
    exit 1
  fi
}

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID%%.*}"
  else
    log_error "无法识别操作系统，仅支持含 /etc/os-release 的发行版"; exit 1
  fi
  case "$DISTRO_ID" in
    ubuntu|debian|raspbian) PKG_MANAGER="apt" ;;
    centos|rhel|almalinux|rocky|fedora)
      PKG_MANAGER="yum"
      command -v dnf &>/dev/null && PKG_MANAGER="dnf" ;;
    alpine) PKG_MANAGER="apk" ;;
    *)
      log_warn "未经测试的发行版: $DISTRO_ID，将尝试使用 apt"
      PKG_MANAGER="apt" ;;
  esac
  log_info "检测到系统: ${PRETTY_NAME:-$DISTRO_ID}（包管理器: $PKG_MANAGER）"
}

# 预装基础组件
bootstrap_packages() {
  log_step "预装基础组件..."
  case "$PKG_MANAGER" in
    apt)
      apt-get update -y -q
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl sudo wget git unzip nano vim openssl ;;
    dnf)
      dnf install -y epel-release 2>/dev/null || true
      dnf install -y curl sudo wget git unzip nano vim openssl ;;
    yum)
      yum install -y epel-release 2>/dev/null || true
      yum install -y curl sudo wget git unzip nano vim openssl ;;
    apk)
      apk add curl sudo wget git unzip nano vim openssl ;;
    *)
      log_warn "未检测到已知包管理器，跳过预装"; return ;;
  esac
  log_ok "基础组件预装完成"
}

install_pkgs() {
  local pkgs=("$@")
  log_info "安装: ${pkgs[*]}"
  case "$PKG_MANAGER" in
    apt)     DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}" ;;
    dnf|yum) $PKG_MANAGER install -y "${pkgs[@]}" ;;
    apk)     apk add "${pkgs[@]}" ;;
  esac
}

backup_file() {
  local f="$1"
  [ -f "$f" ] && cp "$f" "${f}.bak.$(ts)" && log_info "已备份: ${f}.bak.$(ts)"
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
  local prompt="$1" default="${2:-}" var_name="$3" val=""
  if [ -n "$default" ]; then
    read -rp "> ${prompt} [默认: ${default}]: " val
    val="${val:-$default}"
  else
    while [ -z "$val" ]; do
      read -rp "> ${prompt}: " val
      [ -z "$val" ] && echo -e "${YELLOW}此项不能为空${NC}"
    done
  fi
  eval "$var_name='$val'"
}

# ──────────────────────────────────────────────
# 统一证书申请函数（对齐 VPSBox acquire_cert）
# 证书目录: /etc/deploy-cert/{domain}/
# 文件: fullchain.pem / privkey.pem
# ──────────────────────────────────────────────
CERT_DIR=""
acquire_cert() {
  local DOMAIN="$1" cert_mode="$2" CF_Token="$3"
  local acme_domain_dir="/root/.acme.sh/${DOMAIN}_ecc"

  _cert_matches_domain() {
    local cert_file="$1" domain="$2"
    [ -f "$cert_file" ] || return 1
    openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null \
      | grep -Eq "DNS:(\*\.)?${domain//./\\.}([,[:space:]]|$)"
  }

  CERT_DIR="/etc/deploy-cert/${DOMAIN}"
  mkdir -p "$CERT_DIR"

  # 安装 acme.sh（不传邮箱，规避 example.com 禁止域名问题）
  if [ ! -f /root/.acme.sh/acme.sh ]; then
    log_info "安装 acme.sh..."
    if curl https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1; then
      log_ok "acme.sh 安装完成"
    else
      wget -O- https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1 \
        || { echo -e "${RED}[错误] acme.sh 安装失败！${NC}"; return 1; }
      log_ok "acme.sh 安装完成（备用方法）"
    fi
  fi

  /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  echo -e "\n${CYAN}>>> 正在为 ${YELLOW}${DOMAIN}${CYAN} 申请 SSL 证书...${NC}"

  local CERT_RES=1

  # 检查本地是否已有有效证书
  if [ -d "$acme_domain_dir" ] && [ -f "$acme_domain_dir/${DOMAIN}.cer" ]; then
    if _cert_matches_domain "$CERT_DIR/fullchain.pem" "$DOMAIN"; then
      log_ok "检测到本地有效证书（域名匹配），直接复用"
      CERT_RES=0
    else
      log_warn "检测到 acme.sh 记录但目标目录证书不匹配，重新安装..."
    fi
  elif [ -d "$acme_domain_dir" ]; then
    log_warn "检测到损坏的历史证书记录，深度清理后重新申请..."
    /root/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1
    rm -rf "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"
  fi

  if [ "$CERT_RES" -ne 0 ]; then
    if [ "$cert_mode" = "1" ]; then
      export CF_Token="$CF_Token"
      /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf -k ec-256
      CERT_RES=$?
    else
      if ss -tlnp 2>/dev/null | grep -q ':80 '; then
        echo -e "\n${RED}[错误] 检测到 80 端口已被占用，请先手动释放或改用 Cloudflare API 模式。${NC}"
        ss -tlnp | grep ':80 ' || true
        return 1
      fi
      /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256
      CERT_RES=$?
    fi
  fi

  if [ "$CERT_RES" -ne 0 ]; then
    echo -e "\n${RED}[错误] 证书申请失败，彻底清理残留防止后续复用错误记录。${NC}"
    /root/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1
    rm -rf "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"
    rm -rf "$CERT_DIR"
    return 1
  fi

  log_info "安装证书到 ${CERT_DIR}..."
  local INSTALL_OUT; INSTALL_OUT=$(mktemp)
  if /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --fullchain-file "$CERT_DIR/fullchain.pem" \
      --key-file       "$CERT_DIR/privkey.pem" \
      >"$INSTALL_OUT" 2>&1; then
    cat "$INSTALL_OUT"; rm -f "$INSTALL_OUT"
    log_ok "证书已安装至 ${CERT_DIR}"
  else
    echo -e "${RED}[错误] 证书安装失败:${NC}"; cat "$INSTALL_OUT"; rm -f "$INSTALL_OUT"
    rm -rf "$CERT_DIR"; return 1
  fi

  # 验证证书有效性
  if ! openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -dates >/dev/null 2>&1; then
    echo -e "${RED}[错误] 证书文件无效${NC}"; rm -rf "$CERT_DIR"; return 1
  fi
  if ! _cert_matches_domain "$CERT_DIR/fullchain.pem" "$DOMAIN"; then
    echo -e "${RED}[错误] 证书 SAN 与域名不匹配: ${DOMAIN}${NC}"; rm -rf "$CERT_DIR"; return 1
  fi

  chmod 755 "$CERT_DIR"
  chmod 644 "$CERT_DIR"/*.pem
  chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null \
    || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null || true
  return 0
}

# ══════════════════════════════════════════════
# 模块 1：基础安全加固
# ══════════════════════════════════════════════
module_1_security() {
  clear_screen; print_divider
  print_center "[ 模块 1：服务器基础安全加固 ]" "$PURPLE"
  print_divider

  check_root

  # [1] 预装基础工具
  log_step "[1/12] 检查 root 权限 ✓"
  log_step "[2/12] 预装基础组件..."
  bootstrap_packages
  detect_distro

  # [3][4] 收集用户配置（所有交互集中在执行前完成）
  log_step "[3/12] 检测发行版完成: ${PRETTY_NAME:-$DISTRO_ID}"
  log_step "[4/12] 收集配置参数..."
  echo ""

  # SSH 公钥
  echo -e "${CYAN}请输入你的 SSH 公钥（以 ssh-ed25519 / ssh-rsa / ecdsa-sha2 开头）:${NC}"
  while true; do
    read -r -p "> SSH 公钥: " M1_PUBKEY
    if [ -z "$M1_PUBKEY" ]; then echo -e "${YELLOW}公钥不能为空，请重新输入${NC}"; continue; fi
    if ! echo "$M1_PUBKEY" | grep -Eq '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519)'; then
      log_warn "公钥格式可能不正确，但继续执行..."
    fi
    break
  done

  # SSH 端口
  echo ""
  read -r -p "> SSH 端口 (建议 10000-65535，默认 43916): " M1_SSH_PORT
  M1_SSH_PORT="${M1_SSH_PORT:-43916}"
  if ! [[ "$M1_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$M1_SSH_PORT" -lt 1024 ] || [ "$M1_SSH_PORT" -gt 65535 ]; then
    log_warn "端口无效，使用默认值 43916"; M1_SSH_PORT=43916
  fi
  log_info "将使用 SSH 端口: $M1_SSH_PORT"

  # IP 协议优先级
  echo ""
  echo -e "${CYAN}IP 协议优先级:${NC}"
  echo "  1) IPv4 优先（推荐）"
  echo "  2) IPv6 优先"
  echo "  3) 保持不变"
  read -r -p "> 请输入选择 (1-3，默认 1): " _ip_prio
  case "${_ip_prio:-1}" in
    1) M1_IP_PRIORITY="ipv4"; log_info "将设置 IPv4 优先" ;;
    2) M1_IP_PRIORITY="ipv6"; log_info "将设置 IPv6 优先" ;;
    3) M1_IP_PRIORITY="none"; log_info "保持 IP 协议优先级不变" ;;
    *) log_warn "无效选择，使用默认 IPv4 优先"; M1_IP_PRIORITY="ipv4" ;;
  esac

  # IP 协议禁用（默认保持不变，防止误操作断连）
  echo ""
  echo -e "${CYAN}IP 协议禁用:${NC}"
  echo "  1) 禁用 IPv6"
  echo "  2) 禁用 IPv4（危险）"
  echo "  3) 保持不变（默认）"
  read -r -p "> 请输入选择 (1-3，默认 3): " _ip_dis
  case "${_ip_dis:-3}" in
    1) M1_IP_DISABLE="ipv6"; log_info "将禁用 IPv6" ;;
    2) M1_IP_DISABLE="ipv4"
       log_warn "⚠️  禁用 IPv4 可能导致服务器完全无法访问！"
       read -r -p "> 确认要禁用 IPv4 吗？(y/N): " _confirm
       if [[ ! "${_confirm,,}" == "y" ]]; then
         log_info "已取消禁用 IPv4"; M1_IP_DISABLE="none"
       fi ;;
    3) M1_IP_DISABLE="none"; log_info "保持 IP 协议状态不变" ;;
    *) log_warn "无效选择，保持不变"; M1_IP_DISABLE="none" ;;
  esac

  if ! confirm_action "开始执行安全加固"; then pause_for_enter; return; fi

  echo ""
  log_info "开始执行配置，请稍候..."
  echo ""

  # [5] 安装 fail2ban
  log_step "[5/12] 安装 fail2ban..."
  case "$PKG_MANAGER" in
    apt) apt-get install -y fail2ban || log_warn "fail2ban 安装失败，后续步骤将重试" ;;
    dnf|yum) $PKG_MANAGER install -y fail2ban || log_warn "fail2ban 安装失败" ;;
    apk) apk add fail2ban || log_warn "fail2ban 安装失败" ;;
  esac

  # [6] 启用 BBR
  log_step "[6/12] 启用 BBR 拥塞控制..."
  local current_cc; current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [ "$current_cc" = "bbr" ]; then
    log_info "BBR 已启用，跳过"
  else
    local kver; kver=$(uname -r | cut -d. -f1-2 | tr -d '.')
    if [ "$kver" -lt 49 ] 2>/dev/null; then
      log_warn "内核版本低于 4.9，BBR 不受支持，跳过"
    else
      grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || \
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
      grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
      sysctl -p > /dev/null 2>&1
      sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr" \
        && log_ok "BBR 启用成功" \
        || log_warn "BBR 可能未生效，请确认内核已加载 tcp_bbr 模块"
    fi
  fi

  # [7] IP 协议优先级
  log_step "[7/12] 设置 IP 协议优先级..."
  if [ "$M1_IP_PRIORITY" = "none" ]; then
    log_info "跳过 IP 协议优先级设置"
  elif [ ! -f /etc/gai.conf ]; then
    log_warn "/etc/gai.conf 不存在，跳过"
  else
    backup_file /etc/gai.conf
    if [ "$M1_IP_PRIORITY" = "ipv4" ]; then
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
  if [ "$M1_IP_DISABLE" = "none" ]; then
    log_info "跳过 IP 协议禁用"
  else
    mkdir -p /etc/sysctl.d
    if [ "$M1_IP_DISABLE" = "ipv6" ]; then
      local ipv6_conf="/etc/sysctl.d/99-disable-ipv6.conf"
      if [ -f "$ipv6_conf" ]; then
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
      [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ] \
        && log_ok "IPv6 已成功禁用" \
        || log_warn "IPv6 禁用需重启后完全生效"
    elif [ "$M1_IP_DISABLE" = "ipv4" ]; then
      local ipv4_conf="/etc/sysctl.d/99-disable-ipv4.conf"
      [ ! -f "$ipv4_conf" ] && cat > "$ipv4_conf" << 'EOF'
# IPv4 disabled by deploy script
net.ipv4.conf.all.disable_ipv4=1
net.ipv4.conf.default.disable_ipv4=1
EOF
      log_warn "IPv4 禁用配置已写入，重启后生效（请确保有 IPv6 连接方式）"
    fi
  fi

  # [9] 配置 SSH 密钥
  log_step "[9/12] 配置 SSH 密钥登录..."
  mkdir -p /root/.ssh; chmod 700 /root/.ssh; chown root:root /root/.ssh
  if ! grep -qF "$M1_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "$M1_PUBKEY" >> /root/.ssh/authorized_keys
    log_ok "SSH 公钥已追加写入（未覆盖已有密钥）"
  else
    log_info "该公钥已存在，跳过"
  fi
  chmod 600 /root/.ssh/authorized_keys
  chown root:root /root/.ssh/authorized_keys
  # 修复 SELinux 上下文（CentOS/RHEL）
  command -v restorecon &>/dev/null && restorecon -Rv /root/.ssh/ > /dev/null 2>&1 \
    && log_info "SELinux 上下文已修复"

  # [10] SSH 安全加固
  log_step "[10/12] SSH 安全加固..."
  local sshd_conf="/etc/ssh/sshd_config"
  backup_file "$sshd_conf"

  # 辅助：精确替换或追加 sshd_config 参数
  _sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "$sshd_conf"; then
      sed -i -E "s|^#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$sshd_conf"
    else
      echo "${key} ${val}" >> "$sshd_conf"
    fi
  }

  _sshd_set "PubkeyAuthentication"           "yes"
  _sshd_set "AuthorizedKeysFile"             ".ssh/authorized_keys"
  _sshd_set "PermitRootLogin"                "prohibit-password"
  _sshd_set "PasswordAuthentication"         "no"
  _sshd_set "ChallengeResponseAuthentication" "no"
  _sshd_set "KbdInteractiveAuthentication"   "no"
  # 修改 SSH 端口（注释旧端口，追加新端口）
  sed -i 's/^Port[[:space:]]/#Port /' "$sshd_conf"
  grep -q "^Port $M1_SSH_PORT" "$sshd_conf" || echo "Port $M1_SSH_PORT" >> "$sshd_conf"

  log_info "SSH 配置完成（端口: $M1_SSH_PORT，已禁用密码登录，已启用公钥认证）"
  log_warn "如果密码登录仍可用，请检查 UsePAM 设置"

  # 语法检查
  if ! sshd -t 2>&1; then
    log_error "SSH 配置语法错误，请检查 /etc/ssh/sshd_config"
    log_error "备份文件在: /etc/ssh/sshd_config.bak.*"
    pause_for_enter; return
  fi
  log_ok "sshd 配置语法验证通过"

  # [11] 配置 fail2ban
  log_step "[11/12] 配置 fail2ban..."
  if ! command -v fail2ban-server &>/dev/null; then
    log_warn "fail2ban 未安装，再次尝试..."
    case "$PKG_MANAGER" in
      apt) apt-get install -y fail2ban ;;
      dnf|yum) $PKG_MANAGER install -y fail2ban ;;
      apk) apk add fail2ban ;;
    esac
  fi

  if command -v fail2ban-server &>/dev/null; then
    local f2b_backend="auto" f2b_logpath=""
    if _svc_is_active systemd-journald 2>/dev/null; then
      f2b_backend="systemd"
    else
      for lp in /var/log/auth.log /var/log/secure; do
        [ -f "$lp" ] && f2b_logpath="logpath = $lp" && break
      done
      [ -z "$f2b_logpath" ] && f2b_logpath="logpath = /var/log/auth.log"
    fi

    _svc_stop fail2ban 2>/dev/null || true
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
    _svc_enable fail2ban
    _svc_start fail2ban
    _svc_is_active fail2ban 2>/dev/null \
      && log_ok "fail2ban 启动成功（maxretry=1, bantime=-1 永久封禁）" \
      || log_warn "fail2ban 启动失败，查看日志: journalctl -u fail2ban --no-pager -n 30"
  fi

  # [12] 重启 SSH 服务（兼容 sshd / ssh 两种服务名）
  log_step "[12/12] 重启 SSH 服务..."
  if _svc_is_active sshd 2>/dev/null; then
    _svc_restart sshd
  elif _svc_is_active ssh 2>/dev/null; then
    _svc_restart ssh
  else
    _svc_restart sshd 2>/dev/null || _svc_restart ssh 2>/dev/null || \
      { log_error "无法重启 SSH 服务"; pause_for_enter; return; }
  fi
  log_ok "SSH 服务已重启"

  print_divider
  echo -e "\n${GREEN}  配置总结："
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
  echo -e "${NC}"

  pause_for_enter
}

# ══════════════════════════════════════════════
# 模块 2：SSL 证书申请与安装
# ══════════════════════════════════════════════
module_2_ssl() {
  clear_screen; print_divider
  print_center "[ 模块 2：SSL 证书申请与安装 ]" "$PURPLE"
  print_divider

  check_root
  detect_distro

  # [1] 安装依赖（按系统区分 cron 服务名）
  log_step "[1/9] 安装系统依赖..."
  if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl wget socat cron openssl ca-certificates
    _svc_enable cron  2>/dev/null && _svc_start cron  2>/dev/null || true
  elif [ "$PKG_MANAGER" = "apk" ]; then
    apk add curl wget socat openssl dcron
    _svc_enable dcron 2>/dev/null && _svc_start dcron 2>/dev/null || true
  else
    $PKG_MANAGER install -y curl wget socat cronie openssl ca-certificates
    _svc_enable crond 2>/dev/null && _svc_start crond 2>/dev/null || true
  fi
  log_ok "依赖安装完成"

  # [2] 安装/更新 acme.sh（不传邮箱，规避 example.com 禁止域名问题）
  log_step "[2/9] 安装/更新 acme.sh..."
  if [ -f /root/.acme.sh/acme.sh ]; then
    /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
    log_ok "acme.sh 已更新"
  else
    if curl https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1; then
      log_ok "acme.sh 安装成功"
    else
      log_warn "主要安装方法失败，尝试备用..."
      wget -O- https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1 \
        || { log_error "acme.sh 安装失败"; pause_for_enter; return; }
      log_ok "acme.sh 安装成功（备用方法）"
    fi
  fi
  ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  log_ok "ACME 客户端配置完成（CA: Let's Encrypt）"

  # [3] 交互式配置域名
  log_step "[3/9] 配置域名..."
  echo ""
  echo -e "${CYAN}请配置要申请 SSL 证书的域名:${NC}"
  echo "  · 支持多个域名，空格分隔"
  echo "  · 确保域名已正确解析到本服务器"
  echo ""
  while true; do
    read -r -p "> 请输入域名: " _domains_input
    if [ -z "$_domains_input" ]; then log_warn "域名不能为空，请重新输入"; continue; fi
    read -ra M2_DOMAINS <<< "$_domains_input"
    M2_MAIN_DOMAIN="${M2_DOMAINS[0]}"
    for domain in "${M2_DOMAINS[@]}"; do
      printf "  检查 DNS 解析: %s ... " "$domain"
      if nslookup "$domain" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
      else
        echo -e "${YELLOW}! (解析失败，但将继续)${NC}"
      fi
    done
    echo ""
    echo -e "${GREEN}域名配置:${NC}"
    echo "  主域名  : $M2_MAIN_DOMAIN"
    echo "  所有域名: ${M2_DOMAINS[*]}"
    echo ""
    echo "  1) 确认 [默认]"
    echo "  2) 重新输入"
    read -r -p "> 请选择 (1-2) [默认 1]: " _confirm
    [ "${_confirm:-1}" = "1" ] && break
    echo ""
  done

  # 证书存放路径
  echo ""
  echo -e "${CYAN}请选择证书安装位置:${NC}"
  echo "  1) /etc/deploy-cert/{domain}/  [默认，推荐]"
  echo "  2) /etc/ssl/private/"
  echo "  3) /etc/nginx/ssl/"
  echo "  4) /etc/apache2/ssl/"
  echo "  5) 自定义路径"
  read -r -p "> 请选择 (1-5) [默认 1]: " _path_choice
  case "${_path_choice:-1}" in
    1) M2_CERT_PATH="/etc/deploy-cert/${M2_MAIN_DOMAIN}" ;;
    2) M2_CERT_PATH="/etc/ssl/private" ;;
    3) M2_CERT_PATH="/etc/nginx/ssl" ;;
    4) M2_CERT_PATH="/etc/apache2/ssl" ;;
    5) while true; do
         read -r -p "> 请输入自定义路径: " M2_CERT_PATH
         [ -n "$M2_CERT_PATH" ] && break
         log_warn "路径不能为空"
       done ;;
    *) log_warn "无效选择，使用默认路径"; M2_CERT_PATH="/etc/deploy-cert/${M2_MAIN_DOMAIN}" ;;
  esac
  mkdir -p "$M2_CERT_PATH" && chmod 755 "$M2_CERT_PATH"
  log_ok "证书目录: $M2_CERT_PATH"

  # 证书申请模式
  echo ""
  echo -e "${CYAN}证书申请模式:${NC}"
  echo "  1) 【standalone 模式】使用 80 端口申请（需 80 端口空闲）[默认]"
  echo "  2) 【Cloudflare API 模式】使用 CF DNS 验证申请（推荐，无需占用端口）"
  read -r -p "> 请选择 (1-2) [默认 1]: " _cert_mode
  _cert_mode="${_cert_mode:-1}"
  local _cf_token=""
  if [ "$_cert_mode" = "2" ]; then
    read -r -s -p "> 请输入 Cloudflare API Token: " _cf_token
    echo ""
    if [ -z "$_cf_token" ]; then
      log_warn "CF Token 为空，回退到 standalone 模式"
      _cert_mode=1
    fi
  fi

  if ! confirm_action "开始申请并安装 SSL 证书"; then pause_for_enter; return; fi

  # 检测并管理 80 端口（仅 standalone 模式）
  STOPPED_SERVICES=()
  if [ "$_cert_mode" = "1" ]; then
    log_step "[4/9] 检测并管理 Web 服务（80 端口）..."
    local port_info=""
    command -v ss      &>/dev/null && port_info=$(ss -tlnp | grep ":80 " || true)
    command -v netstat &>/dev/null && [ -z "$port_info" ] && \
      port_info=$(netstat -tlnp | grep ":80 " || true)

    if [ -n "$port_info" ]; then
      log_warn "检测到端口 80 被占用: $port_info"
      local found_services=()
      for svc in nginx apache2 httpd lighttpd caddy; do
        _svc_is_active "$svc" 2>/dev/null && found_services+=("$svc")
      done
      if [ ${#found_services[@]} -gt 0 ]; then
        echo -e "${YELLOW}发现运行中的 Web 服务: ${found_services[*]}${NC}"
        echo -e "${CYAN}[说明] 首次申请证书需临时停止 Web 服务以占用 80 端口完成验证。"
        echo -e "       证书申请完成后将立即自动重启，后续自动续期无需手动干预。${NC}"
        echo "  1) 停止并继续 [默认]"
        echo "  2) 不停止（证书申请可能失败）"
        read -r -p "> 请选择 (1-2) [默认 1]: " _stop_choice
        if [ "${_stop_choice:-1}" = "1" ]; then
          for svc in "${found_services[@]}"; do
            _svc_stop "$svc" && STOPPED_SERVICES+=("$svc") && log_ok "已停止 $svc" \
              || log_warn "停止 $svc 失败"
          done
          M2_WEBSERVER="${STOPPED_SERVICES[0]:-none}"
        else
          log_warn "用户选择不停止服务，证书申请可能失败"
          M2_WEBSERVER="none"
        fi
      else
        log_warn "端口 80 被占用但未找到已知 Web 服务，将继续尝试"
        M2_WEBSERVER="none"
      fi
    else
      log_ok "端口 80 未被占用"
      M2_WEBSERVER="none"
    fi
  else
    log_step "[4/9] Cloudflare API 模式，无需检测 80 端口"
    M2_WEBSERVER="none"
  fi

  # 申请证书（使用 acquire_cert）
  log_step "[5/9] 申请证书..."
  echo -e "${YELLOW}域名: ${M2_DOMAINS[*]}${NC}"

  # 针对多域名情况，主域名使用 acquire_cert，其余作为 SAN 附加
  # acquire_cert 只处理单域名，多域名时手动调用 acme.sh
  if [ ${#M2_DOMAINS[@]} -eq 1 ]; then
    if ! acquire_cert "$M2_MAIN_DOMAIN" "$_cert_mode" "$_cf_token"; then
      for svc in "${STOPPED_SERVICES[@]}"; do _svc_start "$svc" 2>/dev/null || true; done
      pause_for_enter; return
    fi
    # acquire_cert 已将证书安装到 /etc/deploy-cert/{domain}/
    # 如果用户选择了其他路径，复制过去
    if [ "$M2_CERT_PATH" != "/etc/deploy-cert/${M2_MAIN_DOMAIN}" ]; then
      cp "$CERT_DIR/fullchain.pem" "$M2_CERT_PATH/fullchain.cer"
      cp "$CERT_DIR/privkey.pem"   "$M2_CERT_PATH/private.key"
      log_info "已复制证书到: $M2_CERT_PATH"
    else
      # 创建标准名称软链接，兼容 sing-box 等工具的默认路径
      ln -sf "$CERT_DIR/fullchain.pem" "$M2_CERT_PATH/fullchain.cer" 2>/dev/null || true
      ln -sf "$CERT_DIR/privkey.pem"   "$M2_CERT_PATH/private.key"   2>/dev/null || true
    fi
  else
    # 多域名模式：直接调用 acme.sh
    log_info "多域名模式，直接调用 acme.sh..."
    CERT_DIR="$M2_CERT_PATH"
    local domain_args=""
    for d in "${M2_DOMAINS[@]}"; do domain_args="$domain_args -d $d"; done
    local cert_res=0
    if [ "$_cert_mode" = "2" ]; then
      export CF_Token="$_cf_token"
      /root/.acme.sh/acme.sh --issue $domain_args --dns dns_cf -k ec-256 || cert_res=$?
    else
      /root/.acme.sh/acme.sh --issue $domain_args --standalone -k ec-256 || cert_res=$?
    fi
    if [ "$cert_res" -ne 0 ]; then
      log_error "证书申请失败"
      for svc in "${STOPPED_SERVICES[@]}"; do _svc_start "$svc" 2>/dev/null || true; done
      pause_for_enter; return
    fi
    mkdir -p "$M2_CERT_PATH"
    /root/.acme.sh/acme.sh --install-cert -d "$M2_MAIN_DOMAIN" --ecc \
      --fullchain-file "$M2_CERT_PATH/fullchain.pem" \
      --key-file       "$M2_CERT_PATH/privkey.pem"
    # 标准名称链接
    ln -sf "$M2_CERT_PATH/fullchain.pem" "$M2_CERT_PATH/fullchain.cer" 2>/dev/null || true
    ln -sf "$M2_CERT_PATH/privkey.pem"   "$M2_CERT_PATH/private.key"   2>/dev/null || true
  fi

  log_ok "证书文件已安装"
  # 设置权限
  chmod 600 "$M2_CERT_PATH/privkey.pem"   2>/dev/null || true
  chmod 644 "$M2_CERT_PATH/fullchain.pem" 2>/dev/null || true

  # [6] Pre/Post Hook 配置（解决续期时 80 端口冲突）
  log_step "[6/9] 配置续期 Pre/Post Hook..."
  if [ "$M2_WEBSERVER" != "none" ] && [ "$_cert_mode" = "1" ]; then
    local conf_file="/root/.acme.sh/${M2_MAIN_DOMAIN}/${M2_MAIN_DOMAIN}.conf"
    # ECC 证书路径
    [ ! -f "$conf_file" ] && conf_file="/root/.acme.sh/${M2_MAIN_DOMAIN}_ecc/${M2_MAIN_DOMAIN}.conf"
    if [ -f "$conf_file" ]; then
      if ! grep -q "Le_PreHook" "$conf_file"; then
        echo "Le_PreHook='_svc_stop ${M2_WEBSERVER}'"  >> "$conf_file"
        echo "Le_PostHook='_svc_start ${M2_WEBSERVER}'" >> "$conf_file"
        log_ok "Pre/Post Hook 写入完成（续期自动停启 $M2_WEBSERVER）"
      else
        log_info "Hook 已存在，跳过写入"
      fi
    else
      log_warn "未找到 acme.sh 配置文件，请手动添加续期 Hook"
    fi
  else
    log_info "无 Web 服务或 CF API 模式，无需配置 Hook"
  fi

  # [7] 设置 cron 自动续期
  log_step "[7/9] 设置 cron 自动续期..."
  local log_file="/var/log/acme-renew.log"
  local cron_job="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $log_file 2>&1"
  if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
    log_info "续期 cron 已存在，跳过"
    # 检查旧任务是否丢弃了日志
    if crontab -l 2>/dev/null | grep "acme.sh.*--cron" | grep -q "/dev/null"; then
      log_warn "检测到旧版续期任务丢弃日志，建议手动更新 crontab："
      log_warn "  $cron_job"
    fi
  else
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab - 2>/dev/null
    crontab -l 2>/dev/null | grep -q "acme.sh.*--cron" \
      && log_ok "cron 已配置：每天 02:00 续期，日志写入 $log_file" \
      || log_warn "cron 任务设置失败，请手动执行：(crontab -l 2>/dev/null; echo \"$cron_job\") | crontab -"
  fi

  # [8] 重启 Web 服务
  log_step "[8/9] 重启 Web 服务..."
  for svc in "${STOPPED_SERVICES[@]}"; do
    if _svc_start "$svc"; then
      sleep 2
      _svc_is_active "$svc" 2>/dev/null \
        && log_ok "$svc 已重启并运行正常" \
        || log_warn "$svc 状态异常，请检查: systemctl status $svc"
    else
      log_error "$svc 启动失败，请手动检查: systemctl status $svc"
    fi
  done
  [ ${#STOPPED_SERVICES[@]} -eq 0 ] && log_info "无需重启 Web 服务"

  # [9] 展示证书信息
  log_step "[9/9] 证书信息..."
  local cert_check_file="$M2_CERT_PATH/fullchain.pem"
  [ ! -f "$cert_check_file" ] && cert_check_file="$M2_CERT_PATH/fullchain.cer"
  if [ -f "$cert_check_file" ]; then
    local expire_date; expire_date=$(openssl x509 -in "$cert_check_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$expire_date" ] && log_info "证书有效期至: $expire_date"
  fi
  log_info "当前证书列表:"
  /root/.acme.sh/acme.sh --list

  print_divider
  echo -e "\n${GREEN}  证书信息:"
  echo "    主域名   : $M2_MAIN_DOMAIN"
  echo "    证书目录 : $M2_CERT_PATH"
  echo "    私钥     : $M2_CERT_PATH/privkey.pem (或 private.key)"
  echo "    证书     : $M2_CERT_PATH/fullchain.pem (或 fullchain.cer)"
  echo ""
  echo "  Nginx 配置参考:"
  echo "    ssl_certificate     $M2_CERT_PATH/fullchain.pem;"
  echo "    ssl_certificate_key $M2_CERT_PATH/privkey.pem;"
  echo ""
  echo "  管理命令:"
  echo "    查看证书列表: acme.sh --list"
  echo "    手动续期:     acme.sh --renew -d $M2_MAIN_DOMAIN --ecc --force"
  echo "    查看续期日志: tail -f $log_file"
  echo -e "${NC}"

  pause_for_enter
}

# ══════════════════════════════════════════════
# 模块 3：安装 sing-box
# ══════════════════════════════════════════════
module_3_install_singbox() {
  clear_screen; print_divider
  print_center "[ 模块 3：安装 sing-box ]" "$PURPLE"
  print_divider

  check_root
  echo -e "\n${YELLOW}将执行官方安装脚本:"
  echo -e "  bash <(curl -fsSL https://sing-box.app/deb-install.sh)${NC}\n"

  if ! confirm_action "安装 sing-box"; then pause_for_enter; return; fi

  log_step "执行官方安装脚本..."
  bash <(curl -fsSL https://sing-box.app/deb-install.sh)

  log_step "重启 sing-box 服务..."
  _svc_restart sing-box

  log_step "检查服务状态..."
  systemctl status sing-box --no-pager 2>/dev/null \
    || _svc_is_active sing-box && log_ok "sing-box 运行中"

  pause_for_enter
}

# ══════════════════════════════════════════════
# 模块 4：配置 sing-box
# ══════════════════════════════════════════════
module_4_config_singbox() {
  clear_screen; print_divider
  print_center "[ 模块 4：配置 sing-box ]" "$PURPLE"
  print_divider
  check_root

  # ── anytls 配置 ──────────────────────────────
  echo ""
  echo -e "${CYAN}── anytls 配置 ─────────────────────────────${NC}"
  ask "anytls 端口" "48790" M4_ANYTLS_PORT
  ask "anytls 服务器域名或 IP" "" M4_ANYTLS_DOMAIN
  local _uuid1; _uuid1=$(gen_uuid)
  read -rp "> anytls UUID [默认: 随机生成]: " _anytls_uuid_input
  if [ -z "$_anytls_uuid_input" ]; then
    M4_ANYTLS_UUID="$_uuid1"
    log_info "已生成 UUID: $M4_ANYTLS_UUID"
  else
    M4_ANYTLS_UUID="$_anytls_uuid_input"
  fi

  # ── vless 配置 ───────────────────────────────
  echo ""
  echo -e "${CYAN}── vless 配置 ──────────────────────────────${NC}"
  ask "vless 端口" "47790" M4_VLESS_PORT
  ask "vless 服务器域名或 IP" "" M4_VLESS_DOMAIN
  local _uuid2; _uuid2=$(gen_uuid)
  read -rp "> vless UUID [默认: 随机生成]: " _vless_uuid_input
  if [ -z "$_vless_uuid_input" ]; then
    M4_VLESS_UUID="$_uuid2"
    log_info "已生成 UUID: $M4_VLESS_UUID"
  else
    M4_VLESS_UUID="$_vless_uuid_input"
  fi

  # ── shadowsocks 配置 ─────────────────────────
  echo ""
  echo -e "${CYAN}── shadowsocks 配置 ────────────────────────${NC}"
  ask "shadowsocks 端口" "46790" M4_SS_PORT
  ask "shadowsocks 服务器域名或 IP" "" M4_SS_DOMAIN
  local _ss_default; _ss_default=$(gen_ss_pass)
  read -rp "> SS 密码 [默认: 随机生成]: " _ss_pass_input
  if [ -z "$_ss_pass_input" ]; then
    M4_SS_PASS="$_ss_default"
    log_info "已生成 SS 密码: $M4_SS_PASS"
  else
    M4_SS_PASS="$_ss_pass_input"
  fi

  # ── 证书配置 ─────────────────────────────────
  echo ""
  echo -e "${CYAN}── 证书配置 ────────────────────────────────${NC}"
  # 若模块2已执行（M2_CERT_PATH 有值），完全静默同步，零交互
  # 若未执行模块2才手动输入（模块4只引用路径，不重复申请证书）
  if [ -n "$M2_CERT_PATH" ]; then
    M4_CERT_DIR="${M2_CERT_PATH%/}/"
    log_info "证书路径已从模块2同步: $M4_CERT_DIR（如需修改请重新执行模块2）"
  elif [ -n "$CERT_DIR" ]; then
    M4_CERT_DIR="${CERT_DIR%/}/"
    log_info "证书路径已从 acquire_cert 同步: $M4_CERT_DIR"
  else
    ask "证书目录路径" "/etc/ssl/private/" M4_CERT_DIR
    M4_CERT_DIR="${M4_CERT_DIR%/}/"
  fi

  if ! confirm_action "生成并写入 sing-box 配置"; then pause_for_enter; return; fi

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
        { "password": "${M4_ANYTLS_UUID}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${M4_ANYTLS_DOMAIN}",
        "certificate_path": "${M4_CERT_DIR}fullchain.pem",
        "key_path": "${M4_CERT_DIR}privkey.pem"
      }
    },
    {
      "type": "vless",
      "tag": "evoxt(hk1)-sb-vision",
      "listen": "::",
      "listen_port": ${M4_VLESS_PORT},
      "users": [
        { "uuid": "${M4_VLESS_UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${M4_VLESS_DOMAIN}",
        "certificate_path": "${M4_CERT_DIR}fullchain.pem",
        "key_path": "${M4_CERT_DIR}privkey.pem"
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
  sing-box check -c /etc/sing-box/config.json \
    && log_ok "配置语法检查通过" \
    || log_warn "配置语法检查失败，请检查参数（证书路径是否存在？）"

  pause_for_enter
}

# ══════════════════════════════════════════════
# 模块 5：sing-box 服务管理
# ══════════════════════════════════════════════
module_5_service() {
  clear_screen; print_divider
  print_center "[ 模块 5：sing-box 服务管理 ]" "$PURPLE"
  print_divider

  check_root
  echo -e "\n${YELLOW}将执行以下命令:"
  echo "  systemctl restart sing-box"
  echo "  systemctl status  sing-box"
  echo "  systemctl enable  sing-box"
  echo -e "  systemctl is-enabled sing-box${NC}\n"

  if ! confirm_action "执行服务管理"; then pause_for_enter; return; fi

  log_step "重启 sing-box..."
  _svc_restart sing-box

  log_step "查看状态..."
  systemctl status sing-box --no-pager 2>/dev/null || true

  log_step "设置开机自启..."
  _svc_enable sing-box
  local enabled; enabled=$(systemctl is-enabled sing-box 2>/dev/null || echo "unknown")
  log_ok "开机自启: $enabled"

  pause_for_enter
}

# ══════════════════════════════════════════════
# 模块 6：生成节点链接
# ══════════════════════════════════════════════
module_6_links() {
  clear_screen; print_divider
  print_center "[ 模块 6：生成节点链接 ]" "$PURPLE"
  print_divider
  echo ""

  # 各协议独立补充未填参数（若模块4已执行则直接使用，否则逐项询问）
  echo -e "${CYAN}── anytls 参数 ─────────────────────────────${NC}"
  [ "$M4_ANYTLS_PORT" -eq 0 ] 2>/dev/null && ask "anytls 端口"          "48790" M4_ANYTLS_PORT
  [ -z "$M4_ANYTLS_DOMAIN" ]  && ask "anytls 服务器域名/IP" ""          M4_ANYTLS_DOMAIN
  if [ -z "$M4_ANYTLS_UUID" ]; then
    read -rp "> anytls UUID [默认: 随机生成]: " _in
    M4_ANYTLS_UUID="${_in:-$(gen_uuid)}"
  fi

  echo ""
  echo -e "${CYAN}── vless 参数 ──────────────────────────────${NC}"
  [ "$M4_VLESS_PORT" -eq 0 ] 2>/dev/null && ask "vless 端口"            "47790" M4_VLESS_PORT
  [ -z "$M4_VLESS_DOMAIN" ]   && ask "vless 服务器域名/IP"  ""          M4_VLESS_DOMAIN
  if [ -z "$M4_VLESS_UUID" ]; then
    read -rp "> vless UUID [默认: 随机生成]: " _in
    M4_VLESS_UUID="${_in:-$(gen_uuid)}"
  fi

  echo ""
  echo -e "${CYAN}── shadowsocks 参数 ────────────────────────${NC}"
  [ "$M4_SS_PORT" -eq 0 ] 2>/dev/null && ask "shadowsocks 端口"        "46790" M4_SS_PORT
  [ -z "$M4_SS_DOMAIN" ]      && ask "shadowsocks 服务器域名/IP" ""     M4_SS_DOMAIN
  if [ -z "$M4_SS_PASS" ]; then
    read -rp "> SS 密码 [默认: 随机生成]: " _in
    M4_SS_PASS="${_in:-$(gen_ss_pass)}"
  fi

  local SS_METHOD="2022-blake3-aes-128-gcm"
  local SS_B64; SS_B64=$(echo -n "${SS_METHOD}:${M4_SS_PASS}" | base64 -w 0)
  local TAG_ANYTLS="evoxt%28hk1%29-sb-anytls"
  local TAG_VLESS="evoxt%28hk1%29-sb-vision"
  local TAG_SS="evoxt%28hk1%29-sb-ss"

  local LINK_ANYTLS="anytls://${M4_ANYTLS_UUID}@${M4_ANYTLS_DOMAIN}:${M4_ANYTLS_PORT}?security=tls&sni=${M4_ANYTLS_DOMAIN}&type=tcp#${TAG_ANYTLS}"
  local LINK_VLESS="vless://${M4_VLESS_UUID}@${M4_VLESS_DOMAIN}:${M4_VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${M4_VLESS_DOMAIN}&fp=chrome&type=tcp&headerType=none#${TAG_VLESS}"
  local LINK_SS="ss://${SS_B64}@${M4_SS_DOMAIN}:${M4_SS_PORT}#${TAG_SS}"

  print_divider
  echo -e "\n${GREEN}✅ 节点链接生成完成${NC}\n"

  echo -e "${PURPLE}【anytls】${NC}"
  echo -e "${CYAN}${LINK_ANYTLS}${NC}\n"
  if command -v qrencode &>/dev/null; then
    echo -e "${YELLOW}>>> 扫码导入 anytls 节点:${NC}"
    qrencode -t UTF8 -s 1 -m 2 "$LINK_ANYTLS"
  fi

  echo -e "${PURPLE}【vless】${NC}"
  echo -e "${CYAN}${LINK_VLESS}${NC}\n"
  if command -v qrencode &>/dev/null; then
    echo -e "${YELLOW}>>> 扫码导入 vless 节点:${NC}"
    qrencode -t UTF8 -s 1 -m 2 "$LINK_VLESS"
  fi

  echo -e "${PURPLE}【shadowsocks】${NC}"
  echo -e "${CYAN}${LINK_SS}${NC}\n"
  if command -v qrencode &>/dev/null; then
    echo -e "${YELLOW}>>> 扫码导入 shadowsocks 节点:${NC}"
    qrencode -t UTF8 -s 1 -m 2 "$LINK_SS"
  fi

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

  pause_for_enter
}

# ══════════════════════════════════════════════
# 菜单辅助：列对齐双列输出（参考 VPSBox menu_pair）
# ══════════════════════════════════════════════
_display_width() {
  local text="$1" chars bytes cjk
  chars=${#text}
  bytes=$(printf "%s" "$text" | wc -c | tr -d ' ')
  cjk=$(( (bytes - chars) / 2 ))
  echo $(( chars + cjk ))
}

menu_pair() {
  local l_no="$1" l_title="$2" r_no="$3" r_title="$4"
  local left_plain left_width pad right_col=40
  left_plain=$(printf "%2s. %s" "$l_no" "$l_title")
  left_width=$(_display_width "$left_plain")
  pad=$(( right_col - 2 - left_width ))
  [ "$pad" -lt 2 ] && pad=2
  printf "  ${GREEN}%2s${NC}. %s%*s${GREEN}%2s${NC}. %s\n"     "$l_no" "$l_title" "$pad" "" "$r_no" "$r_title"
}

# ══════════════════════════════════════════════
# 主菜单
# ══════════════════════════════════════════════
show_menu() {
  clear_screen
  print_divider
  echo -e "${PURPLE}"
  cat << 'BANNER'
  ____             _             _____           _
 |  _ \  ___ _ __ | | ___  _   |_   _|__   ___ | |
 | | | |/ _ \ '_ \| |/ _ \| | | || |/ _ \ / _ \| |
 | |_| |  __/ |_) | | (_) | |_| || | (_) | (_) | |
 |____/ \___| .__/|_|\___/ \__, ||_|\___/ \___/|_|
            |_|            |___/
BANNER
  echo -e "${NC}"
  print_center "服务器一键部署工具  ·  v4" "$CYAN"
  print_divider
  echo ""

  echo -e "  ${CYAN}部署流程${NC}"
  menu_pair 1 "基础安全加固（SSH/fail2ban/BBR）" 2 "SSL 证书申请与安装"
  menu_pair 3 "安装 sing-box"                    4 "配置 sing-box"
  menu_pair 5 "sing-box 服务管理"                6 "生成节点链接"

  echo ""
  echo -e "  ${GREEN} 7${NC}. ${GREEN}── 全部执行（1→6）──${NC}"
  echo ""
  print_divider
  echo -e "  ${GREEN} 0${NC}. 退出"
  echo ""
}

# ══════════════════════════════════════════════
# 主入口
# ══════════════════════════════════════════════
main() {
  check_root
  while true; do
    show_menu
    read -r -p "> 请选择 [0-7]: " choice
    choice="${choice// /}"
    [ -z "$choice" ] && continue
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
        clear_screen; print_divider
        print_center "🎉 全部模块执行完毕！" "$GREEN"
        print_divider
        echo ""
        pause_for_enter ;;
      0) echo -e "\n${GREEN}[感谢使用] 正在退出...${NC}\n"; exit 0 ;;
      *) echo -e "\n${YELLOW}[提示] 编号不存在，请重新输入。${NC}"; sleep 1 ;;
    esac
  done
}

# 仅在 stdin 非终端但存在可交互 tty 时切回 /dev/tty（对齐 VPSBox）
if [ ! -t 0 ] && [ -r /dev/tty ] && [ -t 1 ]; then
  main </dev/tty
else
  main
fi
