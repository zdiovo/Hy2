#!/usr/bin/env bash
set -euo pipefail

# 可通过 HY2_CONFIG_DIR 覆盖配置目录，便于本地测试；正式服务器默认使用 /etc/hysteria。
CONFIG_DIR="${HY2_CONFIG_DIR:-/etc/hysteria}"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
STATE_FILE="$CONFIG_DIR/hy2-manager.env"
SERVICE_NAME="hysteria-server.service"
MIHOMO_FILE="$CONFIG_DIR/hy2-mihomo.yaml"

DEFAULT_PORT_RANGE="20000-50000"
DEFAULT_SINGLE_PORT="443"
DEFAULT_MASQ_URL="https://www.bing.com"
DEFAULT_CONGESTION="bbr"
DEFAULT_BBR_PROFILE="standard"
DEFAULT_HOP_INTERVAL="30"
DEFAULT_CLIENT_UP="50 Mbps"
DEFAULT_CLIENT_DOWN="300 Mbps"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "${BLUE}%s${NC}\n" "$*"; }
ok() { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*" >&2; }
err() { printf "${RED}%s${NC}\n" "$*" >&2; }

pause() {
  read -r -p "按回车继续..." _
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 运行：sudo bash $0"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

read_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

read_required() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt: " value
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
    warn "不能为空，请重新输入。"
  done
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  local answer
  read -r -p "$prompt $hint: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

random_password() {
  if command_exists openssl; then
    openssl rand -base64 32 | tr -d '=+/' | cut -c1-32
  else
    date +%s%N | sha256sum | cut -c1-32
  fi
}

random_email() {
  local domain="${1:-}"
  local token
  token="$(random_password | cut -c1-12)"
  if validate_domain "$domain"; then
    printf 'hy2-%s@%s' "$token" "$domain"
  else
    printf ''
  fi
}

email_uses_forbidden_domain() {
  local email="$1"
  [[ "$email" =~ @(example\.com|example\.net|example\.org|invalid|localhost)$ ]]
}

ensure_acme_email() {
  # Let's Encrypt 会拒绝 example.com 这类保留域名；随机邮箱使用用户自己的域名。
  if [[ -z "${ACME_EMAIL:-}" ]] || email_uses_forbidden_domain "$ACME_EMAIL"; then
    ACME_EMAIL="$(random_email "$DOMAIN")"
  fi
  if [[ -z "$ACME_EMAIL" ]]; then
    err "无法生成 ACME 邮箱，请检查域名格式。"
    return 1
  fi
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

save_state() {
  # 维护脚本自己的状态，避免每次都从 YAML 里反向解析字段。
  mkdir -p "$CONFIG_DIR"
  cat > "$STATE_FILE" <<EOF
DOMAIN=$(printf '%q' "${DOMAIN:-}")
ACME_EMAIL=$(printf '%q' "${ACME_EMAIL:-}")
PASSWORD=$(printf '%q' "${PASSWORD:-}")
LISTEN_MODE=$(printf '%q' "${LISTEN_MODE:-range}")
PORT_START=$(printf '%q' "${PORT_START:-20000}")
PORT_END=$(printf '%q' "${PORT_END:-50000}")
MASQ_URL=$(printf '%q' "${MASQ_URL:-$DEFAULT_MASQ_URL}")
OBFS_ENABLED=$(printf '%q' "${OBFS_ENABLED:-false}")
OBFS_PASSWORD=$(printf '%q' "${OBFS_PASSWORD:-}")
CONGESTION_TYPE=$(printf '%q' "${CONGESTION_TYPE:-$DEFAULT_CONGESTION}")
BBR_PROFILE=$(printf '%q' "${BBR_PROFILE:-$DEFAULT_BBR_PROFILE}")
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  DOMAIN="${DOMAIN:-}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  PASSWORD="${PASSWORD:-}"
  LISTEN_MODE="${LISTEN_MODE:-range}"
  PORT_START="${PORT_START:-20000}"
  PORT_END="${PORT_END:-50000}"
  MASQ_URL="${MASQ_URL:-$DEFAULT_MASQ_URL}"
  OBFS_ENABLED="${OBFS_ENABLED:-false}"
  OBFS_PASSWORD="${OBFS_PASSWORD:-}"
  CONGESTION_TYPE="${CONGESTION_TYPE:-$DEFAULT_CONGESTION}"
  BBR_PROFILE="${BBR_PROFILE:-$DEFAULT_BBR_PROFILE}"
}

backup_config() {
  # 所有会改服务端配置的操作都会先备份，方便维护时快速恢复。
  mkdir -p "$CONFIG_DIR"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "$CONFIG_FILE.bak.$ts"
    ok "已备份：$CONFIG_FILE.bak.$ts"
  fi
  if [[ -f "$STATE_FILE" ]]; then
    cp -a "$STATE_FILE" "$STATE_FILE.bak.$ts"
    ok "已备份：$STATE_FILE.bak.$ts"
  fi
}

validate_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

validate_port_range() {
  [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  local start="${BASH_REMATCH[1]}"
  local end="${BASH_REMATCH[2]}"
  validate_port "$start" && validate_port "$end" && (( start < end ))
}

validate_url() {
  [[ "$1" =~ ^https://[^[:space:]/]+(/.*)?$ ]]
}

install_deps() {
  local packages=(curl openssl ca-certificates iptables nftables)
  if command_exists apt-get; then
    apt-get update
    apt-get install -y "${packages[@]}"
  elif command_exists dnf; then
    dnf install -y "${packages[@]}"
  elif command_exists yum; then
    yum install -y "${packages[@]}"
  elif command_exists apk; then
    apk add --no-cache "${packages[@]}"
  else
    warn "未识别包管理器，请确保已安装 curl、openssl、ca-certificates。"
  fi
}

print_firewall_hint() {
  load_state
  echo
  warn "请确认云厂商安全组/本机防火墙已放行："
  echo "  TCP 80              用于 ACME HTTP-01"
  if [[ "$LISTEN_MODE" == "range" ]]; then
    echo "  UDP ${PORT_START}-${PORT_END}      用于 Hysteria2 端口跳跃"
  else
    echo "  UDP ${PORT_START}            用于 Hysteria2 单端口"
  fi
}

set_server_config_permissions() {
  # 官方 systemd 服务可能不是 root 运行；config.yaml 必须让服务用户可读。
  local service_user service_group
  service_user=""
  service_group=""

  if command_exists systemctl; then
    service_user="$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)"
    service_group="$(systemctl show "$SERVICE_NAME" -p Group --value 2>/dev/null || true)"
  fi

  if [[ -n "$service_user" && "$service_user" != "root" ]] && id "$service_user" >/dev/null 2>&1; then
    if [[ -z "$service_group" ]] || ! getent group "$service_group" >/dev/null 2>&1; then
      service_group="$(id -gn "$service_user")"
    fi
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      chown root:"$service_group" "$CONFIG_DIR" "$CONFIG_FILE"
    fi
    chmod 750 "$CONFIG_DIR"
    chmod 640 "$CONFIG_FILE"
    ok "已设置配置权限：root:$service_group 640，服务用户 $service_user 可读取。"
  elif [[ -z "$service_user" || "$service_user" == "root" ]]; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      chown root:root "$CONFIG_FILE" 2>/dev/null || chown root:0 "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE"
    ok "已设置配置权限：root:root 600。"
  else
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      chown root:root "$CONFIG_FILE" 2>/dev/null || chown root:0 "$CONFIG_FILE"
    fi
    chmod 644 "$CONFIG_FILE"
    warn "未能确认服务用户 $service_user，已临时设置 config.yaml 为 644 以保证服务可读取。"
  fi
}

detect_hysteria_service_user() {
  local service_user
  service_user=""

  if command_exists systemctl; then
    service_user="$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)"
  fi

  if [[ -z "$service_user" && -f /etc/systemd/system/hysteria-server.service ]]; then
    service_user="$(grep -E '^User=' /etc/systemd/system/hysteria-server.service 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
  fi

  printf '%s' "${service_user:-hysteria}"
}

stop_disable_hysteria_services() {
  local services service
  services="$SERVICE_NAME"

  if command_exists systemctl; then
    services="$(
      {
        printf '%s\n' "$SERVICE_NAME"
        systemctl list-units --all --type=service --plain --no-legend 'hysteria-server*.service' 2>/dev/null | awk '{print $1}'
        systemctl list-unit-files --type=service --plain --no-legend 'hysteria-server*.service' 2>/dev/null | awk '{print $1}'
      } | sort -u
    )"
    while IFS= read -r service; do
      [[ -z "$service" ]] && continue
      systemctl stop "$service" >/dev/null 2>&1 || true
      systemctl disable "$service" >/dev/null 2>&1 || true
    done <<< "$services"
  fi
}

check_environment() {
  info "检查运行环境..."
  if ! command_exists systemctl; then
    warn "未检测到 systemctl。官方安装脚本通常按 systemd 服务部署，请确认系统支持。"
  fi
  if ! command_exists nft && ! command_exists iptables; then
    warn "未检测到 nft 或 iptables。端口跳跃需要其中之一。"
  fi
  if command_exists ss && ss -lnt "( sport = :80 )" | grep -q ':80'; then
    warn "TCP 80 已被占用。HTTP-01 证书签发可能失败，除非你已做好反代/端口转发。"
  fi
  ok "环境检查完成。"
}

install_hysteria() {
  # 使用官方安装脚本，避免脚本内硬编码不同架构的下载地址。
  install_deps
  info "使用官方脚本安装/更新 Hysteria2..."
  bash <(curl -fsSL https://get.hy2.sh/)
  ok "Hysteria2 安装/更新完成。"
}

select_masquerade_url() {
  # 不默认反代当前 Hysteria2 域名，避免自己反代自己导致循环。
  local choice custom
  while true; do
    cat <<'EOF'

请选择伪装站点 masquerade proxy url：
1. https://www.bing.com              推荐，稳定，通用
2. https://www.apple.com             大流量品牌站
3. https://www.icloud.com            Apple 云服务
4. https://www.yahoo.com             门户站
5. https://www.microsoft.com         大厂官网
6. https://www.epicgames.com         游戏平台
7. https://store.steampowered.com    游戏商店
8. https://www.nvidia.com            游戏/硬件相关
9. 自定义 URL
EOF
    read -r -p "请选择 [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) MASQ_URL="https://www.bing.com"; return ;;
      2) MASQ_URL="https://www.apple.com"; return ;;
      3) MASQ_URL="https://www.icloud.com"; return ;;
      4) MASQ_URL="https://www.yahoo.com"; return ;;
      5) MASQ_URL="https://www.microsoft.com"; return ;;
      6) MASQ_URL="https://www.epicgames.com"; return ;;
      7) MASQ_URL="https://store.steampowered.com"; return ;;
      8) MASQ_URL="https://www.nvidia.com"; return ;;
      9)
        custom="$(read_required "请输入 https:// 开头的伪装 URL")"
        if validate_url "$custom"; then
          MASQ_URL="$custom"
          return
        fi
        warn "URL 格式不正确，必须是 https:// 开头。"
        ;;
      *) warn "无效选择。" ;;
    esac
  done
}

