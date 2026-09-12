#!/usr/bin/env bash

###############################################################################
# EC2 BLUE-GREEN — GENERIC REBUILD + DEPLOY SCRIPT
#
# Works for any Node.js application (backend or frontend) that has a
# package.json with a "start" script, and optionally a "build" script.
# Not tied to any specific app, repo, database, or set of env vars.
#
# What it does:
#   PART A — Infra bootstrap (Node.js, PM2, Nginx, Blue-Green config,
#            reusable deploy.sh / rollback.sh / monitor.sh)
#   PART B — Interactive first deploy (clone repos, collect env vars,
#            install/build, start under PM2 on the GREEN slot)
#
# Re-run this script for a different application: give it a different
# app name and it builds a fully separate /opt/<app> stack alongside
# (or instead of) any previous one.
###############################################################################

set -Eeuo pipefail

trap 'echo "[ERROR] Line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

###############################################################################
# ROOT CHECK
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    echo
    echo "ERROR: Run this script with sudo:"
    echo
    echo "  sudo bash ec2-blue-green-deploy.sh"
    echo
    exit 1
fi

###############################################################################
# OS CHECK
###############################################################################

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    echo "ERROR: This script requires Ubuntu."
    exit 1
fi

ARCH="$(dpkg --print-architecture)"

if [[ "${ARCH}" != "amd64" ]]; then
    echo "ERROR: Expected amd64 architecture. Detected: ${ARCH}"
    exit 1
fi

echo "OS           : ${PRETTY_NAME}"
echo "Architecture : ${ARCH}"

###############################################################################
# CONFIGURATION — asked once, drives every path/name below
###############################################################################

echo
echo "===== Application configuration ====="
echo

read -r -p "Application name (letters, numbers, hyphens only, e.g. 'myshop'): " APP_NAME_INPUT

# Sanitize: lowercase, replace anything unsafe with '-'
APP_NAME="$(echo "${APP_NAME_INPUT}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"

if [[ -z "${APP_NAME}" ]]; then
    echo "ERROR: Application name cannot be empty."
    exit 1
fi

echo "Using application name: ${APP_NAME}"

read -r -p "Blue  frontend port [3000]: " BLUE_FRONTEND_PORT_INPUT
read -r -p "Green frontend port [3001]: " GREEN_FRONTEND_PORT_INPUT
read -r -p "Blue  backend  port [8080]: " BLUE_BACKEND_PORT_INPUT
read -r -p "Green backend  port [8081]: " GREEN_BACKEND_PORT_INPUT
read -r -p "Node.js major version [22]: " NODE_MAJOR_INPUT

BLUE_FRONTEND_PORT="${BLUE_FRONTEND_PORT_INPUT:-3000}"
GREEN_FRONTEND_PORT="${GREEN_FRONTEND_PORT_INPUT:-3001}"
BLUE_BACKEND_PORT="${BLUE_BACKEND_PORT_INPUT:-8080}"
GREEN_BACKEND_PORT="${GREEN_BACKEND_PORT_INPUT:-8081}"
NODE_MAJOR="${NODE_MAJOR_INPUT:-22}"

BASE_DIR="/opt/${APP_NAME}"
DEPLOY_DIR="${BASE_DIR}/deploy"
MONITOR_DIR="${BASE_DIR}/monitor"
RELEASES_DIR="${BASE_DIR}/releases"
REPOSITORY_DIR="${BASE_DIR}/repository"

BLUE_DIR="${RELEASES_DIR}/recovery/blue"
GREEN_DIR="${RELEASES_DIR}/recovery/green"

ACTIVE_SLOT_FILE="${DEPLOY_DIR}/active_slot"

LOG_FILE="/var/log/${APP_NAME}-dr-rebuild.log"

###############################################################################
# LOGGING
###############################################################################

mkdir -p "$(dirname "${LOG_FILE}")"

exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
    echo
    echo "=================================================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "=================================================================="
}

log "Starting bootstrap for application: ${APP_NAME}"
echo "Base dir : ${BASE_DIR}"
echo "Ports    : blue frontend=${BLUE_FRONTEND_PORT} green frontend=${GREEN_FRONTEND_PORT} | blue backend=${BLUE_BACKEND_PORT} green backend=${GREEN_BACKEND_PORT}"

###############################################################################
# SYSTEM UPDATE
###############################################################################

log "Updating Ubuntu packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y

###############################################################################
# INSTALL BASE PACKAGES
###############################################################################

log "Installing base packages"

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    git \
    jq \
    unzip \
    rsync \
    build-essential \
    python3 \
    python3-pip \
    openssl \
    nginx \
    lsof \
    net-tools \
    procps \
    htop \
    tree

###############################################################################
# NODE.JS
###############################################################################

