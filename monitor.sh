#!/usr/bin/env bash
# ============================================================
# PM2 CONFIGURATION
# ============================================================

# PM2 processes belong to the ubuntu user.
# The monitor may run with sudo, so explicitly point PM2
# to the ubuntu user's PM2 daemon.

export PM2_HOME="/home/ubuntu/.pm2"

###############################################################################
# INVENTIVO END-TO-END MONITOR
#
# Monitors:
#   EC2
#   PM2
#   Blue-Green application processes
#   Application ports
#   Nginx
#   Nginx Blue-Green routing
#   Public frontend
#   Backend health
#   MongoDB connectivity evidence
#   Deployment state
#
# Current architecture:
#
#   BLUE
#     Frontend : 3000
#     Backend  : 8080
#
#   GREEN
#     Frontend : 3001
#     Backend  : 8081
#
#   PM2
#     inventivo-frontend-green
#     inventivo-backend-green
#
###############################################################################

set -u
set -o pipefail

###############################################################################
# CONFIGURATION
###############################################################################

APP_NAME="inventivo"

BASE_DIR="/opt/inventivo"

MONITOR_DIR="${BASE_DIR}/monitor"

LOG_DIR="${MONITOR_DIR}/logs"

STATE_DIR="${MONITOR_DIR}/state"

INCIDENT_DIR="${MONITOR_DIR}/incidents"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$INCIDENT_DIR"

LOG_FILE="${LOG_DIR}/monitor.log"

###############################################################################
# APPLICATION PORTS
###############################################################################

BLUE_FRONTEND_PORT=3000
BLUE_BACKEND_PORT=8080

GREEN_FRONTEND_PORT=3001
GREEN_BACKEND_PORT=8081

NGINX_PORT=80

###############################################################################
# ACTUAL PM2 PROCESS NAMES
###############################################################################

BLUE_FRONTEND="inventivo-frontend-blue"
BLUE_BACKEND="inventivo-backend-blue"

GREEN_FRONTEND="inventivo-frontend-green"
GREEN_BACKEND="inventivo-backend-green"

###############################################################################
# HEALTH ENDPOINT
###############################################################################

BACKEND_HEALTH_PATH="/"

###############################################################################
# THRESHOLDS
###############################################################################

CPU_THRESHOLD=90
RAM_THRESHOLD=90
DISK_THRESHOLD=90
INODE_THRESHOLD=90

###############################################################################
# TIMESTAMP
###############################################################################

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

###############################################################################
# LOG
###############################################################################

log() {

    local message="$1"

    printf '[%s] %s\n' "$(timestamp)" "$message" | tee -a "$LOG_FILE"

}

###############################################################################
# INCIDENT FILE
###############################################################################

incident_file() {

    local key="$1"

    echo "${INCIDENT_DIR}/${key}.incident"

}

###############################################################################
# OPEN INCIDENT
###############################################################################

open_incident() {

    local key="$1"
    local severity="$2"
    local component="$3"
    local root_cause="$4"
    local evidence="$5"
    local fix="$6"

    local file

    file="$(incident_file "$key")"

    if [[ -f "$file" ]]; then
        return 0
    fi

    local incident_id

    incident_id="INC-$(date '+%Y%m%d-%H%M%S')"

    cat > "$file" <<EOF
INCIDENT_ID=$incident_id
FIRST_DETECTED=$(timestamp)
SEVERITY=$severity
COMPONENT=$component

ROOT_CAUSE:
$root_cause

EVIDENCE:
$evidence

HOW_TO_FIX:
$fix
EOF

    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "🚨 INCIDENT DETECTED"
    printf '%s\n' "============================================================"
    printf 'Incident ID : %s\n' "$incident_id"
    printf 'Severity    : %s\n' "$severity"
    printf 'Component   : %s\n' "$component"
    printf '\n'
    printf '%s\n' "ROOT CAUSE"
    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "$root_cause"
    printf '\n'
    printf '%s\n' "EVIDENCE"
    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "$evidence"
    printf '\n'
    printf '%s\n' "HOW TO FIX"
    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "$fix"
    printf '%s\n' "============================================================"
    printf '\n'

}