configure_base() {
  # 全新部署只询问服务端必要字段；客户端 bandwidth 在导出 YAML 时再问。
  load_state

  while true; do
    DOMAIN="$(read_required "请输入 Hysteria2 域名，例如 hy2.example.com")"
    if validate_domain "$DOMAIN"; then
      break
    fi
    warn "域名格式不正确。"
  done

  ACME_EMAIL="$(random_email "$DOMAIN")"
  ok "ACME 邮箱已随机生成：$ACME_EMAIL"

  local password_input
  read -r -p "请输入认证密码，直接回车随机生成: " password_input
  PASSWORD="${password_input:-$(random_password)}"
  ok "认证密码：$PASSWORD"

  cat <<'EOF'

请选择监听模式：
1. 多端口跳跃，默认 20000-50000
2. 单端口，默认 443
EOF
  local mode range port
  read -r -p "请选择 [1]: " mode
  mode="${mode:-1}"
  if [[ "$mode" == "2" ]]; then
    LISTEN_MODE="single"
    while true; do
      port="$(read_default "请输入监听端口" "$DEFAULT_SINGLE_PORT")"
      if validate_port "$port"; then
        PORT_START="$port"
        PORT_END="$port"
        break
      fi
      warn "端口必须是 1-65535。"
    done
  else
    LISTEN_MODE="range"
    while true; do
      range="$(read_default "请输入端口跳跃范围" "$DEFAULT_PORT_RANGE")"
      if validate_port_range "$range"; then
        PORT_START="${range%-*}"
        PORT_END="${range#*-}"
        ok "主端口自动使用范围第一个端口：$PORT_START"
        break
      fi
      warn "端口范围格式应为 小端口-大端口，例如 20000-50000。"
    done
  fi

  select_masquerade_url

  OBFS_ENABLED="false"
  OBFS_PASSWORD=""
  if confirm "是否启用 Salamander 混淆？默认关闭"; then
    OBFS_ENABLED="true"
    read -r -p "请输入 obfs 密码，直接回车随机生成: " password_input
    OBFS_PASSWORD="${password_input:-$(random_password)}"
  fi

  CONGESTION_TYPE="$DEFAULT_CONGESTION"
  BBR_PROFILE="$DEFAULT_BBR_PROFILE"
  if confirm "是否进入高级拥塞控制设置？默认否，直接回车使用 bbr standard"; then
    select_congestion
  fi

  save_state
  write_server_config
  print_firewall_hint
}

