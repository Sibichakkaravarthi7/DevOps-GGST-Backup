#!/usr/bin/env bash

###############################################################################
# DESKTOP BACKEND - SINGLE SHOT EC2 DISASTER RECOVERY
#
# Everything is handled by this script:
#
#   1. Verify backup
#   2. Install system packages
#   3. Install exact Node.js version
#   4. Restore application
#   5. Restore .env
#   6. Update new EC2 public IP
#   7. npm ci
#   8. Validate mediasoup + FFmpeg
#   9. Restore Let's Encrypt
#  10. Restore Nginx
#  11. Restore Coturn
#  12. Install exact PM2 version
#  13. Create correct PM2 systemd service
#  14. Start application
#  15. Start Nginx
#  16. Start Coturn
#  17. Configure firewall
#  18. Validate everything
#
# PM2 architecture:
#
#       systemd
#          |
#          v
#     pm2-runtime
#          |
#          v
#       desktop
#          |
#          v
#      server.js :5000
#
# IMPORTANT:
#   This script DOES NOT use:
#       pm2 save
#       pm2 resurrect
#       pm2 startup
#
# systemd directly owns pm2-runtime.
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# VARIABLES
###############################################################################

BACKUP_DIR="/home/ubuntu/dr-recovery"

ARCHIVE="$BACKUP_DIR/server-dr-20260911-062830.tar.zst"

EXPECTED_SHA256="4f66291543db372addb1cf4c0a6859da0fbbe91a99f4b1424283f111ff159b21"

ARCHIVE_ROOT="server-dr-20260911-062830"

UBUNTU_USER="ubuntu"

APP_NAME="desktop"
APP_DIR="/home/ubuntu/Desktop-Backend"
APP_ENTRY="$APP_DIR/server.js"
APP_PORT="5000"

NODE_VERSION="20.20.2"
PM2_VERSION="7.0.3"

TMP_DIR="/tmp/desktop-backend-dr"

NODE_PREFIX=""
NODE_BIN=""
NPM_BIN=""
NPX_BIN=""
PM2_BIN=""
PM2_RUNTIME=""

PM2_HOME="/home/ubuntu/.pm2"

NEW_PUBLIC_IP=""

NGINX_BIN="/usr/sbin/nginx"

COTURN_CONFIG="/etc/coturn/turnserver.conf"

###############################################################################
# FUNCTIONS
###############################################################################

section() {
    echo
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
}

info() {
    echo "[INFO] $*"
}

success() {
    echo "[OK] $*"
}

warn() {
    echo "[WARN] $*"
}

fail() {
    echo
    echo "[ERROR] $*"
    echo
    exit 1
}

###############################################################################
# ERROR HANDLER
###############################################################################

error_handler() {
    local line="$1"
    local code="$2"

    echo
    echo "======================================================================"
    echo " RECOVERY FAILED"
    echo "======================================================================"
    echo
    echo "Failed line : $line"
    echo "Exit code   : $code"
    echo
    echo "Useful commands:"
    echo
    echo "  sudo systemctl status pm2-ubuntu.service --no-pager"
    echo "  sudo journalctl -u pm2-ubuntu.service -n 100 --no-pager"
    echo "  sudo nginx -t"
    echo "  sudo systemctl status nginx --no-pager"
    echo "  sudo systemctl status coturn --no-pager"
    echo
}

trap 'error_handler "${LINENO}" "$?"' ERR

###############################################################################
# ROOT CHECK
###############################################################################

section "1. CHECKING ROOT ACCESS"

if [ "$(id -u)" -ne 0 ]; then
    fail "Run with:

sudo bash restore-server.sh"
fi

success "Running as root."

###############################################################################
# USER CHECK
###############################################################################

section "2. CHECKING UBUNTU USER"

if ! id "$UBUNTU_USER" >/dev/null 2>&1; then
    fail "User '$UBUNTU_USER' does not exist."
fi

success "User '$UBUNTU_USER' exists."

###############################################################################
# PUBLIC IP
###############################################################################

section "3. DETECTING NEW EC2 PUBLIC IP"

NEW_PUBLIC_IP="$(
    curl \
        -4 \
        -fsS \
        --max-time 10 \
        http://169.254.169.254/latest/meta-data/public-ipv4 \
        2>/dev/null || true
)"