###############################################################################
# RECOVERY
###############################################################################

recover_incident() {

    local key="$1"
    local recovery="$2"

    local file

    file="$(incident_file "$key")"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local incident_id

    incident_id="$(
        grep '^INCIDENT_ID=' "$file" 2>/dev/null |
        cut -d'=' -f2-
    )"

    if [[ -z "$incident_id" ]]; then
        incident_id="UNKNOWN"
    fi

    rm -f "$file"

    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "✅ INCIDENT RECOVERED"
    printf '%s\n' "============================================================"
    printf 'Incident ID : %s\n' "$incident_id"
    printf 'Recovery    : %s\n' "$(timestamp)"
    printf '\n'
    printf '%s\n' "$recovery"
    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "RECOVERY STATUS: SUCCESSFUL"
    printf '%s\n' "============================================================"
    printf '\n'

}

###############################################################################
# COMMAND CHECK
###############################################################################

command_exists() {

    command -v "$1" >/dev/null 2>&1

}

###############################################################################
# PM2 STATUS
###############################################################################

pm2_status() {

    local name="$1"

    if ! command_exists pm2; then
        echo "PM2_UNAVAILABLE"
        return
    fi

    pm2 jlist 2>/dev/null |
        python3 -c '
import sys
import json

name = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception:
    print("PM2_ERROR")
    sys.exit(0)

for process in data:
    if process.get("name") == name:
        print(process.get("pm2_env", {}).get("status", "unknown"))
        sys.exit(0)

print("NOT_FOUND")
' "$name"

}

###############################################################################
# PM2 RESTART COUNT
###############################################################################

pm2_restarts() {

    local name="$1"

    if ! command_exists pm2; then
        echo "UNKNOWN"
        return
    fi

    pm2 jlist 2>/dev/null |
        python3 -c '
import sys
import json

name = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception:
    print("UNKNOWN")
    sys.exit(0)

for process in data:
    if process.get("name") == name:
        print(process.get("pm2_env", {}).get("restart_time", 0))
        sys.exit(0)

print("UNKNOWN")
' "$name"

}

###############################################################################
# PORT CHECK
###############################################################################

port_listening() {

    local port="$1"

    if ss -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -qE "[:.]${port}$"; then

        echo "YES"

    else

        echo "NO"

    fi

}

###############################################################################
# HTTP CHECK
###############################################################################

http_check() {

    local port="$1"
    local path="${2:-/}"

    local status

    status="$(
        curl \
            -s \
            -o /dev/null \
            -w '%{http_code}' \
            --connect-timeout 3 \
            --max-time 5 \
            "http://127.0.0.1:${port}${path}" \
            2>/dev/null
    )"

    if [[ -z "$status" ]]; then
        echo "000"
    else
        echo "$status"
    fi

}

###############################################################################
# PUBLIC HTTP CHECK
###############################################################################

public_http_check() {

    local status

    status="$(
        curl \
            -s \
            -o /dev/null \
            -w '%{http_code}' \
            --connect-timeout 5 \
            --max-time 10 \
            "http://127.0.0.1/" \
            2>/dev/null
    )"

    if [[ -z "$status" ]]; then
        echo "000"
    else
        echo "$status"
    fi

}

###############################################################################
# NGINX CONFIG
###############################################################################

nginx_dump() {

    sudo nginx -T 2>/dev/null

}

###############################################################################
# DETECT NGINX FRONTEND UPSTREAM PORT
###############################################################################

detect_frontend_upstream_port() {

    local dump="$1"

    printf '%s\n' "$dump" |
        awk '
        /^[[:space:]]*upstream[[:space:]]+inventivo_frontend[[:space:]]*\{/ {
            inside=1
            next
        }

        inside && /^[[:space:]]*server[[:space:]]+/ {

            line=$0

            if (match(line, /:[0-9]+/)) {

                value=substr(line, RSTART + 1, RLENGTH - 1)

                print value

                exit
            }
        }

        inside && /^[[:space:]]*\}/ {
            inside=0
        }
        '

}