select_congestion() {
  # 未配置 bandwidth 的方向会使用 congestion；默认 bbr standard 更稳妥。
  local choice
  cat <<'EOF'

请选择拥塞控制：
1. bbr standard       推荐默认
2. bbr conservative   更保守
3. bbr aggressive     更激进
4. reno               更简单保守
EOF
  read -r -p "请选择 [1]: " choice
  choice="${choice:-1}"
  case "$choice" in
    2) CONGESTION_TYPE="bbr"; BBR_PROFILE="conservative" ;;
    3) CONGESTION_TYPE="bbr"; BBR_PROFILE="aggressive" ;;
    4) CONGESTION_TYPE="reno"; BBR_PROFILE="" ;;
    *) CONGESTION_TYPE="bbr"; BBR_PROFILE="standard" ;;
  esac
}

write_server_config() {
  # 只生成官方 Hysteria2 服务端需要的配置，不写客户端视角的 up/down。
  load_state
  if [[ -z "$DOMAIN" || -z "$PASSWORD" ]]; then
    err "缺少域名或密码，请先完成基础配置。"
    return 1
  fi
  ensure_acme_email
  save_state

  backup_config
  mkdir -p "$CONFIG_DIR"

  local listen_value
  if [[ "$LISTEN_MODE" == "range" ]]; then
    listen_value=":${PORT_START}-${PORT_END}"
  else
    listen_value=":${PORT_START}"
  fi

  {
    printf 'listen: %s\n\n' "$listen_value"
    printf 'acme:\n'
    printf '  domains:\n'
    printf '    - %s\n' "$DOMAIN"
    printf '  email: %s\n' "$ACME_EMAIL"
    printf '  type: http\n'
    printf '  http:\n'
    printf '    altPort: 80\n\n'
    printf 'auth:\n'
    printf '  type: password\n'
    printf '  password: %s\n\n' "$(yaml_quote "$PASSWORD")"
    if [[ "$OBFS_ENABLED" == "true" ]]; then
      printf 'obfs:\n'
      printf '  type: salamander\n'
      printf '  salamander:\n'
      printf '    password: %s\n\n' "$(yaml_quote "$OBFS_PASSWORD")"
    fi
    printf 'congestion:\n'
    printf '  type: %s\n' "$CONGESTION_TYPE"
    if [[ "$CONGESTION_TYPE" == "bbr" ]]; then
      printf '  bbrProfile: %s\n' "$BBR_PROFILE"
    fi
    printf '\n'
    printf 'masquerade:\n'
    printf '  type: proxy\n'
    printf '  proxy:\n'
    printf '    url: %s\n' "$MASQ_URL"
    printf '    rewriteHost: true\n'
  } > "$CONFIG_FILE"

  set_server_config_permissions
  ok "服务端配置已生成：$CONFIG_FILE"
}