log "Installing Node.js ${NODE_MAJOR}"

if command -v node >/dev/null 2>&1; then
    CURRENT_NODE="$(node -v | sed 's/^v//' | cut -d. -f1)"
    echo "Existing Node.js major version: ${CURRENT_NODE}"
    if [[ "${CURRENT_NODE}" != "${NODE_MAJOR}" ]]; then
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
        apt-get install -y nodejs
    fi
else
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
fi

echo
echo "Node.js : $(node -v)"
echo "NPM     : $(npm -v)"

###############################################################################
# PM2
###############################################################################

log "Installing PM2"

if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2
fi

echo "PM2: $(pm2 -v)"

###############################################################################
# OPTIONAL: MONGODB DATABASE TOOLS
###############################################################################

echo
read -r -p "Install MongoDB Database Tools (mongodump/mongorestore)? Skip if this app doesn't use MongoDB. [y/N]: " INSTALL_MONGO_TOOLS

if [[ "${INSTALL_MONGO_TOOLS,,}" == "y" || "${INSTALL_MONGO_TOOLS,,}" == "yes" ]]; then
    log "Installing MongoDB Database Tools"

    if command -v mongodump >/dev/null 2>&1; then
        echo "MongoDB Database Tools already installed."
    else
        TMP_DIR="$(mktemp -d)"
        TOOL_URL="https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2404-x86_64-100.12.2.tgz"

        echo "Downloading MongoDB Database Tools..."

        if curl -fL "${TOOL_URL}" -o "${TMP_DIR}/mongodb-tools.tgz"; then
            tar -xzf "${TMP_DIR}/mongodb-tools.tgz" -C "${TMP_DIR}"
            TOOLS_DIR="$(find "${TMP_DIR}" -maxdepth 1 -type d -name 'mongodb-database-tools-*' | head -1)"
            if [[ -n "${TOOLS_DIR}" ]]; then
                install -m 0755 "${TOOLS_DIR}/bin/"* /usr/local/bin/
            fi
        else
            echo "WARNING: MongoDB Database Tools could not be downloaded. Continuing anyway."
        fi

        rm -rf "${TMP_DIR}"
    fi

    if command -v mongodump >/dev/null 2>&1; then
        mongodump --version | head -1
    fi
else
    log "Skipping MongoDB Database Tools"
fi

###############################################################################
# CREATE DIRECTORY STRUCTURE
###############################################################################

log "Creating directory structure under ${BASE_DIR}"

mkdir -p \
    "${BASE_DIR}" \
    "${DEPLOY_DIR}" \
    "${MONITOR_DIR}" \
    "${MONITOR_DIR}/incidents" \
    "${MONITOR_DIR}/logs" \
    "${MONITOR_DIR}/state" \
    "${RELEASES_DIR}" \
    "${REPOSITORY_DIR}" \
    "${BLUE_DIR}/backend" \
    "${BLUE_DIR}/frontend" \
    "${GREEN_DIR}/backend" \
    "${GREEN_DIR}/frontend"

chown -R ubuntu:ubuntu "${BASE_DIR}"

###############################################################################
# BACKUP ANY EXISTING NGINX CONFIG
###############################################################################

log "Backing up Nginx configuration"

NGINX_BACKUP="/root/nginx-before-${APP_NAME}-$(date '+%Y%m%d-%H%M%S').tar.gz"
tar -czf "${NGINX_BACKUP}" /etc/nginx 2>/dev/null || true
echo "Nginx backup: ${NGINX_BACKUP}"

###############################################################################
# NGINX ACTIVE CONFIGURATION (GREEN active initially)
###############################################################################

log "Creating Blue-Green Nginx configuration for ${APP_NAME}"

NGINX_ACTIVE_CONF="/etc/nginx/conf.d/${APP_NAME}-active.conf"
UPSTREAM_FRONTEND="${APP_NAME}_frontend"
UPSTREAM_BACKEND="${APP_NAME}_backend"

cat > "${NGINX_ACTIVE_CONF}" <<NGINXACTIVE_EOF
# ============================================================
# ${APP_NAME} BLUE-GREEN ACTIVE CONFIGURATION
#
# Initial recovery state: GREEN
#
# BLUE  : Frontend ${BLUE_FRONTEND_PORT} / Backend ${BLUE_BACKEND_PORT}
# GREEN : Frontend ${GREEN_FRONTEND_PORT} / Backend ${GREEN_BACKEND_PORT}
# ============================================================

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream ${UPSTREAM_FRONTEND} {
    server 127.0.0.1:${GREEN_FRONTEND_PORT};
}

upstream ${UPSTREAM_BACKEND} {
    server 127.0.0.1:${GREEN_BACKEND_PORT};
}
NGINXACTIVE_EOF

###############################################################################
# NGINX SITE
###############################################################################