###############################################################################
# DETECT NGINX BACKEND UPSTREAM PORT
###############################################################################

detect_backend_upstream_port() {

    local dump="$1"

    printf '%s\n' "$dump" |
        awk '
        /^[[:space:]]*upstream[[:space:]]+inventivo_backend[[:space:]]*\{/ {
            inside=1
            next
        }

        inside && /^[[:space:]]*server[[:space:]]+/ {

            line=$0

            if (match(line, /:[0-9]+/)) {

                value=substr(line, RSTART + 1, RLENGTH - 1)

                print value

                exit
            }
        }

        inside && /^[[:space:]]*\}/ {
            inside=0
        }
        '

}

###############################################################################
# DETECT LIVE SLOT
###############################################################################

detect_live_slot() {

    local frontend_port="$1"
    local backend_port="$2"

    if [[ "$frontend_port" == "$GREEN_FRONTEND_PORT" ]] &&
       [[ "$backend_port" == "$GREEN_BACKEND_PORT" ]]; then

        echo "GREEN"

        return

    fi

    if [[ "$frontend_port" == "$BLUE_FRONTEND_PORT" ]] &&
       [[ "$backend_port" == "$BLUE_BACKEND_PORT" ]]; then

        echo "BLUE"

        return

    fi

    echo "UNKNOWN"

}

###############################################################################
# GET ERROR EVIDENCE
###############################################################################

get_pm2_evidence() {

    local name="$1"

    if ! command_exists pm2; then
        echo "PM2 command unavailable."
        return
    fi

    pm2 logs "$name" \
        --lines 80 \
        --nostream \
        2>&1 |
        tail -80

}

###############################################################################
# EC2 CPU
###############################################################################

check_cpu() {

    local cpu

    cpu="$(
        top -bn1 |
        awk '/Cpu\(s\)/ {
            print int(100 - $8)
        }' |
        head -1
    )"

    if [[ -z "$cpu" ]]; then
        cpu=0
    fi

    if (( cpu >= CPU_THRESHOLD )); then

        open_incident \
            "ec2_cpu" \
            "HIGH" \
            "EC2 CPU" \
            "EC2 CPU utilization is above the configured threshold." \
            "Current CPU: ${cpu}%
Threshold: ${CPU_THRESHOLD}%" \
            "Check:
top
htop
ps aux --sort=-%cpu | head -20

Identify the process consuming CPU.

If the process is an application:
pm2 list
pm2 logs <application> --lines 100"

    else

        recover_incident \
            "ec2_cpu" \
            "EC2 CPU recovered.

Current CPU:
${cpu}%

Threshold:
${CPU_THRESHOLD}%"

    fi

}

###############################################################################
# EC2 RAM
###############################################################################

check_ram() {

    local ram

    ram="$(
        free |
        awk '/Mem:/ {
            if ($2 > 0)
                print int(($3 / $2) * 100)
            else
                print 0
        }'
    )"

    if [[ -z "$ram" ]]; then
        ram=0
    fi

    if (( ram >= RAM_THRESHOLD )); then

        open_incident \
            "ec2_ram" \
            "HIGH" \
            "EC2 MEMORY" \
            "EC2 memory utilization is above the configured threshold." \
            "Current memory: ${ram}%
Threshold: ${RAM_THRESHOLD}%

Memory:
$(free -h)" \
            "Run:

free -h

ps aux --sort=-%mem | head -20

pm2 monit

Identify the process consuming excessive memory.

If required:
pm2 restart <application>"

    else

        recover_incident \
            "ec2_ram" \
            "EC2 memory recovered.

Current memory:
${ram}%

Threshold:
${RAM_THRESHOLD}%"

    fi

}

###############################################################################
# DISK
###############################################################################

