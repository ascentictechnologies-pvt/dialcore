#!/usr/bin/env bash
# ============================================================
#  DialCore — Production Deployment Script
#
#  Downloads pre-built artifacts from the GitHub repository,
#  extracts them to the correct locations, then runs install.sh
#  to configure services.
#
#  Artifacts expected in the repo root branch:
#    dialcore-backend.zip   (dotnet publish output)
#    dialcore-ui.zip        (Angular dist output)
#
#  Usage:
#    sudo bash deploy-production.sh [OPTIONS]
#
#  Options:
#    --domain <value>          Server FQDN (required on first install)
#    --secret-key <value>      AES-256 DB key — REQUIRED on redeploy to preserve data
#    --ssl-cert <path>         Path to existing SSL certificate (.crt / fullchain.pem)
#    --ssl-key  <path>         Path to existing SSL private key (.key)
#    --certbot                 Use Let's Encrypt (requires --letsencrypt-email)
#    --letsencrypt-email <v>   E-mail for Let's Encrypt
#    --no-ssl                  HTTP only (behind load balancer)
#    --github-token <value>    GitHub PAT (optional — repo is public)
#    -y / --yes                Non-interactive
#    -h / --help               Show this help
#
#  Repo:  git@github.com:ascentictechnologies-pvt/dialcore.git  (public)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GITHUB_REPO="ascentictechnologies-pvt/dialcore"
readonly GITHUB_BRANCH="main"
readonly BACKEND_ZIP="dialcore-backend.zip"
readonly FRONTEND_ZIP="dialcore-ui.zip"
readonly APP_DIR="/opt/Ascentic/Dialer"
readonly BACKEND_DIR="${APP_DIR}/BackEnd"
readonly FRONTEND_DIR="${APP_DIR}/FrontEnd"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
DOMAIN=""
SECRET_KEY=""
USE_CERTBOT=false
LE_EMAIL=""
NO_SSL=false
CUSTOM_CERT=""
CUSTOM_KEY=""
NON_INTERACTIVE=false
GITHUB_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)             DOMAIN="$2";          shift 2 ;;
    --secret-key)         SECRET_KEY="$2";       shift 2 ;;
    --ssl-cert)           CUSTOM_CERT="$2";       shift 2 ;;
    --ssl-key)            CUSTOM_KEY="$2";        shift 2 ;;
    --certbot)            USE_CERTBOT=true;       shift ;;
    --letsencrypt-email)  LE_EMAIL="$2";          shift 2 ;;
    --no-ssl)             NO_SSL=true;            shift ;;
    --github-token)       GITHUB_TOKEN="$2";     shift 2 ;;
    -y|--yes)             NON_INTERACTIVE=true;  shift ;;
    -h|--help)
      sed -n '8,32p' "$0" | sed 's/^#  \{0,2\}//' | sed 's/^#//'
      exit 0 ;;
    *) die "Unknown option: $1. Run with --help." ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash deploy-production.sh"

# ── Download helper ───────────────────────────────────────────────────────────
download_zip() {
  local filename="$1"
  local dest="$2"
  local url="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/${filename}"

  info "Downloading ${filename} ..."

  local curl_args=(-fsSL -o "${dest}")
  # Optional token — not needed for public repos but supported if repo goes private
  [[ -n "${GITHUB_TOKEN}" ]] && curl_args+=(-H "Authorization: token ${GITHUB_TOKEN}")

  curl "${curl_args[@]}" "${url}" \
    || die "Failed to download ${filename} from ${url}"

  [[ -s "${dest}" ]] || die "${filename} downloaded but is empty."
  ok "Downloaded ${filename} ($(du -sh "${dest}" | cut -f1))"
}

# ── Phase 1: Download Artifacts ──────────────────────────────────────────────
header "Phase 1 — Downloading Artifacts from GitHub"
info "Repo: github.com/${GITHUB_REPO}  branch: ${GITHUB_BRANCH}"

