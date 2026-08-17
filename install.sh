#!/usr/bin/env bash
set -euo pipefail

REPO="lipeiying032/naive-reality"
VERSION=""
DOMAIN=""
REALITY_TARGET=""
REALITY_SNI=""
NAIVE_USER="user"
NAIVE_PASS="$(openssl rand -hex 8)"
H3_PORT="8443"
FRONTEND_PORT="443"
INSTALL_DIR="/opt/naivereal"
CONFIG_DIR="${INSTALL_DIR}/config"
SYSTEMD_DIR="/etc/systemd/system"

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
  --frontend-port <port>    REALITY frontend TCP port (default: 443)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --reality-target) REALITY_TARGET="$2"; shift 2;;
    --reality-sni) REALITY_SNI="$2"; shift 2;;
    --user) NAIVE_USER="$2"; shift 2;;
    --pass) NAIVE_PASS="$2"; shift 2;;
    --h3-port) H3_PORT="$2"; shift 2;;
    --frontend-port) FRONTEND_PORT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh" >&2
  exit 1
fi

command -v curl >/dev/null || { echo "curl required"; exit 1; }
command -v tar >/dev/null || { echo "tar required"; exit 1; }
command -v unzip >/dev/null || { echo "unzip required"; exit 1; }
command -v systemctl >/dev/null || { echo "systemd required"; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) KERNEL_ARCH="x64"; GO_ARCH="amd64";;
  aarch64|arm64) KERNEL_ARCH="arm64"; GO_ARCH="arm64";;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1;;
esac

if [[ -z "$VERSION" ]]; then
  echo "Fetching latest release version..."
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$VERSION" ]]; then
  echo "Failed to determine latest release version" >&2
  exit 1
fi
echo "Using naivereal release: ${VERSION}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${INSTALL_DIR}/bin" "${CONFIG_DIR}"

echo "Downloading release assets..."
BASE="https://github.com/${REPO}/releases/download/${VERSION}"
curl -fsSL -o "$TMP/kernel.tar.xz" "${BASE}/naivereal-kernel-linux-${KERNEL_ARCH}.tar.xz"
curl -fsSL -o "$TMP/frontend" "${BASE}/naivereal-frontend-linux-${GO_ARCH}"
curl -fsSL -o "$TMP/h3frontend" "${BASE}/naivereal-h3frontend-linux-${GO_ARCH}"

echo "Installing binaries..."
tar -xJf "$TMP/kernel.tar.xz" -C "$TMP"
find "$TMP" -type f -name naive -exec cp {} "${INSTALL_DIR}/bin/naive" \;
cp "$TMP/frontend" "${INSTALL_DIR}/bin/naivereal-frontend"
cp "$TMP/h3frontend" "${INSTALL_DIR}/bin/h3frontend"
chmod 755 "${INSTALL_DIR}/bin/naive" "${INSTALL_DIR}/bin/naivereal-frontend" "${INSTALL_DIR}/bin/h3frontend"

cat > "${SYSTEMD_DIR}/naivereal-server.service" <<UNIT
[Unit]
Description=naivereal official naive server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/bin/naive --listen=http://${NAIVE_USER}:${NAIVE_PASS}@127.0.0.1:18080 --log
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now naivereal-server.service

if [[ -n "$REALITY_TARGET" ]]; then
  echo "Setting up REALITY frontend..."
  if [[ -z "$REALITY_SNI" ]]; then REALITY_SNI="$REALITY_TARGET"; fi
  KEY_OUT="$("${INSTALL_DIR}/bin/naivereal-frontend" genkey)"
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
ExecStart=${INSTALL_DIR}/bin/naivereal-frontend ${CONFIG_DIR}/frontend.toml
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
fi

if [[ -n "$DOMAIN" ]]; then
  echo "Setting up h3frontend with domain ${DOMAIN}..."
  CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    if ! command -v certbot >/dev/null; then
      echo "Installing certbot..."
      if command -v apt-get >/dev/null; then
        apt-get update -qq && apt-get install -y -qq certbot
      elif command -v dnf >/dev/null; then
        dnf install -y certbot
      else
        echo "certbot not found; please install certbot and obtain a certificate manually" >&2
        exit 1
      fi
    fi
    echo "Obtaining Let's Encrypt certificate for ${DOMAIN}..."
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

  cat > "${SYSTEMD_DIR}/naivereal-h3frontend.service" <<UNIT
[Unit]
Description=naivereal QUIC/HTTP3 frontend
After=network.target naivereal-server.service
Wants=naivereal-server.service

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/bin/h3frontend ${CONFIG_DIR}/h3frontend.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now naivereal-h3frontend.service
  echo "H3 frontend listening on UDP ${H3_PORT}"
fi

echo
echo "============================================="
echo "Installation complete."
echo "naive backend: 127.0.0.1:18080 user=${NAIVE_USER} pass=${NAIVE_PASS}"
echo "config dir: ${CONFIG_DIR}"
echo "systemd: naivereal-server.service"
if [[ -n "$REALITY_TARGET" ]]; then echo "systemd: naivereal-frontend.service"; fi
if [[ -n "$DOMAIN" ]]; then
  echo "systemd: naivereal-h3frontend.service"
  echo "H3 client: quic://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:${H3_PORT}"
fi
echo "============================================="
