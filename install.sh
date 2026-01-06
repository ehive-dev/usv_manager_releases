#!/usr/bin/env bash
# usv-manager Installer/Updater (DietPi / arm64)
# Main functions:
# - need_root/need_tools: ensure required tools and root privileges
# - api/get_release_json/pick_deb_from_release: resolve correct GitHub release asset URL
# - install_deb: install .deb with dpkg + apt --fix-broken fallback
# - ensure_unit_defaults/ensure_unit_dropin: ensure systemd unit + paths (if not shipped by package)
# - start_and_check: enable/start service and show recent logs on failure
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ehive-dev/usv-manager-releases/main/install.sh | sudo bash -s -- [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo] [--arch arm64]
#   sudo bash install.sh --pre | --stable | --tag vX.Y.Z | --repo owner/repo

set -euo pipefail
umask 022

APP_NAME="usv-manager"
UNIT="${APP_NAME}.service"
UNIT_BASE="${APP_NAME}"

# Defaults (override via env or CLI)
REPO="${REPO:-ehive-dev/usv-manager-releases}"
CHANNEL="stable"          # stable | pre
TAG="${TAG:-}"
ARCH_REQ="${ARCH_REQ:-arm64}"
DPKG_PKG="${DPKG_PKG:-$APP_NAME}"

# ---------- CLI args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --arch) ARCH_REQ="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo] [--arch arm64]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------- helpers ----------
info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){  printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Bitte als root ausführen (sudo)."; exit 1; fi
}

apt_update_once() {
  if [[ "${_APT_UPDATED:-0}" != "1" ]]; then
    apt-get update -y
    _APT_UPDATED=1
  fi
}

ensure_pkg() {
  local pkg="$1"
  dpkg -s "$pkg" >/dev/null 2>&1 && return 0
  apt_update_once
  apt-get install -y "$pkg"
}

need_tools() {
  command -v systemctl >/dev/null || { err "systemd/systemctl erforderlich."; exit 1; }
  command -v curl >/dev/null || { apt_update_once; apt-get install -y curl; }
  command -v jq >/dev/null || { apt_update_once; apt-get install -y jq; }
  command -v ss >/dev/null 2>&1 || true
}

# gpiod python bindings (Bookworm vs others)
ensure_python_gpiod() {
  apt_update_once
  if apt-cache show python3-gpiod >/dev/null 2>&1; then
    ensure_pkg python3-gpiod
    return 0
  fi
  if apt-cache show python3-libgpiod >/dev/null 2>&1; then
    ensure_pkg python3-libgpiod
    return 0
  fi
  err "Kein passendes Paket gefunden: python3-gpiod ODER python3-libgpiod."
  exit 1
}

