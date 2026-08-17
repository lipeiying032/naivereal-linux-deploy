#!/usr/bin/env bash
set -euo pipefail

REPO="lipeiying032/naive-reality"
REPO_DEPLOY="lipeiying032/naivereal-linux-deploy"
INSTALL_DIR="/opt/naivereal"
CONFIG_DIR="${INSTALL_DIR}/config"
BIN_DIR="${INSTALL_DIR}/bin"
SYSTEMD_DIR="/etc/systemd/system"
MANAGE_CMD="/usr/local/bin/naivereal"

VERSION=""
DOMAIN=""
REALITY_TARGET=""
REALITY_SNI=""
NAIVE_USER="user"
NAIVE_PASS=""
H3_PORT="8443"
H3_MODE="tls"
H3_REALITY_TARGET=""
H3_REALITY_SNI=""
H3_SHORT_ID="0123456789abcdef"
FRONTEND_PORT="443"
DEPLOY_REALITY="no"
DEPLOY_H3="no"

usage() {
  cat <<'USAGE'
Usage: sudo bash install.sh [options]

Options:
  --version <ver>           naivereal Release version, e.g. 1.1.0 (default: latest)
  --domain <domain>         domain for h3frontend TLS (Let's Encrypt)
  --reality-target <host>   REALITY fallback target, e.g. www.microsoft.com
  --reality-sni <host>      REALITY SNI, usually same as target
  --user <user>             naive auth username (default: user)
  --pass <pass>             naive auth password (default: random)
  --h3-port <port>          h3frontend UDP port (default: 8443)
  --h3-mode <tls|reality>   h3frontend transport mode (default: tls)
  --h3-reality-target <host> h3frontend REALITY dest (probe relay target)
  --h3-reality-sni <host>   h3frontend REALITY SNI (default: target)
  --h3-short-id <hex>       h3frontend REALITY short id (default: 0123456789abcdef)
  --frontend-port <port>    REALITY frontend TCP port (default: 443)
  --with-reality            deploy REALITY frontend
  --with-h3                 deploy H3 frontend (--h3-mode reality needs --h3-reality-target)
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) VERSION="$2"; shift 2;;
      --domain) DOMAIN="$2"; DEPLOY_H3="yes"; shift 2;;
      --reality-target) REALITY_TARGET="$2"; DEPLOY_REALITY="yes"; shift 2;;
      --reality-sni) REALITY_SNI="$2"; shift 2;;
      --user) NAIVE_USER="$2"; shift 2;;
      --pass) NAIVE_PASS="$2"; shift 2;;
      --h3-port) H3_PORT="$2"; shift 2;;
      --h3-mode) H3_MODE="$2"; DEPLOY_H3="yes"; shift 2;;
      --h3-reality-target) H3_REALITY_TARGET="$2"; DEPLOY_H3="yes"; shift 2;;
      --h3-reality-sni) H3_REALITY_SNI="$2"; shift 2;;
      --h3-short-id) H3_SHORT_ID="$2"; shift 2;;
      --frontend-port) FRONTEND_PORT="$2"; shift 2;;
      --with-reality) DEPLOY_REALITY="yes"; shift;;
      --with-h3) DEPLOY_H3="yes"; shift;;
      -h|--help) usage; exit 0;;
      *) echo "unknown option: $1" >&2; usage; exit 1;;
    esac
  done
  if [[ -z "$NAIVE_PASS" ]]; then NAIVE_PASS="$(openssl rand -hex 8)"; fi
  if [[ "$H3_MODE" != "tls" && "$H3_MODE" != "reality" ]]; then
    echo "invalid --h3-mode: $H3_MODE (want tls or reality)" >&2
    exit 1
  fi
  if [[ "$H3_MODE" == "reality" && -z "$H3_REALITY_TARGET" ]]; then
    H3_REALITY_TARGET="${REALITY_TARGET:-www.microsoft.com}"
  fi
  if [[ -z "$H3_REALITY_SNI" && -n "$H3_REALITY_TARGET" ]]; then
    H3_REALITY_SNI="${H3_REALITY_TARGET%%:*}"
  fi
}

