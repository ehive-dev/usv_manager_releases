#!/usr/bin/env bash
# usv-manager Installer/Updater (DietPi / Debian)
# Main functions:
# - apt_update_once: führt apt-get update genau einmal aus (non-interactive)
# - need_tools: stellt sicher, dass curl/jq/dpkg/dpkg-deb/systemctl vorhanden sind
# - api/get_release_json/pick_deb_from_release: ermittelt das passende .deb aus GitHub Releases (stable/pre, optional tag)
# - ensure_python_gpiod: Bookworm-fix (Candidate-Check) + installiert python3-libgpiod (+ libgpiod2 + gpiod) statt python3-gpiod
# - patch_deb_dep_if_needed: patcht .deb "Depends: python3-gpiod" -> "python3-libgpiod | python3-gpiod" (Workaround für alte Releases)
# - ensure_unit_exists/ensure_defaults_file: systemd Unit + /etc/default non-destructive bereitstellen
# - wait_service_active: prüft, ob der Dienst aktiv ist

set -euo pipefail
umask 022

APP_NAME="usv-manager"
UNIT="${APP_NAME}.service"
UNIT_BASE="${APP_NAME}"

# Non-interactive APT (keine Rückfragen)
export DEBIAN_FRONTEND=noninteractive
APT_INSTALL_OPTS=(
  -y
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

# Defaults (can be overridden via env or CLI)
REPO="${REPO:-ehive-dev/usv_manager_releases}" # releases repo
CHANNEL="stable"                               # stable | pre
TAG="${TAG:-}"
ARCH_REQ="arm64"
DPKG_PKG="${DPKG_PKG:-$APP_NAME}"

# ---------- CLI args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre) CHANNEL="pre"; shift ;;
    --stable) CHANNEL="stable"; shift ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 [--pre|--stable] [--tag vX.Y.Z] [--repo owner/repo]"
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

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

apt_update_once(){
  if [[ "${_APT_UPDATED:-0}" != "1" ]]; then
    apt-get update
    _APT_UPDATED=1
  fi
}

need_tools(){
  command -v curl     >/dev/null || { apt_update_once; apt-get install "${APT_INSTALL_OPTS[@]}" curl; }
  command -v jq       >/dev/null || { apt_update_once; apt-get install "${APT_INSTALL_OPTS[@]}" jq; }
  command -v dpkg     >/dev/null || { apt_update_once; apt-get install "${APT_INSTALL_OPTS[@]}" dpkg; }
  command -v dpkg-deb >/dev/null || { apt_update_once; apt-get install "${APT_INSTALL_OPTS[@]}" dpkg; }
  command -v systemctl >/dev/null || { err "systemd/systemctl erforderlich."; exit 1; }
  command -v ss >/dev/null 2>&1 || true
}

# Use GitHub API with optional token (GITHUB_TOKEN or GH_TOKEN)
api(){
  local url="$1"
  local hdr=(-H "Accept: application/vnd.github+json")
  local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  [[ -n "$tok" ]] && hdr+=(-H "Authorization: Bearer ${tok}")
  curl -fsSL "${hdr[@]}" "$url"
}

trim_one_line(){ tr -d '\r' | tr -d '\n' | sed 's/[[:space:]]\+$//'; }

get_release_json(){
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

pick_deb_from_release(){
  # Accepts:
  # - usv-manager_<ver>_arm64.deb
  # - usv-manager_<ver>_all.deb (allowed fallback)
  jq -r --arg arch "$ARCH_REQ" --arg app "$APP_NAME" '
    .assets // []
    | ( map(select(.name | test("^" + $app + "_.*_" + $arch + "\\.deb$")))
      + map(select(.name | test("^" + $app + "_.*_all\\.deb$"))) )
    | .[0].browser_download_url // empty
  '
}

installed_version(){ dpkg-query -W -f='${Version}\n' "$DPKG_PKG" 2>/dev/null || true; }

pkg_candidate(){
  local pkg="$1"
  apt-cache policy "$pkg" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit 0}'
}