api() {
  local url="$1"
  local hdr=(-H "Accept: application/vnd.github+json")
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  [[ -n "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${GH_TOKEN}")
  curl -fsSL "${hdr[@]}" "$url"
}

trim_one_line(){ tr -d '\r' | tr -d '\n' | sed 's/[[:space:]]\+$//'; }

get_release_json() {
  if [[ -n "$TAG" ]]; then
    api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
  else
    api "https://api.github.com/repos/${REPO}/releases?per_page=25" \
    | jq -c 'if "'"${CHANNEL}"'"=="pre"
             then ([ .[]|select(.draft==false and .prerelease==true) ]|.[0])
             else ([ .[]|select(.draft==false and .prerelease==false) ]|.[0])
             end'
  fi
}

pick_deb_from_release() {
  jq -r --arg arch "$ARCH_REQ" --arg app "$APP_NAME" '
    .assets // []
    | map(select(.name | test("^" + $app + "_.*_" + $arch + "\\.deb$")))
    | .[0].browser_download_url // empty
  '
}

installed_version() { dpkg-query -W -f='${Version}\n' "$DPKG_PKG" 2>/dev/null || true; }

install_deb() {
  local deb_file="$1"
  set +e
  dpkg -i "$deb_file"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "dpkg -i scheiterte — versuche apt --fix-broken"
    apt_update_once
    apt-get -f install -y
    dpkg -i "$deb_file"
  fi
}

detect_exec() {
  # Prefer /usr/local/bin wrapper if present, else python entry in /opt
  if [[ -x "/usr/local/bin/${APP_NAME}" ]]; then
    echo "/usr/local/bin/${APP_NAME}"
  elif command -v "${APP_NAME}" >/dev/null 2>&1; then
    command -v "${APP_NAME}"
  elif [[ -f "/opt/${APP_NAME}/usvManager.py" ]]; then
    echo "/usr/bin/python3 /opt/${APP_NAME}/usvManager.py"
  elif [[ -f "/opt/${APP_NAME}/${APP_NAME}.py" ]]; then
    echo "/usr/bin/python3 /opt/${APP_NAME}/${APP_NAME}.py"
  else
    echo "/usr/local/bin/${APP_NAME}"
  fi
}

ensure_unit_defaults() {
  # Only create /etc/default if not existing
  if [[ ! -f "/etc/default/${APP_NAME}" ]]; then
    install -D -m 644 /dev/null "/etc/default/${APP_NAME}"
    {
      echo "# USV-Manager defaults"
      echo "# GPIO_CHIP=/dev/gpiochip3"
      echo "# GPIO_OUT_1=2"
      echo "# GPIO_OUT_2=5"
      echo "# GPIO_IN_1=11"
      echo "# LOG_LEVEL=info"
    } >>"/etc/default/${APP_NAME}"
  fi

  # Only create unit if not already known to systemd (package might ship it)
  if ! systemctl list-unit-files | awk '{print $1}' | grep -qx "${UNIT}"; then
    local exec_bin
    exec_bin="$(detect_exec)"
    local unit_path="/etc/systemd/system/${UNIT}"
    install -D -m 644 /dev/null "$unit_path"
    cat >"$unit_path" <<UNITFILE
[Unit]
Description=${APP_NAME}
After=multi-user.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=-/etc/default/${APP_NAME}
ExecStart=${exec_bin}
Restart=always
RestartSec=2s
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
KillMode=process
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
UNITFILE
  fi
}

ensure_unit_dropin() {
  install -d -m 755 "/etc/systemd/system/${UNIT}.d"
  cat >"/etc/systemd/system/${UNIT}.d/10-paths.conf" <<UNITDROP
[Service]
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
UNITDROP
}

start_and_check() {
  systemctl daemon-reload
  systemctl enable --now "${UNIT}" >/dev/null 2>&1 || true
  systemctl restart "${UNIT}" >/dev/null 2>&1 || true

  sleep 0.5
  if systemctl is-active --quiet "${UNIT}"; then
    ok "Service active: ${UNIT}"
    return 0
  fi

  err "Service ist nicht active: ${UNIT}"
  journalctl -u "${UNIT}" -n 200 --no-pager -o cat || true
  return 1
}

# ---------- start ----------
need_root
need_tools

ARCH_SYS="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [[ "$ARCH_SYS" != "$ARCH_REQ" ]]; then
  warn "Systemarchitektur '$ARCH_SYS', Release ist für '$ARCH_REQ'."
  exit 1
fi

# runtime deps commonly needed by usv-manager
ensure_pkg python3
ensure_python_gpiod
ensure_pkg systemd
ensure_pkg iproute2

OLD_VER="$(installed_version || true)"
if [[ -n "$OLD_VER" ]]; then info "Installiert: ${DPKG_PKG} ${OLD_VER}"; else info "Keine bestehende ${DPKG_PKG}-Installation gefunden."; fi

info "Ermittle Release aus ${REPO} (${CHANNEL}${TAG:+, tag=$TAG}) ..."
RELEASE_JSON="$(get_release_json || true)"
if [[ -z "$RELEASE_JSON" || "$RELEASE_JSON" == "null" ]]; then
  err "Keine passende Release gefunden."
  exit 1
fi

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
[[ -z "$TAG" || "$TAG" == "null" ]] && TAG="$TAG_NAME"
VER_CLEAN="${TAG#v}"

DEB_URL_RAW="$(printf '%s' "$RELEASE_JSON" | pick_deb_from_release || true)"
DEB_URL="$(printf '%s' "$DEB_URL_RAW" | trim_one_line)"
[[ -z "$DEB_URL" ]] && { err "Kein .deb Asset (${ARCH_REQ}) in Release ${TAG} gefunden."; exit 1; }

TMPDIR="$(mktemp -d -t usvmanager-install.XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
DEB_FILE="${TMPDIR}/${APP_NAME}_${VER_CLEAN}_${ARCH_REQ}.deb"

info "Lade: ${DEB_URL}"
curl -fL --retry 3 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL" || { err "Download fehlgeschlagen."; exit 1; }
dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 || { err "Ungültiges .deb"; exit 1; }

# stop service if exists
systemctl stop "${UNIT}" >/dev/null 2>&1 || true

info "Installiere Paket ..."
install_deb "$DEB_FILE"
ok "Installiert: ${DPKG_PKG} ${VER_CLEAN}"

# ensure unit + defaults (only if package didn't ship it)
ensure_unit_defaults
ensure_unit_dropin
start_and_check

NEW_VER="$(installed_version || echo "$VER_CLEAN")"
ok "Fertig: ${APP_NAME} ${OLD_VER:+${OLD_VER} → }${NEW_VER}"