command -v curl  &>/dev/null || { apt-get install -y -qq curl;  }
command -v unzip &>/dev/null || { apt-get install -y -qq unzip; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

download_zip "${BACKEND_ZIP}" "${TMP_DIR}/${BACKEND_ZIP}"
download_zip "${FRONTEND_ZIP}" "${TMP_DIR}/${FRONTEND_ZIP}"

# ── Phase 2: Extract Artifacts ───────────────────────────────────────────────
header "Phase 2 — Extracting Artifacts"

# Stop API service if running (graceful)
if systemctl is-active --quiet dialcore-api 2>/dev/null; then
  info "Stopping dialcore-api service..."
  systemctl stop dialcore-api
fi

mkdir -p "${BACKEND_DIR}" "${FRONTEND_DIR}"

# Extract backend — auto-detect top-level folder name, strip __MACOSX entries
info "Extracting BackEnd..."
unzip -q -o "${TMP_DIR}/${BACKEND_ZIP}" -x "__MACOSX/*" "*.DS_Store" -d "${TMP_DIR}/be"
BE_PREFIX=$(find "${TMP_DIR}/be" -maxdepth 1 -mindepth 1 -type d ! -name '__MACOSX' | head -1)
if [[ -n "${BE_PREFIX}" ]]; then
  cp -r "${BE_PREFIX}/." "${BACKEND_DIR}/"
else
  cp -r "${TMP_DIR}/be/." "${BACKEND_DIR}/"
fi
[[ -f "${BACKEND_DIR}/DialCore.API.dll" ]] \
  || die "Extraction failed — DialCore.API.dll not found in ${BACKEND_DIR}"
ok "BackEnd extracted → ${BACKEND_DIR}"

# Extract frontend — auto-detect top-level folder name, strip __MACOSX entries
info "Extracting FrontEnd..."
unzip -q -o "${TMP_DIR}/${FRONTEND_ZIP}" -x "__MACOSX/*" "*.DS_Store" -d "${TMP_DIR}/fe"
FE_PREFIX=$(find "${TMP_DIR}/fe" -maxdepth 1 -mindepth 1 -type d ! -name '__MACOSX' | head -1)
if [[ -n "${FE_PREFIX}" ]]; then
  cp -r "${FE_PREFIX}/." "${FRONTEND_DIR}/"
else
  cp -r "${TMP_DIR}/fe/." "${FRONTEND_DIR}/"
fi
[[ -f "${FRONTEND_DIR}/index.html" ]] \
  || die "Extraction failed — index.html not found in ${FRONTEND_DIR}"
ok "FrontEnd extracted → ${FRONTEND_DIR}"

# Ownership (dialcore user must already exist or install.sh will create it)
id dialcore &>/dev/null && chown -R dialcore:dialcore "${BACKEND_DIR}" "${FRONTEND_DIR}" || true

# ── Phase 3: Run install.sh ───────────────────────────────────────────────────
header "Phase 3 — Configuring Server (install.sh)"

INSTALL_SCRIPT="${SCRIPT_DIR}/install.sh"
[[ -f "${INSTALL_SCRIPT}" ]] || die "install.sh not found at ${INSTALL_SCRIPT}"

INSTALL_ARGS=()
[[ -n "${DOMAIN}"     ]] && INSTALL_ARGS+=(--domain "${DOMAIN}")
[[ -n "${SECRET_KEY}" ]] && INSTALL_ARGS+=(--secret-key "${SECRET_KEY}")
[[ -n "${CUSTOM_CERT}" ]] && INSTALL_ARGS+=(--ssl-cert "${CUSTOM_CERT}")
[[ -n "${CUSTOM_KEY}"  ]] && INSTALL_ARGS+=(--ssl-key  "${CUSTOM_KEY}")
$USE_CERTBOT             && INSTALL_ARGS+=(--certbot)
[[ -n "${LE_EMAIL}"    ]] && INSTALL_ARGS+=(--letsencrypt-email "${LE_EMAIL}")
$NO_SSL                  && INSTALL_ARGS+=(--no-ssl)
$NON_INTERACTIVE        && INSTALL_ARGS+=(-y)

exec bash "${INSTALL_SCRIPT}" "${INSTALL_ARGS[@]}"