interactive() {
  echo "===== naivereal 交互式部署 ====="
  echo "直接回车使用默认值；想自定义就先输入内容再回车。"
  echo
  read -r -p "naivereal 版本 (默认 latest): " input
  VERSION="${input:-$VERSION}"

  read -r -p "naive 用户名 (默认 user): " input
  NAIVE_USER="${input:-user}"

  read -r -p "naive 密码 (默认自动生成): " input
  if [[ -n "$input" ]]; then NAIVE_PASS="$input"; fi
  if [[ -z "$NAIVE_PASS" ]]; then NAIVE_PASS="$(openssl rand -hex 8)"; fi

  read -r -p "是否部署 REALITY 前端 (H2 REALITY)? [Y/n] 默认 Y: " input
  if [[ -z "$input" || "$input" =~ ^[Yy]$ ]]; then DEPLOY_REALITY="yes"; fi

  if [[ "$DEPLOY_REALITY" == "yes" ]]; then
    read -r -p "REALITY 目标域名 (默认 www.microsoft.com): " input
    REALITY_TARGET="${input:-www.microsoft.com}"
    read -r -p "REALITY SNI (默认同目标域名): " input
    REALITY_SNI="${input:-$REALITY_TARGET}"
    read -r -p "REALITY 监听端口 (默认 443): " input
    FRONTEND_PORT="${input:-443}"
  fi

  read -r -p "是否部署 H3 frontend (QUIC/HTTP3)? [y/N] 默认 N: " input
  if [[ "$input" =~ ^[Yy]$ ]]; then DEPLOY_H3="yes"; fi

  if [[ "$DEPLOY_H3" == "yes" ]]; then
    read -r -p "H3 模式 tls/reality (默认 tls): " input
    H3_MODE="${input:-tls}"
    if [[ "$H3_MODE" == "reality" ]]; then
      read -r -p "H3 REALITY 目标域名 (默认 www.microsoft.com): " input
      H3_REALITY_TARGET="${input:-www.microsoft.com}"
      H3_REALITY_SNI="${H3_REALITY_TARGET%%:*}"
      read -r -p "H3 REALITY SNI (默认同目标域名): " input
      [[ -n "$input" ]] && H3_REALITY_SNI="${input}"
      read -r -p "H3 REALITY short id (默认 0123456789abcdef): " input
      [[ -n "$input" ]] && H3_SHORT_ID="${input}"
    else
      while [[ -z "$DOMAIN" ]]; do
        read -r -p "H3 域名 (必须填写，用于 TLS 证书): " input
        DOMAIN="${input}"
      done
    fi
    read -r -p "H3 UDP 端口 (默认 8443): " input
    H3_PORT="${input:-8443}"
  fi
  echo
}