check_disk() {

    local disk

    disk="$(
        df -P / |
        awk 'NR==2 {
            gsub("%","",$5)
            print $5
        }'
    )"

    if [[ -z "$disk" ]]; then
        disk=0
    fi

    if (( disk >= DISK_THRESHOLD )); then

        open_incident \
            "ec2_disk" \
            "HIGH" \
            "EC2 DISK" \
            "The root filesystem is above the configured disk threshold." \
            "Disk usage: ${disk}%
Threshold: ${DISK_THRESHOLD}%

$(df -h /)" \
            "Run:

df -h

Find large directories:

sudo du -xh /opt/inventivo 2>/dev/null |
sort -h |
tail -30

Remove only confirmed obsolete data."

    else

        recover_incident \
            "ec2_disk" \
            "EC2 disk usage recovered.

Current usage:
${disk}%

Threshold:
${DISK_THRESHOLD}%"

    fi

}

###############################################################################
# INODES
###############################################################################

check_inodes() {

    local inode

    inode="$(
        df -Pi / |
        awk 'NR==2 {
            gsub("%","",$5)
            print $5
        }'
    )"

    if [[ -z "$inode" ]]; then
        inode=0
    fi

    if (( inode >= INODE_THRESHOLD )); then

        open_incident \
            "ec2_inodes" \
            "HIGH" \
            "EC2 INODES" \
            "The root filesystem is running low on available inodes." \
            "Inode usage: ${inode}%
Threshold: ${INODE_THRESHOLD}%

$(df -Pi /)" \
            "Run:

df -Pi /

Find directories containing large numbers of files:

sudo find /opt/inventivo -xdev -type f 2>/dev/null |
awk -F/ '{print $1"/"$2"/"$3}' |
sort |
uniq -c |
sort -nr |
head -20"

    else

        recover_incident \
            "ec2_inodes" \
            "EC2 inode usage recovered.

Current usage:
${inode}%

Threshold:
${INODE_THRESHOLD}%"

    fi

}

###############################################################################
# PM2 DAEMON
###############################################################################

check_pm2() {

    if ! command_exists pm2; then

        open_incident \
            "pm2_daemon" \
            "CRITICAL" \
            "PM2" \
            "PM2 command is not available." \
            "pm2 command could not be executed." \
            "Check:

which pm2
node --version
pm2 --version

If PM2 is installed but daemon is down:

pm2 ping

pm2 resurrect"

        return

    fi

    if pm2 ping >/dev/null 2>&1; then

        recover_incident \
            "pm2_daemon" \
            "PM2 daemon is healthy."

    else

        open_incident \
            "pm2_daemon" \
            "CRITICAL" \
            "PM2" \
            "PM2 daemon is not responding." \
            "pm2 ping failed." \
            "Run:

pm2 ping

pm2 list

pm2 resurrect

If required:

pm2 update"

    fi

}

###############################################################################
# APPLICATION CHECK
###############################################################################

