#!/usr/bin/env bash

################################################################################
#                PteroQuick: Modern Pterodactyl Automated Installer             #
#                For Ubuntu 22.04 | (C) 2024 Ghost Dev Team                    #
#                    https://github.com/ghost-dev-gr/pterodactyl-installer-v4   #
################################################################################

set -euo pipefail

# ---- Variables ----
PANEL_PATH="/var/www/pterodactyl"
DOMAIN="$1"
SSL="$2"
EMAIL="$3"
USER_NAME="$4"
FIRST_NAME="$5"
LAST_NAME="$6"
USER_PASS="$7"
INSTALL_WINGS="$8"

MYSQL_PANEL_PASS=""
MYSQL_PANEL_USER="pterodactyl"
MYSQL_PANEL_DB="panel"

print_head() {
    echo ""
    echo "=============================================="
    echo "     PteroQuick Pterodactyl Panel Installer   "
    echo "=============================================="
    echo ""
}

error_exit() {
    echo "[ERROR] $*" >&2
    exit 1
}

check_os() {
    if ! grep -q "Ubuntu 22.04" /etc/os-release; then
        error_exit "This script supports Ubuntu 22.04 only."
    fi
}

show_config() {
    echo ""
    echo ">> Install Details:"
    echo "Domain:           $DOMAIN"
    echo "SSL:              $SSL"
    echo "Admin Email:      $EMAIL"
    echo "Admin Username:   $USER_NAME"
    echo "Admin Name:       $FIRST_NAME $LAST_NAME"
    echo "Install Wings:    $INSTALL_WINGS"
    echo "Panel Path:       $PANEL_PATH"
    echo ""
    sleep 2
}

pre_install() {
    echo "[INFO] Updating system and installing required packages..."
    apt-get update -qq
    apt-get install -yqq curl sudo software-properties-common ca-certificates lsb-release apt-transport-https gnupg2
    add-apt-repository -y ppa:ondrej/php
    apt-get update -qq
    apt-get install -yqq nginx mariadb-server redis-server tar unzip git certbot python3-certbot-nginx docker.io
    apt-get install -yqq php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}
    if ! command -v composer >/dev/null 2>&1; then
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    fi
}

db_setup() {
    echo "[INFO] Creating panel database/user in MariaDB..."
    MYSQL_PANEL_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
    systemctl enable --now mariadb
    mariadb -u root -e "CREATE USER IF NOT EXISTS '${MYSQL_PANEL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PANEL_PASS}';"
    mariadb -u root -e "CREATE DATABASE IF NOT EXISTS ${MYSQL_PANEL_DB};"
    mariadb -u root -e "GRANT ALL PRIVILEGES ON ${MYSQL_PANEL_DB}.* TO '${MYSQL_PANEL_USER}'@'127.0.0.1' WITH GRANT OPTION;"
    mariadb -u root -e "FLUSH PRIVILEGES;"
}

install_panel() {
    echo "[INFO] Setting up panel files in $PANEL_PATH..."
    mkdir -p "$PANEL_PATH"
    cd "$PANEL_PATH"
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz && rm panel.tar.gz
    cp .env.example .env
    composer install --no-dev --optimize-autoloader --no-interaction
    php artisan key:generate --force
}

artisan_config() {
    local URL_PROTO
    if [[ "$SSL" == "true" ]]; then
        URL_PROTO="https://"
    else
        URL_PROTO="http://"
    fi

    echo "[INFO] Running artisan configuration..."
    php artisan p:environment:setup \
        --author="$EMAIL" \
        --url="${URL_PROTO}${DOMAIN}" \
        --timezone="UTC" \
        --telemetry=false \
        --cache="redis" \
        --session="redis" \
        --queue="redis" \
        --redis-host="localhost" \
        --redis-pass="null" \
        --redis-port="6379" \
        --settings-ui=true

    php artisan p:environment:database \
        --host="127.0.0.1" \
        --port="3306" \
        --database="${MYSQL_PANEL_DB}" \
        --username="${MYSQL_PANEL_USER}" \
        --password="${MYSQL_PANEL_PASS}"

    php artisan migrate --seed --force

    php artisan p:user:make \
        --email="$EMAIL" \
        --username="$USER_NAME" \
        --name-first="$FIRST_NAME" \
        --name-last="$LAST_NAME" \
        --password="$USER_PASS" \
        --admin=1

    chown -R www-data:www-data "$PANEL_PATH"
}

setup_services() {
    echo "[INFO] Installing pteroq service and schedule cron..."
    curl -o /etc/systemd/system/pteroq.service https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pteroq.service
    systemctl daemon-reload
    systemctl enable --now redis-server pteroq.service
    (crontab -l 2>/dev/null; echo "* * * * * php $PANEL_PATH/artisan schedule:run >> /dev/null 2>&1") | crontab -
}

nginx_setup() {
    echo "[INFO] Configuring nginx for the panel..."
    rm -rf /etc/nginx/sites-enabled/default
    if [[ "$SSL" == "true" ]]; then
        curl -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pterodactyl-nginx-ssl.conf
        sed -i -e "s@<domain>@${DOMAIN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
        systemctl reload nginx
        echo "[INFO] Issuing SSL certificate with certbot..."
        certbot --nginx --redirect --agree-tos --email "$EMAIL" -d "$DOMAIN" --non-interactive || true
    else
        curl -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/www-pterodactyl.conf
        sed -i -e "s@<domain>@${DOMAIN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
        systemctl reload nginx
    fi
}

install_wings_node() {
    if [[ "$INSTALL_WINGS" != "true" ]]; then
        echo "[INFO] Skipping Wings node installation as requested."
        return
    fi
    echo "[INFO] Installing Wings node..."
    systemctl enable --now docker
    mkdir -p /etc/pterodactyl
    local WARCH
    WARCH="$(uname -m | grep -q '64' && echo amd64 || echo arm64)"
    curl -Lo /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WARCH}"
    chmod +x /usr/local/bin/wings
    curl -o /etc/systemd/system/wings.service https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/wings.service
    systemctl daemon-reload
    systemctl enable --now wings
}

final_msg() {
    echo ""
    echo "=============================================="
    echo "  Panel installed at: http${SSL:+s}://${DOMAIN}"
    echo "  Panel admin user:   $USER_NAME"
    echo "  DB Name:            $MYSQL_PANEL_DB"
    echo "  DB User:            $MYSQL_PANEL_USER"
    echo "  DB Pass:            $MYSQL_PANEL_PASS"
    echo "  Wings installed:    $INSTALL_WINGS"
    echo "=============================================="
    echo ""
}

# ========== Main flow ==========

if [[ $# -ne 8 ]]; then
    echo "Usage:"
    echo "  $0 <domain> <use_ssl:true|false> <admin_email> <username> <firstname> <lastname> <admin_pass> <wings:true|false>"
    exit 1
fi

print_head
check_os
show_config
pre_install
db_setup
install_panel
artisan_config
setup_services
nginx_setup
install_wings_node
final_msg