NGINX_SITE_FILE="/etc/nginx/sites-available/${APP_NAME}"

cat > "${NGINX_SITE_FILE}" <<NGINXSITE_EOF
server {

    listen 80;
    listen [::]:80;

    server_name _;

    location /api/ {
        proxy_pass http://${UPSTREAM_BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location / {
        proxy_pass http://${UPSTREAM_FRONTEND};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 60s;
    }
}
NGINXSITE_EOF

###############################################################################
# ENABLE NGINX SITE
###############################################################################

log "Enabling Nginx site for ${APP_NAME}"

rm -f /etc/nginx/sites-enabled/default
ln -sfn "${NGINX_SITE_FILE}" "/etc/nginx/sites-enabled/${APP_NAME}"

nginx -t
systemctl enable nginx
systemctl restart nginx
systemctl is-active nginx

###############################################################################
# ACTIVE SLOT MARKER
###############################################################################

echo "green" > "${ACTIVE_SLOT_FILE}"

###############################################################################
# DEPLOYMENT CONFIG
###############################################################################

log "Creating deployment configuration"

cat > "${DEPLOY_DIR}/config.env" <<CONFIGENV_EOF
# ============================================================
# ${APP_NAME} DEPLOYMENT CONFIGURATION
# Generated by ec2-blue-green-deploy.sh
# ============================================================

APP_NAME="${APP_NAME}"

BASE_DIR="${BASE_DIR}"
RELEASES_DIR="${RELEASES_DIR}"
REPOSITORY_DIR="${REPOSITORY_DIR}"
DEPLOY_DIR="${DEPLOY_DIR}"
MONITOR_DIR="${MONITOR_DIR}"

BLUE_DIR="${BLUE_DIR}"
GREEN_DIR="${GREEN_DIR}"

BLUE_FRONTEND_PORT="${BLUE_FRONTEND_PORT}"
BLUE_BACKEND_PORT="${BLUE_BACKEND_PORT}"

GREEN_FRONTEND_PORT="${GREEN_FRONTEND_PORT}"
GREEN_BACKEND_PORT="${GREEN_BACKEND_PORT}"

ACTIVE_SLOT_FILE="${ACTIVE_SLOT_FILE}"
NGINX_ACTIVE_CONF="/etc/nginx/conf.d/${APP_NAME}-active.conf"
UPSTREAM_FRONTEND="${APP_NAME}_frontend"
UPSTREAM_BACKEND="${APP_NAME}_backend"
CONFIGENV_EOF

chown ubuntu:ubuntu "${DEPLOY_DIR}/config.env"
chmod 600 "${DEPLOY_DIR}/config.env"

###############################################################################
# deploy.sh — promotes the INACTIVE slot after a fresh build.
# Generic: builds only if package.json has a "build" script; always
# starts via "npm start" (requires a "start" script in package.json).
###############################################################################

log "Writing deploy.sh"

cat > "${DEPLOY_DIR}/deploy.sh" <<'DEPLOYSH_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DEPLOY_DIR}/config.env"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run with sudo."
    exit 1
fi

BACKEND_REPO_URL="${1:-}"
FRONTEND_REPO_URL="${2:-}"
REPO_BRANCH="${3:-main}"

if [[ -z "${BACKEND_REPO_URL}" || -z "${FRONTEND_REPO_URL}" ]]; then
    echo "Usage: sudo bash deploy.sh <backend-repo-url> <frontend-repo-url> [branch]"
    exit 1
fi

CURRENT_SLOT="$(cat "${ACTIVE_SLOT_FILE}")"

if [[ "${CURRENT_SLOT}" == "blue" ]]; then
    TARGET_SLOT="green"
    TARGET_DIR="${GREEN_DIR}"
    TARGET_FRONTEND_PORT="${GREEN_FRONTEND_PORT}"
    TARGET_BACKEND_PORT="${GREEN_BACKEND_PORT}"
else
    TARGET_SLOT="blue"
    TARGET_DIR="${BLUE_DIR}"
    TARGET_FRONTEND_PORT="${BLUE_FRONTEND_PORT}"
    TARGET_BACKEND_PORT="${BLUE_BACKEND_PORT}"
fi

echo "Current active slot : ${CURRENT_SLOT}"
echo "Deploying to slot    : ${TARGET_SLOT}"

# Load a previously saved GitHub token, if any.
GITHUB_TOKEN=""
if [[ -f "${DEPLOY_DIR}/github_token" ]]; then
    GITHUB_TOKEN="$(cat "${DEPLOY_DIR}/github_token")"
fi