ensure_python_gpiod(){
  apt_update_once

  # python3-gpiod nur installieren, wenn wirklich ein Candidate existiert (Bookworm oft: (none))
  local cand
  cand="$(pkg_candidate python3-gpiod || true)"
  if [[ -n "${cand:-}" && "${cand:-}" != "(none)" ]]; then
    apt-get install "${APT_INSTALL_OPTS[@]}" python3 python3-gpiod iproute2
    return 0
  fi

  # Bookworm-Standard: python3-libgpiod (+ libgpiod2 + gpiod)
  cand="$(pkg_candidate python3-libgpiod || true)"
  if [[ -n "${cand:-}" && "${cand:-}" != "(none)" ]]; then
    apt-get install "${APT_INSTALL_OPTS[@]}" python3 python3-libgpiod libgpiod2 gpiod iproute2
    return 0
  fi

  err "Kein passendes Paket gefunden: python3-gpiod (Candidate) ODER python3-libgpiod (Candidate)."
  err "Fix: apt-cache search gpiod | grep python3  (oder Repo/Distribution prüfen)"
  exit 1
}

patch_deb_dep_if_needed(){
  # Workaround für alte .deb, die "Depends: python3-gpiod" hardcoden (Bookworm: nicht installierbar)
  local deb_in="$1"

  local depends
  depends="$(dpkg-deb -f "$deb_in" Depends 2>/dev/null || true)"

  # nur patchen wenn wirklich python3-gpiod verlangt wird
  if ! printf '%s' "$depends" | grep -qE '(^|[,[:space:]])python3-gpiod($|[,[:space:]])'; then
    echo "$deb_in"
    return 0
  fi

  # nur patchen wenn python3-gpiod NICHT installierbar ist, aber python3-libgpiod schon
  local cand_gpiod cand_lib
  cand_gpiod="$(pkg_candidate python3-gpiod || true)"
  cand_lib="$(pkg_candidate python3-libgpiod || true)"
  if [[ -n "${cand_gpiod:-}" && "${cand_gpiod:-}" != "(none)" ]]; then
    echo "$deb_in"
    return 0
  fi
  if [[ -z "${cand_lib:-}" || "${cand_lib:-}" == "(none)" ]]; then
    err "Paket hängt von python3-gpiod ab, aber weder python3-gpiod noch python3-libgpiod ist installierbar."
    exit 1
  fi

  warn "Patch: .deb Depends python3-gpiod → python3-libgpiod | python3-gpiod (Bookworm Fix)"

  local work out
  work="$(mktemp -d -t usv-debpatch.XXXXX)"
  out="${work}/patched.deb"

  dpkg-deb -R "$deb_in" "${work}/root"
  # robust: ersetze nur das Paket-Token, nicht irgendwelche Teilstrings
  sed -i -E 's/(^Depends:.*)(^|[,[:space:]])python3-gpiod([,[:space:]]|$)/\1 python3-libgpiod | python3-gpiod\3/I' "${work}/root/DEBIAN/control" || true
  dpkg-deb -b "${work}/root" "$out" >/dev/null 2>&1 || { rm -rf "$work"; err "Repack des gepatchten .deb fehlgeschlagen."; exit 1; }

  echo "$out"
}

wait_service_active(){
  local unit="$1"
  for _ in {1..30}; do
    systemctl is-active --quiet "$unit" && return 0
    sleep 0.5
  done
  return 1
}

ensure_unit_exists(){
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "${UNIT}"; then
    return 0
  fi

  warn "Keine Unit-Datei im System gefunden (${UNIT}) — lege Minimal-Unit an."
  local unit_path="/etc/systemd/system/${UNIT}"
  cat >"$unit_path" <<UNITFILE
[Unit]
Description=${APP_NAME}
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=-/etc/default/${APP_NAME}
ExecStart=/usr/local/bin/${APP_NAME}
Restart=always
RestartSec=1s
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
KillMode=process
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
UNITFILE
}