check_application() {

    local slot="$1"
    local type="$2"
    local name="$3"
    local port="$4"
    local production="$5"

    local status
    local listening
    local http
    local restarts
    local evidence

    local key

    status="$(pm2_status "$name")"

    listening="$(port_listening "$port")"

    if [[ "$type" == "BACKEND" ]]; then
        http="$(http_check "$port" "$BACKEND_HEALTH_PATH")"
    else
        http="$(http_check "$port" "/")"
    fi

    restarts="$(pm2_restarts "$name")"

    key="${slot,,}_${type,,}"

    ###########################################################################
    # PRODUCTION / LIVE APPLICATION
    ###########################################################################

    if [[ "$production" == "YES" ]]; then

        if [[ "$status" == "online" ]] &&
           [[ "$listening" == "YES" ]] &&
           [[ "$http" == "200" ]]; then

            recover_incident \
                "$key" \
                "${slot} ${type} recovered.

PM2:
${status}

Port:
${port}

HTTP:
${http}"

            return

        fi

        evidence="$(get_pm2_evidence "$name")"

        local root_cause
        local fix

        root_cause="The LIVE ${slot} ${type} application is unhealthy."

        fix="Check:

pm2 describe ${name}

pm2 logs ${name} --lines 100

sudo ss -lntp | grep ':${port}'

curl -i http://127.0.0.1:${port}

Restart only after identifying the cause:

pm2 restart ${name}"

        if echo "$evidence" |
            grep -qiE 'EADDRINUSE|address already in use'; then

            root_cause="Port ${port} is already being used by another process."

            fix="Run:

sudo lsof -i :${port}

Identify the process.

Then verify:

ps -fp <PID>

Stop only the unwanted process:

sudo kill <PID>

Then:

pm2 restart ${name}

Verify:

sudo ss -lntp | grep ':${port}'"

        elif echo "$evidence" |
            grep -qiE \
            'MongooseServerSelectionError|MongoServerSelectionError|MongoNetworkError|MongoParseError|mongoose|mongodb|database.*connect'; then

            root_cause="The LIVE backend cannot connect to MongoDB."

            fix="Check the MongoDB connection configuration.

Check environment:

grep -RniE 'MONGO|MONGODB' \
/opt/inventivo/releases \
/opt/inventivo/repository \
2>/dev/null

Check MongoDB Atlas:

1. Cluster is running.
2. Database user exists.
3. Username/password are correct.
4. EC2 public IP is allowed in Network Access.
5. MONGODB_URI points to the correct cluster.

Then:

pm2 restart ${name}

Verify:

curl -i http://127.0.0.1:${port}${BACKEND_HEALTH_PATH}"

        elif echo "$evidence" |
            grep -qiE \
            'ENOMEM|heap out of memory|OOMKilled|out of memory'; then

            root_cause="The LIVE ${type} Node.js process ran out of memory."

            fix="Check:

free -h

pm2 monit

ps aux --sort=-%mem | head -20

Check application logs:

pm2 logs ${name} --lines 100

Restart after investigation:

pm2 restart ${name}

If the problem repeats, investigate memory leaks or increase EC2 memory."

        elif echo "$evidence" |
            grep -qiE 'ENOSPC|no space left'; then

            root_cause="The EC2 filesystem does not have enough free space."

            fix="Run:

df -h

sudo du -xh /opt/inventivo 2>/dev/null |
sort -h |
tail -30

Remove only confirmed obsolete files/releases.

Then:

pm2 restart ${name}"

        elif [[ "$status" == "NOT_FOUND" ]]; then

            root_cause="PM2 does not contain the LIVE application process."

            fix="Run:

pm2 list

pm2 jlist

Verify the deployment created:

${name}

Check the current release:

readlink -f /opt/inventivo/current

Then inspect the deployment script."

        elif [[ "$status" != "online" ]]; then

            root_cause="PM2 reports the LIVE application status as ${status}."

            fix="Run:

pm2 describe ${name}

pm2 logs ${name} --lines 100

Then fix the reported application error.

Restart:

pm2 restart ${name}"

        elif [[ "$listening" == "NO" ]]; then

            root_cause="Nothing is listening on the LIVE port ${port}."

            fix="Check:

pm2 describe ${name}

pm2 logs ${name} --lines 100

sudo ss -lntp | grep ':${port}'

Restart after identifying the reason:

pm2 restart ${name}"

        elif [[ "$http" == "000" ]] ||
             [[ "$http" =~ ^5 ]]; then

            root_cause="The LIVE application process exists, but its HTTP health check is failing."

            fix="Run:

curl -i http://127.0.0.1:${port}

pm2 logs ${name} --lines 100

sudo ss -lntp | grep ':${port}'

Check environment variables.

Then:

pm2 restart ${name}"

        else

            root_cause="The LIVE application failed one or more health checks."

        fi

        open_incident \
            "$key" \
            "CRITICAL" \
            "${slot} ${type}" \
            "$root_cause" \
            "PM2 status : ${status}
Port        : ${port}
Listening   : ${listening}
HTTP status : ${http}
Restarts    : ${restarts}

PM2 evidence:
${evidence}" \
            "$fix"

        return

    fi

    ###########################################################################
    # STANDBY APPLICATION
    #
    # A standby slot being stopped/not found is NOT an incident.
    ###########################################################################

    if [[ "$status" == "NOT_FOUND" ]] ||
       [[ "$status" == "stopped" ]] ||
       [[ "$listening" == "NO" ]]; then

        log "${slot} ${type}: standby/inactive"

    else

        log "${slot} ${type}: PM2=${status}, port=${listening}, HTTP=${http}"

    fi

}

