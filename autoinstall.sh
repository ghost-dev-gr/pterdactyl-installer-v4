#!/usr/bin/env bash

################################################################################
#                   PteroNova Universal Installer (2024)                       #
#        Cleanroom Rewrite - For Ubuntu 22.04, NGINX, Wings (Node)             #
#         Maintained by Ghost Dev Team | MIT License | v4.0+                   #
################################################################################

set -euo pipefail

##############################
#      GLOBAL VARS           #
##############################
PANEL_DOMAIN=""
USE_SSL=""
ADMIN_EMAIL=""
ADMIN_USER=""
FIRST_NAME=""
LAST_NAME=""
ADMIN_PASS=""
DEPLOY_WINGS=""

DB_USER="pterodactyl"
DB_NAME="panel"
DB_PASS=""
PANEL_ROOT="/var/www/pterodactyl"
NGINX_CONF_NAME="pterodactyl.conf"
CONFIG_BASE_URL="https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs"
LOG_FILE="/root/pteronova-install.log"

##############################
#     ARGUMENT PARSER        #
##############################
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

    # Validate
    for v in PANEL_DOMAIN USE_SSL ADMIN_EMAIL ADMIN_USER FIRST_NAME LAST_NAME ADMIN_PASS DEPLOY_WINGS; do
        if [ -z "${!v}" ]; then
            echo "[Error] Missing required argument: $v"
            exit 1
        fi
    done
}