repair_acme_email_if_needed() {
  load_state
  if [[ -z "$DOMAIN" || -z "$PASSWORD" ]]; then
    return
  fi
  if [[ -z "${ACME_EMAIL:-}" ]] || email_uses_forbidden_domain "$ACME_EMAIL"; then
    warn "检测到 ACME 邮箱为空或使用了 CA 禁止的保留域名，正在自动修复。"
    write_server_config
  fi
}

restart_service() {
  if command_exists systemctl; then
    repair_acme_email_if_needed
    [[ -f "$CONFIG_FILE" ]] && set_server_config_permissions
    systemctl enable --now "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    ok "服务已重启：$SERVICE_NAME"
  else
    warn "未检测到 systemctl，请手动启动 Hysteria2。"
  fi
}

update_hysteria() {
  install_hysteria
  if [[ -f "$CONFIG_FILE" ]] && confirm "是否立即重启服务以使用新版 Hysteria2？" "y"; then
    restart_service
  fi
}

show_status() {
  if command_exists systemctl; then
    systemctl status "$SERVICE_NAME" --no-pager || true
  else
    warn "未检测到 systemctl。"
  fi
}

show_logs() {
  if command_exists journalctl; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
  else
    warn "未检测到 journalctl。"
  fi
}

show_logs_since() {
  local since="$1"
  if command_exists journalctl; then
    journalctl -u "$SERVICE_NAME" --since "$since" --no-pager || true
  else
    warn "未检测到 journalctl。"
  fi
}

