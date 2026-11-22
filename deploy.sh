#!/usr/bin/env bash
#
# WebStack Deploy：Debian 服务器初始化与网站部署脚本
# 项目地址：https://github.com/Xrotor-dev/webstack-deploy
#
# 首次运行（初始化服务器）：bash deploy.sh
# 初始化完成后添加网站：    deploy
# 查看全部命令：            deploy help
#
# 本脚本不会安装任何数据库服务（MySQL、MariaDB 等）。

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.0.0"
PROJECT_URL="https://github.com/Xrotor-dev/webstack-deploy"
UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/Xrotor-dev/webstack-deploy/main/deploy.sh}"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 可通过环境变量设置的参数（完整说明见 README）
# ---------------------------------------------------------------------------
if [[ -n "${LE_EMAIL+x}" ]]; then LE_EMAIL_PRESET=1; else LE_EMAIL_PRESET=0; fi
LE_EMAIL="${LE_EMAIL:-}"
LE_STAGING="${LE_STAGING:-0}"
DOMAIN="${DOMAIN:-}"
WITH_WWW="${WITH_WWW:-}"
SITE_TYPE="${SITE_TYPE:-}"
PHP_VERSION="${PHP_VERSION:-}"
PHP_EXTENSIONS="${PHP_EXTENSIONS:-}"
PROXY_TARGET="${PROXY_TARGET:-}"
WEBROOT="${WEBROOT:-}"
SWAP_SIZE="${SWAP_SIZE:-}"
SWAPFILE="${SWAPFILE:-/swapfile}"
SWAPPINESS="${SWAPPINESS:-10}"
SSH_PORT="${SSH_PORT:-}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-}"
FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-}"
WWW_SHORTCUT="${WWW_SHORTCUT:-1}"
ADD_FIRST_SITE="${ADD_FIRST_SITE:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
REQUIRE_DNS_MATCH="${REQUIRE_DNS_MATCH:-0}"
RUN_RENEW_DRY_RUN="${RUN_RENEW_DRY_RUN:-0}"
ALLOW_UNSUPPORTED="${ALLOW_UNSUPPORTED:-0}"

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
CONFIG_DIR="/etc/webstack-deploy"
CONFIG_FILE="${CONFIG_DIR}/config"
STATE_DIR="/var/lib/webstack-deploy"
ACME_DIR="${STATE_DIR}/acme"
BACKUP_DIR="${STATE_DIR}/backup"
LOG_FILE="/var/log/webstack-deploy.log"
INSTALL_DIR="/usr/local/lib/webstack-deploy"
INSTALLED_SCRIPT="${INSTALL_DIR}/deploy.sh"
BIN_DIR="/usr/local/bin"
WWW_BASE="/var/www"
WWW_LINK="/root/www"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_SNIPPETS="/etc/nginx/snippets"
NGINX_CONF_D="/etc/nginx/conf.d"
NGINX_LOG_DIR="/var/log/nginx"
LE_DIR="/etc/letsencrypt"
LE_LOG="/var/log/letsencrypt/letsencrypt.log"
F2B_JAIL_FILE="/etc/fail2ban/jail.d/99-webstack.local"
F2B_FILTER_DIR="/etc/fail2ban/filter.d"
SYSCTL_SWAP_FILE="/etc/sysctl.d/99-webstack-swap.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
SSHD_PORT_FILE="${SSHD_CONFIG_DIR}/00-webstack-port.conf"
SSHD_RUN_DIR="/run/sshd"
FSTAB_FILE="/etc/fstab"
PHP_ETC_DIR="/etc/php"
APT_SOURCES_LIST="/etc/apt/sources.list"
APT_SOURCES_DIR="/etc/apt/sources.list.d"
SURY_LIST_FILE="${APT_SOURCES_DIR}/php-sury.list"
SURY_KEYRING="/usr/share/keyrings/debsuryorg-archive-keyring.gpg"

APT_OPTIONS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------------------------------------------------------------------------
# 运行时状态
# ---------------------------------------------------------------------------
SCRIPT_SOURCE="$(readlink -f -- "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
COLOR_OUT=0
COLOR_ERR=0
LOG_READY=0
TTY_STATE=""
VALIDATION_ERROR=""
APT_UPDATED=0
KV_WIDTH=14

OS_ID=""
OS_VERSION=""
OS_CODENAME=""
OS_PRETTY=""
MEM_TOTAL_MB=0
DISK_AVAIL_MB=0
SSH_PORTS="22"
CURRENT_SSH_PORT="22"
SSH_PORT_CHANGED=0
SSH_OLD_PORT=""
HAS_IPV6=0
NGINX_VERSION="0"

CFG_LE_EMAIL=""
CFG_FAIL2BAN="0"
CFG_PHP_VERSION=""

SWAP_MB=0
SWAP_NOTE=""
RECOMMENDED_SWAP_MB=0
WANT_FIRST_SITE=0

SITE_CONF=""
SITE_LINK=""
SERVER_NAMES=""
SITE_EXISTS=0
SITE_BACKUP=""
SITE_BACKUP_DONE=0
SITE_WAS_ENABLED=0
WEBROOT_EXISTS=0
WEBROOT_CREATED=0
DNS_CHECKED=0
DNS_DEFERRED=0
META_TYPE=""
META_WWW=""
META_PHP=""
META_ROOT=""
META_PROXY=""

# ---------------------------------------------------------------------------
# 输出与日志
# ---------------------------------------------------------------------------
setup_colors() {
  if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then COLOR_OUT=1; fi
  if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then COLOR_ERR=1; fi
}

paint() {
  # paint <是否着色> <颜色代码> <文本>
  if [[ "$1" == 1 ]]; then
    printf '\033[%sm%s\033[0m' "$2" "$3"
  else
    printf '%s' "$3"
  fi
}