###############################################################################
# BLUE-GREEN CHECK
###############################################################################

check_blue_green() {

    local dump
    local frontend_upstream
    local backend_upstream
    local live_slot

    dump="$(nginx_dump)"

    if [[ -z "$dump" ]]; then

        open_incident \
            "nginx_config" \
            "CRITICAL" \
            "NGINX CONFIGURATION" \
            "Nginx configuration could not be read." \
            "sudo nginx -T returned no configuration output." \
            "Run:

sudo nginx -t

sudo nginx -T

sudo systemctl status nginx"

        return

    fi

    frontend_upstream="$(detect_frontend_upstream_port "$dump")"

    backend_upstream="$(detect_backend_upstream_port "$dump")"

    live_slot="$(detect_live_slot "$frontend_upstream" "$backend_upstream")"

    log "Nginx frontend upstream : ${frontend_upstream:-UNKNOWN}"

    log "Nginx backend upstream  : ${backend_upstream:-UNKNOWN}"

    log "Detected LIVE SLOT      : ${live_slot}"

    if [[ "$live_slot" == "UNKNOWN" ]]; then

        open_incident \
            "blue_green_routing" \
            "CRITICAL" \
            "BLUE-GREEN ROUTING" \
            "Nginx upstreams do not match a known Blue or Green deployment." \
            "Frontend upstream : ${frontend_upstream:-UNKNOWN}
Backend upstream  : ${backend_upstream:-UNKNOWN}

Expected BLUE:
Frontend : ${BLUE_FRONTEND_PORT}
Backend  : ${BLUE_BACKEND_PORT}

Expected GREEN:
Frontend : ${GREEN_FRONTEND_PORT}
Backend  : ${GREEN_BACKEND_PORT}" \
            "Inspect:

sudo nginx -T

Check the upstream blocks:

upstream inventivo_frontend
upstream inventivo_backend

They should point to either:

BLUE:
Frontend : ${BLUE_FRONTEND_PORT}
Backend  : ${BLUE_BACKEND_PORT}

or:

GREEN:
Frontend : ${GREEN_FRONTEND_PORT}
Backend  : ${GREEN_BACKEND_PORT}

After fixing:

sudo nginx -t

sudo systemctl reload nginx"

    else

        recover_incident \
            "blue_green_routing" \
            "Blue-Green routing recovered.

LIVE SLOT:
${live_slot}

Frontend upstream:
${frontend_upstream}

Backend upstream:
${backend_upstream}"

    fi

    ###########################################################################
    # APPLICATION CHECKS
    ###########################################################################

    if [[ "$live_slot" == "GREEN" ]]; then

        check_application \
            "GREEN" \
            "FRONTEND" \
            "$GREEN_FRONTEND" \
            "$GREEN_FRONTEND_PORT" \
            "YES"

        check_application \
            "GREEN" \
            "BACKEND" \
            "$GREEN_BACKEND" \
            "$GREEN_BACKEND_PORT" \
            "YES"

        check_application \
            "BLUE" \
            "FRONTEND" \
            "$BLUE_FRONTEND" \
            "$BLUE_FRONTEND_PORT" \
            "NO"

        check_application \
            "BLUE" \
            "BACKEND" \
            "$BLUE_BACKEND" \
            "$BLUE_BACKEND_PORT" \
            "NO"

    elif [[ "$live_slot" == "BLUE" ]]; then

        check_application \
            "BLUE" \
            "FRONTEND" \
            "$BLUE_FRONTEND" \
            "$BLUE_FRONTEND_PORT" \
            "YES"

        check_application \
            "BLUE" \
            "BACKEND" \
            "$BLUE_BACKEND" \
            "$BLUE_BACKEND_PORT" \
            "YES"

        check_application \
            "GREEN" \
            "FRONTEND" \
            "$GREEN_FRONTEND" \
            "$GREEN_FRONTEND_PORT" \
            "NO"

        check_application \
            "GREEN" \
            "BACKEND" \
            "$GREEN_BACKEND" \
            "$GREEN_BACKEND_PORT" \
            "NO"

    else

        log "LIVE SLOT UNKNOWN - skipping production application classification"

    fi

}