ensure_defaults_file(){
  if [[ -f /etc/default/${APP_NAME} ]]; then
    return 0
  fi
  install -D -m 644 /dev/null "/etc/default/${APP_NAME}"
  cat >>"/etc/default/${APP_NAME}" <<EOF
# usv-manager defaults (example)
USV_CHIP=/dev/gpiochip3
USV_OUT1_LINE=2
USV_OUT2_LINE=5
USV_IN_LINE=11
EOF
}

# ---------- start ----------
need_root
need_tools

ARCH_SYS="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [[ "$ARCH_SYS" != "$ARCH_REQ" ]]; then
  warn "Systemarchitektur '$ARCH_SYS', Ziel ist '$ARCH_REQ'. (all.deb ist trotzdem ok)"
fi

OLD_VER="$(installed_version || true)"
if [[ -n "$OLD_VER" ]]; then
  info "Installiert: ${DPKG_PKG} ${OLD_VER}"
else
  info "Keine bestehende ${DPKG_PKG}-Installation gefunden."
fi

info "Installiere Runtime-Abhängigkeiten (python3 + gpiod bindings + iproute2) ..."
ensure_python_gpiod

info "Ermittle Release aus ${REPO} (${CHANNEL}${TAG:+, tag=$TAG}) ..."
RELEASE_JSON="$(get_release_json || true)"

if [[ -z "${RELEASE_JSON:-}" || "${RELEASE_JSON:-}" == "null" ]]; then
  err "Keine passende Release gefunden oder API-Fehler."
  err "Tipp: export GITHUB_TOKEN=\$(gh auth token)  (bei 403/rate limit/private repo)"
  exit 1
fi

TAG_NAME="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name')"
[[ -z "$TAG" ]] && TAG="$TAG_NAME"
VER_CLEAN="${TAG#v}"

DEB_URL_RAW="$(printf '%s' "$RELEASE_JSON" | pick_deb_from_release || true)"
DEB_URL="$(printf '%s' "$DEB_URL_RAW" | trim_one_line)"
[[ -z "$DEB_URL" ]] && { err "Kein .deb Asset (arm64/all) in Release ${TAG} gefunden."; exit 1; }

TMPDIR="$(mktemp -d -t usv-install.XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

DEB_FILE="${TMPDIR}/$(basename "$DEB_URL")"

info "Lade: ${DEB_URL}"
curl -fL --retry 3 --retry-delay 1 -o "$DEB_FILE" "$DEB_URL"
dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 || { err "Ungültiges .deb"; exit 1; }

# Stop service if present
systemctl stop "$UNIT" >/dev/null 2>&1 || true

# Patch .deb dependency if needed (old releases)
DEB_INSTALL="$(patch_deb_dep_if_needed "$DEB_FILE")"

info "Installiere Paket ..."
set +e
dpkg -i "$DEB_INSTALL"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  warn "dpkg -i scheiterte — versuche apt --fix-broken"
  apt_update_once
  apt-get -f install "${APT_INSTALL_OPTS[@]}"
  dpkg -i "$DEB_INSTALL"
fi
ok "Installiert: ${DPKG_PKG} ${VER_CLEAN}"

ensure_defaults_file
ensure_unit_exists

install -d -m 755 "/etc/systemd/system/${UNIT}.d"
cat >"/etc/systemd/system/${UNIT}.d/10-paths.conf" <<UNITDROP
[Service]
StateDirectory=${UNIT_BASE}
LogsDirectory=${UNIT_BASE}
UNITDROP

systemctl daemon-reload
systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
systemctl restart "$UNIT" >/dev/null 2>&1 || true

info "Prüfe Service-Status: ${UNIT} ..."
if ! wait_service_active "$UNIT"; then
  err "Service nicht aktiv: ${UNIT}"
  journalctl -u "${UNIT}" -n 200 --no-pager -o cat || true
  exit 1
fi

NEW_VER="$(installed_version || echo "$VER_CLEAN")"
ok "Fertig: ${APP_NAME} ${OLD_VER:+${OLD_VER} → }${NEW_VER} (service active)"