write_log() {
  if [[ "$LOG_READY" == 1 ]]; then
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

info() {
  printf '%s %s\n' "$(paint "$COLOR_OUT" '1;32' '[信息]')" "$*"
  write_log 信息 "$*"
}

warn() {
  printf '%s %s\n' "$(paint "$COLOR_ERR" '1;33' '[警告]')" "$*" >&2
  write_log 警告 "$*"
}

error_msg() {
  printf '%s %s\n' "$(paint "$COLOR_ERR" '1;31' '[错误]')" "$*" >&2
  write_log 错误 "$*"
}

die() {
  error_msg "$*"
  exit 1
}

section() {
  printf '\n%s\n' "$(paint "$COLOR_OUT" '1' "=== $* ===")"
  write_log 步骤 "$*"
}

init_log() {
  if touch "$LOG_FILE" 2>/dev/null; then
    chmod 0640 "$LOG_FILE" 2>/dev/null || true
    LOG_READY=1
    printf '\n===== %s webstack-deploy v%s：%s =====\n' "$(date '+%F %T')" "$SCRIPT_VERSION" "$1" >> "$LOG_FILE"
  fi
}

# 计算终端显示宽度：中文字符和全角标点占 2 列（UTF-8 下每个占 3 字节）
display_width() {
  # shellcheck disable=SC2034
  local LC_ALL=C
  local text="$1" wide
  wide="${text//[ -~]/}"
  printf '%d' $(( ${#text} - ${#wide} / 3 ))
}

pad() {
  local text="$1" width="$2" current
  current="$(display_width "$text")"
  printf '%s%*s' "$text" $(( width > current ? width - current : 0 )) ''
}

kv() {
  printf '  %s%s\n' "$(pad "$1" "$KV_WIDTH")" "$2"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

join_lines() {
  printf '%s' "$1" | paste -sd ' ' -
}

on_error() {
  local code=$? line="$1" cmd="$2"
  trap - ERR
  if (( BASH_SUBSHELL > 0 )); then
    exit "$code"
  fi
  error_msg "命令执行失败（第 ${line} 行，退出码 ${code}）：${cmd}"
  if [[ "$LOG_READY" == 1 ]]; then
    printf '运行日志：%s\n' "$LOG_FILE" >&2
  fi
  exit "$code"
}

on_interrupt() {
  printf '\n' >&2
  warn "操作已中断。"
  exit 130
}

# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------
is_true() {
  case "${1,,}" in
    1|y|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

# 把变量的值规范化为 1 或 0；空值保持为空；无法识别时报错退出
normalize_bool_var() {
  local name="$1" value="${!1:-}"
  case "${value,,}" in
    '') ;;
    1|y|yes|true|on) printf -v "$name" '1' ;;
    0|n|no|false|off) printf -v "$name" '0' ;;
    *) die "${name} 的值无效：${value}（可用值：1 或 0）" ;;
  esac
}

# 是否能真正打开终端（cron、cloud-init 等环境下返回假）
has_tty() {
  if [[ -z "$TTY_STATE" ]]; then
    if { true </dev/tty; } 2>/dev/null; then TTY_STATE=1; else TTY_STATE=0; fi
  fi
  [[ "$TTY_STATE" == 1 ]]
}

# ASSUME_YES=1 时不提问，全部使用默认值
can_prompt() {
  ! is_true "$ASSUME_YES" && has_tty
}

read_tty() {
  # read_tty <变量名> <提示>
  local __answer
  printf '%s' "$2" >/dev/tty
  if ! IFS= read -r __answer </dev/tty; then
    printf '\n' >/dev/tty
    die "无法读取终端输入。"
  fi
  printf -v "$1" '%s' "$(trim "$__answer")"
}

ask_yes_no() {
  # ask_yes_no <变量名> <问题> <默认值 y|n>；结果写入变量（1 或 0）
  local __var="$1" __question="$2" __default="$3" __hint __reply
  if [[ "$__default" == y ]]; then __hint='Y/n'; else __hint='y/N'; fi
  if ! can_prompt; then
    if [[ "$__default" == y ]]; then printf -v "$__var" '1'; else printf -v "$__var" '0'; fi
    return 0
  fi
  while true; do
    read_tty __reply "${__question} [${__hint}] "
    if [[ -z "$__reply" ]]; then __reply="$__default"; fi
    case "${__reply,,}" in
      y|yes|是) printf -v "$__var" '1'; return 0 ;;
      n|no|否) printf -v "$__var" '0'; return 0 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

# 确认后继续；不能交互时直接继续
confirm_or_exit() {
  local answer
  if ! can_prompt; then
    return 0
  fi
  printf '\n' >/dev/tty
  ask_yes_no answer "$1" y
  if [[ "$answer" != 1 ]]; then
    info "已取消，未做任何修改。"
    exit 0
  fi
}

# 有风险的操作：默认“否”；ASSUME_YES=1 视为同意；无终端且未设置 ASSUME_YES 时退出
confirm_risky() {
  local answer
  if is_true "$ASSUME_YES"; then
    return 0
  fi
  if ! has_tty; then
    die "该操作需要确认。非交互模式下请设置 ASSUME_YES=1。"
  fi
  printf '\n' >/dev/tty
  ask_yes_no answer "$1" n
  [[ "$answer" == 1 ]]
}

# resolve_value <变量名> <提示> <默认值> <校验函数> [允许留空 0|1]
# 变量已有值时只做校验；否则交互输入；不能交互时使用默认值
resolve_value() {
  local __var="$1" __prompt="$2" __default="$3" __check="$4" __optional="${5:-0}" __input
  if [[ -n "${!__var:-}" ]]; then
    "$__check" "$__var" || die "$VALIDATION_ERROR"
    return 0
  fi
  if ! can_prompt; then
    if [[ -z "$__default" && "$__optional" != 1 ]]; then
      die "缺少 ${__var}：非交互模式下请通过环境变量提供。"
    fi
    printf -v "$__var" '%s' "$__default"
    "$__check" "$__var" || die "$VALIDATION_ERROR"
    return 0
  fi
  while true; do
    if [[ -n "$__default" ]]; then
      read_tty __input "${__prompt} [${__default}]："
    else
      read_tty __input "${__prompt}："
    fi
    printf -v "$__var" '%s' "${__input:-$__default}"
    if "$__check" "$__var"; then
      return 0
    fi
    warn "$VALIDATION_ERROR"
    printf -v "$__var" '%s' ''
  done
}

# ---------------------------------------------------------------------------
# 输入校验：成功时把变量规范化后返回 0，失败时设置 VALIDATION_ERROR 并返回 1
# ---------------------------------------------------------------------------
validate_domain() {
  local __var="$1" __d __label
  local -a __labels
  __d="$(trim "${!1:-}")"
  __d="${__d,,}"
  __d="${__d#http://}"
  __d="${__d#https://}"
  __d="${__d%%/*}"
  __d="${__d%.}"
  if [[ -z "$__d" ]]; then
    VALIDATION_ERROR="域名不能为空。"
    return 1
  fi
  if [[ "$__d" == *:* ]]; then
    VALIDATION_ERROR="域名不能包含端口号：${__d}"
    return 1
  fi
  if [[ ! "$__d" =~ ^[a-z0-9.-]+$ ]]; then
    VALIDATION_ERROR="域名只能包含字母、数字、连字符和点；中文域名请填写 Punycode 格式（以 xn-- 开头）：${__d}"
    return 1
  fi
  if (( ${#__d} > 253 )); then
    VALIDATION_ERROR="域名过长：${__d}"
    return 1
  fi
  IFS='.' read -r -a __labels <<< "$__d"
  if (( ${#__labels[@]} < 2 )); then
    VALIDATION_ERROR="请输入完整域名，例如 example.com：${__d}"
    return 1
  fi
  for __label in "${__labels[@]}"; do
    if [[ ! "$__label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
      VALIDATION_ERROR="域名格式不正确：${__d}"
      return 1
    fi
  done
  if [[ "${__labels[-1]}" =~ ^[0-9]+$ ]]; then
    VALIDATION_ERROR="请输入域名，而不是 IP 地址：${__d}"
    return 1
  fi
  printf -v "$__var" '%s' "$__d"
}

validate_email() {
  local __var="$1" __e
  __e="$(trim "${!1:-}")"
  if [[ -z "$__e" ]]; then
    printf -v "$__var" '%s' ''
    return 0
  fi
  if [[ ! "$__e" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    VALIDATION_ERROR="邮箱格式不正确：${__e}"
    return 1
  fi
  printf -v "$__var" '%s' "$__e"
}

validate_swap_size() {
  local __var="$1" __raw __num __unit __mb
  __raw="$(trim "${!1:-}")"
  __raw="${__raw,,}"
  __raw="${__raw%b}"
  if [[ ! "$__raw" =~ ^([0-9]+)([mg]?)$ ]]; then
    VALIDATION_ERROR="Swap 大小格式不正确：${!1}（示例：0、512、1024、2G）"
    return 1
  fi
  __num=$(( 10#${BASH_REMATCH[1]} ))
  __unit="${BASH_REMATCH[2]}"
  if [[ "$__unit" == g ]]; then __mb=$(( __num * 1024 )); else __mb=$__num; fi
  if (( __mb != 0 && __mb < 128 )); then
    VALIDATION_ERROR="Swap 至少需要 128 MB（输入 0 表示不创建）。"
    return 1
  fi
  if (( __mb > 0 && DISK_AVAIL_MB > 0 && __mb > DISK_AVAIL_MB / 2 )); then
    VALIDATION_ERROR="Swap 不能超过磁盘可用空间的一半（当前最多 $(( DISK_AVAIL_MB / 2 )) MB）。"
    return 1
  fi
  printf -v "$__var" '%s' "$__mb"
}

validate_site_type() {
  local __var="$1" __t
  __t="$(trim "${!1:-}")"
  __t="${__t,,}"
  case "$__t" in
    1|static|html|静态|静态网站) __t=static ;;
    2|php) __t=php ;;
    3|proxy|反向代理|反代) __t=proxy ;;
    *)
      VALIDATION_ERROR="网站类型无效：${!1}（可选：1 静态网站、2 PHP 网站、3 反向代理）"
      return 1
      ;;
  esac
  printf -v "$__var" '%s' "$__t"
}

validate_proxy_target() {
  local __var="$1" __t __port
  __t="$(trim "${!1:-}")"
  __t="${__t,,}"
  if [[ "$__t" == https://* ]]; then
    VALIDATION_ERROR="暂不支持 https 后端，请填写 http 地址或端口号。"
    return 1
  fi
  __t="${__t#http://}"
  __t="${__t%/}"
  if [[ "$__t" =~ ^[0-9]+$ ]]; then
    __t="127.0.0.1:${__t}"
  fi
  if [[ ! "$__t" =~ ^(\[[0-9a-f:]+\]|[a-z0-9.-]+):([0-9]+)$ ]]; then
    VALIDATION_ERROR="后端地址格式不正确：${!1}（示例：3000、127.0.0.1:3000）"
    return 1
  fi
  __port=$(( 10#${BASH_REMATCH[2]} ))
  if (( __port < 1 || __port > 65535 )); then
    VALIDATION_ERROR="端口号必须在 1 到 65535 之间：${!1}"
    return 1
  fi
  printf -v "$__var" '%s' "$__t"
}

validate_webroot() {
  local __var="$1" __p
  __p="$(trim "${!1:-}")"
  __p="${__p%/}"
  if [[ ! "$__p" =~ ^/[A-Za-z0-9._/-]+$ || "$__p" == *..* ]]; then
    VALIDATION_ERROR="网站目录必须是绝对路径，且只能包含字母、数字和 . _ - /：${!1}"
    return 1
  fi
  case "$__p" in
    /etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/root|/root/*|/var|/var/lib|/var/lib/*|/var/www)
      VALIDATION_ERROR="不能使用这个目录作为网站目录：${__p}"
      return 1
      ;;
  esac
  printf -v "$__var" '%s' "$__p"
}

validate_php_version() {
  local __var="$1" __v
  __v="$(trim "${!1:-}")"
  __v="${__v,,}"
  __v="${__v#php}"
  if [[ ! "$__v" =~ ^8\.[0-9]+$ ]]; then
    VALIDATION_ERROR="PHP 版本无效：${!1}（示例：8.3、8.4）"
    return 1
  fi
  printf -v "$__var" '%s' "$__v"
}

validate_php_extensions() {
  local __var="$1" __list __ext
  local -a __exts=()
  __list="${!1:-}"
  __list="${__list//,/ }"
  read -r -a __exts <<< "$__list"
  for __ext in "${__exts[@]}"; do
    if [[ ! "$__ext" =~ ^[a-z0-9_-]+$ ]]; then
      VALIDATION_ERROR="PHP_EXTENSIONS 中的扩展名无效：${__ext}（示例：mysql sqlite3 redis）"
      return 1
    fi
  done
  printf -v "$__var" '%s' "${__exts[*]}"
}

validate_ssh_port() {
  local __var="$1" __port
  __port="$(trim "${!1:-}")"
  if [[ ! "$__port" =~ ^[0-9]{1,5}$ ]] || (( 10#$__port < 1 || 10#$__port > 65535 )); then
    VALIDATION_ERROR="SSH 端口必须是 1 到 65535 之间的数字：${!1}"
    return 1
  fi
  __port=$(( 10#$__port ))
  case "$__port" in
    80|443)
      VALIDATION_ERROR="端口 ${__port} 用于网站访问，请换一个端口。"
      return 1
      ;;
  esac
  if [[ ",${SSH_PORTS}," != *",${__port},"* ]] && command -v ss >/dev/null 2>&1 && port_listening "$__port"; then
    VALIDATION_ERROR="端口 ${__port} 已被其他程序占用，请换一个端口。"
    return 1
  fi
  printf -v "$__var" '%s' "$__port"
}

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "请使用 root 用户运行（可以先执行 sudo -i 切换到 root）。"
  fi
}

check_os() {
  local os_info
  # shellcheck disable=SC1091
  os_info="$(. /etc/os-release 2>/dev/null; printf '%s|%s|%s|%s' "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" "${PRETTY_NAME:-未知系统}")" || os_info=""
  IFS='|' read -r OS_ID OS_VERSION OS_CODENAME OS_PRETTY <<< "$os_info"

  case "${OS_ID}:${OS_VERSION}" in
    debian:12|debian:13) ;;
    *)
      if is_true "$ALLOW_UNSUPPORTED"; then
        warn "当前系统为 ${OS_PRETTY:-未知系统}，本脚本只在 Debian 12/13 上测试过。已设置 ALLOW_UNSUPPORTED=1，继续执行。"
      else
        die "本脚本只支持 Debian 12 和 13，当前系统：${OS_PRETTY:-未知系统}（确需继续可设置 ALLOW_UNSUPPORTED=1）。"
      fi
      ;;
  esac

  if ! command -v systemctl >/dev/null 2>&1; then
    die "未检测到 systemd，本脚本需要通过 systemd 管理服务。"
  fi
}

detect_hardware() {
  local swap_dir
  swap_dir="$(dirname "$SWAPFILE")"
  MEM_TOTAL_MB="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)" || MEM_TOTAL_MB=0
  DISK_AVAIL_MB="$(df -Pm "$swap_dir" 2>/dev/null | awk 'NR == 2 {print $4}')" || DISK_AVAIL_MB=0
  if [[ ! "$MEM_TOTAL_MB" =~ ^[0-9]+$ ]]; then MEM_TOTAL_MB=0; fi
  if [[ ! "$DISK_AVAIL_MB" =~ ^[0-9]+$ ]]; then DISK_AVAIL_MB=0; fi
}

detect_ssh_ports() {
  local ports=""
  if command -v sshd >/dev/null 2>&1; then
    mkdir -p "$SSHD_RUN_DIR" 2>/dev/null || true
    ports="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | paste -sd ',' -)" || ports=""
  fi
  SSH_PORTS="${ports:-22}"
  CURRENT_SSH_PORT="${SSH_PORTS%%,*}"
}

detect_ipv6() {
  if [[ -s /proc/net/if_inet6 ]]; then HAS_IPV6=1; else HAS_IPV6=0; fi
}

has_global_ipv6() {
  awk '$4 == "00" {found = 1} END {exit !found}' /proc/net/if_inet6 2>/dev/null
}

detect_nginx_version() {
  NGINX_VERSION="$(nginx -v 2>&1 | sed -n 's|^.*nginx/\([0-9][0-9.]*\).*$|\1|p')" || NGINX_VERSION=""
  if [[ -z "$NGINX_VERSION" ]]; then NGINX_VERSION="0"; fi
}

# version_ge A B：A >= B 时返回真
version_ge() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]
}

preflight() {
  require_root
  init_log "$1"
  check_os
  detect_hardware
  detect_ssh_ports
  detect_ipv6
  if is_initialized; then
    load_config
  fi
}

# ---------------------------------------------------------------------------
# 配置文件
# ---------------------------------------------------------------------------
is_initialized() {
  [[ -f "$CONFIG_FILE" ]]
}

load_config() {
  local key value
  if [[ ! -r "$CONFIG_FILE" ]]; then
    die "未找到配置文件 ${CONFIG_FILE}，请先运行 bash deploy.sh 完成初始化。"
  fi
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      ''|'#'*) continue ;;
    esac
    if [[ ! "$value" =~ ^[A-Za-z0-9@._%+-]*$ ]]; then
      warn "配置项 ${key} 包含无效字符，已忽略。"
      continue
    fi
    case "$key" in
      LE_EMAIL) CFG_LE_EMAIL="$value" ;;
      ENABLE_FAIL2BAN) CFG_FAIL2BAN="$value" ;;
      PHP_VERSION) CFG_PHP_VERSION="$value" ;;
    esac
  done < "$CONFIG_FILE"
  if is_true "$CFG_FAIL2BAN"; then CFG_FAIL2BAN=1; else CFG_FAIL2BAN=0; fi
}

save_config() {
  local tmp
  install -d -m 0755 "$CONFIG_DIR"
  tmp="$(mktemp)"
  {
    printf '# 由 webstack-deploy 生成，供 deploy 命令读取。\n'
    printf 'LE_EMAIL=%s\n' "$CFG_LE_EMAIL"
    printf 'ENABLE_FAIL2BAN=%s\n' "$CFG_FAIL2BAN"
    printf 'PHP_VERSION=%s\n' "$CFG_PHP_VERSION"
  } > "$tmp"
  install -m 0600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 通用文件与软件包操作
# ---------------------------------------------------------------------------
# write_file <路径> [权限]：从标准输入读取内容，内容不变时不改写
write_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 0
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

# 原子替换文件（用于替换正在运行的脚本）
install_file_atomic() {
  local src="$1" dest="$2" mode="$3"
  install -d -m 0755 "$(dirname "$dest")"
  install -m "$mode" "$src" "${dest}.new"
  mv -f "${dest}.new" "$dest"
}

apt_run() {
  apt-get "${APT_OPTIONS[@]}" "$@"
}

pkg_installed() {
  local status
  # shellcheck disable=SC2016
  status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || status=""
  [[ "$status" == "install ok installed" ]]
}

pkg_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

# 只安装尚未安装的软件包
install_packages() {
  local pkg
  local -a missing=()
  for pkg in "$@"; do
    if ! pkg_installed "$pkg"; then missing+=("$pkg"); fi
  done
  if (( ${#missing[@]} == 0 )); then
    return 0
  fi
  if [[ "$APT_UPDATED" != 1 ]]; then
    apt_run update
    APT_UPDATED=1
  fi
  info "安装软件包：${missing[*]}"
  apt_run install -y --no-install-recommends "${missing[@]}"
}

service_label() {
  local unit="$1" active enabled
  if ! systemctl cat "$unit" >/dev/null 2>&1; then
    printf '未安装'
    return 0
  fi
  active="$(systemctl is-active "$unit" 2>/dev/null)" || true
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null)" || true
  case "$active" in
    active) active="运行中" ;;
    inactive) active="已停止" ;;
    failed) active="运行失败" ;;
    *) active="状态未知" ;;
  esac
  case "$enabled" in
    enabled) enabled="，开机自启" ;;
    disabled) enabled="，未设置开机自启" ;;
    *) enabled="" ;;
  esac
  printf '%s%s' "$active" "$enabled"
}

command_name() {
  if [[ -f "${BIN_DIR}/deploy" ]] && grep -q 'webstack-deploy' "${BIN_DIR}/deploy" 2>/dev/null; then
    printf 'deploy'
  elif [[ -f "${BIN_DIR}/webstack-deploy" ]]; then
    printf 'webstack-deploy'
  else
    printf 'deploy'
  fi
}

# ---------------------------------------------------------------------------
# 系统初始化
# ---------------------------------------------------------------------------
update_system() {
  section "更新系统软件包"
  apt_run update
  APT_UPDATED=1
  apt_run upgrade -y
}

collect_swap() {
  local current_swap fstype
  current_swap="$(awk '/^SwapTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)" || current_swap=0
  if [[ "${current_swap:-0}" =~ ^[0-9]+$ ]] && (( current_swap > 0 )); then
    SWAP_MB=0
    SWAP_NOTE="已存在 ${current_swap} MB，保持不变"
    return 0
  fi

  if [[ ! "$SWAPFILE" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    die "SWAPFILE 必须是绝对路径，且只能包含字母、数字和 . _ - /：${SWAPFILE}"
  fi
  if [[ ! "$SWAPPINESS" =~ ^[0-9]+$ ]] || (( SWAPPINESS > 100 )); then
    die "SWAPPINESS 必须是 0 到 100 之间的整数：${SWAPPINESS}"
  fi
  if [[ -e "$SWAPFILE" ]]; then
    SWAP_MB=0
    SWAP_NOTE="${SWAPFILE} 已存在但未启用，为安全起见不做处理"
    warn "${SWAP_NOTE}。"
    return 0
  fi
  fstype="$(findmnt -no FSTYPE -T "$(dirname "$SWAPFILE")" 2>/dev/null)" || fstype=""
  if [[ "$fstype" == btrfs ]]; then
    SWAP_MB=0
    SWAP_NOTE="btrfs 文件系统需要手动创建 Swap，已跳过"
    warn "${SWAP_NOTE}。"
    return 0
  fi

  if (( DISK_AVAIL_MB > 0 && DISK_AVAIL_MB < 3072 )); then
    RECOMMENDED_SWAP_MB=0
  elif (( MEM_TOTAL_MB <= 4096 )); then
    RECOMMENDED_SWAP_MB=1024
  else
    RECOMMENDED_SWAP_MB=0
  fi

  if [[ -n "$SWAP_SIZE" ]]; then
    validate_swap_size SWAP_SIZE || die "$VALIDATION_ERROR"
  elif can_prompt; then
    section "Swap"
    kv "内存" "${MEM_TOTAL_MB} MB"
    kv "磁盘可用" "${DISK_AVAIL_MB} MB"
    kv "当前 Swap" "无"
    kv "建议大小" "${RECOMMENDED_SWAP_MB} MB"
    resolve_value SWAP_SIZE "请输入 Swap 大小（单位 MB，可写 2G；输入 0 表示不创建）" "$RECOMMENDED_SWAP_MB" validate_swap_size
  else
    SWAP_SIZE="$RECOMMENDED_SWAP_MB"
  fi

  SWAP_MB="$SWAP_SIZE"
  if (( SWAP_MB > 0 )); then
    SWAP_NOTE="创建 ${SWAP_MB} MB（${SWAPFILE}，swappiness ${SWAPPINESS}）"
  else
    SWAP_NOTE="不创建"
  fi
}

configure_swap() {
  if (( SWAP_MB <= 0 )); then
    info "Swap：${SWAP_NOTE}。"
    return 0
  fi
  info "创建 ${SWAP_MB} MB Swap 文件：${SWAPFILE}"
  if ! fallocate -l "${SWAP_MB}M" "$SWAPFILE" 2>/dev/null; then
    rm -f "$SWAPFILE"
    info "当前文件系统不支持 fallocate，改用 dd 创建（需要一些时间）..."
    if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_MB" status=progress; then
      rm -f "$SWAPFILE"
      die "创建 Swap 文件失败。"
    fi
  fi
  chmod 0600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  swapon "$SWAPFILE"
  if ! awk -v f="$SWAPFILE" '$1 == f {found = 1} END {exit !found}' "$FSTAB_FILE"; then
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >> "$FSTAB_FILE"
  fi
  printf 'vm.swappiness = %s\n' "$SWAPPINESS" | write_file "$SYSCTL_SWAP_FILE"
  if ! sysctl -q -w "vm.swappiness=${SWAPPINESS}" >/dev/null 2>&1; then
    warn "无法立即应用 swappiness，重启后生效。"
  fi
  SWAP_NOTE="已创建 ${SWAP_MB} MB（${SWAPFILE}，swappiness ${SWAPPINESS}）"
}

collect_fail2ban() {
  local default=y
  normalize_bool_var ENABLE_FAIL2BAN
  if [[ -z "$ENABLE_FAIL2BAN" ]]; then
    # 重新初始化时沿用当前设置
    if is_initialized && [[ "$CFG_FAIL2BAN" != 1 ]]; then default=n; fi
    ask_yes_no ENABLE_FAIL2BAN "是否安装并启用 Fail2ban（防止 SSH 暴力破解）？" "$default"
  fi
  CFG_FAIL2BAN="$ENABLE_FAIL2BAN"
  if [[ -n "$FAIL2BAN_IGNOREIP" && ! "$FAIL2BAN_IGNOREIP" =~ ^[0-9A-Fa-f.:/,\ ]+$ ]]; then
    die "FAIL2BAN_IGNOREIP 格式不正确：${FAIL2BAN_IGNOREIP}（示例：203.0.113.10,198.51.100.0/24）"
  fi
}

collect_email() {
  if [[ "$LE_EMAIL_PRESET" == 1 ]] || ! can_prompt; then
    validate_email LE_EMAIL || die "$VALIDATION_ERROR"
  else
    printf '\n%s\n' "Let's Encrypt 自 2025 年 6 月起已不再发送证书到期提醒，邮箱可以留空。" >/dev/tty
    resolve_value LE_EMAIL "Let's Encrypt 邮箱（可选，直接回车跳过）" "$CFG_LE_EMAIL" validate_email 1
  fi
  CFG_LE_EMAIL="$LE_EMAIL"
}

decide_first_site() {
  case "${ADD_FIRST_SITE,,}" in
    auto|'')
      if [[ -n "$DOMAIN" ]]; then
        WANT_FIRST_SITE=1
      elif can_prompt; then
        ask_yes_no WANT_FIRST_SITE "初始化完成后是否立即添加第一个网站？" y
      else
        WANT_FIRST_SITE=0
      fi
      ;;
    1|y|yes|true|on) WANT_FIRST_SITE=1 ;;
    0|n|no|false|off) WANT_FIRST_SITE=0 ;;
    *) die "ADD_FIRST_SITE 的值无效：${ADD_FIRST_SITE}（可用值：auto、1、0）" ;;
  esac
}

ensure_www_shortcut() {
  if ! is_true "$WWW_SHORTCUT"; then
    return 0
  fi
  install -d -m 0755 "$WWW_BASE"
  if [[ -L "$WWW_LINK" ]]; then
    if [[ "$(readlink "$WWW_LINK")" != "$WWW_BASE" ]]; then
      warn "${WWW_LINK} 已指向其他位置，未修改。"
    fi
  elif [[ -e "$WWW_LINK" ]]; then
    warn "${WWW_LINK} 已存在且不是软链接，未创建 WinSCP 快捷入口。"
  else
    ln -s "$WWW_BASE" "$WWW_LINK"
    info "已创建快捷入口：${WWW_LINK} → ${WWW_BASE}"
  fi
}

ufw_active() {
  local status
  if ! command -v ufw >/dev/null 2>&1; then
    return 1
  fi
  status="$(ufw status 2>/dev/null)" || status=""
  [[ "$status" == *"Status: active"* ]]
}

ufw_allow() {
  # ufw_allow <端口>...
  local port
  for port in "$@"; do
    ufw allow "${port}/tcp" >/dev/null
  done
}

# UFW 已启用时放行 SSH（包括即将启用的新端口）、80 和 443；脚本不会主动启用 UFW
configure_ufw() {
  local -a ports=()
  if ! ufw_active; then
    return 0
  fi
  IFS=',' read -r -a ports <<< "$SSH_PORTS"
  if [[ "$SSH_PORT_CHANGED" == 1 ]]; then
    ports+=("$SSH_PORT")
  fi
  info "检测到 UFW 已启用，放行 SSH（$(IFS=','; printf '%s' "${ports[*]}")）、80 和 443 端口。"
  ufw_allow "${ports[@]}" 80 443
}

# ---------------------------------------------------------------------------
# SSH 端口
# ---------------------------------------------------------------------------
port_listening() {
  [[ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]]
}

wait_port_listening() {
  local i
  for (( i = 0; i < 5; i++ )); do
    if port_listening "$1"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ListenAddress 中直接写了端口时，Port 设置不起作用，脚本不做自动修改
ssh_listen_address_has_port() {
  grep -hsE '^[[:space:]]*ListenAddress[[:space:]]+(\[[^]]+\]|[0-9.]+|[A-Za-z0-9.-]+):[0-9]+[[:space:]]*$' \
    "$SSHD_CONFIG" "$SSHD_CONFIG_DIR"/*.conf >/dev/null 2>&1
}

collect_ssh_port() {
  SSH_PORT_CHANGED=0
  if ssh_listen_address_has_port; then
    if [[ -n "$SSH_PORT" && "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
      die "sshd 配置的 ListenAddress 中直接指定了端口，脚本无法自动修改 SSH 端口，请手动修改。"
    fi
    SSH_PORT="$CURRENT_SSH_PORT"
    return 0
  fi
  if [[ -z "$SSH_PORT" ]] && can_prompt; then
    section "SSH 端口"
    kv "当前端口" "$SSH_PORTS"
    printf '  把 SSH 改为非 22 端口，可以大幅减少自动扫描和暴力破解（可选）。\n'
    printf '  建议使用 10000–65000 之间的端口；修改后用 ssh -p 端口 root@服务器IP 登录。\n'
  fi
  resolve_value SSH_PORT "请输入 SSH 端口（直接回车保持不变）" "$CURRENT_SSH_PORT" validate_ssh_port
  if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
    SSH_PORT_CHANGED=1
  fi
}

ssh_port_label() {
  if [[ "$SSH_PORT_CHANGED" == 1 ]]; then
    printf '%s → %s' "$CURRENT_SSH_PORT" "$SSH_PORT"
  else
    printf '%s（不变）' "$SSH_PORTS"
  fi
}

# 修改端口前提醒放行云防火墙，否则断开后无法登录
confirm_ssh_port_change() {
  if [[ "$SSH_PORT_CHANGED" != 1 ]]; then
    return 0
  fi
  warn "SSH 端口将从 ${CURRENT_SSH_PORT} 改为 ${SSH_PORT}。如果服务商启用了安全组或云防火墙（例如阿里云安全组、netcup 云防火墙），必须先在控制台放行 TCP ${SSH_PORT}，否则当前连接断开后将无法登录。"
  if ! confirm_risky "是否已放行 TCP ${SSH_PORT}（服务商没有启用这类防火墙时也可以继续）？"; then
    info "已取消，未做任何修改。请先放行新端口后再运行。"
    exit 0
  fi
}

restart_ssh() {
  # restart_ssh <期望监听的端口>
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload
    systemctl restart ssh.socket || true
  else
    systemctl restart ssh || true
  fi
  if wait_port_listening "$1"; then
    return 0
  fi
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    warn "ssh.socket 没有在端口 $1 上监听，改为由 ssh.service 直接监听。"
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable ssh.service >/dev/null 2>&1 || true
    systemctl restart ssh.service || true
    wait_port_listening "$1"
    return
  fi
  return 1
}

restore_sshd_config() {
  # restore_sshd_config <临时备份目录>
  cp -p "$1/sshd_config" "$SSHD_CONFIG"
  if [[ -f "$1/port.conf" ]]; then
    cp -p "$1/port.conf" "$SSHD_PORT_FILE"
  else
    rm -f "$SSHD_PORT_FILE"
  fi
  rm -rf "$1"
}

# 修改 SSH 端口；失败时恢复原配置并返回 1。已经建立的 SSH 连接不会断开。
change_ssh_port() {
  local old="$CURRENT_SSH_PORT" new="$SSH_PORT" tmp ports
  info "修改 SSH 端口：${old} → ${new}"
  install -d -m 0755 "$SSHD_RUN_DIR" "$SSHD_CONFIG_DIR"
  install -d -m 0700 "$BACKUP_DIR"
  cp -p "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config.$(date +%Y%m%d-%H%M%S)"
  tmp="$(mktemp -d)"
  cp -p "$SSHD_CONFIG" "${tmp}/sshd_config"
  if [[ -f "$SSHD_PORT_FILE" ]]; then
    cp -p "$SSHD_PORT_FILE" "${tmp}/port.conf"
  fi

  # 确保主配置会读取 sshd_config.d 目录
  if ! awk -v dir="${SSHD_CONFIG_DIR}/" '$1 == "Include" && index($0, dir) {found = 1} END {exit !found}' "$SSHD_CONFIG"; then
    sed -i "1i Include ${SSHD_CONFIG_DIR}/*.conf" "$SSHD_CONFIG"
  fi
  # Port 可以写多次且同时生效，所以要注释掉主配置中原有的 Port
  sed -Ei 's/^([[:space:]]*)([Pp][Oo][Rr][Tt][[:space:]])/\1# \2/' "$SSHD_CONFIG"
  printf '# 由 webstack-deploy 管理：SSH 端口\nPort %s\n' "$new" | write_file "$SSHD_PORT_FILE"

  if ! sshd -t >/dev/null 2>&1; then
    restore_sshd_config "$tmp"
    warn "新的 SSH 配置没有通过检查（sshd -t），已恢复原设置。"
    return 1
  fi
  ports="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | paste -sd ',' -)" || ports=""
  if [[ "$ports" != "$new" ]]; then
    restore_sshd_config "$tmp"
    warn "其他 SSH 配置文件中也设置了端口（实际生效：${ports:-未知}），已恢复原设置。请检查 ${SSHD_CONFIG_DIR}/ 中的 Port 设置。"
    return 1
  fi
  if ! restart_ssh "$new"; then
    restore_sshd_config "$tmp"
    if ! restart_ssh "$old"; then
      warn "恢复后 SSH 仍没有在端口 ${old} 上监听。请不要关闭当前窗口，并检查：systemctl status ssh"
    fi
    warn "SSH 没有在新端口 ${new} 上启动，已恢复原设置。"
    return 1
  fi
  rm -rf "$tmp"
  SSH_OLD_PORT="$old"
  CURRENT_SSH_PORT="$new"
  SSH_PORTS="$new"
  info "SSH 已在新端口 ${new} 上运行，当前连接不受影响。"
}

print_ssh_port_notice() {
  local ip
  if [[ -z "$SSH_OLD_PORT" ]]; then
    return 0
  fi
  ip="$(detect_public_ip 4)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || ip=""
  fi
  printf '\n'
  warn "SSH 端口已从 ${SSH_OLD_PORT} 改为 ${SSH_PORT}。"
  printf '  1. 请不要关闭当前窗口，先打开一个新窗口测试登录：ssh -p %s root@%s\n' "$SSH_PORT" "${ip:-服务器IP}"
  printf '  2. 如果服务商启用了安全组或云防火墙，需要放行 TCP %s。\n' "$SSH_PORT"
  if ufw_active; then
    printf '  3. UFW 已放行新端口。确认可以登录后，可以删除旧端口的规则：ufw delete allow %s/tcp\n' "$SSH_OLD_PORT"
  fi
  printf '  如果无法登录：通过服务商控制台的 VNC 登录服务器，删除 %s 后执行 systemctl restart ssh，即可恢复为默认端口 22。\n' "$SSHD_PORT_FILE"
}

render_fail2ban_config() {
  local ignoreip="127.0.0.1/8 ::1"
  if [[ -n "$FAIL2BAN_IGNOREIP" ]]; then
    ignoreip+=" ${FAIL2BAN_IGNOREIP//,/ }"
  fi
  cat <<EOF
# 由 webstack-deploy 管理，重新初始化时会被覆盖。
[DEFAULT]
ignoreip = ${ignoreip}
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORTS}
backend = systemd
EOF
  if [[ -f "${F2B_FILTER_DIR}/nginx-botsearch.conf" ]]; then
    cat <<EOF

[nginx-botsearch]
enabled = true
port = http,https
backend = auto
logpath = ${NGINX_LOG_DIR}/*access.log
maxretry = 10
EOF
  fi
}

configure_fail2ban() {
  if [[ "$CFG_FAIL2BAN" != 1 ]]; then
    if [[ -f "$F2B_JAIL_FILE" ]]; then
      rm -f "$F2B_JAIL_FILE"
      if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload >/dev/null 2>&1 || true
      fi
      info "已移除 webstack-deploy 的 Fail2ban 规则。"
    fi
    return 0
  fi
  info "配置 Fail2ban：SSH（端口 ${SSH_PORTS}）和 Nginx 扫描防护"
  if [[ ! -f "${F2B_FILTER_DIR}/nginx-botsearch.conf" ]]; then
    warn "未找到 nginx-botsearch 过滤规则，只启用 SSH 防护。"
  fi
  render_fail2ban_config | write_file "$F2B_JAIL_FILE"
  if ! fail2ban-client -t >/dev/null 2>&1; then
    die "Fail2ban 配置检查未通过，请运行 fail2ban-client -t 查看详情。"
  fi
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
}

reload_fail2ban() {
  if [[ "$CFG_FAIL2BAN" != 1 ]]; then
    return 0
  fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    if ! fail2ban-client reload >/dev/null 2>&1; then
      warn "Fail2ban 重新加载失败，可以稍后手动执行：fail2ban-client reload"
    fi
  fi
}

configure_renewal() {
  write_file "${LE_DIR}/renewal-hooks/deploy/reload-nginx.sh" 0755 <<'EOF'
#!/bin/sh
# 由 webstack-deploy 管理：证书续签成功后重新加载 Nginx
systemctl reload nginx
EOF
  if systemctl cat certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer >/dev/null 2>&1
  else
    warn "未找到 certbot.timer，请确认系统中存在证书自动续签任务。"
  fi
}

installed_version() {
  local v=""
  if [[ -f "$INSTALLED_SCRIPT" ]]; then
    v="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"$/\1/p' "$INSTALLED_SCRIPT" | head -n 1)" || v=""
    printf '%s' "$v"
  fi
}

install_command() {
  local target="${BIN_DIR}/deploy"
  if [[ ! "$SCRIPT_SOURCE" -ef "$INSTALLED_SCRIPT" ]]; then
    install_file_atomic "$SCRIPT_SOURCE" "$INSTALLED_SCRIPT" 0755
  fi
  if [[ -e "$target" ]] && ! grep -q 'webstack-deploy' "$target" 2>/dev/null; then
    warn "${target} 已被其他程序占用，改为安装命令 webstack-deploy。"
    target="${BIN_DIR}/webstack-deploy"
  fi
  write_file "$target" 0755 <<EOF
#!/bin/sh
# webstack-deploy 命令入口
exec /bin/bash ${INSTALLED_SCRIPT} "\$@"
EOF
}

# ---------------------------------------------------------------------------
# Nginx
# ---------------------------------------------------------------------------
nginx_test() {
  local out
  if out="$(nginx -t 2>&1)"; then
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
}

reload_nginx() {
  systemctl enable nginx >/dev/null 2>&1 || true
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
}

emit_listen() {
  # emit_listen <端口及参数>，例如 "80" 或 "443 ssl"
  printf '    listen %s;\n' "$1"
  if [[ "$HAS_IPV6" == 1 ]]; then
    printf '    listen [::]:%s;\n' "$1"
  fi
}

emit_https_listen() {
  # nginx 1.25.1 起使用独立的 http2 指令
  if version_ge "$NGINX_VERSION" 1.25.1; then
    emit_listen "443 ssl"
    printf '    http2 on;\n'
  else
    emit_listen "443 ssl http2"
  fi
}

render_default_server() {
  cat <<EOF
# 由 webstack-deploy 管理：默认站点。
# 拒绝直接用 IP 或未添加的域名访问，同时为新域名提供证书验证路径。
server {
$(emit_listen "80 default_server")
    server_name _;

    include snippets/webstack-acme.conf;

    location / {
        return 444;
    }
}
EOF
  # ssl_reject_handshake 需要 nginx 1.19.4 及以上
  if version_ge "$NGINX_VERSION" 1.19.4; then
    cat <<EOF

server {
$(emit_listen "443 ssl default_server")
    server_name _;
    ssl_reject_handshake on;
}
EOF
  fi
}

ensure_default_server() {
  local conf="${NGINX_SITES_AVAILABLE}/webstack-default"
  local link="${NGINX_SITES_ENABLED}/webstack-default"
  local debian_link="${NGINX_SITES_ENABLED}/default"
  local debian_target="" removed_debian=0

  render_default_server | write_file "$conf"
  ln -sfn "$conf" "$link"
  if [[ -L "$debian_link" ]]; then
    debian_target="$(readlink "$debian_link")"
    rm -f "$debian_link"
    removed_debian=1
  fi
  if nginx_test 2>/dev/null; then
    if [[ "$removed_debian" == 1 ]]; then
      info "已停用 Nginx 自带的欢迎页（原配置仍保留在 ${NGINX_SITES_AVAILABLE}/default）。"
    fi
    return 0
  fi
  rm -f "$link"
  if [[ "$removed_debian" == 1 ]]; then
    ln -sfn "$debian_target" "$debian_link"
  fi
  warn "现有 Nginx 配置中已有 default_server，跳过 webstack-deploy 默认站点。"
}

ensure_nginx_base() {
  if ! nginx_test; then
    die "现有 Nginx 配置有错误（见上方输出），请先修复后再运行。"
  fi
  detect_nginx_version
  install -d -m 0755 "$ACME_DIR"
  install -d -m 0700 "$BACKUP_DIR"

  write_file "${NGINX_SNIPPETS}/webstack-acme.conf" <<EOF
# 由 webstack-deploy 管理：Let's Encrypt 证书验证目录（所有站点共用）
location ^~ /.well-known/acme-challenge/ {
    root ${ACME_DIR};
    default_type "text/plain";
    try_files \$uri =404;
}
EOF

  write_file "${NGINX_SNIPPETS}/webstack-https.conf" <<'EOF'
# 由 webstack-deploy 管理：HTTPS 通用参数
ssl_protocols TLSv1.2 TLSv1.3;
ssl_session_cache shared:WebStackSSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF

  write_file "${NGINX_SNIPPETS}/webstack-deny-hidden.conf" <<'EOF'
# 由 webstack-deploy 管理：禁止访问隐藏文件（如 .git、.env），保留 /.well-known/
location ~ /\.(?!well-known/) {
    deny all;
}
EOF

  write_file "${NGINX_CONF_D}/webstack.conf" <<'EOF'
# 由 webstack-deploy 管理：反向代理站点使用的 WebSocket 变量
map $http_upgrade $webstack_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

  ensure_default_server
}

set_site_paths() {
  SITE_CONF="${NGINX_SITES_AVAILABLE}/${DOMAIN}"
  SITE_LINK="${NGINX_SITES_ENABLED}/${DOMAIN}"
}

update_server_names() {
  SERVER_NAMES="$DOMAIN"
  if [[ "$WITH_WWW" == 1 ]]; then
    SERVER_NAMES+=" www.${DOMAIN}"
  fi
}

# 读取本脚本生成的配置中的元数据，用作重新添加时的默认值
load_site_meta() {
  local line item
  local -a items=()
  META_TYPE=""; META_WWW=""; META_PHP=""; META_ROOT=""; META_PROXY=""
  if [[ ! -f "$1" ]]; then
    return 0
  fi
  line="$(grep -m 1 '^# webstack-deploy ' "$1" 2>/dev/null)" || line=""
  read -r -a items <<< "${line#\# webstack-deploy }"
  for item in "${items[@]}"; do
    case "$item" in
      type=*) META_TYPE="${item#type=}" ;;
      www=*) META_WWW="${item#www=}" ;;
      php=*) META_PHP="${item#php=}" ;;
      root=*) META_ROOT="${item#root=}" ;;
      proxy=*) META_PROXY="${item#proxy=}" ;;
    esac
  done
  if [[ "$META_ROOT" == "-" ]]; then META_ROOT=""; fi
  if [[ "$META_PHP" == "-" ]]; then META_PHP=""; fi
  if [[ "$META_PROXY" == "-" ]]; then META_PROXY=""; fi
}

render_site_header() {
  local php="-" root="-" proxy="-"
  if [[ "$SITE_TYPE" == php ]]; then php="${PHP_VERSION:--}"; fi
  if [[ "$SITE_TYPE" != proxy ]]; then root="$WEBROOT"; else proxy="$PROXY_TARGET"; fi
  printf '# 由 webstack-deploy v%s 生成。再次添加同一域名时会覆盖本文件（原文件自动备份）。\n' "$SCRIPT_VERSION"
  printf '# webstack-deploy type=%s www=%s php=%s root=%s proxy=%s\n' "$SITE_TYPE" "$WITH_WWW" "$php" "$root" "$proxy"
}

render_acme_config() {
  render_site_header
  cat <<EOF
# 临时配置：仅用于申请证书，申请完成后会替换为正式配置。

server {
$(emit_listen 80)
    server_name ${SERVER_NAMES};

    include snippets/webstack-acme.conf;

    location / {
        return 404;
    }
}
EOF
}

render_site_body() {
  case "$SITE_TYPE" in
    static)
      cat <<EOF
    root ${WEBROOT};
    index index.html index.htm;

    include snippets/webstack-deny-hidden.conf;

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
      ;;
    php)
      cat <<EOF
    root ${WEBROOT};
    index index.php index.html index.htm;
    client_max_body_size 64m;

    include snippets/webstack-deny-hidden.conf;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_read_timeout 120s;
    }
EOF
      ;;
    proxy)
      cat <<EOF
    client_max_body_size 64m;

    location / {
        proxy_pass http://${PROXY_TARGET};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$webstack_connection_upgrade;
        proxy_read_timeout 120s;
    }
EOF
      ;;
  esac
}

render_final_config() {
  local logs cert
  logs="    access_log ${NGINX_LOG_DIR}/${DOMAIN}.access.log;
    error_log ${NGINX_LOG_DIR}/${DOMAIN}.error.log;"
  cert="    ssl_certificate ${LE_DIR}/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${LE_DIR}/live/${DOMAIN}/privkey.pem;
    include snippets/webstack-https.conf;"

  render_site_header
  cat <<EOF

# HTTP：证书验证，其余请求跳转到 HTTPS
server {
$(emit_listen 80)
    server_name ${SERVER_NAMES};
${logs}

    include snippets/webstack-acme.conf;

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}
EOF
  if [[ "$WITH_WWW" == 1 ]]; then
    cat <<EOF

# HTTPS：www 跳转到主域名
server {
$(emit_https_listen)
    server_name www.${DOMAIN};
${logs}

${cert}

    return 301 https://${DOMAIN}\$request_uri;
}
EOF
  fi
  cat <<EOF

# HTTPS：网站
server {
$(emit_https_listen)
    server_name ${DOMAIN};
${logs}

${cert}

$(render_site_body)
}
EOF
}

backup_site_config() {
  # 每次运行只备份一次（备份的是运行前的原始配置）
  if [[ "$SITE_BACKUP_DONE" == 1 ]]; then
    return 0
  fi
  SITE_BACKUP_DONE=1
  if [[ -f "$SITE_CONF" ]]; then
    install -d -m 0700 "$BACKUP_DIR"
    SITE_BACKUP="${BACKUP_DIR}/${DOMAIN}.$(date +%Y%m%d-%H%M%S).conf"
    cp -p "$SITE_CONF" "$SITE_BACKUP"
    if [[ -e "$SITE_LINK" ]]; then SITE_WAS_ENABLED=1; else SITE_WAS_ENABLED=0; fi
  fi
}

restore_site_config() {
  if [[ -n "$SITE_BACKUP" ]]; then
    cp -p "$SITE_BACKUP" "$SITE_CONF"
    if [[ "$SITE_WAS_ENABLED" == 1 ]]; then
      ln -sfn "$SITE_CONF" "$SITE_LINK"
    else
      rm -f "$SITE_LINK"
    fi
  else
    rm -f "$SITE_LINK" "$SITE_CONF"
  fi
  if nginx_test 2>/dev/null; then
    reload_nginx
  fi
}

# apply_site_config <acme|final>：写入配置、检查语法并重新加载，失败时恢复原状态
apply_site_config() {
  local tmp
  tmp="$(mktemp)"
  if [[ "$1" == acme ]]; then
    render_acme_config > "$tmp"
  else
    render_final_config > "$tmp"
  fi
  backup_site_config
  install -m 0644 "$tmp" "$SITE_CONF"
  rm -f "$tmp"
  ln -sfn "$SITE_CONF" "$SITE_LINK"
  if ! nginx_test; then
    restore_site_config
    die "生成的 Nginx 配置未通过检查（见上方输出），已恢复原状态。"
  fi
  reload_nginx
}

# ---------------------------------------------------------------------------
# PHP
# ---------------------------------------------------------------------------
sury_repo_present() {
  grep -rqsE 'packages\.sury\.org/php' "$APT_SOURCES_LIST" "$APT_SOURCES_DIR" 2>/dev/null
}

add_sury_repo() {
  local tmp
  if sury_repo_present && [[ -f "$SURY_KEYRING" ]]; then
    return 0
  fi
  if [[ -z "$OS_CODENAME" ]]; then
    die "无法识别系统代号（VERSION_CODENAME），不能添加 PHP 软件源。"
  fi
  info "添加 PHP 软件源（packages.sury.org）..."
  tmp="$(mktemp --suffix=.deb)"
  if ! curl -fsSL --max-time 60 -o "$tmp" https://packages.sury.org/debsuryorg-archive-keyring.deb; then
    rm -f "$tmp"
    die "下载 PHP 软件源密钥失败，请检查网络后重试。"
  fi
  dpkg -i "$tmp" >/dev/null
  rm -f "$tmp"
  if ! sury_repo_present; then
    printf 'deb [signed-by=%s] https://packages.sury.org/php/ %s main\n' "$SURY_KEYRING" "$OS_CODENAME" | write_file "$SURY_LIST_FILE"
  fi
  apt_run update
  APT_UPDATED=1
}

detect_latest_php() {
  local latest
  latest="$(apt-cache search --names-only '^php8\.[0-9]+-fpm$' 2>/dev/null \
    | awk '{print $1}' | sed -nE 's/^php(8\.[0-9]+)-fpm$/\1/p' | sort -V | tail -n 1)" || latest=""
  if [[ -z "$latest" ]]; then
    die "软件源中没有可用的 PHP 8.x（php8.x-fpm）。"
  fi
  PHP_VERSION="$latest"
}

set_pool_value() {
  local file="$1" key="$2" value="$3" pattern
  pattern="${2//./\\.}"
  if grep -Eq "^[[:space:]]*${pattern}[[:space:]]*=" "$file"; then
    sed -Ei "s|^[[:space:]]*${pattern}[[:space:]]*=.*|${key} = ${value}|" "$file"
  else
    if [[ -n "$(tail -c 1 "$file")" ]]; then printf '\n' >> "$file"; fi
    printf '%s = %s\n' "$key" "$value" >> "$file"
  fi
}

tune_php_fpm() {
  local pool="${PHP_ETC_DIR}/${PHP_VERSION}/fpm/pool.d/www.conf"
  local conf_dir="${PHP_ETC_DIR}/${PHP_VERSION}/fpm/conf.d"
  local children opcache_mb
  if [[ ! -f "$pool" ]]; then
    die "未找到 PHP-FPM 配置文件：${pool}"
  fi
  if (( MEM_TOTAL_MB <= 1536 )); then
    children=3; opcache_mb=64
  elif (( MEM_TOTAL_MB <= 3072 )); then
    children=6; opcache_mb=128
  elif (( MEM_TOTAL_MB <= 6144 )); then
    children=10; opcache_mb=128
  else
    children=16; opcache_mb=192
  fi
  info "按内存（${MEM_TOTAL_MB} MB）调整 PHP-FPM：最多 ${children} 个进程，OPcache ${opcache_mb} MB"
  set_pool_value "$pool" pm ondemand
  set_pool_value "$pool" pm.max_children "$children"
  set_pool_value "$pool" pm.process_idle_timeout 10s
  set_pool_value "$pool" pm.max_requests 500
  set_pool_value "$pool" request_terminate_timeout 120s

  write_file "${conf_dir}/99-webstack.ini" <<EOF
; 由 webstack-deploy 管理
memory_limit = 128M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
opcache.enable = 1
opcache.memory_consumption = ${opcache_mb}
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 1
EOF
}

install_php() {
  local ext pkg
  local -a optional=(curl mbstring opcache xml zip intl gd) extras=() wanted=()
  read -r -a extras <<< "$PHP_EXTENSIONS"

  if [[ -n "$PHP_VERSION" ]] && pkg_installed "php${PHP_VERSION}-fpm"; then
    info "使用已安装的 PHP ${PHP_VERSION}"
  else
    add_sury_repo
    if [[ -z "$PHP_VERSION" ]]; then
      detect_latest_php
      info "软件源中最新的 PHP 版本：${PHP_VERSION}"
    fi
    if ! pkg_available "php${PHP_VERSION}-fpm"; then
      die "软件源中没有 php${PHP_VERSION}-fpm。"
    fi
    info "安装 PHP ${PHP_VERSION}"
    install_packages "php${PHP_VERSION}-cli" "php${PHP_VERSION}-common" "php${PHP_VERSION}-fpm"
    for ext in "${optional[@]}"; do
      pkg="php${PHP_VERSION}-${ext}"
      if pkg_available "$pkg"; then wanted+=("$pkg"); fi
    done
  fi

  if (( ${#extras[@]} > 0 )); then
    info "额外的 PHP 扩展：${extras[*]}"
  fi
  for ext in "${extras[@]}"; do
    pkg="php${PHP_VERSION}-${ext}"
    if pkg_available "$pkg"; then
      wanted+=("$pkg")
    else
      warn "软件源中没有 ${pkg}，已跳过。"
    fi
  done
  if (( ${#wanted[@]} > 0 )); then
    install_packages "${wanted[@]}"
  fi

  tune_php_fpm
  systemctl enable "php${PHP_VERSION}-fpm" >/dev/null 2>&1
  systemctl reload-or-restart "php${PHP_VERSION}-fpm"

  if [[ -z "$CFG_PHP_VERSION" ]]; then
    CFG_PHP_VERSION="$PHP_VERSION"
    save_config
  fi
}

# ---------------------------------------------------------------------------
# DNS 检查
# ---------------------------------------------------------------------------
detect_public_ip() {
  # detect_public_ip <4|6>
  local ip url
  local -a urls
  if [[ "$1" == 4 ]]; then
    urls=(https://api.ipify.org https://ifconfig.me/ip)
  else
    urls=(https://api6.ipify.org https://ifconfig.me/ip)
  fi
  for url in "${urls[@]}"; do
    ip="$(curl -fsS "-$1" --max-time 8 "$url" 2>/dev/null)" || ip=""
    ip="$(trim "$ip")"
    if [[ "$1" == 4 && "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
    if [[ "$1" == 6 && "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
      printf '%s' "${ip,,}"
      return 0
    fi
  done
  return 0
}

dns_lookup() {
  # dns_lookup <4|6> <域名>：输出去重后的地址，每行一个
  if [[ "$1" == 4 ]]; then
    getent ahostsv4 "$2" 2>/dev/null | awk '{print $1}' | sort -u || true
  else
    getent ahostsv6 "$2" 2>/dev/null | awk '{print tolower($1)}' | grep -v '^::ffff:' | sort -u || true
  fi
}

check_dns() {
  local ip4="" ip6="" name a aaaa problems=0 ip_mismatch=0 www_missing=0 name_ok answer
  local -a names=("$DOMAIN")
  DNS_CHECKED=1
  if ! command -v curl >/dev/null 2>&1 || ! command -v getent >/dev/null 2>&1; then
    warn "缺少 curl 或 getent，跳过 DNS 检查。"
    return 0
  fi
  if [[ "$WITH_WWW" == 1 ]]; then
    names+=("www.${DOMAIN}")
  fi

  info "检查域名解析..."
  ip4="$(detect_public_ip 4)"
  if has_global_ipv6; then
    ip6="$(detect_public_ip 6)"
  fi
  if [[ -z "$ip4" && -z "$ip6" ]]; then
    warn "无法获取本机公网 IP，只检查是否存在解析记录。"
  fi

  for name in "${names[@]}"; do
    a="$(dns_lookup 4 "$name")"
    aaaa="$(dns_lookup 6 "$name")"
    name_ok=1
    if [[ -z "$a" && -z "$aaaa" ]]; then
      if [[ "$name" == "www.${DOMAIN}" ]]; then
        www_missing=1
      else
        warn "${name} 没有任何解析记录（A 或 AAAA）。"
        problems=1
      fi
      continue
    fi
    if [[ -n "$a" && -n "$ip4" ]] && ! grep -Fxq "$ip4" <<< "$a"; then
      warn "${name} 的 A 记录是 $(join_lines "$a")，本机公网 IPv4 是 ${ip4}。"
      problems=1
      ip_mismatch=1
      name_ok=0
    fi
    if [[ -n "$aaaa" ]]; then
      if [[ -n "$ip6" ]]; then
        if ! grep -Fxq "$ip6" <<< "$aaaa"; then
          warn "${name} 的 AAAA 记录是 $(join_lines "$aaaa")，本机公网 IPv6 是 ${ip6}。"
          problems=1
          ip_mismatch=1
          name_ok=0
        fi
      elif ! has_global_ipv6; then
        warn "${name} 有 AAAA 记录（$(join_lines "$aaaa")），但本机没有公网 IPv6。Let's Encrypt 会优先通过 IPv6 验证，建议删除这条 AAAA 记录。"
        problems=1
        name_ok=0
      fi
    fi
    if [[ "$name_ok" == 1 ]]; then
      info "${name} 解析正常。"
    fi
  done

  if [[ "$www_missing" == 1 ]]; then
    warn "www.${DOMAIN} 没有解析记录，带上 www 申请证书会失败。"
    if can_prompt; then
      ask_yes_no answer "是否改为只配置 ${DOMAIN}（不含 www）？" y
      if [[ "$answer" == 1 ]]; then
        WITH_WWW=0
      fi
    else
      WITH_WWW=0
      warn "已自动改为只配置 ${DOMAIN}。"
    fi
    update_server_names
  fi

  if [[ "$ip_mismatch" == 1 ]]; then
    warn "如果域名开启了 CDN 代理（例如 Cloudflare 的橙色云朵），IP 不一致是正常的，可以继续。"
  fi
  if [[ "$problems" == 1 ]]; then
    if is_true "$REQUIRE_DNS_MATCH"; then
      die "DNS 检查未通过（已设置 REQUIRE_DNS_MATCH=1）。"
    fi
    if can_prompt; then
      ask_yes_no answer "DNS 检查未通过，仍要继续申请证书吗？" n
      if [[ "$answer" != 1 ]]; then
        if [[ "$DNS_DEFERRED" == 1 ]]; then
          info "已取消添加网站。服务器初始化已完成，修正 DNS 后运行 $(command_name) 重新添加。"
        else
          info "已取消，未做任何修改。请修正 DNS 解析后重新运行。"
        fi
        exit 0
      fi
    else
      warn "非交互模式：继续执行。"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 证书
# ---------------------------------------------------------------------------
cert_exists() {
  [[ -f "${LE_DIR}/live/${DOMAIN}/fullchain.pem" && -f "${LE_DIR}/live/${DOMAIN}/privkey.pem" ]]
}

obtain_certificate() {
  local renewal="${LE_DIR}/renewal/${DOMAIN}.conf"
  local -a args=(certonly --webroot -w "$ACME_DIR" --cert-name "$DOMAIN" -d "$DOMAIN")
  if [[ "$WITH_WWW" == 1 ]]; then
    args+=(-d "www.${DOMAIN}")
  fi
  args+=(--non-interactive --agree-tos --expand)
  if [[ -n "$LE_EMAIL" ]]; then
    args+=(--email "$LE_EMAIL" --no-eff-email)
  else
    args+=(--register-unsafely-without-email)
  fi
  if is_true "$LE_STAGING"; then
    if [[ -f "$renewal" ]] && ! grep -q 'acme-staging' "$renewal"; then
      warn "${DOMAIN} 已有正式证书，忽略 LE_STAGING。"
      LE_STAGING=0
    else
      args+=(--test-cert)
    fi
  fi
  if [[ -f "$renewal" ]] && ! is_true "$LE_STAGING" && grep -q 'acme-staging' "$renewal"; then
    info "当前是测试证书，将重新签发正式证书。"
    args+=(--force-renewal)
  else
    args+=(--keep-until-expiring)
  fi
  info "申请 Let's Encrypt 证书：${SERVER_NAMES}"
  certbot "${args[@]}"
}

print_cert_failure_hint() {
  error_msg "证书申请失败，已撤销本次 Nginx 配置改动。"
  cat >&2 <<EOF
常见原因：
  1. 域名还没有解析到本服务器，或者解析尚未生效；
  2. 服务商的安全组或防火墙没有放行 80 端口；
  3. 域名开启了 CDN 代理，并且 CDN 强制跳转 HTTPS；
  4. 短时间内失败次数过多，被 Let's Encrypt 临时限流（排查期间可以加 LE_STAGING=1 使用测试证书）。
详细日志：${LE_LOG}
EOF
}

cert_expiry_label() {
  local cert="${LE_DIR}/live/$1/fullchain.pem" end end_ts days
  if [[ ! -f "$cert" ]]; then
    printf '无证书'
    return 0
  fi
  end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null)" || end=""
  end_ts="$(date -d "${end#notAfter=}" +%s 2>/dev/null)" || end_ts=""
  if [[ -z "$end" || -z "$end_ts" ]]; then
    printf '未知'
    return 0
  fi
  days=$(( (end_ts - $(date +%s)) / 86400 ))
  printf '%s（剩余 %s 天）' "$(date -d "@${end_ts}" +%F)" "$days"
}

issue_certificate_and_configure() {
  # 已有证书：先写正式配置，保证验证路径可用；没有证书：写临时配置
  if cert_exists; then
    apply_site_config final
  else
    apply_site_config acme
  fi
  if ! obtain_certificate; then
    restore_site_config
    if [[ "$WEBROOT_CREATED" == 1 ]]; then
      rmdir "$WEBROOT" 2>/dev/null || true
    fi
    print_cert_failure_hint
    exit 1
  fi
  if ! cert_exists; then
    restore_site_config
    die "证书申请完成，但没有找到证书文件：${LE_DIR}/live/${DOMAIN}/"
  fi
  apply_site_config final
}

# ---------------------------------------------------------------------------
# 网站设置
# ---------------------------------------------------------------------------
check_existing_site() {
  local others
  SITE_EXISTS=0
  others="$(grep -RlsE "^[[:space:]]*server_name[^;]*[[:space:]]${DOMAIN//./\\.}[[:space:];]" \
    "$NGINX_SITES_ENABLED" "$NGINX_CONF_D" 2>/dev/null | grep -vxF "$SITE_LINK" || true)"
  if [[ -n "$others" ]]; then
    warn "以下 Nginx 配置中也使用了 ${DOMAIN}，可能导致冲突：$(join_lines "$others")"
  fi
  if [[ -f "$SITE_CONF" ]]; then
    SITE_EXISTS=1
    load_site_meta "$SITE_CONF"
    warn "${DOMAIN} 已存在 Nginx 配置：${SITE_CONF}"
    if ! confirm_risky "继续将覆盖该配置（原配置会自动备份）。是否继续？"; then
      info "已取消，未做任何修改。"
      exit 0
    fi
  fi
}

collect_www() {
  local default=n
  if [[ "$DOMAIN" == www.* ]]; then
    WITH_WWW=0
    return 0
  fi
  normalize_bool_var WITH_WWW
  if [[ -n "$WITH_WWW" ]]; then
    return 0
  fi
  if [[ -n "$META_WWW" ]]; then
    if [[ "$META_WWW" == 1 ]]; then default=y; fi
  elif [[ "$DOMAIN" =~ ^[^.]+\.[^.]+$ ]]; then
    default=y
  fi
  ask_yes_no WITH_WWW "是否同时配置 www.${DOMAIN}（自动跳转到 ${DOMAIN}）？" "$default"
}

collect_site_type() {
  local default=1
  case "$META_TYPE" in
    php) default=2 ;;
    proxy) default=3 ;;
  esac
  if [[ -z "$SITE_TYPE" ]] && can_prompt; then
    printf '\n网站类型：\n  1) 静态网站（HTML、CSS、JS）\n  2) PHP 网站\n  3) 反向代理（转发到本机端口，例如 Node.js 或 Docker 应用）\n' >/dev/tty
  fi
  resolve_value SITE_TYPE "请选择网站类型" "$default" validate_site_type
}

collect_site_settings() {
  section "网站设置"
  resolve_value DOMAIN "请输入域名（例如 example.com）" "" validate_domain
  set_site_paths
  check_existing_site
  collect_www
  collect_site_type

  case "$SITE_TYPE" in
    proxy)
      WEBROOT=""
      resolve_value PROXY_TARGET "请输入后端地址（端口号或 IP:端口，例如 3000）" "$META_PROXY" validate_proxy_target
      ;;
    static|php)
      PROXY_TARGET=""
      if [[ -z "$WEBROOT" ]]; then
        WEBROOT="${META_ROOT:-${WWW_BASE}/${DOMAIN}}"
      fi
      validate_webroot WEBROOT || die "$VALIDATION_ERROR"
      if [[ -d "$WEBROOT" ]]; then WEBROOT_EXISTS=1; else WEBROOT_EXISTS=0; fi
      ;;
  esac

  if [[ "$SITE_TYPE" == php ]]; then
    if [[ -n "$PHP_VERSION" ]]; then
      validate_php_version PHP_VERSION || die "$VALIDATION_ERROR"
    elif [[ -n "$META_PHP" ]] && pkg_installed "php${META_PHP}-fpm"; then
      PHP_VERSION="$META_PHP"
    elif [[ -n "$CFG_PHP_VERSION" ]] && pkg_installed "php${CFG_PHP_VERSION}-fpm"; then
      PHP_VERSION="$CFG_PHP_VERSION"
    fi
    validate_php_extensions PHP_EXTENSIONS || die "$VALIDATION_ERROR"
  fi

  normalize_bool_var LE_STAGING
  update_server_names
  if command -v curl >/dev/null 2>&1; then
    check_dns
  fi
}

site_type_label() {
  case "$SITE_TYPE" in
    static) printf '静态网站' ;;
    php)
      if [[ -n "$PHP_VERSION" ]]; then printf 'PHP %s' "$PHP_VERSION"; else printf 'PHP（自动选择最新的 8.x）'; fi
      ;;
    proxy) printf '反向代理 → http://%s' "$PROXY_TARGET" ;;
  esac
}

show_site_plan() {
  kv "域名" "$DOMAIN"
  if [[ "$WITH_WWW" == 1 ]]; then
    kv "www" "www.${DOMAIN} → 跳转到 ${DOMAIN}"
  fi
  kv "网站类型" "$(site_type_label)"
  if [[ "$SITE_TYPE" != proxy ]]; then
    if [[ "$WEBROOT_EXISTS" == 1 ]]; then
      kv "网站目录" "${WEBROOT}（已存在，保留现有文件）"
    else
      kv "网站目录" "${WEBROOT}（新建）"
    fi
  fi
  if [[ "$SITE_EXISTS" == 1 ]]; then
    kv "现有配置" "覆盖（自动备份到 ${BACKUP_DIR}）"
  fi
  if is_true "$LE_STAGING"; then
    kv "证书" "测试证书（LE_STAGING=1，浏览器会提示不安全）"
  fi
}

prepare_webroot() {
  if [[ "$SITE_TYPE" == proxy ]]; then
    return 0
  fi
  if [[ -d "$WEBROOT" ]]; then
    info "网站目录已存在，保留现有文件和权限：${WEBROOT}"
    return 0
  fi
  install -d -m 0755 -o www-data -g www-data "$WEBROOT"
  WEBROOT_CREATED=1
  info "已创建网站目录：${WEBROOT}"
}

ensure_base_packages() {
  local -a pkgs=(ca-certificates curl openssl iproute2 nginx certbot)
  if [[ "$CFG_FAIL2BAN" == 1 ]]; then
    pkgs+=(fail2ban python3-systemd)
  fi
  install_packages "${pkgs[@]}"
}

run_add_site_steps() {
  section "添加网站：${DOMAIN}"
  ensure_base_packages
  if [[ "$DNS_CHECKED" != 1 ]]; then
    DNS_DEFERRED=1
    check_dns
  fi
  ensure_nginx_base
  if [[ "$SITE_TYPE" == php ]]; then
    install_php
  fi
  prepare_webroot
  issue_certificate_and_configure
  reload_fail2ban
  if is_true "$RUN_RENEW_DRY_RUN"; then
    info "测试证书续签（dry-run）..."
    certbot renew --dry-run --cert-name "$DOMAIN"
  fi
}

print_site_summary() {
  local cmd
  cmd="$(command_name)"
  section "网站添加完成"
  kv "网站地址" "https://${DOMAIN}"
  if [[ "$WITH_WWW" == 1 ]]; then
    kv "www 跳转" "https://www.${DOMAIN} → https://${DOMAIN}"
  fi
  kv "网站类型" "$(site_type_label)"
  if [[ "$SITE_TYPE" != proxy ]]; then
    kv "网站目录" "$WEBROOT"
  fi
  kv "Nginx 配置" "$SITE_CONF"
  kv "证书到期" "$(cert_expiry_label "$DOMAIN")，到期前自动续签"
  if is_true "$LE_STAGING"; then
    warn "当前是测试证书，浏览器会提示不安全。确认流程无误后，不带 LE_STAGING 重新添加即可换成正式证书。"
  fi

  printf '\n下一步：\n'
  case "$SITE_TYPE" in
    static|php)
      printf '  把网站文件上传到 %s（上传前访问网站会显示 403）。\n' "$WEBROOT"
      if [[ -L "$WWW_LINK" && "$WEBROOT" == "${WWW_BASE}/"* ]]; then
        printf '  使用 WinSCP 时可以直接打开 %s/%s。\n' "$WWW_LINK" "${WEBROOT#"${WWW_BASE}"/}"
      fi
      ;;
    proxy)
      printf '  确认后端服务正在 %s 上运行，否则访问网站会返回 502。\n' "$PROXY_TARGET"
      ;;
  esac
  if [[ "$SITE_TYPE" == php ]]; then
    printf '  PHP 以 www-data 用户运行；程序需要写入文件时，请执行：chown -R www-data:www-data %s\n' "$WEBROOT"
  fi

  printf '\n常用命令：\n'
  printf '  %-30s %s\n' "${cmd}" "添加网站"
  printf '  %-30s %s\n' "${cmd} list" "查看已添加的网站"
  printf '  %-30s %s\n' "${cmd} status" "查看服务状态"
  if [[ "$SITE_TYPE" == php ]]; then
    printf '  %-30s %s\n' "systemctl status php${PHP_VERSION}-fpm" "查看 PHP-FPM 状态"
  fi
  printf '  %-30s %s\n' "certbot certificates" "查看证书详情"
}

# ---------------------------------------------------------------------------
# 命令：init
# ---------------------------------------------------------------------------
show_init_plan() {
  local components="Nginx、Certbot"
  if [[ "$CFG_FAIL2BAN" == 1 ]]; then components+="、Fail2ban"; fi
  section "即将执行"
  kv "系统更新" "apt-get update && apt-get upgrade"
  kv "安装组件" "$components"
  kv "Swap" "$SWAP_NOTE"
  kv "SSH 端口" "$(ssh_port_label)"
  if [[ "$CFG_FAIL2BAN" == 1 ]]; then
    kv "Fail2ban" "启用"
  else
    kv "Fail2ban" "不启用"
  fi
  kv "证书邮箱" "${CFG_LE_EMAIL:-不填写}"
  if [[ "$WANT_FIRST_SITE" == 1 ]]; then
    printf '\n  初始化完成后添加网站：\n'
    show_site_plan
  fi
}

print_init_summary() {
  local cmd
  cmd="$(command_name)"
  section "初始化完成"
  kv "Nginx" "$(service_label nginx)"
  kv "证书自动续签" "$(service_label certbot.timer)"
  if [[ "$CFG_FAIL2BAN" == 1 ]]; then
    kv "Fail2ban" "$(service_label fail2ban)"
  else
    kv "Fail2ban" "未启用"
  fi
  kv "Swap" "$SWAP_NOTE"
  kv "SSH 端口" "$SSH_PORTS"
  kv "管理命令" "${BIN_DIR}/${cmd}"
  if [[ "$WANT_FIRST_SITE" != 1 ]]; then
    printf '\n以后添加网站，请运行：%s\n' "$cmd"
  fi
}

cmd_init() {
  preflight init
  if [[ ! -f "$SCRIPT_SOURCE" ]]; then
    die "请先把脚本下载为文件再运行，例如：wget -O deploy.sh <下载地址> && bash deploy.sh"
  fi
  if is_initialized; then
    load_config
    warn "系统已经初始化过（${CONFIG_FILE}）。重新初始化会重新应用 Swap、Fail2ban 等设置，已添加的网站不受影响。"
  fi

  section "系统初始化"
  collect_swap
  collect_ssh_port
  collect_fail2ban
  collect_email
  decide_first_site
  if [[ "$WANT_FIRST_SITE" == 1 ]]; then
    collect_site_settings
  fi

  show_init_plan
  confirm_ssh_port_change
  confirm_or_exit "确认开始？"

  update_system
  section "安装与配置"
  configure_swap
  ensure_base_packages
  ensure_www_shortcut
  ensure_nginx_base
  reload_nginx
  configure_ufw
  if [[ "$SSH_PORT_CHANGED" == 1 ]] && ! change_ssh_port; then
    SSH_PORT_CHANGED=0
    SSH_PORT="$CURRENT_SSH_PORT"
  fi
  configure_fail2ban
  configure_renewal
  save_config
  install_command
  print_init_summary

  if [[ "$WANT_FIRST_SITE" == 1 ]]; then
    run_add_site_steps
    print_site_summary
  fi
  print_ssh_port_notice
}

# ---------------------------------------------------------------------------
# 命令：add
# ---------------------------------------------------------------------------
cmd_add() {
  preflight add
  if ! is_initialized; then
    die "系统尚未初始化，请先运行：bash deploy.sh"
  fi
  load_config
  if [[ -n "${1:-}" ]]; then
    DOMAIN="$1"
  fi
  if [[ "$LE_EMAIL_PRESET" != 1 ]]; then
    LE_EMAIL="$CFG_LE_EMAIL"
  fi
  validate_email LE_EMAIL || die "$VALIDATION_ERROR"

  collect_site_settings
  section "即将添加网站"
  show_site_plan
  confirm_or_exit "确认添加？"

  run_add_site_steps
  print_site_summary
}

# ---------------------------------------------------------------------------
# 命令：list / status / remove / update
# ---------------------------------------------------------------------------
cmd_list() {
  local conf name check type state expiry width=8 i
  local -a names=() types=() states=() expiries=()

  for conf in "$NGINX_SITES_AVAILABLE"/*; do
    [[ -f "$conf" ]] || continue
    name="${conf##*/}"
    check="$name"
    if ! validate_domain check || [[ "$check" != "$name" ]]; then
      continue
    fi
    load_site_meta "$conf"
    case "$META_TYPE" in
      static) type="静态网站" ;;
      php) type="PHP ${META_PHP}" ;;
      proxy) type="反向代理 → ${META_PROXY}" ;;
      *) type="非本脚本创建" ;;
    esac
    if [[ -e "${NGINX_SITES_ENABLED}/${name}" ]]; then state="已启用"; else state="未启用"; fi
    expiry="$(cert_expiry_label "$name")"
    names+=("$name"); types+=("$type"); states+=("$state"); expiries+=("$expiry")
    if (( ${#name} + 2 > width )); then width=$(( ${#name} + 2 )); fi
  done

  section "已添加的网站"
  if (( ${#names[@]} == 0 )); then
    printf '  还没有添加任何网站。运行 %s 添加。\n' "$(command_name)"
    return 0
  fi
  printf '  %s%s%s%s\n' "$(pad "域名" "$width")" "$(pad "状态" 10)" "$(pad "证书到期" 28)" "类型"
  for (( i = 0; i < ${#names[@]}; i++ )); do
    printf '  %s%s%s%s\n' "$(pad "${names[$i]}" "$width")" "$(pad "${states[$i]}" 10)" "$(pad "${expiries[$i]}" 28)" "${types[$i]}"
  done
}

cmd_status() {
  local unit swap_mb
  section "服务状态"
  kv "Nginx" "$(service_label nginx)"
  while read -r unit _; do
    if [[ "$unit" =~ ^php([0-9.]+)-fpm\.service$ ]]; then
      kv "PHP-FPM ${BASH_REMATCH[1]}" "$(service_label "$unit")"
    fi
  done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null || true)
  if [[ "$CFG_FAIL2BAN" == 1 ]]; then
    kv "Fail2ban" "$(service_label fail2ban)"
  else
    kv "Fail2ban" "未启用"
  fi
  kv "证书自动续签" "$(service_label certbot.timer)"
  swap_mb="$(awk '/^SwapTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)" || swap_mb=0
  if [[ "${swap_mb:-0}" =~ ^[1-9][0-9]*$ ]]; then kv "Swap" "${swap_mb} MB"; else kv "Swap" "无"; fi
  kv "脚本版本" "v${SCRIPT_VERSION}"
  cmd_list
}

cmd_remove() {
  local has_conf=0 has_cert=0 root=""
  DOMAIN="${1:-}"
  if [[ -z "$DOMAIN" ]]; then
    die "请指定要删除的域名，例如：$(command_name) remove example.com"
  fi
  validate_domain DOMAIN || die "$VALIDATION_ERROR"
  set_site_paths
  if [[ -f "$SITE_CONF" ]]; then has_conf=1; fi
  if cert_exists; then has_cert=1; fi
  if [[ "$has_conf" == 0 && "$has_cert" == 0 ]]; then
    die "没有找到 ${DOMAIN} 的 Nginx 配置或证书。"
  fi
  load_site_meta "$SITE_CONF"
  root="$META_ROOT"

  section "删除网站：${DOMAIN}"
  if [[ "$has_conf" == 1 ]]; then kv "Nginx 配置" "删除（自动备份到 ${BACKUP_DIR}）"; fi
  if [[ "$has_cert" == 1 ]]; then kv "证书" "删除"; fi
  if [[ -n "$root" ]]; then kv "网站文件" "${root}（保留，不会删除）"; fi
  if ! confirm_risky "确认删除 ${DOMAIN}？"; then
    info "已取消。"
    exit 0
  fi

  if [[ "$has_conf" == 1 ]]; then
    backup_site_config
    rm -f "$SITE_LINK" "$SITE_CONF"
    if nginx_test; then
      reload_nginx
    else
      warn "删除后 Nginx 配置检查未通过，请手动检查。被删除的配置已备份到：${SITE_BACKUP}"
    fi
  fi
  if [[ "$has_cert" == 1 ]]; then
    certbot delete --cert-name "$DOMAIN" --non-interactive
  fi
  info "已删除 ${DOMAIN}。"
  if [[ -n "$root" && -d "$root" ]]; then
    info "网站文件仍保留在 ${root}，确认不再需要后可以手动删除。"
  fi
}

cmd_ssh_port() {
  if ! is_initialized; then
    die "系统尚未初始化，请先运行：bash deploy.sh"
  fi
  if [[ -n "${1:-}" ]]; then
    SSH_PORT="$1"
  fi
  collect_ssh_port
  if [[ "$SSH_PORT_CHANGED" != 1 ]]; then
    info "SSH 端口没有变化（${SSH_PORTS}）。"
    return 0
  fi
  section "修改 SSH 端口"
  kv "SSH 端口" "$(ssh_port_label)"
  confirm_ssh_port_change
  install_packages iproute2
  if ufw_active; then
    info "检测到 UFW 已启用，放行新端口 ${SSH_PORT}。"
    ufw_allow "$SSH_PORT"
  fi
  if ! change_ssh_port; then
    die "修改 SSH 端口失败，SSH 仍使用原端口 ${CURRENT_SSH_PORT}。"
  fi
  configure_fail2ban
  print_ssh_port_notice
}

cmd_update() {
  local tmp remote current
  current="$(installed_version)"
  current="${current:-$SCRIPT_VERSION}"
  tmp="$(mktemp)"
  info "下载最新版本：${UPDATE_URL}"
  if ! curl -fsSL --max-time 60 -o "$tmp" "$UPDATE_URL"; then
    rm -f "$tmp"
    die "下载失败，请检查网络后重试。"
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "下载的文件不是有效的脚本，已放弃更新。"
  fi
  remote="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"$/\1/p' "$tmp" | head -n 1)" || remote=""
  if [[ -z "$remote" ]]; then
    rm -f "$tmp"
    die "无法识别下载文件的版本号，已放弃更新。"
  fi
  if version_ge "$current" "$remote"; then
    rm -f "$tmp"
    info "已是最新版本（v${current}）。"
    return 0
  fi
  install_file_atomic "$tmp" "$INSTALLED_SCRIPT" 0755
  rm -f "$tmp"
  SCRIPT_SOURCE="$INSTALLED_SCRIPT"
  install_command
  info "已从 v${current} 更新到 v${remote}。"
}

usage() {
  cat <<EOF
WebStack Deploy v${SCRIPT_VERSION}：Debian 服务器初始化与网站部署

用法：
  bash deploy.sh [命令]      首次使用：下载脚本后运行，初始化服务器
  deploy [命令] [参数]       初始化完成后使用

命令：
  （不带命令）      未初始化时执行 init，已初始化时执行 add
  init              初始化服务器；可重复执行，用于修改 Swap、SSH 端口、Fail2ban 等设置
  add [域名]        添加网站，也可以直接写成 deploy example.com
  list              列出已添加的网站和证书到期时间
  remove <域名>     删除网站的 Nginx 配置和证书（网站文件保留）
  status            查看 Nginx、PHP-FPM、Fail2ban 等服务的状态
  ssh-port [端口]   修改 SSH 端口
  update            把 deploy 命令更新到最新版本
  help              显示本帮助
  version           显示版本号

非交互使用方法和全部环境变量见：${PROJECT_URL}
EOF
}

main() {
  local cmd="${1:-}"
  setup_colors
  case "$cmd" in
    -h|--help|help) usage; return 0 ;;
    -v|--version|version) printf 'webstack-deploy v%s\n' "$SCRIPT_VERSION"; return 0 ;;
  esac
  if (( $# > 0 )); then shift; fi

  case "$cmd" in
    '')
      if is_initialized; then
        if [[ ! "$SCRIPT_SOURCE" -ef "$INSTALLED_SCRIPT" ]]; then
          info "系统已经初始化，进入添加网站流程（如需重新初始化，请运行 deploy init）。"
        fi
        cmd_add
      else
        cmd_init
      fi
      ;;
    init) cmd_init ;;
    add) cmd_add "${1:-}" ;;
    list|ls) preflight list; cmd_list ;;
    status) preflight status; cmd_status ;;
    remove|rm|delete) preflight remove; cmd_remove "${1:-}" ;;
    ssh-port) preflight ssh-port; cmd_ssh_port "${1:-}" ;;
    update) preflight update; cmd_update ;;
    -*) die "未知选项：${cmd}。运行 deploy help 查看用法。" ;;
    *.*) cmd_add "$cmd" ;;
    *) die "未知命令：${cmd}。运行 deploy help 查看用法。" ;;
  esac
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap on_interrupt INT

if [[ "${WEBSTACK_DEPLOY_LIB:-0}" != 1 ]]; then
  main "$@"
fi