install_deps() {
  echo "检查并安装依赖..."
  local need=()
  command -v curl >/dev/null || need+=(curl)
  command -v tar >/dev/null || need+=(tar)
  command -v unzip >/dev/null || need+=(unzip)
  command -v openssl >/dev/null || need+=(openssl)
  if [[ "$DEPLOY_H3" == "yes" && "$H3_MODE" == "tls" ]] && ! command -v certbot >/dev/null; then
    need+=(certbot)
  fi
  if [[ ${#need[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null; then
      apt-get update -qq
      apt-get install -y -qq "${need[@]}"
    elif command -v dnf >/dev/null; then
      dnf install -y "${need[@]}"
    else
      echo "无法自动安装依赖，请手动安装: ${need[*]}" >&2
      exit 1
    fi
  fi
}

download_install() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) KERNEL_ARCH="x64"; GO_ARCH="amd64";;
    aarch64|arm64) KERNEL_ARCH="arm64"; GO_ARCH="arm64";;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1;;
  esac

  if [[ -z "$VERSION" ]]; then
    echo "获取最新 Release 版本..."
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  fi
  if [[ -z "$VERSION" ]]; then
    echo "无法获取最新版本" >&2
    exit 1
  fi
  echo "使用 naivereal 版本: ${VERSION}"

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "${BIN_DIR}" "${CONFIG_DIR}"

  echo "下载 Release 资源..."
  BASE="https://github.com/${REPO}/releases/download/${VERSION}"
  curl -fsSL -o "$TMP/kernel.tar.xz" "${BASE}/naivereal-kernel-linux-${KERNEL_ARCH}.tar.xz"
  curl -fsSL -o "$TMP/frontend" "${BASE}/naivereal-frontend-linux-${GO_ARCH}"
  curl -fsSL -o "$TMP/h3frontend" "${BASE}/naivereal-h3frontend-linux-${GO_ARCH}"

  echo "安装二进制..."
  tar -xJf "$TMP/kernel.tar.xz" -C "$TMP"
  find "$TMP" -type f -name naive -exec cp {} "${BIN_DIR}/naive" \;
  cp "$TMP/frontend" "${BIN_DIR}/naivereal-frontend"
  cp "$TMP/h3frontend" "${BIN_DIR}/h3frontend"
  chmod 755 "${BIN_DIR}/naive" "${BIN_DIR}/naivereal-frontend" "${BIN_DIR}/h3frontend"
}

write_server_service() {
  cat > "${SYSTEMD_DIR}/naivereal-server.service" <<UNIT
[Unit]
Description=naivereal official naive server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BIN_DIR}/naive --listen=http://${NAIVE_USER}:${NAIVE_PASS}@127.0.0.1:18080 --log
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now naivereal-server.service
}

write_frontend_service() {
  if [[ -z "$REALITY_SNI" ]]; then REALITY_SNI="$REALITY_TARGET"; fi
  KEY_OUT="$("${BIN_DIR}/naivereal-frontend" genkey)"
  PRIVATE_KEY="$(echo "$KEY_OUT" | sed -n 's/^Private key: //p' | tr -d '\r')"
  PUBLIC_KEY="$(echo "$KEY_OUT" | sed -n 's/^Public key:  //p' | tr -d '\r')"
  SHORT_ID="$(openssl rand -hex 8)"

  cat > "${CONFIG_DIR}/frontend.toml" <<EOF
log_level = "info"

[inbound]
listen = "0.0.0.0:${FRONTEND_PORT}"
mode = "reality"

[inbound.reality]
private_key = "${PRIVATE_KEY}"
short_ids = ["${SHORT_ID}"]
server_names = ["${REALITY_SNI}"]
target = "${REALITY_TARGET}:443"
relay_enabled = true

[upstream]
addr = "127.0.0.1:18080"

[limits]
max_connections = 1024
max_relays = 64
handshake_timeout = "10s"
idle_timeout = "300s"
EOF

  cat > "${SYSTEMD_DIR}/naivereal-frontend.service" <<UNIT
[Unit]
Description=naivereal REALITY frontend
After=network.target naivereal-server.service
Wants=naivereal-server.service

[Service]
Type=simple
User=root
ExecStart=${BIN_DIR}/naivereal-frontend ${CONFIG_DIR}/frontend.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now naivereal-frontend.service
  echo "REALITY public key: ${PUBLIC_KEY}"
  echo "REALITY short id: ${SHORT_ID}"
}