##############################
#         LOGGING            #
##############################
log()       { echo -e "$(date "+%F %T") [INFO] $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "$(date "+%F %T") [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

##############################
#     ENVIRONMENT CHECK      #
##############################
verify_env() {
    log "Checking environment..."
    grep -q "Ubuntu 22.04" /etc/os-release || { log_error "Ubuntu 22.04 required."; exit 1; }
    [ "$(id -u)" = "0" ] || { log_error "Script must be run as root."; exit 1; }
}

##############################
#      INSTALL PACKAGES      #
##############################
install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    log "Updating apt sources..."
    apt-get update -qq

    log "Installing base tools and adding PHP 8.3 repo if needed..."
    apt-get install -yqq software-properties-common curl lsb-release ca-certificates apt-transport-https gnupg2 > /dev/null
    if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update -qq
    fi

    log "Installing panel dependencies (nginx, MariaDB, PHP, Redis, etc)..."
    apt-get install -yqq \
        nginx mariadb-server redis-server tar unzip git wget \
        php8.3 php8.3-cli php8.3-fpm php8.3-mysql php8.3-xml php8.3-curl php8.3-zip php8.3-mbstring php8.3-bcmath php8.3-gd php8.3-tokenizer \
        certbot python3-certbot-nginx docker.io > /dev/null

    log "Ensuring Composer is present..."
    if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi
    log "All required system packages are installed."
}

##############################
#    MARIADB DATABASE SETUP  #
##############################
setup_database() {
    log "Configuring MariaDB panel user/database..."
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    systemctl enable --now mariadb
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF
    log "Database and user ready."
}

##############################
#      PANEL INSTALLATION     #
##############################
deploy_panel() {
    log "Preparing $PANEL_ROOT directory..."
    mkdir -p "$PANEL_ROOT"
    cd "$PANEL_ROOT"
    if [ ! -f panel.tar.gz ]; then
        log "Downloading latest panel release..."
        curl -sL https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
    fi
    tar -xzf panel.tar.gz
    rm -f panel.tar.gz

    cp -f .env.example .env
    log "Installing PHP dependencies..."
    composer install --no-dev --optimize-autoloader --no-interaction

    log "Generating application key..."
    php artisan key:generate --force

    PANEL_URL="http://${PANEL_DOMAIN}"
    if [ "${USE_SSL,,}" = "true" ]; then
        PANEL_URL="https://${PANEL_DOMAIN}"
    fi

    log "Configuring panel environment..."
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

    log "Setting up database connection..."
    php artisan p:environment:database \
        --host="127.0.0.1" \
        --port="3306" \
        --database="$DB_NAME" \
        --username="$DB_USER" \
        --password="$DB_PASS"

    log "Migrating and seeding database..."
    php artisan migrate --seed --force

    log "Creating admin user..."
    php artisan p:user:make \
        --email="$ADMIN_EMAIL" \
        --username="$ADMIN_USER" \
        --name-first="$FIRST_NAME" \
        --name-last="$LAST_NAME" \
        --password="$ADMIN_PASS" \
        --admin=1

    chown -R www-data:www-data "$PANEL_ROOT"
    log "Panel files/permissions set."
}

##############################
#    SYSTEMD SERVICE SETUP    #
##############################
configure_services() {
    log "Setting up queue runner service..."
    curl -sL "$CONFIG_BASE_URL/pteroq.service" -o /etc/systemd/system/pteroq.service
    systemctl daemon-reload
    systemctl enable --now redis-server pteroq.service

    log "Configuring panel schedule cron..."
    (crontab -l 2>/dev/null; echo "* * * * * php $PANEL_ROOT/artisan schedule:run >> /dev/null 2>&1") | crontab -
}

##############################
#      NGINX & SSL SETUP      #
##############################
configure_nginx() {
    log "Setting up NGINX webserver config..."
    rm -f /etc/nginx/sites-enabled/default
    if [ "${USE_SSL,,}" = "true" ]; then
        curl -sL "$CONFIG_BASE_URL/pterodactyl-nginx-ssl.conf" -o /etc/nginx/sites-enabled/$NGINX_CONF_NAME
        sed -i "s|<domain>|${PANEL_DOMAIN}|g" /etc/nginx/sites-enabled/$NGINX_CONF_NAME
        systemctl reload nginx
        log "Getting Let's Encrypt SSL for $PANEL_DOMAIN ..."
        certbot --nginx --redirect --agree-tos --email "$ADMIN_EMAIL" -d "$PANEL_DOMAIN" --non-interactive || log_error "Let's Encrypt certificate failed, continuing without SSL!"
    else
        curl -sL "$CONFIG_BASE_URL/pterodactyl-nginx.conf" -o /etc/nginx/sites-enabled/$NGINX_CONF_NAME
        sed -i "s|<domain>|${PANEL_DOMAIN}|g" /etc/nginx/sites-enabled/$NGINX_CONF_NAME
        systemctl reload nginx
    fi
    log "NGINX setup complete."
}

##############################
#       WINGS INSTALL         #
##############################
install_wings() {
    if [ "${DEPLOY_WINGS,,}" != "true" ]; then
        log "Wings install not requested."
        return
    fi
    log "Installing Wings node agent..."
    systemctl enable --now docker
    mkdir -p /etc/pterodactyl
    ARCH_TYPE="$(uname -m | grep -q '64' && echo amd64 || echo arm64)"
    curl -Ls "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH_TYPE}" -o /usr/local/bin/wings
    chmod +x /usr/local/bin/wings
    curl -sL "$CONFIG_BASE_URL/wings.service" -o /etc/systemd/system/wings.service
    systemctl daemon-reload
    systemctl enable --now wings
    log "Wings installed and started."
}

##############################
#        FINAL INFO           #
##############################
print_summary() {
    echo ""
    echo "============================================================================"
    echo "           PteroNova - Pterodactyl Panel & Wings Installed                  "
    echo "============================================================================"
    echo "Panel URL        : ${PANEL_URL}"
    echo "Admin Username   : ${ADMIN_USER}"
    echo "Admin Password   : (hidden)"
    echo "MariaDB Database : ${DB_NAME}"
    echo "MariaDB User     : ${DB_USER}"
    echo "MariaDB Pass     : ${DB_PASS}"
    echo "Wings Installed  : ${DEPLOY_WINGS}"
    echo "Log File         : $LOG_FILE"
    echo "============================================================================"
    echo ""
    echo "Access your panel at the URL above."
    echo ""
}

##############################
#           MAIN             #
##############################
main() {
    parse_args "$@"
    verify_env
    install_packages
    setup_database
    deploy_panel
    configure_services
    configure_nginx
    install_wings
    print_summary
}

main "$@"