# git_clone_auth <repo-url> <branch> <dest-dir>
# Uses GIT_ASKPASS so the token never appears in the repo URL, argv, or logs.
git_clone_auth() {
    local repo_url="$1" branch="$2" dest_dir="$3"

    if [[ -n "${GITHUB_TOKEN}" ]]; then
        local askpass_script
        askpass_script="$(mktemp)"
        cat > "${askpass_script}" <<EOF
#!/usr/bin/env bash
echo "${GITHUB_TOKEN}"
EOF
        chmod 700 "${askpass_script}"

        GIT_ASKPASS="${askpass_script}" GIT_TERMINAL_PROMPT=0 \
            git clone --branch "${branch}" --depth 1 "${repo_url}" "${dest_dir}"

        rm -f "${askpass_script}"
    else
        GIT_TERMINAL_PROMPT=0 git clone --branch "${branch}" --depth 1 "${repo_url}" "${dest_dir}"
    fi
}

# install_and_build <dir-path> <label>
# Runs npm ci, then npm run build only if package.json defines a "build" script.
# Fails loudly if no "start" script exists, since PM2 needs one to run.
install_and_build() {
    local dir_path="$1" label="$2"

    if [[ ! -f "${dir_path}/package.json" ]]; then
        echo "ERROR: no package.json found in ${label} (${dir_path})."
        exit 1
    fi

    if ! jq -e '.scripts.start' "${dir_path}/package.json" >/dev/null 2>&1; then
        echo "ERROR: ${label} package.json has no \"start\" script. PM2 needs one to run this app."
        exit 1
    fi

    echo "Installing dependencies for ${label}..."
    ( cd "${dir_path}" && npm ci )

    if jq -e '.scripts.build' "${dir_path}/package.json" >/dev/null 2>&1; then
        echo "Build script found for ${label} — running npm run build..."
        ( cd "${dir_path}" && npm run build )
    else
        echo "No build script for ${label} — skipping build step."
    fi
}

rm -rf "${TARGET_DIR}/backend" "${TARGET_DIR}/frontend"
mkdir -p "${TARGET_DIR}/backend" "${TARGET_DIR}/frontend"

git_clone_auth "${BACKEND_REPO_URL}" "${REPO_BRANCH}" "${TARGET_DIR}/backend"
git_clone_auth "${FRONTEND_REPO_URL}" "${REPO_BRANCH}" "${TARGET_DIR}/frontend"

cp "${DEPLOY_DIR}/backend.env" "${TARGET_DIR}/backend/.env"
cp "${DEPLOY_DIR}/frontend.env" "${TARGET_DIR}/frontend/.env"
cp "${DEPLOY_DIR}/frontend.env" "${TARGET_DIR}/frontend/.env.production" 2>/dev/null || true

sed -i "s/^PORT=.*/PORT=${TARGET_BACKEND_PORT}/" "${TARGET_DIR}/backend/.env"
sed -i "s/^PORT=.*/PORT=${TARGET_FRONTEND_PORT}/" "${TARGET_DIR}/frontend/.env"

install_and_build "${TARGET_DIR}/backend" "backend"
install_and_build "${TARGET_DIR}/frontend" "frontend"

chown -R ubuntu:ubuntu "${TARGET_DIR}"

BACKEND_PROC="${APP_NAME}-backend-${TARGET_SLOT}"
FRONTEND_PROC="${APP_NAME}-frontend-${TARGET_SLOT}"

sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 pm2 delete "${BACKEND_PROC}" 2>/dev/null || true
sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 pm2 delete "${FRONTEND_PROC}" 2>/dev/null || true

sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 PORT="${TARGET_BACKEND_PORT}" \
    pm2 start npm --name "${BACKEND_PROC}" --cwd "${TARGET_DIR}/backend" -- start

sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 PORT="${TARGET_FRONTEND_PORT}" \
    pm2 start npm --name "${FRONTEND_PROC}" --cwd "${TARGET_DIR}/frontend" -- start

sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 pm2 save

echo "Waiting for new slot to become healthy..."

HEALTHY=0
for i in $(seq 1 15); do
    if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${TARGET_BACKEND_PORT}" \
       && curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${TARGET_FRONTEND_PORT}"; then
        HEALTHY=1
        break
    fi
    echo "  not ready yet (attempt ${i}/15)..."
    sleep 2
done

if [[ "${HEALTHY}" -eq 1 ]]; then

    echo "New slot healthy. Switching Nginx to ${TARGET_SLOT}..."

    cat > "${NGINX_ACTIVE_CONF}" <<NGINXSWITCH_EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream ${UPSTREAM_FRONTEND} {
    server 127.0.0.1:${TARGET_FRONTEND_PORT};
}

upstream ${UPSTREAM_BACKEND} {
    server 127.0.0.1:${TARGET_BACKEND_PORT};
}
NGINXSWITCH_EOF

    nginx -t
    systemctl reload nginx

    echo "${CURRENT_SLOT}" > "${DEPLOY_DIR}/previous_slot"
    echo "${TARGET_SLOT}" > "${ACTIVE_SLOT_FILE}"

    echo "Deploy complete. Active slot is now: ${TARGET_SLOT}"