if [ -z "$NEW_PUBLIC_IP" ]; then

    NEW_PUBLIC_IP="$(
        curl \
            -4 \
            -fsS \
            --max-time 10 \
            https://checkip.amazonaws.com \
            2>/dev/null || true
    )"

fi

NEW_PUBLIC_IP="$(echo "$NEW_PUBLIC_IP" | tr -d '[:space:]')"

if [ -z "$NEW_PUBLIC_IP" ]; then
    fail "Could not determine EC2 public IP."
fi

if ! [[ "$NEW_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Invalid public IP:

$NEW_PUBLIC_IP"
fi

echo "New EC2 Public IP:"
echo "$NEW_PUBLIC_IP"

###############################################################################
# BACKUP CHECK
###############################################################################

section "4. CHECKING BACKUP"

if [ ! -f "$ARCHIVE" ]; then
    fail "Backup archive does not exist:

$ARCHIVE"
fi

echo "Backup:"
ls -lh "$ARCHIVE"

###############################################################################
# SHA256
###############################################################################

section "5. VERIFYING BACKUP SHA256"

ACTUAL_SHA256="$(
    sha256sum "$ARCHIVE" |
    awk '{print $1}'
)"

echo "Expected:"
echo "$EXPECTED_SHA256"

echo
echo "Actual:"
echo "$ACTUAL_SHA256"

if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    fail "Backup SHA256 verification failed."
fi

success "Backup SHA256 verified."

###############################################################################
# PREPARE TEMP
###############################################################################

section "6. PREPARING RECOVERY WORKSPACE"

rm -rf "$TMP_DIR"

mkdir -p "$TMP_DIR"

chmod 700 "$TMP_DIR"

###############################################################################
# APT
###############################################################################

section "7. INSTALLING REQUIRED PACKAGES"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    curl \
    wget \
    ca-certificates \
    tar \
    zstd \
    xz-utils \
    rsync \
    jq \
    git \
    build-essential \
    python3 \
    python3-pip \
    pkg-config \
    openssl \
    ffmpeg \
    nginx \
    coturn \
    ufw \
    net-tools \
    lsof

success "Required packages installed."

###############################################################################
# NODE ARCHITECTURE
###############################################################################

section "8. INSTALLING NODE.JS $NODE_VERSION"

MACHINE_ARCH="$(uname -m)"

case "$MACHINE_ARCH" in

    x86_64)

        NODE_ARCH="x64"

        NODE_SHA256="df770b2a6f130ed8627c9782c988fda9669fa23898329a61a871e32f965e007d"

        ;;

    aarch64|arm64)

        NODE_ARCH="arm64"

        NODE_SHA256="73093db209e4e9e09dd7d15a47aeaab1b74833830df03efa5f942a1122c5fa71"

        ;;

    *)

        fail "Unsupported architecture: $MACHINE_ARCH"

        ;;

esac

NODE_PREFIX="/usr/local/node-v${NODE_VERSION}-linux-${NODE_ARCH}"

NODE_BIN="$NODE_PREFIX/bin/node"
NPM_BIN="$NODE_PREFIX/bin/npm"
NPX_BIN="$NODE_PREFIX/bin/npx"

NODE_TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"

NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"

NODE_DOWNLOAD="$TMP_DIR/$NODE_TARBALL"

echo "Architecture : $NODE_ARCH"
echo "Node prefix  : $NODE_PREFIX"

if [ ! -x "$NODE_BIN" ]; then

    info "Downloading Node.js..."

    curl \
        -fL \
        --retry 3 \
        --retry-delay 2 \
        "$NODE_URL" \
        -o "$NODE_DOWNLOAD"

    ACTUAL_NODE_SHA="$(
        sha256sum "$NODE_DOWNLOAD" |
        awk '{print $1}'
    )"

    echo
    echo "Expected Node SHA:"
    echo "$NODE_SHA256"

    echo
    echo "Actual Node SHA:"
    echo "$ACTUAL_NODE_SHA"

    if [ "$ACTUAL_NODE_SHA" != "$NODE_SHA256" ]; then
        fail "Node.js SHA256 verification failed."
    fi

    rm -rf "$NODE_PREFIX"

    tar \
        -xJf "$NODE_DOWNLOAD" \
        -C /usr/local

