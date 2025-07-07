#!/usr/bin/env bash

################################################################################
#                                                                              #
#             PteroNova Automatic Installer for Ubuntu 22.04                   #
#                   (C) 2024 Ghost Dev Team - MIT License                     #
#     https://github.com/ghost-dev-gr/pterdactyl-installer-v4                  #
#                                                                              #
################################################################################

set -euo pipefail

######################################
#          GLOBAL VARIABLES          #
######################################
PANEL_DOMAIN=""
USE_SSL=""
ADMIN_EMAIL=""
ADMIN_USER=""
FIRST_NAME=""
LAST_NAME=""
ADMIN_PASS=""
DEPLOY_WINGS=""
MYSQL_RANDOM_PASS=""
PANEL_URL=""
MYSQL_USER="paneldbuser"
MYSQL_DATABASE="paneldb"
PANEL_ROOT="/srv/pteronova"
CONFIG_BASE="https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs"
LOG_FILE="/root/pteronova-install.log"

######################################
#           ARGUMENT PARSER          #
######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --panel-domain) PANEL_DOMAIN="$2"; shift ;;
            --use-ssl)      USE_SSL="$2"; shift ;;
            --admin-email)  ADMIN_EMAIL="$2"; shift ;;
            --admin-user)   ADMIN_USER="$2"; shift ;;
            --first-name)   FIRST_NAME="$2"; shift ;;
            --last-name)    LAST_NAME="$2"; shift ;;
            --admin-pass)   ADMIN_PASS="$2"; shift ;;
            --deploy-wings) DEPLOY_WINGS="$2"; shift ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
        shift
    done

    # Required fields
    for var in PANEL_DOMAIN USE_SSL ADMIN_EMAIL ADMIN_USER FIRST_NAME LAST_NAME ADMIN_PASS DEPLOY_WINGS; do
        if [ -z "${!var}" ]; then
            echo "[Error] Missing required parameter: $var"
            exit 1
        fi
    done
}

######################################
#          LOGGING FUNCTION          #
######################################
log() {
    echo -e "$(date +"%F %T") [INFO] $*" | tee -a "$LOG_FILE"
}
log_error() {
    echo -e "$(date +"%F %T") [ERROR] $*" | tee -a "$LOG_FILE" >&2
}

######################################
#      ENVIRONMENT AND OS CHECK      #
######################################
verify_environment() {
    log "Checking OS compatibility..."
    if ! grep -q "Ubuntu 22.04" /etc/os-release; then
        log_error "This script only supports Ubuntu 22.04."
        exit 1
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "You must run this script as root."
        exit 1
    fi
}

######################################
#         PACKAGE INSTALLATION       #
######################################
install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    log "Updating system packages..."
    apt-get update -qq
    log "Installing dependencies (nginx, MariaDB, PHP, Redis, etc)..."
    apt-get install -yqq \
        nginx mariadb-server redis-server tar unzip git curl wget \
        php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} \
        certbot python3-certbot-nginx docker.io \
        > /dev/null

    log "Installing Composer (PHP dependency manager)..."
    if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi

    log "All required system packages installed."
}

######################################
#         DATABASE SETUP             #
######################################
setup_database() {
    log "Configuring MariaDB database and user..."
    MYSQL_RANDOM_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    systemctl enable --now mariadb
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_RANDOM_PASS}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF
    log "MariaDB user: ${MYSQL_USER} / Database: ${MYSQL_DATABASE}"
}

######################################
#         PANEL INSTALLATION          #
######################################
deploy_panel() {
    log "Creating Pterodactyl panel directory at $PANEL_ROOT ..."
    mkdir -p "$PANEL_ROOT"
    cd "$PANEL_ROOT"
    log "Downloading latest Pterodactyl Panel release..."
    curl -sL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
    tar -xzf panel.tar.gz
    rm panel.tar.gz

    cp .env.example .env
    log "Installing panel PHP dependencies with Composer..."
    composer install --no-dev --optimize-autoloader --no-interaction

    log "Generating panel encryption key..."
    php artisan key:generate --force

    PANEL_URL="http${USE_SSL,,} == true && echo 's' || echo ''}://${PANEL_DOMAIN}"

    log "Setting up Pterodactyl environment..."
    php artisan p:environment:setup \
        --author="$ADMIN_EMAIL" \
        --url="$PANEL_URL" \
        --timezone="UTC" \
        --telemetry=false \
        --cache="redis" \
        --session="redis" \
        --queue="redis" \
        --redis-host="127.0.0.1" \
        --redis-pass="null" \
        --redis-port="6379" \
        --settings-ui=true

    log "Setting up panel database credentials..."
    php artisan p:environment:database \
        --host="127.0.0.1" \
        --port="3306" \
        --database="${MYSQL_DATABASE}" \
        --username="${MYSQL_USER}" \
        --password="${MYSQL_RANDOM_PASS}"

    log "Migrating and seeding database..."
    php artisan migrate --seed --force

    log "Creating admin user..."
    php artisan p:user:make \
        --email="${ADMIN_EMAIL}" \
        --username="${ADMIN_USER}" \
        --name-first="${FIRST_NAME}" \
        --name-last="${LAST_NAME}" \
        --password="${ADMIN_PASS}" \
        --admin=1

    chown -R www-data:www-data "$PANEL_ROOT"
    log "Panel file permissions set."
}