follow_logs() {
  if command_exists journalctl; then
    journalctl -u "$SERVICE_NAME" -f
  else
    warn "未检测到 journalctl。"
  fi
}

show_current_config() {
  load_state
  cat <<EOF

当前脚本状态：
域名: ${DOMAIN:-未设置}
ACME 邮箱: ${ACME_EMAIL:-未设置}
监听模式: ${LISTEN_MODE:-未设置}
主端口: ${PORT_START:-未设置}
端口范围: ${PORT_START:-}-${PORT_END:-}
伪装 URL: ${MASQ_URL:-未设置}
obfs: ${OBFS_ENABLED:-false}
拥塞控制: ${CONGESTION_TYPE:-bbr} ${BBR_PROFILE:-}

配置文件: $CONFIG_FILE
客户端 YAML: $MIHOMO_FILE
EOF
  if [[ -f "$CONFIG_FILE" ]]; then
    echo
    sed -n '1,220p' "$CONFIG_FILE"
  fi
}

change_domain_acme() {
  load_state
  local new_domain
  while true; do
    new_domain="$(read_required "请输入新域名")"
    if validate_domain "$new_domain"; then
      DOMAIN="$new_domain"
      break
    fi
    warn "域名格式不正确。"
  done
  ACME_EMAIL="$(random_email "$DOMAIN")"
  ok "新的 ACME 邮箱：$ACME_EMAIL"
  save_state
  write_server_config
  print_firewall_hint
  restart_service
}

change_ports() {
  load_state
  local mode range port
  cat <<'EOF'

请选择监听模式：
1. 多端口跳跃
2. 单端口
EOF
  read -r -p "请选择 [1]: " mode
  mode="${mode:-1}"
  if [[ "$mode" == "2" ]]; then
    LISTEN_MODE="single"
    while true; do
      port="$(read_default "请输入监听端口" "$DEFAULT_SINGLE_PORT")"
      if validate_port "$port"; then
        PORT_START="$port"
        PORT_END="$port"
        break
      fi
      warn "端口必须是 1-65535。"
    done
  else
    LISTEN_MODE="range"
    while true; do
      range="$(read_default "请输入端口跳跃范围" "$DEFAULT_PORT_RANGE")"
      if validate_port_range "$range"; then
        PORT_START="${range%-*}"
        PORT_END="${range#*-}"
        break
      fi
      warn "端口范围格式应为 小端口-大端口。"
    done
  fi
  save_state
  write_server_config
  print_firewall_hint
  restart_service
}