else
    echo "ERROR: new slot failed health check after 30s (15 attempts). Nginx NOT switched."
    echo "Old slot (${CURRENT_SLOT}) remains active."
    exit 1
fi
DEPLOYSH_EOF

chmod +x "${DEPLOY_DIR}/deploy.sh"
chown ubuntu:ubuntu "${DEPLOY_DIR}/deploy.sh"

###############################################################################
# rollback.sh — flips Nginx back to the previous slot
###############################################################################

log "Writing rollback.sh"

cat > "${DEPLOY_DIR}/rollback.sh" <<'ROLLBACKSH_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DEPLOY_DIR}/config.env"

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run with sudo."
    exit 1
fi

if [[ ! -f "${DEPLOY_DIR}/previous_slot" ]]; then
    echo "ERROR: no previous slot recorded. Nothing to roll back to."
    exit 1
fi

PREVIOUS_SLOT="$(cat "${DEPLOY_DIR}/previous_slot")"

if [[ "${PREVIOUS_SLOT}" == "blue" ]]; then
    FRONTEND_PORT="${BLUE_FRONTEND_PORT}"
    BACKEND_PORT="${BLUE_BACKEND_PORT}"
else
    FRONTEND_PORT="${GREEN_FRONTEND_PORT}"
    BACKEND_PORT="${GREEN_BACKEND_PORT}"
fi

echo "Rolling back to slot: ${PREVIOUS_SLOT}"

cat > "${NGINX_ACTIVE_CONF}" <<NGINXROLLBACK_EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream ${UPSTREAM_FRONTEND} {
    server 127.0.0.1:${FRONTEND_PORT};
}

upstream ${UPSTREAM_BACKEND} {
    server 127.0.0.1:${BACKEND_PORT};
}
NGINXROLLBACK_EOF

nginx -t
systemctl reload nginx

echo "${PREVIOUS_SLOT}" > "${ACTIVE_SLOT_FILE}"

echo "Rollback complete. Active slot is now: ${PREVIOUS_SLOT}"
ROLLBACKSH_EOF

chmod +x "${DEPLOY_DIR}/rollback.sh"
chown ubuntu:ubuntu "${DEPLOY_DIR}/rollback.sh"

###############################################################################
# monitor.sh — health check + incident logging + auto-rollback
###############################################################################

log "Writing monitor.sh"

cat > "${MONITOR_DIR}/monitor.sh" <<'MONITORSH_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${MONITOR_DIR}/../deploy" && pwd)"
source "${DEPLOY_DIR}/config.env"

TS="$(date '+%Y-%m-%d %H:%M:%S')"
CURRENT_SLOT="$(cat "${ACTIVE_SLOT_FILE}" 2>/dev/null || echo unknown)"

if [[ "${CURRENT_SLOT}" == "blue" ]]; then
    FRONTEND_PORT="${BLUE_FRONTEND_PORT}"
    BACKEND_PORT="${BLUE_BACKEND_PORT}"
else
    FRONTEND_PORT="${GREEN_FRONTEND_PORT}"
    BACKEND_PORT="${GREEN_BACKEND_PORT}"
fi

LOG_LINE="[${TS}] slot=${CURRENT_SLOT}"
SLOT_DOWN=0

if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${FRONTEND_PORT}"; then
    LOG_LINE="${LOG_LINE} frontend=UP"
else
    LOG_LINE="${LOG_LINE} frontend=DOWN"
    SLOT_DOWN=1
    echo "${TS} frontend down on port ${FRONTEND_PORT}" >> "${MONITOR_DIR}/incidents/incidents.log"
fi

if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${BACKEND_PORT}"; then
    LOG_LINE="${LOG_LINE} backend=UP"
else
    LOG_LINE="${LOG_LINE} backend=DOWN"
    SLOT_DOWN=1
    echo "${TS} backend down on port ${BACKEND_PORT}" >> "${MONITOR_DIR}/incidents/incidents.log"
fi

echo "${LOG_LINE}" >> "${MONITOR_DIR}/logs/monitor.log"

###############################################################################
# AUTO-ROLLBACK ON REPEATED FAILURE
###############################################################################

FAIL_COUNT_FILE="${MONITOR_DIR}/state/fail_count"
FAIL_COUNT="$(cat "${FAIL_COUNT_FILE}" 2>/dev/null || echo 0)"

if [[ "${SLOT_DOWN}" -eq 1 ]]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    FAIL_COUNT=0
fi

echo "${FAIL_COUNT}" > "${FAIL_COUNT_FILE}"