fi

###############################################################################
# NODE SYMLINKS
###############################################################################

ln -sfn "$NODE_BIN" /usr/local/bin/node
ln -sfn "$NPM_BIN" /usr/local/bin/npm
ln -sfn "$NPX_BIN" /usr/local/bin/npx

cat > /etc/profile.d/nodejs.sh <<EOF
export PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin:\$PATH"
EOF

chmod 644 /etc/profile.d/nodejs.sh

export PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin"

hash -r

NODE_ACTUAL="$("$NODE_BIN" --version)"

if [ "$NODE_ACTUAL" != "v$NODE_VERSION" ]; then
    fail "Incorrect Node.js version.

Expected: v$NODE_VERSION
Actual:   $NODE_ACTUAL"
fi

success "Node.js $NODE_ACTUAL installed."

###############################################################################
# EXTRACT BACKUP
###############################################################################

section "9. EXTRACTING BACKUP"

EXTRACT_DIR="$TMP_DIR/extracted"

mkdir -p "$EXTRACT_DIR"

tar \
    --zstd \
    -xf "$ARCHIVE" \
    -C "$EXTRACT_DIR"

BACKUP_ROOT="$EXTRACT_DIR/$ARCHIVE_ROOT"

if [ ! -d "$BACKUP_ROOT" ]; then
    fail "Backup root not found:

$BACKUP_ROOT"
fi

success "Backup extracted."

###############################################################################
# STOP SERVICES
###############################################################################

section "10. STOPPING EXISTING SERVICES"

systemctl stop pm2-ubuntu.service >/dev/null 2>&1 || true
systemctl stop nginx >/dev/null 2>&1 || true
systemctl stop coturn >/dev/null 2>&1 || true

###############################################################################
# PM2 INSTALL
###############################################################################

section "11. INSTALLING PM2 $PM2_VERSION"

"$NPM_BIN" install -g "pm2@$PM2_VERSION"

PM2_BIN="$NODE_PREFIX/bin/pm2"
PM2_RUNTIME="$NODE_PREFIX/bin/pm2-runtime"

if [ ! -x "$PM2_BIN" ]; then
    fail "PM2 executable not found:

$PM2_BIN"
fi

if [ ! -x "$PM2_RUNTIME" ]; then
    fail "pm2-runtime executable not found:

$PM2_RUNTIME"
fi

ln -sfn "$PM2_BIN" /usr/local/bin/pm2
ln -sfn "$PM2_RUNTIME" /usr/local/bin/pm2-runtime

export PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin"

hash -r

PM2_ACTUAL="$(
    "$PM2_BIN" --version |
    tail -n 1 |
    tr -d '[:space:]'
)"

if [ "$PM2_ACTUAL" != "$PM2_VERSION" ]; then
    fail "Incorrect PM2 version.

Expected: $PM2_VERSION
Actual:   $PM2_ACTUAL"
fi

success "PM2 $PM2_ACTUAL installed."

###############################################################################
# RESTORE APPLICATION
###############################################################################

section "12. RESTORING APPLICATION"

BACKUP_APP_DIR="$BACKUP_ROOT/app/Desktop-Backend"

if [ ! -d "$BACKUP_APP_DIR" ]; then
    fail "Application backup not found:

$BACKUP_APP_DIR"
fi

rm -rf "$APP_DIR"

mkdir -p "$APP_DIR"

rsync \
    -a \
    "$BACKUP_APP_DIR/" \
    "$APP_DIR/"

chown -R "$UBUNTU_USER:$UBUNTU_USER" "$APP_DIR"

success "Application restored."

###############################################################################
# ENV
###############################################################################

section "13. RESTORING APPLICATION ENVIRONMENT"

if [ -f "$APP_DIR/.env" ]; then

    chown "$UBUNTU_USER:$UBUNTU_USER" "$APP_DIR/.env"

    chmod 600 "$APP_DIR/.env"

    success ".env restored."

else

    warn ".env was not found."

fi

###############################################################################
# UPDATE IP
###############################################################################

section "14. UPDATING PUBLIC IP"