###############################################################################
# NGINX SERVICE
###############################################################################

check_nginx() {

    local status
    local config_test

    status="$(systemctl is-active nginx 2>/dev/null || true)"

    if [[ "$status" != "active" ]]; then

        open_incident \
            "nginx_service" \
            "CRITICAL" \
            "NGINX SERVICE" \
            "Nginx service is not active." \
            "systemctl status nginx:
$(systemctl status nginx --no-pager 2>&1 | tail -40)" \
            "Run:

sudo nginx -t

sudo systemctl status nginx

If configuration is valid:

sudo systemctl restart nginx"

        return

    fi

    config_test="$(sudo nginx -t 2>&1 || true)"

    if ! echo "$config_test" |
        grep -q "syntax is ok"; then

        open_incident \
            "nginx_config_test" \
            "CRITICAL" \
            "NGINX CONFIGURATION" \
            "Nginx configuration test failed." \
            "$config_test" \
            "Run:

sudo nginx -t

Inspect the reported configuration file and line.

After fixing:

sudo nginx -t

sudo systemctl reload nginx"

    else

        recover_incident \
            "nginx_service" \
            "Nginx service recovered and is active."

        recover_incident \
            "nginx_config_test" \
            "Nginx configuration test is valid."

    fi

}

###############################################################################
# PUBLIC FRONTEND
###############################################################################

check_public_frontend() {

    local status

    status="$(public_http_check)"

    if [[ "$status" == "200" ]]; then

        recover_incident \
            "public_frontend" \
            "Public frontend recovered.

HTTP status:
${status}"

        return

    fi

    open_incident \
        "public_frontend" \
        "CRITICAL" \
        "PUBLIC FRONTEND" \
        "The public frontend is not returning HTTP 200 through Nginx." \
        "Public HTTP status: ${status}

Nginx:
$(systemctl is-active nginx 2>/dev/null || true)

Public endpoint:
http://127.0.0.1/" \
        "Check:

sudo nginx -t

sudo systemctl status nginx

Check active upstream:

sudo nginx -T

Check PM2:

pm2 list

Test frontend ports:

curl -i http://127.0.0.1:${BLUE_FRONTEND_PORT}

curl -i http://127.0.0.1:${GREEN_FRONTEND_PORT}

Check Nginx errors:

sudo tail -100 /var/log/nginx/error.log"

}

###############################################################################
# PORT MONITORING
###############################################################################

check_ports() {

    local port
    local state

    for port in \
        "$BLUE_FRONTEND_PORT" \
        "$BLUE_BACKEND_PORT" \
        "$GREEN_FRONTEND_PORT" \
        "$GREEN_BACKEND_PORT"
    do

        state="$(port_listening "$port")"

        log "Port ${port}: ${state}"

    done

}

###############################################################################
# DEPLOYMENT CHECK
###############################################################################