write_h3_service() {
  local h3_public_key=""
  if [[ "$H3_MODE" == "reality" ]]; then
    local keys priv pub
    keys="$("${BIN_DIR}/h3frontend" genkey)"
    priv="$(printf '%s\n' "$keys" | awk '$1 == "Private" && $2 == "key:" { print $3; exit }')"
    pub="$(printf '%s\n' "$keys" | awk '$1 == "Public" && $2 == "key:" { print $3; exit }')"
    if [[ -z "$priv" || -z "$pub" ]]; then
      echo "h3frontend genkey 失败" >&2
      exit 1
    fi
    h3_public_key="$pub"

    cat > "${CONFIG_DIR}/h3frontend.toml" <<EOF
log_level = "info"
listen = "0.0.0.0:${H3_PORT}"
mode = "reality"

[reality]
private_key = "${priv}"
short_ids = ["${H3_SHORT_ID}"]
server_names = ["${H3_REALITY_SNI}"]
dest = "${H3_REALITY_TARGET}"
dest_server_name = "${H3_REALITY_SNI}"
fallback_timeout = "120s"

[quic]
initPacketSize = 1200
initStreamReceiveWindow = 8388608
maxStreamReceiveWindow = 8388608
initConnReceiveWindow = 20971520
maxConnReceiveWindow = 20971520
maxIdleTimeout = "30s"
maxIncomingStreams = 1024
disablePathMTUDiscovery = true
disableGSO = true
disablePathManager = true

[congestion]
type = "bbr"
bbrProfile = "aggressive"

[upstream]
addr = "127.0.0.1:18080"
EOF
  else
    CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
      echo "为 ${DOMAIN} 申请 Let's Encrypt 证书..."
      certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    fi

    cat > "${CONFIG_DIR}/h3frontend.toml" <<EOF
log_level = "info"
listen = "0.0.0.0:${H3_PORT}"

[tls]
cert = "${CERT}"
key = "${KEY}"

[quic]
initPacketSize = 1200
initStreamReceiveWindow = 8388608
maxStreamReceiveWindow = 8388608
initConnReceiveWindow = 20971520
maxConnReceiveWindow = 20971520
maxIdleTimeout = "30s"
maxIncomingStreams = 1024
disablePathMTUDiscovery = true
disableGSO = true
disablePathManager = true

[congestion]
type = "bbr"
bbrProfile = "aggressive"

[upstream]
addr = "127.0.0.1:18080"
EOF
  fi

  cat > "${SYSTEMD_DIR}/naivereal-h3frontend.service" <<UNIT
[Unit]
Description=naivereal QUIC/HTTP3 frontend
After=network.target naivereal-server.service
Wants=naivereal-server.service

[Service]
Type=simple
User=root
ExecStart=${BIN_DIR}/h3frontend ${CONFIG_DIR}/h3frontend.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now naivereal-h3frontend.service
  if [[ "$H3_MODE" == "reality" ]]; then
    echo "H3 REALITY public key: ${h3_public_key}"
    echo "H3 REALITY short id: ${H3_SHORT_ID}"
  fi
}