if [[ "${FAIL_COUNT}" -ge 3 ]]; then
    echo "${TS} active slot (${CURRENT_SLOT}) failed ${FAIL_COUNT} consecutive checks — triggering auto-rollback" >> "${MONITOR_DIR}/incidents/incidents.log"

    if [[ -x "${DEPLOY_DIR}/rollback.sh" ]]; then
        bash "${DEPLOY_DIR}/rollback.sh" >> "${MONITOR_DIR}/incidents/incidents.log" 2>&1 || true
    fi

    echo 0 > "${FAIL_COUNT_FILE}"
fi
MONITORSH_EOF

chmod +x "${MONITOR_DIR}/monitor.sh"
chown ubuntu:ubuntu "${MONITOR_DIR}/monitor.sh"

echo
echo "Tip: add a cron entry to run this every 5 minutes, e.g.:"
echo "  */5 * * * * root ${MONITOR_DIR}/monitor.sh"

###############################################################################
# PLACEHOLDER ENV FILES (real values collected in Part B)
###############################################################################

cat > "${DEPLOY_DIR}/backend.env" <<BACKENDENV_EOF
NODE_ENV=production
PORT=${GREEN_BACKEND_PORT}
BACKENDENV_EOF

chmod 600 "${DEPLOY_DIR}/backend.env"
chown ubuntu:ubuntu "${DEPLOY_DIR}/backend.env"

cat > "${DEPLOY_DIR}/frontend.env" <<FRONTENDENV_EOF
NODE_ENV=production
PORT=${GREEN_FRONTEND_PORT}
FRONTENDENV_EOF

chmod 600 "${DEPLOY_DIR}/frontend.env"
chown ubuntu:ubuntu "${DEPLOY_DIR}/frontend.env"

###############################################################################
# RECOVERY INFORMATION
###############################################################################

log "Creating recovery information"

cat > "${BASE_DIR}/${APP_NAME^^}-RECOVERY-INFO.txt" <<RECOVERYINFO_EOF
${APP_NAME} EC2 RECOVERY SERVER
================================

Frontend: Blue ${BLUE_FRONTEND_PORT} / Green ${GREEN_FRONTEND_PORT}
Backend : Blue ${BLUE_BACKEND_PORT} / Green ${GREEN_BACKEND_PORT}
Nginx   : Port 80

Reusable scripts:
  ${DEPLOY_DIR}/deploy.sh <backend-repo-url> <frontend-repo-url> [branch]
  ${DEPLOY_DIR}/rollback.sh
  ${MONITOR_DIR}/monitor.sh

Env vars for backend/frontend live in:
  ${DEPLOY_DIR}/backend.env
  ${DEPLOY_DIR}/frontend.env
Edit these directly to add/change app-specific variables, then re-run deploy.sh.

GitHub token (if any) for private repos:
  ${DEPLOY_DIR}/github_token
RECOVERYINFO_EOF

chown ubuntu:ubuntu "${BASE_DIR}/${APP_NAME^^}-RECOVERY-INFO.txt"

###############################################################################
# PM2 STARTUP
###############################################################################

log "Configuring PM2 startup"

export PM2_HOME="/home/ubuntu/.pm2"
mkdir -p "${PM2_HOME}"
chown -R ubuntu:ubuntu "${PM2_HOME}"

PM2_STARTUP_OUTPUT="/tmp/${APP_NAME}-pm2-startup.txt"

sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 \
    pm2 startup systemd -u ubuntu --hp /home/ubuntu \
    > "${PM2_STARTUP_OUTPUT}" 2>&1 || true

STARTUP_COMMAND="$(grep '^sudo ' "${PM2_STARTUP_OUTPUT}" | tail -1 || true)"

if [[ -n "${STARTUP_COMMAND}" ]]; then
    echo "Executing PM2 startup command..."
    bash -c "${STARTUP_COMMAND}" || true
fi

###############################################################################
# ENABLE SERVICES
###############################################################################

log "Enabling services"

systemctl enable nginx
systemctl start nginx

###############################################################################
# PART B — INTERACTIVE DEPLOY
###############################################################################

log "PART B: Interactive application deploy"

echo
echo "This will clone your backend and frontend repos, collect env vars,"
echo "install/build, and start both on the GREEN slot"
echo "(frontend ${GREEN_FRONTEND_PORT} / backend ${GREEN_BACKEND_PORT})."
echo
read -r -p "Deploy the application now? [y/N]: " DO_DEPLOY