if [ -f "$APP_DIR/.env" ]; then

    for KEY in \
        MEDIASOUP_ANNOUNCED_IP \
        RECORDING_ANNOUNCED_IP \
        PUBLIC_IP \
        SERVER_IP \
        ANNOUNCED_IP
    do

        if grep -q "^${KEY}=" "$APP_DIR/.env"; then

            sed -i \
                -E "s|^${KEY}=.*$|${KEY}=${NEW_PUBLIC_IP}|" \
                "$APP_DIR/.env"

        fi

    done

    chmod 600 "$APP_DIR/.env"

    success "Application public IP updated."

else

    warn "Cannot update IP because .env does not exist."

fi

###############################################################################
# NPM INSTALL
###############################################################################

section "15. INSTALLING APPLICATION DEPENDENCIES"

chown -R "$UBUNTU_USER:$UBUNTU_USER" "$APP_DIR"

if [ -f "$APP_DIR/package-lock.json" ]; then

    info "package-lock.json found."
    info "Running npm ci --omit=dev..."

    sudo -u "$UBUNTU_USER" \
        env \
            HOME="/home/$UBUNTU_USER" \
            PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
        bash -c 'cd "$1" && "$2" ci --omit=dev' \
        bash "$APP_DIR" "$NPM_BIN"

else

    warn "package-lock.json not found."
    info "Running npm install --omit=dev..."

    sudo -u "$UBUNTU_USER" \
        env \
            HOME="/home/$UBUNTU_USER" \
            PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
        bash -c 'cd "$1" && "$2" install --omit=dev' \
        bash "$APP_DIR" "$NPM_BIN"

fi

chown -R "$UBUNTU_USER:$UBUNTU_USER" "$APP_DIR"

success "Dependencies installed."

###############################################################################
# MEDIASOUP
###############################################################################

section "16. CHECKING MEDIASOUP"

if [ ! -d "$APP_DIR/node_modules/mediasoup" ]; then
    fail "mediasoup is not installed."
fi

MEDIASOUP_VERSION_ACTUAL="$(
    sudo -u "$UBUNTU_USER" \
        env \
            PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
        "$NODE_BIN" \
        -e '
            const p = require(process.argv[1]);
            process.stdout.write(p.version);
        ' \
        "$APP_DIR/node_modules/mediasoup/package.json" \
        2>/dev/null || true
)"

echo "mediasoup version:"
echo "${MEDIASOUP_VERSION_ACTUAL:-unknown}"

success "mediasoup directory exists."

###############################################################################
# FFMPEG
###############################################################################

section "17. CHECKING FFMPEG"

if ! command -v ffmpeg >/dev/null 2>&1; then
    fail "FFmpeg is not installed."
fi

FFMPEG_PATH="$(command -v ffmpeg)"

echo "FFmpeg:"
echo "$FFMPEG_PATH"

ffmpeg -version | head -n 1

success "FFmpeg available."

###############################################################################
# LETSENCRYPT
###############################################################################

section "18. RESTORING LET'S ENCRYPT"

BACKUP_LETSENCRYPT="$BACKUP_ROOT/etc/letsencrypt"

if [ -d "$BACKUP_LETSENCRYPT" ]; then

    mkdir -p /etc/letsencrypt

    rsync \
        -a \
        "$BACKUP_LETSENCRYPT/" \
        /etc/letsencrypt/

    success "Let's Encrypt restored."

else

    warn "Let's Encrypt backup not found."

fi

###############################################################################
# NGINX
###############################################################################

section "19. RESTORING NGINX"

BACKUP_NGINX="$BACKUP_ROOT/etc/nginx"

if [ ! -d "$BACKUP_NGINX" ]; then
    fail "Nginx backup not found."
fi

rm -rf /etc/nginx

mkdir -p /etc/nginx

rsync \
    -a \
    "$BACKUP_NGINX/" \
    /etc/nginx/

###############################################################################
# NGINX BINARY
###############################################################################

NGINX_BIN="$(command -v nginx 2>/dev/null || true)"

if [ -z "$NGINX_BIN" ] && [ -x /usr/sbin/nginx ]; then
    NGINX_BIN="/usr/sbin/nginx"
fi

if [ -z "$NGINX_BIN" ]; then
    fail "Nginx binary not found."
fi

###############################################################################
# NGINX TEST
###############################################################################

section "20. TESTING NGINX"