write_manager() {
  cat > "$MANAGE_CMD" <<'M'
#!/usr/bin/env bash
set -euo pipefail
BIN_DIR="/opt/naivereal/bin"
CONFIG_DIR="/opt/naivereal/config"

case "${1:-}" in
  status)
    systemctl --no-pager status naivereal-server.service naivereal-frontend.service naivereal-h3frontend.service
    ;;
  start)
    systemctl start naivereal-server.service
    [[ -f "$CONFIG_DIR/frontend.toml" ]] && systemctl start naivereal-frontend.service
    [[ -f "$CONFIG_DIR/h3frontend.toml" ]] && systemctl start naivereal-h3frontend.service
    ;;
  stop)
    systemctl stop naivereal-h3frontend.service naivereal-frontend.service naivereal-server.service 2>/dev/null || true
    ;;
  restart)
    systemctl restart naivereal-h3frontend.service naivereal-frontend.service naivereal-server.service 2>/dev/null || true
    ;;
  info|show)
    echo "=== naivereal 配置信息 ==="
    echo "二进制目录: $BIN_DIR"
    echo "配置目录:   $CONFIG_DIR"
    echo
    echo "--- naive 后端 ---"
    systemctl cat naivereal-server.service 2>/dev/null | grep ExecStart || true
    echo
    if [[ -f "$CONFIG_DIR/frontend.toml" ]]; then
      echo "--- REALITY 前端 ---"
      grep -E 'listen|private_key|short_ids|server_names|target' "$CONFIG_DIR/frontend.toml"
      echo
    fi
    if [[ -f "$CONFIG_DIR/h3frontend.toml" ]]; then
      echo "--- H3 frontend ---"
      grep -E 'listen|cert|key' "$CONFIG_DIR/h3frontend.toml"
      echo
    fi
    ;;
  remove-kernel)
    echo "删除 naive 内核..."
    systemctl stop naivereal-server.service 2>/dev/null || true
    systemctl disable naivereal-server.service 2>/dev/null || true
    rm -f /etc/systemd/system/naivereal-server.service
    rm -f "$BIN_DIR/naive"
    systemctl daemon-reload
    echo "已删除 naive 内核和相关 systemd 服务。"
    ;;
  remove-script)
    echo "删除 naivereal 管理命令..."
    rm -f /usr/local/bin/naivereal
    echo "已删除 /usr/local/bin/naivereal。"
    ;;
  uninstall)
    echo "卸载全部 naivereal 组件..."
    systemctl stop naivereal-h3frontend.service naivereal-frontend.service naivereal-server.service 2>/dev/null || true
    systemctl disable naivereal-h3frontend.service naivereal-frontend.service naivereal-server.service 2>/dev/null || true
    rm -f /etc/systemd/system/naivereal-h3frontend.service
    rm -f /etc/systemd/system/naivereal-frontend.service
    rm -f /etc/systemd/system/naivereal-server.service
    rm -rf "$BIN_DIR"
    rm -rf "$CONFIG_DIR"
    rm -f /usr/local/bin/naivereal
    systemctl daemon-reload
    echo "已卸载全部 naivereal 组件。"
    ;;
  update)
    echo "更新命令："
    echo "  sudo bash -c "\$(curl -fsSL https://raw.githubusercontent.com/lipeiying032/naivereal-linux-deploy/master/bootstrap.sh)" --version latest"
    ;;
  *)
    echo "用法: naivereal {status|start|stop|restart|info|remove-kernel|remove-script|uninstall|update}"
    exit 1
    ;;
esac
M
  chmod +x "$MANAGE_CMD"
}

main() {
  if [[ $# -eq 0 ]]; then
    interactive
  else
    parse_args "$@"
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行: sudo bash install.sh" >&2
    exit 1
  fi

  install_deps
  download_install
  write_server_service

  if [[ "$DEPLOY_REALITY" == "yes" ]]; then
    echo "部署 REALITY 前端..."
    write_frontend_service
  fi
  if [[ "$DEPLOY_H3" == "yes" ]]; then
    echo "部署 H3 frontend..."
    write_h3_service
  fi

  write_manager

  echo
  echo "============================================="
  echo "安装完成！"
  echo "管理命令: naivereal status|restart|info"
  echo "配置目录: ${CONFIG_DIR}"
  echo "naive 后端: 127.0.0.1:18080 user=${NAIVE_USER} pass=${NAIVE_PASS}"
  if [[ "$DEPLOY_REALITY" == "yes" ]]; then
    echo "REALITY 前端已启用"
  fi
  if [[ "$DEPLOY_H3" == "yes" ]]; then
    if [[ "$H3_MODE" == "reality" ]]; then
      echo "H3 REALITY 已启用 (public key/short id 见上方输出)"
      echo "H3 客户端(补丁内核): quic://${NAIVE_USER}:${NAIVE_PASS}@<服务器IP>:${H3_PORT} + reality 块"
      echo "  或 TUI 导入: naivereal+quic://${NAIVE_USER}:${NAIVE_PASS}@<服务器IP>:${H3_PORT}?server_name=${H3_REALITY_SNI}&short_id=${H3_SHORT_ID}"
    else
      echo "H3 客户端: quic://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:${H3_PORT}"
    fi
  fi
  echo "============================================="
}

main "$@"