change_password() {
  load_state
  local password_input
  read -r -p "请输入新认证密码，直接回车随机生成: " password_input
  PASSWORD="${password_input:-$(random_password)}"
  ok "新认证密码：$PASSWORD"
  save_state
  write_server_config
  restart_service
}

change_masquerade() {
  load_state
  select_masquerade_url
  save_state
  write_server_config
  restart_service
}

toggle_obfs() {
  load_state
  local password_input
  if [[ "$OBFS_ENABLED" == "true" ]]; then
    if confirm "当前 obfs 已开启，是否关闭？" "y"; then
      OBFS_ENABLED="false"
      OBFS_PASSWORD=""
    fi
  else
    if confirm "当前 obfs 已关闭，是否开启？" "y"; then
      OBFS_ENABLED="true"
      read -r -p "请输入 obfs 密码，直接回车随机生成: " password_input
      OBFS_PASSWORD="${password_input:-$(random_password)}"
      ok "obfs 密码：$OBFS_PASSWORD"
    fi
  fi
  save_state
  write_server_config
  restart_service
}

change_congestion() {
  load_state
  select_congestion
  save_state
  write_server_config
  restart_service
}

export_mihomo() {
  # mihomo 的 up/down 是客户端视角参数，允许每次导出时按当前网络重新填写。
  load_state
  if [[ -z "$DOMAIN" || -z "$PASSWORD" ]]; then
    err "缺少服务端状态，请先安装或配置服务端。"
    return 1
  fi

  local prefix node_name hop up down skip_verify
  prefix="${DOMAIN%%.*}"
  node_name="$(read_default "请输入节点名称" "HY2-$prefix")"
  hop="$(read_default "请输入端口跳跃间隔，单位秒" "$DEFAULT_HOP_INTERVAL")"
  up="$(read_default "请输入客户端上行 up，例如 50 Mbps" "$DEFAULT_CLIENT_UP")"
  down="$(read_default "请输入客户端下载 down，例如 300 Mbps" "$DEFAULT_CLIENT_DOWN")"
  skip_verify="$(read_default "是否跳过证书验证 skip-cert-verify" "false")"

  mkdir -p "$CONFIG_DIR"
  {
    printf 'proxies:\n'
    printf '  - name: %s\n' "$(yaml_quote "$node_name")"
    printf '    type: hysteria2\n'
    printf '    server: %s\n' "$DOMAIN"
    printf '    port: %s\n' "$PORT_START"
    if [[ "$LISTEN_MODE" == "range" ]]; then
      printf '    ports: %s-%s\n' "$PORT_START" "$PORT_END"
      printf '    hop-interval: %s\n' "$hop"
    fi
    printf '    password: %s\n' "$(yaml_quote "$PASSWORD")"
    printf '    up: %s\n' "$(yaml_quote "$up")"
    printf '    down: %s\n' "$(yaml_quote "$down")"
    if [[ "$OBFS_ENABLED" == "true" ]]; then
      printf '    obfs: salamander\n'
      printf '    obfs-password: %s\n' "$(yaml_quote "$OBFS_PASSWORD")"
    fi
    printf '    sni: %s\n' "$DOMAIN"
    printf '    skip-cert-verify: %s\n' "$skip_verify"
    printf '    alpn:\n'
    printf '      - h3\n'
  } > "$MIHOMO_FILE"
  chmod 600 "$MIHOMO_FILE"

  ok "mihomo 客户端 YAML 已生成：$MIHOMO_FILE"
  echo
  cat "$MIHOMO_FILE"
}

restore_config() {
  local latest_config latest_state
  latest_config="$(ls -1t "$CONFIG_FILE".bak.* 2>/dev/null | head -n1 || true)"
  latest_state="$(ls -1t "$STATE_FILE".bak.* 2>/dev/null | head -n1 || true)"
  if [[ -z "$latest_config" && -z "$latest_state" ]]; then
    warn "没有找到备份。"
    return
  fi
  warn "将恢复最近备份："
  [[ -n "$latest_config" ]] && echo "$latest_config"
  [[ -n "$latest_state" ]] && echo "$latest_state"
  if confirm "确认恢复？"; then
    [[ -n "$latest_config" ]] && cp -a "$latest_config" "$CONFIG_FILE"
    [[ -n "$latest_state" ]] && cp -a "$latest_state" "$STATE_FILE"
    [[ -f "$CONFIG_FILE" ]] && set_server_config_permissions
    restart_service
  fi
}

