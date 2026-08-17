#!/usr/bin/env bash
set -euo pipefail

# One-line bootstrap for naivereal-linux-deploy.
# Usage:
#   sudo bash bootstrap.sh --domain example.com --reality-target www.microsoft.com
#
# This script only needs curl; it does not require git.

URL="https://raw.githubusercontent.com/lipeiying032/naivereal-linux-deploy/master/install.sh"
TMP="$(mktemp /tmp/naivereal-install.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

echo "Downloading naivereal installer..."
curl -fsSL "$URL" -o "$TMP"
chmod +x "$TMP"

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo bash "$TMP" "$@"
fi

exec bash "$TMP" "$@"
