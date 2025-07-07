#!/usr/bin/env bash

#############################################################
#                                                           #
#  Automated Pterodactyl Setup for Ubuntu 22.04             #
#  Custom Script (2024), No Official Affiliation            #
#  Generated uniquely for your usage.                       #
#                                                           #
#############################################################

os_type="$(. /etc/os-release && echo "$ID")"
os_release="$(. /etc/os-release && echo "$VERSION_ID")"

# Usage:
# ./myinstaller.sh <DOMAIN> <USE_SSL> <ADMIN_EMAIL> <ADMIN_USER> <FIRSTNAME> <LASTNAME> <ADMIN_PASSWORD> <INSTALL_WINGS>

complete_message() {
    clear
    echo ""
    echo "[+] Pterodactyl installation finished."
    echo ""
}

configure_panel() {
    [[ "$USE_HTTPS" == "true" ]] && panel_url="https://$DOMAIN"
    [[ "$USE_HTTPS" == "false" ]] && panel_url="http://$DOMAIN"

    SQLPASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 18)
    mariadb -u root -e "CREATE USER 'paneluser'@'127.0.0.1' IDENTIFIED BY '$SQLPASS';"
    mariadb -u root -e "CREATE DATABASE pteropanel;"
    mariadb -u root -e "GRANT ALL PRIVILEGES ON pteropanel.* TO 'paneluser'@'127.0.0.1';"
    mariadb -u root -e "FLUSH PRIVILEGES;"

    php artisan p:environment:setup --author="$ADMIN_EMAIL" --url="$panel_url" --timezone="Europe/Athens" --telemetry=false --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-pass="null" --redis-port="6379" --settings-ui=true
    php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="pteropanel" --username="paneluser" --password="$SQLPASS"
    php artisan migrate --seed --force

    php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --name-first="$FIRST" --name-last="$LAST" --password="$ADMIN_PASS" --admin=1

    chown -R www-data:www-data /var/www/panel/*

    # Get services
    curl -sLo /etc/systemd/system/pteroqueue.service "https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pteroq.service"
    (crontab -l 2>/dev/null; echo "* * * * * php /var/www/panel/artisan schedule:run > /dev/null 2>&1") | crontab -
    systemctl enable --now redis-server
    systemctl enable --now pteroqueue.service

    if [[ "$INSTALL_WINGS" == "true" ]]; then
        curl -sSL https://get.docker.com/ | sh
        systemctl enable --now docker
        mkdir -p /etc/panelwings
        apt install -y curl tar unzip
        ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCHSTR="amd64" || ARCHSTR="arm64"
        curl -Lo /usr/local/bin/panelwings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCHSTR}"
        curl -sLo /etc/systemd/system/wings.service "https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/wings.service"
        chmod +x /usr/local/bin/panelwings
    fi

    if [[ "$USE_HTTPS" == "true" ]]; then
        rm -rf /etc/nginx/sites-enabled/default
        curl -sLo /etc/nginx/sites-enabled/panel.conf "https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pterodactyl-nginx-ssl.conf"
        sed -i "s@<domain>@$DOMAIN@g" /etc/nginx/sites-enabled/panel.conf
        systemctl stop nginx
        certbot certonly --standalone -d $DOMAIN --staple-ocsp --no-eff-email -m $ADMIN_EMAIL --agree-tos
        systemctl start nginx
        complete_message
    else
        rm -rf /etc/nginx/sites-enabled/default
        curl -sLo /etc/nginx/sites-enabled/panel.conf "https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/www-pterodactyl.conf"
        sed -i "s@<domain>@$DOMAIN@g" /etc/nginx/sites-enabled/panel.conf
        systemctl restart nginx
        complete_message
    fi
}

panel_setup() {
    echo "Updating repositories and installing dependencies..."
    apt update
    apt install -y certbot

    if [[ "$os_type" == "ubuntu" && "$os_release" == "22.04" ]]; then
        apt install -y software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release
        add-apt-repository -y ppa:ondrej/php
        curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis.gpg
        echo "deb [signed-by=/usr/share/keyrings/redis.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
        curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
        apt update
    fi

    apt install -y mariadb-server tar unzip git redis-server
    systemctl restart mariadb

    apt install -y php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    export COMPOSER_ALLOW_SUPERUSER=1

    mkdir -p /var/www/panel
    cd /var/www/panel
    curl -Lo panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/
    cp .env.example .env
    composer install --no-dev --optimize-autoloader --no-interaction
    php artisan key:generate --force

    apt install -y nginx
    configure_panel
}


# Params
DOMAIN="$1"
USE_HTTPS="$2"
ADMIN_EMAIL="$3"
ADMIN_USER="$4"
FIRST="$5"
LAST="$6"
ADMIN_PASS="$7"
INSTALL_WINGS="$8"

if [[ -z "$DOMAIN" || -z "$USE_HTTPS" || -z "$ADMIN_EMAIL" || -z "$ADMIN_USER" || -z "$FIRST" || -z "$LAST" || -z "$ADMIN_PASS" || -z "$INSTALL_WINGS" ]]; then
    echo "Usage: $0 <domain> <ssl true|false> <email> <user> <firstname> <lastname> <password> <wings true|false>"
    exit 1
fi

echo "Detected OS: $os_type $os_release"
if [[ "$os_type" == "ubuntu" && "$os_release" == "22.04" ]]; then
    echo "Starting Pterodactyl Panel setup for Ubuntu 22.04"
    sleep 2
    panel_setup
else
    echo "Unsupported OS: $os_type $os_release"
    exit 1
fi