uninstall_hysteria() {
  warn "真正卸载会移除 Hysteria2 程序、systemd 服务，以及本脚本生成的配置。"
  warn "官方卸载路径：bash <(curl -fsSL https://get.hy2.sh/) --remove"
  if ! confirm "确认继续卸载？"; then
    return
  fi

  local keep_data="n"
  local service_user
  service_user="$(detect_hysteria_service_user)"

  if confirm "是否保留配置、备份、客户端 YAML、ACME 证书和服务用户？默认全部删除"; then
    keep_data="y"
  fi

  stop_disable_hysteria_services

  if command_exists curl; then
    info "调用官方安装脚本执行卸载..."
    bash <(curl -fsSL https://get.hy2.sh/) --remove || warn "官方卸载脚本执行失败，将继续清理已知残留。"
  else
    warn "未检测到 curl，跳过官方卸载脚本，改为清理已知路径。"
  fi

  rm -f /usr/local/bin/hysteria
  rm -f /etc/systemd/system/hysteria-server.service
  rm -f /etc/systemd/system/hysteria-server@.service
  rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service
  rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service

  if [[ "$keep_data" == "y" ]]; then
    ok "已按要求保留配置目录、ACME 数据和服务用户。"
  else
    rm -rf "$CONFIG_DIR"
    ok "已删除配置目录：$CONFIG_DIR"

    if [[ -n "$service_user" && "$service_user" != "root" ]] && id "$service_user" >/dev/null 2>&1; then
      if command_exists userdel; then
        userdel -r "$service_user" >/dev/null 2>&1 || warn "删除用户 $service_user 失败，请手动检查。"
      else
        warn "未检测到 userdel，请手动删除用户 $service_user。"
      fi
    fi
  fi

  if command_exists systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_NAME" "hysteria-server@.service" >/dev/null 2>&1 || true
  fi

  ok "Hysteria2 卸载完成。"
}

fresh_install_flow() {
  local log_since
  check_environment
  install_hysteria
  configure_base
  log_since="$(date '+%Y-%m-%d %H:%M:%S')"
  restart_service
  show_logs_since "$log_since"
  export_mihomo
}

main_menu() {
  need_root
  load_state
  while true; do
    cat <<'EOF'

================ Hysteria2 官方服务端管理 ================
1. 全新安装/重装 Hysteria2
2. 查看当前配置
3. 修改域名与 ACME 配置
4. 修改监听端口/端口跳跃范围
5. 修改认证密码
6. 修改伪装站点 masquerade
7. 开启/关闭 Salamander 混淆
8. 修改拥塞控制 congestion
9. 生成/导出 mihomo 客户端 YAML
10. 查看服务状态
11. 查看最近日志
12. 实时跟随日志
13. 重启服务
14. 更新 Hysteria2
15. 备份配置
16. 恢复最近备份
17. 卸载 Hysteria2
0. 退出
===========================================================
EOF
    local choice
    read -r -p "请选择: " choice
    case "$choice" in
      1) fresh_install_flow; pause ;;
      2) show_current_config; pause ;;
      3) change_domain_acme; pause ;;
      4) change_ports; pause ;;
      5) change_password; pause ;;
      6) change_masquerade; pause ;;
      7) toggle_obfs; pause ;;
      8) change_congestion; pause ;;
      9) export_mihomo; pause ;;
      10) show_status; pause ;;
      11) show_logs; pause ;;
      12) follow_logs ;;
      13) restart_service; pause ;;
      14) update_hysteria; pause ;;
      15) backup_config; pause ;;
      16) restore_config; pause ;;
      17) uninstall_hysteria; pause ;;
      0) exit 0 ;;
      *) warn "无效选择。"; pause ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_menu "$@"
fi