if ! "$NGINX_BIN" -t; then
    fail "Nginx configuration test failed."
fi

success "Nginx configuration test successful."

###############################################################################
# COTURN
###############################################################################

section "21. RESTORING COTURN"

BACKUP_COTURN="$BACKUP_ROOT/etc/coturn"

if [ -d "$BACKUP_COTURN" ]; then

    mkdir -p /etc/coturn

    rsync \
        -a \
        "$BACKUP_COTURN/" \
        /etc/coturn/

    success "Coturn configuration restored."

else

    warn "Coturn backup not found."

fi

###############################################################################
# COTURN PUBLIC IP
###############################################################################

section "22. UPDATING COTURN PUBLIC IP"

if [ -f "$COTURN_CONFIG" ]; then

    if grep -q '^external-ip=' "$COTURN_CONFIG"; then

        sed -i \
            -E "s|^external-ip=.*$|external-ip=$NEW_PUBLIC_IP|" \
            "$COTURN_CONFIG"

    else

        echo "external-ip=$NEW_PUBLIC_IP" \
            >> "$COTURN_CONFIG"

    fi

    success "Coturn external IP updated."

    echo
    grep '^external-ip=' "$COTURN_CONFIG" || true

else

    warn "Coturn configuration not found."

fi

###############################################################################
# PM2 HOME
###############################################################################

section "23. PREPARING PM2 HOME"

mkdir -p "$PM2_HOME"

chown -R "$UBUNTU_USER:$UBUNTU_USER" "$PM2_HOME"

chmod 700 "$PM2_HOME"

###############################################################################
# CLEAN OLD PM2 SERVICE
###############################################################################

section "24. REMOVING OLD PM2 SERVICE CONFIGURATION"

systemctl stop pm2-ubuntu.service >/dev/null 2>&1 || true

systemctl disable pm2-ubuntu.service >/dev/null 2>&1 || true

###############################################################################
# CREATE PM2 SERVICE
###############################################################################

section "25. CREATING PM2 SYSTEMD SERVICE"

#
# IMPORTANT:
#
# There is intentionally NO --time here.
#
# PM2 7.0.3 pm2-runtime does not accept --time in this command form.
#

cat > /etc/systemd/system/pm2-ubuntu.service <<EOF
[Unit]
Description=PM2 Runtime - Desktop Backend
Documentation=https://pm2.keymetrics.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=$UBUNTU_USER
Group=$UBUNTU_USER

WorkingDirectory=$APP_DIR

Environment=HOME=/home/$UBUNTU_USER
Environment=PATH=$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin
Environment=PM2_HOME=$PM2_HOME
Environment=NODE_ENV=production

ExecStart=$PM2_RUNTIME start $APP_ENTRY --name $APP_NAME

Restart=always
RestartSec=5

LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity

KillMode=process

TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/pm2-ubuntu.service

###############################################################################
# VERIFY SERVICE FILE
###############################################################################

section "26. VERIFYING PM2 SERVICE"

grep -n '^ExecStart=' \
    /etc/systemd/system/pm2-ubuntu.service

if grep -q -- '--time' /etc/systemd/system/pm2-ubuntu.service; then
    fail "Invalid --time option still exists in PM2 service."
fi

success "PM2 service configuration is correct."

###############################################################################
# SYSTEMD RELOAD
###############################################################################

section "27. RELOADING SYSTEMD"

systemctl daemon-reload

systemctl enable pm2-ubuntu.service

success "PM2 service enabled."

###############################################################################
# START APPLICATION
###############################################################################

section "28. STARTING DESKTOP BACKEND"

systemctl restart pm2-ubuntu.service

sleep 8

###############################################################################
# PM2 SERVICE CHECK
###############################################################################

if ! systemctl is-active --quiet pm2-ubuntu.service; then

    echo
    echo "PM2 service status:"
    systemctl status \
        pm2-ubuntu.service \
        --no-pager \
        --full || true

    echo
    echo "PM2 service logs:"
    journalctl \
        -u pm2-ubuntu.service \
        -n 100 \
        --no-pager || true

    fail "pm2-ubuntu.service failed to start."

fi

success "pm2-ubuntu.service is ACTIVE."

###############################################################################
# PM2 JLIST
###############################################################################

section "29. CHECKING PM2 APPLICATION"