if [[ "${DO_DEPLOY,,}" == "y" || "${DO_DEPLOY,,}" == "yes" ]]; then

    read -r -p "Backend repository URL: " BACKEND_REPO_URL
    read -r -p "Frontend repository URL: " FRONTEND_REPO_URL
    read -r -p "Branch to deploy [main]: " REPO_BRANCH_INPUT
    REPO_BRANCH="${REPO_BRANCH_INPUT:-main}"

    echo
    echo "--- GitHub access (leave blank if both repos are public) ---"
    read -r -p "GitHub Personal Access Token: " GITHUB_TOKEN

    if [[ -n "${GITHUB_TOKEN}" ]]; then
        printf '%s' "${GITHUB_TOKEN}" > "${DEPLOY_DIR}/github_token"
        chmod 600 "${DEPLOY_DIR}/github_token"
        chown ubuntu:ubuntu "${DEPLOY_DIR}/github_token"
        echo "Token saved to ${DEPLOY_DIR}/github_token (chmod 600) for reuse by deploy.sh"
    fi

    # git_clone_auth <repo-url> <branch> <dest-dir>
    git_clone_auth() {
        local repo_url="$1" branch="$2" dest_dir="$3"

        if [[ -n "${GITHUB_TOKEN:-}" ]]; then
            local askpass_script
            askpass_script="$(mktemp)"
            cat > "${askpass_script}" <<EOF
#!/usr/bin/env bash
echo "${GITHUB_TOKEN}"
EOF
            chmod 700 "${askpass_script}"

            GIT_ASKPASS="${askpass_script}" GIT_TERMINAL_PROMPT=0 \
                git clone --branch "${branch}" --depth 1 "${repo_url}" "${dest_dir}"

            rm -f "${askpass_script}"
        else
            GIT_TERMINAL_PROMPT=0 git clone --branch "${branch}" --depth 1 "${repo_url}" "${dest_dir}"
        fi
    }

    log "Cloning backend (${BACKEND_REPO_URL}, ${REPO_BRANCH})"
    rm -rf "${GREEN_DIR:?}/backend"
    git_clone_auth "${BACKEND_REPO_URL}" "${REPO_BRANCH}" "${GREEN_DIR}/backend"

    log "Cloning frontend (${FRONTEND_REPO_URL}, ${REPO_BRANCH})"
    rm -rf "${GREEN_DIR:?}/frontend"
    git_clone_auth "${FRONTEND_REPO_URL}" "${REPO_BRANCH}" "${GREEN_DIR}/frontend"

    # collect_env_vars <label> -> writes to stdout as KEY=VALUE lines
    collect_env_vars() {
        local label="$1"
        echo >&2
        echo "--- ${label} environment variables ---" >&2
        echo "Enter KEY=VALUE, one per line. Press Enter on an empty line to finish." >&2
        while true; do
            read -r -p "  ${label} env> " LINE
            [[ -z "${LINE}" ]] && break
            if [[ "${LINE}" != *"="* ]]; then
                echo "  Skipped (not KEY=VALUE): ${LINE}" >&2
                continue
            fi
            if [[ "${LINE}" == PORT=* ]]; then
                echo "  Skipped: PORT is set automatically per slot, don't set it manually." >&2
                continue
            fi
            echo "${LINE}"
        done
    }

    BACKEND_EXTRA_ENV="$(collect_env_vars "Backend")"
    FRONTEND_EXTRA_ENV="$(collect_env_vars "Frontend")"

    {
        echo "NODE_ENV=production"
        echo "PORT=${GREEN_BACKEND_PORT}"
        [[ -n "${BACKEND_EXTRA_ENV}" ]] && echo "${BACKEND_EXTRA_ENV}"
    } > "${DEPLOY_DIR}/backend.env"

    {
        echo "NODE_ENV=production"
        echo "PORT=${GREEN_FRONTEND_PORT}"
        [[ -n "${FRONTEND_EXTRA_ENV}" ]] && echo "${FRONTEND_EXTRA_ENV}"
    } > "${DEPLOY_DIR}/frontend.env"

    chmod 600 "${DEPLOY_DIR}/backend.env" "${DEPLOY_DIR}/frontend.env"
    chown ubuntu:ubuntu "${DEPLOY_DIR}/backend.env" "${DEPLOY_DIR}/frontend.env"

    cp "${DEPLOY_DIR}/backend.env" "${GREEN_DIR}/backend/.env"
    cp "${DEPLOY_DIR}/frontend.env" "${GREEN_DIR}/frontend/.env"
    cp "${DEPLOY_DIR}/frontend.env" "${GREEN_DIR}/frontend/.env.production" 2>/dev/null || true
    chown ubuntu:ubuntu "${GREEN_DIR}/backend/.env" "${GREEN_DIR}/frontend/.env"
    chmod 600 "${GREEN_DIR}/backend/.env"

    # install_and_build <dir-path> <label>
    install_and_build() {
        local dir_path="$1" label="$2"

        if [[ ! -f "${dir_path}/package.json" ]]; then
            echo "ERROR: no package.json found in ${label} (${dir_path})."
            exit 1
        fi

        if ! jq -e '.scripts.start' "${dir_path}/package.json" >/dev/null 2>&1; then
            echo "ERROR: ${label} package.json has no \"start\" script. PM2 needs one to run this app."
            exit 1
        fi

        echo "Installing dependencies for ${label}..."
        ( cd "${dir_path}" && npm ci )

        if jq -e '.scripts.build' "${dir_path}/package.json" >/dev/null 2>&1; then
            echo "Build script found for ${label} — running npm run build..."
            ( cd "${dir_path}" && npm run build )
        else
            echo "No build script for ${label} — skipping build step."
        fi
    }

    install_and_build "${GREEN_DIR}/backend" "backend"
    install_and_build "${GREEN_DIR}/frontend" "frontend"

    chown -R ubuntu:ubuntu "${GREEN_DIR}"

    log "Starting GREEN slot under PM2"

    sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 pm2 delete "${APP_NAME}-backend-green" 2>/dev/null || true
    sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 pm2 delete "${APP_NAME}-frontend-green" 2>/dev/null || true

    sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 PORT="${GREEN_BACKEND_PORT}" \
        pm2 start npm --name "${APP_NAME}-backend-green" --cwd "${GREEN_DIR}/backend" -- start

    sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 PORT="${GREEN_FRONTEND_PORT}" \
        pm2 start npm --name "${APP_NAME}-frontend-green" --cwd "${GREEN_DIR}/frontend" -- start

    sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 pm2 save

    echo "Waiting for services to come up..."
    HEALTHY=0
    for i in $(seq 1 15); do
        if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${GREEN_BACKEND_PORT}" \
           && curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${GREEN_FRONTEND_PORT}"; then
            HEALTHY=1
            break
        fi
        echo "  not ready yet (attempt ${i}/15)..."
        sleep 2
    done

    if [[ "${HEALTHY}" -ne 1 ]]; then
        echo "WARNING: services did not respond within 30s. Check 'pm2 logs' for details."
    fi

    sudo -u ubuntu env PM2_HOME=/home/ubuntu/.pm2 pm2 list