check_deployment() {

    local current

    if [[ -L "${BASE_DIR}/current" ]]; then

        current="$(readlink -f "${BASE_DIR}/current")"

        log "Current release: ${current}"

        if [[ -d "$current" ]]; then

            recover_incident \
                "deployment_current_release" \
                "Current deployment release is valid.

${current}"

        else

            open_incident \
                "deployment_current_release" \
                "HIGH" \
                "DEPLOYMENT" \
                "The current release symlink points to a directory that does not exist." \
                "Current target:
${current}" \
                "Check:

ls -la ${BASE_DIR}

readlink -f ${BASE_DIR}/current

Inspect the latest deployment release."

        fi

    else

        open_incident \
            "deployment_current_release" \
            "HIGH" \
            "DEPLOYMENT" \
            "The /opt/inventivo/current symlink does not exist." \
            "Expected:
${BASE_DIR}/current" \
            "Check the deployment process and release directory.

ls -la ${BASE_DIR}

ls -la ${BASE_DIR}/releases"

    fi

}

###############################################################################
# SYSTEM SUMMARY
###############################################################################

print_summary() {

    local frontend_upstream
    local backend_upstream
    local live

    local nginx
    local pm2
    local public

    local blue_frontend_status
    local blue_backend_status
    local green_frontend_status
    local green_backend_status

    local dump

    dump="$(nginx_dump)"

    frontend_upstream="$(detect_frontend_upstream_port "$dump")"

    backend_upstream="$(detect_backend_upstream_port "$dump")"

    live="$(detect_live_slot "$frontend_upstream" "$backend_upstream")"

    nginx="$(systemctl is-active nginx 2>/dev/null || true)"

    if pm2 ping >/dev/null 2>&1; then
        pm2="ONLINE"
    else
        pm2="DOWN"
    fi

    public="$(public_http_check)"

    blue_frontend_status="$(pm2_status "$BLUE_FRONTEND")"

    blue_backend_status="$(pm2_status "$BLUE_BACKEND")"

    green_frontend_status="$(pm2_status "$GREEN_FRONTEND")"

    green_backend_status="$(pm2_status "$GREEN_BACKEND")"

    log "============================================================"
    log "INVENTIVO MONITOR SUMMARY"
    log "============================================================"

    log "Host              : $(hostname)"

    log "Public IP         : $(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n' || echo UNKNOWN)"

    log "LIVE SLOT         : $live"

    log "NGINX             : $nginx"

    log "PM2               : $pm2"

    log "PUBLIC HTTP       : $public"

    log "FRONTEND UPSTREAM : ${frontend_upstream:-UNKNOWN}"

    log "BACKEND UPSTREAM  : ${backend_upstream:-UNKNOWN}"

    log "BLUE FRONTEND     : $blue_frontend_status :${BLUE_FRONTEND_PORT}"

    log "BLUE BACKEND      : $blue_backend_status :${BLUE_BACKEND_PORT}"

    log "GREEN FRONTEND    : $green_frontend_status :${GREEN_FRONTEND_PORT}"

    log "GREEN BACKEND     : $green_backend_status :${GREEN_BACKEND_PORT}"

    log "============================================================"

}

###############################################################################
# MAIN
###############################################################################

main() {

    log "============================================================"

    log "INVENTIVO END-TO-END MONITOR START"

    log "============================================================"

    ###########################################################################
    # EC2
    ###########################################################################

    check_cpu

    check_ram

    check_disk

    check_inodes

    ###########################################################################
    # PM2
    ###########################################################################

    check_pm2

    ###########################################################################
    # PORTS
    ###########################################################################

    check_ports

    ###########################################################################
    # NGINX
    ###########################################################################

    check_nginx

    ###########################################################################
    # BLUE-GREEN
    ###########################################################################

    check_blue_green

    ###########################################################################
    # PUBLIC FRONTEND
    ###########################################################################

    check_public_frontend

    ###########################################################################
    # DEPLOYMENT
    ###########################################################################

    check_deployment

    ###########################################################################
    # SUMMARY
    ###########################################################################

    print_summary

    log "INVENTIVO MONITOR CHECK COMPLETED"

}

###############################################################################
# START
###############################################################################

main "$@"