PM2_JLIST="$(
    sudo -u "$UBUNTU_USER" \
        env \
            HOME="/home/$UBUNTU_USER" \
            PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
            PM2_HOME="$PM2_HOME" \
        "$PM2_BIN" \
        jlist \
        2>/dev/null || true
)"

echo "$PM2_JLIST" | jq . 2>/dev/null || echo "$PM2_JLIST"

###############################################################################
# APP STATUS
###############################################################################

APP_STATUS="$(
    echo "$PM2_JLIST" |
    jq -r \
        --arg APP "$APP_NAME" \
        '.[] | select(.name == $APP) | .pm2_env.status' \
        2>/dev/null |
    head -n 1
)"

echo
echo "Application:"
echo "$APP_NAME"

echo
echo "Status:"
echo "${APP_STATUS:-unknown}"

if [ "$APP_STATUS" != "online" ]; then

    echo
    echo "PM2 status:"
    sudo -u "$UBUNTU_USER" \
        env \
            HOME="/home/$UBUNTU_USER" \
            PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
            PM2_HOME="$PM2_HOME" \
        "$PM2_BIN" status || true

    echo
    echo "PM2 logs:"
    sudo -u "$UBUNTU_USER" \
        env \
            HOME="/home/$UBUNTU_USER" \
            PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
            PM2_HOME="$PM2_HOME" \
        "$PM2_BIN" logs "$APP_NAME" \
        --lines 50 \
        --nostream || true

    fail "Application '$APP_NAME' is not ONLINE."

fi

success "Application '$APP_NAME' is ONLINE."

###############################################################################
# APPLICATION PORT
###############################################################################

section "30. CHECKING APPLICATION PORT"

sleep 3

if ss -lntp | grep -q ":$APP_PORT "; then

    success "Application listening on port $APP_PORT."

    ss -lntp | grep ":$APP_PORT " || true

else

    warn "Port $APP_PORT is not listening."

fi

###############################################################################
# LOCAL HTTP TEST
###############################################################################

section "31. TESTING LOCAL APPLICATION"

HTTP_STATUS="$(
    curl \
        -s \
        -o /dev/null \
        -w "%{http_code}" \
        --max-time 10 \
        "http://127.0.0.1:$APP_PORT/" \
        2>/dev/null || true
)"

echo "HTTP status:"
echo "$HTTP_STATUS"

if [ "$HTTP_STATUS" != "000" ] && [ -n "$HTTP_STATUS" ]; then
    success "Application accepted HTTP connection."
else
    warn "Application did not return HTTP response."
fi

###############################################################################
# NGINX
###############################################################################

section "32. STARTING NGINX"

if ! "$NGINX_BIN" -t; then
    fail "Nginx test failed."
fi

systemctl enable nginx

systemctl restart nginx

sleep 3

if ! systemctl is-active --quiet nginx; then

    systemctl status nginx \
        --no-pager \
        --full || true

    fail "Nginx failed to start."

fi

success "Nginx is ACTIVE."

###############################################################################
# COTURN
###############################################################################

section "33. STARTING COTURN"

if [ -f "$COTURN_CONFIG" ]; then

    systemctl enable coturn

    systemctl restart coturn

    sleep 3

    if systemctl is-active --quiet coturn; then

        success "Coturn is ACTIVE."

    else

        warn "Coturn is not active."

        systemctl status coturn \
            --no-pager \
            --full || true

        journalctl \
            -u coturn \
            -n 50 \
            --no-pager || true

    fi

else

    warn "Coturn configuration not found. Skipping."

fi

###############################################################################
# UFW
###############################################################################

section "34. CONFIGURING FIREWALL"

ufw allow OpenSSH >/dev/null 2>&1 || true

ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

ufw allow "$APP_PORT/tcp" >/dev/null 2>&1 || true

ufw allow 3478/tcp >/dev/null 2>&1 || true
ufw allow 3478/udp >/dev/null 2>&1 || true

ufw allow 5349/tcp >/dev/null 2>&1 || true
ufw allow 5349/udp >/dev/null 2>&1 || true

ufw allow 49152:65535/tcp >/dev/null 2>&1 || true
ufw allow 49152:65535/udp >/dev/null 2>&1 || true

ufw status verbose || true