else
    echo "Skipping application deploy. Run deploy.sh manually later:"
    echo "  sudo bash ${DEPLOY_DIR}/deploy.sh <backend-repo-url> <frontend-repo-url> [branch]"
fi

###############################################################################
# PERMISSIONS
###############################################################################

log "Fixing permissions"

chown -R ubuntu:ubuntu "${BASE_DIR}"
chmod +x "${BASE_DIR}" 2>/dev/null || true

###############################################################################
# FINAL VERIFICATION
###############################################################################

log "Running final verification"

echo
echo "===== NODE ====="
node -v

echo
echo "===== NGINX ====="
nginx -t
systemctl is-active nginx

echo
echo "===== PORTS ====="
ss -lntp | grep -E ":80 |:${BLUE_FRONTEND_PORT} |:${GREEN_FRONTEND_PORT} |:${BLUE_BACKEND_PORT} |:${GREEN_BACKEND_PORT} " || true

echo
echo "===== APPLICATION HEALTH (GREEN slot) ====="

if curl -s -o /dev/null --max-time 3 -w "frontend (${GREEN_FRONTEND_PORT}): HTTP %{http_code}\n" "http://127.0.0.1:${GREEN_FRONTEND_PORT}" 2>/dev/null; then
    :
else
    echo "frontend (${GREEN_FRONTEND_PORT}): not responding"
fi

if curl -s -o /dev/null --max-time 3 -w "backend  (${GREEN_BACKEND_PORT}): HTTP %{http_code}\n" "http://127.0.0.1:${GREEN_BACKEND_PORT}" 2>/dev/null; then
    :
else
    echo "backend  (${GREEN_BACKEND_PORT}): not responding"
fi

curl -I http://127.0.0.1 2>/dev/null || echo "nginx (80): not responding"

###############################################################################
# FINAL MESSAGE
###############################################################################

echo
echo
echo "####################################################################"
echo "#      ${APP_NAME} REBUILD + DEPLOY COMPLETED"
echo "####################################################################"
echo
echo "Active slot: GREEN (frontend ${GREEN_FRONTEND_PORT} / backend ${GREEN_BACKEND_PORT})"
echo
echo "Reusable for next deploy:"
echo "  sudo bash ${DEPLOY_DIR}/deploy.sh <backend-repo-url> <frontend-repo-url> [branch]"
echo "  sudo bash ${DEPLOY_DIR}/rollback.sh"
echo "  sudo bash ${MONITOR_DIR}/monitor.sh"
echo
echo "Recovery information:"
echo "  ${BASE_DIR}/${APP_NAME^^}-RECOVERY-INFO.txt"
echo
echo "####################################################################"