######################################
#       SYSTEMD SERVICES SETUP       #
######################################
configure_services() {
    log "Setting up Pteroq queue service..."
    curl -sL "$CONFIG_BASE/pteroq.service" -o /etc/systemd/system/pteroq.service
    systemctl daemon-reload
    systemctl enable --now redis-server pteroq.service

    log "Configuring cronjob for schedule tasks..."
    (crontab -l 2>/dev/null; echo "* * * * * php $PANEL_ROOT/artisan schedule:run >> /dev/null 2>&1") | crontab -
}

######################################
#        NGINX + SSL SETUP           #
######################################
configure_nginx() {
    log "Configuring NGINX webserver..."
    rm -f /etc/nginx/sites-enabled/default
    if [ "${USE_SSL,,}" = "true" ]; then
        curl -sL "$CONFIG_BASE/pterodactyl-nginx-ssl.conf" -o /etc/nginx/sites-enabled/pteronova.conf
        sed -i "s|<domain>|${PANEL_DOMAIN}|g" /etc/nginx/sites-enabled/pteronova.conf
        systemctl reload nginx
        log "Requesting Let's Encrypt certificate for $PANEL_DOMAIN ..."
        certbot --nginx --redirect --agree-tos --email "$ADMIN_EMAIL" -d "$PANEL_DOMAIN" --non-interactive || log_error "Let's Encrypt certificate failed, continuing without SSL!"
    else
        curl -sL "$CONFIG_BASE/www-pterodactyl.conf" -o /etc/nginx/sites-enabled/pteronova.conf
        sed -i "s|<domain>|${PANEL_DOMAIN}|g" /etc/nginx/sites-enabled/pteronova.conf
        systemctl reload nginx
    fi
    log "NGINX configuration complete."
}

######################################
#         WINGS INSTALLATION         #
######################################
install_wings() {
    if [ "${DEPLOY_WINGS,,}" != "true" ]; then
        log "Wings deployment skipped."
        return
    fi
    log "Installing Wings node..."
    systemctl enable --now docker
    mkdir -p /etc/pterodactyl
    ARCH_TYPE="$(uname -m | grep -q '64' && echo amd64 || echo arm64)"
    curl -Ls "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH_TYPE}" -o /usr/local/bin/wings
    chmod +x /usr/local/bin/wings
    curl -sL "$CONFIG_BASE/wings.service" -o /etc/systemd/system/wings.service
    systemctl daemon-reload
    systemctl enable --now wings
    log "Wings node installed and started."
}

######################################
#         PRINT FINAL INFO           #
######################################
print_summary() {
    echo ""
    echo "============================================================================"
    echo "      PteroNova: Pterodactyl Panel & Wings Deployment - Installation Complete"
    echo "============================================================================"
    echo "Panel URL       : ${PANEL_URL}"
    echo "Admin Username  : ${ADMIN_USER}"
    echo "Admin Password  : (hidden)"
    echo "MariaDB Database: ${MYSQL_DATABASE}"
    echo "MariaDB User    : ${MYSQL_USER}"
    echo "MariaDB Pass    : ${MYSQL_RANDOM_PASS}"
    echo "Wings Installed : ${DEPLOY_WINGS}"
    echo "Log File        : $LOG_FILE"
    echo "============================================================================"
    echo ""
    echo "Tip: Copy your DB credentials and keep them safe!"
    echo "You may now access your Pterodactyl panel and start using your node(s)."
    echo ""
}

######################################
#               MAIN                 #
######################################
main() {
    parse_args "$@"
    verify_environment
    install_packages
    setup_database
    deploy_panel
    configure_services
    configure_nginx
    install_wings
    print_summary
}

main "$@"