###############################################################################
# PORTS
###############################################################################

section "35. CHECKING LISTENING PORTS"

echo
echo "TCP:"
ss -lntp || true

echo
echo "UDP:"
ss -lnup || true

###############################################################################
# SYSTEMD
###############################################################################

section "36. CHECKING SYSTEMD SERVICES"

echo
echo "PM2:"
systemctl is-active pm2-ubuntu.service || true

echo
echo "Nginx:"
systemctl is-active nginx || true

echo
echo "Coturn:"
systemctl is-active coturn || true

###############################################################################
# FINAL PM2
###############################################################################

section "37. FINAL PM2 STATUS"

FINAL_JLIST="$(
    sudo -u "$UBUNTU_USER" \
        env \
            HOME="/home/$UBUNTU_USER" \
            PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
            PM2_HOME="$PM2_HOME" \
        "$PM2_BIN" \
        jlist \
        2>/dev/null || true
)"

FINAL_STATUS="$(
    echo "$FINAL_JLIST" |
    jq -r \
        --arg APP "$APP_NAME" \
        '.[] | select(.name == $APP) | .pm2_env.status' \
        2>/dev/null |
    head -n 1
)"

echo "Application status:"
echo "${FINAL_STATUS:-unknown}"

if [ "$FINAL_STATUS" != "online" ]; then
    fail "Final PM2 status is not online."
fi

sudo -u "$UBUNTU_USER" \
    env \
        HOME="/home/$UBUNTU_USER" \
        PATH="$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
        PM2_HOME="$PM2_HOME" \
    "$PM2_BIN" status

###############################################################################
# FINAL NGINX
###############################################################################

section "38. FINAL NGINX TEST"

"$NGINX_BIN" -t

success "Nginx configuration is valid."

###############################################################################
# FINAL VERSIONS
###############################################################################

section "39. FINAL SOFTWARE VERSIONS"

echo
echo "Node.js:"
"$NODE_BIN" --version

echo
echo "npm:"
"$NPM_BIN" --version

echo
echo "PM2:"
"$PM2_BIN" --version

echo
echo "Nginx:"
"$NGINX_BIN" -v 2>&1 || true

echo
echo "FFmpeg:"
ffmpeg -version | head -n 1

echo
echo "Coturn:"
turnserver --version 2>&1 | head -n 1 || true

###############################################################################
# FINAL SYSTEMD STATUS
###############################################################################

section "40. FINAL SERVICE STATUS"

systemctl is-active pm2-ubuntu.service
systemctl is-active nginx

if [ -f "$COTURN_CONFIG" ]; then
    systemctl is-active coturn || true
fi

###############################################################################
# FINAL SUMMARY
###############################################################################

section "41. RECOVERY COMPLETE"

echo
echo "======================================================================"
echo "              DESKTOP BACKEND RECOVERY SUCCESSFUL"
echo "======================================================================"
echo
echo "SERVER"
echo "------"
echo "Hostname       : $(hostname)"
echo "Public IP      : $NEW_PUBLIC_IP"
echo
echo "APPLICATION"
echo "-----------"
echo "Name           : $APP_NAME"
echo "Directory      : $APP_DIR"
echo "Entry          : $APP_ENTRY"
echo "Port           : $APP_PORT"
echo "Status         : $FINAL_STATUS"
echo
echo "NODE.JS"
echo "-------"
echo "Version        : $("$NODE_BIN" --version)"
echo
echo "PM2"
echo "---"
echo "Version        : $("$PM2_BIN" --version)"
echo "Service        : pm2-ubuntu.service"
echo "Architecture   : systemd -> pm2-runtime -> desktop"
echo
echo "NGINX"
echo "-----"
echo "Status         : $(systemctl is-active nginx)"
echo "Config test    : SUCCESS"
echo
echo "COTURN"
echo "------"
echo "Status         : $(systemctl is-active coturn 2>/dev/null || true)"
echo "External IP    : $NEW_PUBLIC_IP"
echo "Relay ports    : 49152-65535"
echo
echo "======================================================================"
echo "                         ALL DONE"
echo "======================================================================"
echo

###############################################################################
# CLEANUP
###############################################################################

rm -rf "$TMP_DIR"

success "Temporary recovery files removed."

exit 0
