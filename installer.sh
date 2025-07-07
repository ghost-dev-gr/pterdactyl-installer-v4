#!/usr/bin/env bash
#
# Fresh Pterodactyl & Wings installer, NGINX-only, Ubuntu 22.04 only, auto-install, non-interactive
# Copyright 2024-2025, (your name/brand)
# MIT License
#

set -euo pipefail

### --- MAIN USAGE --- ###
if [[ "$#" -lt 14 ]]; then
    echo ""
    echo "Usage: bash <(curl -s https://yourdomain.com/ptero.sh) \\"
    echo "    --domain <panel.domain> \\"
    echo "    --ssl <true|false> \\"
    echo "    --email <you@site.com> \\"
    echo "    --admin <adminuser> \\"
    echo "    --first <firstname> \\"
    echo "    --last <lastname> \\"
    echo "    --pass <adminpassword> \\"
    echo "    --wings <yes|no>"
    echo ""
    exit 2
fi

### --- CONFIG VARS (CLI ONLY) --- ###
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --domain)      export PT_PANEL_FQDN="$2"; shift ;;
        --ssl)         export PT_SSL_ENABLE="$2"; shift ;;
        --email)       export PT_EMAIL="$2"; shift ;;
        --admin)       export PT_ADMIN="$2"; shift ;;
        --first)       export PT_FNAME="$2"; shift ;;
        --last)        export PT_LNAME="$2"; shift ;;
        --pass)        export PT_APASS="$2"; shift ;;
        --wings)       export PT_WINGS="$2"; shift ;;
        *) echo "Unknown option: $1" ; exit 2 ;;
    esac
    shift
done

### --- CONSTANTS --- ###
OS_REQUIRED="ubuntu"
OS_VERSION_REQUIRED="22.04"
PT_USER="www-data"
PT_PATH="/var/www/panel"
PT_DB_NAME="pteropanel"
PT_DB_USER="pterouser"
PT_DB_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18)"
PT_DB_ROOTPASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)"
REDIS_SERVICE="redis-server"

### --- COLORS --- ###
C_RESET="\e[0m"
C_B="\e[34m"
C_G="\e[32m"
C_R="\e[31m"
C_Y="\e[33m"
function cecho() { echo -e "${2}${1}${C_RESET}"; }

### --- OS CHECK --- ###
function check_osver() {
    local D=$(lsb_release -is | awk '{print tolower($0)}')
    local V=$(lsb_release -rs)
    if [[ "$D" != "$OS_REQUIRED" ]] || [[ "$V" != "$OS_VERSION_REQUIRED" ]]; then
        cecho "FATAL: Only Ubuntu 22.04 supported. Detected $D $V" "$C_R"
        exit 99
    fi
}

### --- ROOT CHECK --- ###
function check_root() {
    if [[ $EUID -ne 0 ]]; then
        cecho "You must be root to run this installer." "$C_R"
        exit 1
    fi
}

### --- DEPENDENCY INSTALL --- ###
function get_tools() {
    cecho "Installing core utilities and NGINX..." "$C_B"
    apt-get update -y
    apt-get install -y curl wget git unzip tar lsb-release ca-certificates software-properties-common gnupg2 \
        mariadb-server redis-server php8.2 php8.2-{cli,gd,xml,mysql,mbstring,tokenizer,curl,zip,fpm,bcmath,pgsql} \
        nginx certbot python3-certbot-nginx
    cecho "Base dependencies installed." "$C_G"
}

### --- MARIADB INIT --- ###
function init_mariadb() {
    cecho "Configuring MariaDB server and secure password..." "$C_B"
    systemctl enable --now mariadb
    sleep 2
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${PT_DB_ROOTPASS}'; FLUSH PRIVILEGES;"
    mysql -uroot -p"${PT_DB_ROOTPASS}" -e \
      "CREATE DATABASE IF NOT EXISTS \`${PT_DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
       CREATE USER IF NOT EXISTS '${PT_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PT_DB_PASS}';
       GRANT ALL PRIVILEGES ON \`${PT_DB_NAME}\`.* TO '${PT_DB_USER}'@'127.0.0.1';
       FLUSH PRIVILEGES;"
    cecho "Database ready: ${PT_DB_NAME}, user: ${PT_DB_USER}" "$C_G"
}

### --- PANEL DOWNLOAD --- ###
function fetch_panel() {
    cecho "Downloading latest Pterodactyl Panel..." "$C_B"
    rm -rf "$PT_PATH"
    mkdir -p "$PT_PATH"
    cd "$PT_PATH"
    curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz -o panel.tar.gz
    tar -xzf panel.tar.gz
    chown -R "$PT_USER":"$PT_USER" "$PT_PATH"
    cecho "Panel code extracted." "$C_G"
}

### --- COMPOSER INSTALL --- ###
function install_composer() {
    cecho "Installing Composer..." "$C_B"
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
    chmod +x /usr/local/bin/composer
    cecho "Composer installed." "$C_G"
}

### --- PANEL SETUP --- ###
function setup_panel() {
    cd "$PT_PATH"
    cp .env.example .env
    chown "$PT_USER":"$PT_USER" .env
    sudo -u "$PT_USER" composer install --no-dev --optimize-autoloader --no-interaction
    sudo -u "$PT_USER" php artisan key:generate --force
    cecho "Running Panel environment setup..." "$C_B"
    sudo -u "$PT_USER" php artisan p:environment:setup --author="$PT_EMAIL" --url="${PT_SSL_ENABLE,,}" == "true" && echo "https://${PT_PANEL_FQDN}" || echo "http://${PT_PANEL_FQDN}" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-pass="null" --redis-port="6379"
    sudo -u "$PT_USER" php artisan p:environment:database --host="127.0.0.1" --port=3306 --database="${PT_DB_NAME}" --username="${PT_DB_USER}" --password="${PT_DB_PASS}"
    sudo -u "$PT_USER" php artisan migrate --seed --force
    sudo -u "$PT_USER" php artisan p:user:make --email="$PT_EMAIL" --username="$PT_ADMIN" --name-first="$PT_FNAME" --name-last="$PT_LNAME" --password="$PT_APASS" --admin=1
    chown -R "$PT_USER":"$PT_USER" storage/* bootstrap/cache/
    cecho "Panel configured & admin account created." "$C_G"
}

### --- NGINX CONFIG --- ###
function config_nginx() {
    cecho "Deploying NGINX config for Pterodactyl..." "$C_B"
    rm -f /etc/nginx/sites-enabled/default
    PANEL_NGINX_CONF="/etc/nginx/sites-available/pterodactyl"
    cat > "$PANEL_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $PT_PANEL_FQDN;
    root $PT_PATH/public;

    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        internal;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf "$PANEL_NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl
    systemctl restart nginx
    cecho "NGINX config deployed and restarted." "$C_G"
}

### --- SSL SETUP (Let's Encrypt) --- ###
function get_ssl_cert() {
    if [[ "${PT_SSL_ENABLE,,}" == "true" ]]; then
        cecho "Requesting SSL certificate from Let's Encrypt..." "$C_B"
        certbot --nginx --redirect --no-eff-email --agree-tos --email "$PT_EMAIL" -d "$PT_PANEL_FQDN"
        cecho "SSL applied." "$C_G"
    else
        cecho "SSL setup skipped per arguments." "$C_Y"
    fi
}

### --- REDIS ENABLE --- ###
function start_redis() {
    cecho "Ensuring Redis is running..." "$C_B"
    systemctl enable --now $REDIS_SERVICE
}

### --- PT-SERVICE --- ###
function add_pteroq_service() {
    cecho "Adding Pteroq service..." "$C_B"
    cat >/etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=$PT_USER
WorkingDirectory=$PT_PATH
ExecStart=/usr/bin/php $PT_PATH/artisan queue:work --queue=high,default --sleep=3 --tries=3
Restart=on-failure
RestartSec=5s
StartLimitInterval=600
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable --now pteroq
    cecho "Pteroq enabled." "$C_G"
}

### --- CRONJOB --- ###
function setup_cronjob() {
    cecho "Enabling cron for schedule..." "$C_B"
    (crontab -l 2>/dev/null; echo "* * * * * php $PT_PATH/artisan schedule:run >> /dev/null 2>&1") | crontab -
}

### --- WINGS INSTALL --- ###
function install_wings() {
    if [[ "${PT_WINGS,,}" != "yes" ]]; then
        cecho "Wings node install skipped." "$C_Y"
        return 0
    fi
    cecho "Installing Docker & Wings Daemon..." "$C_B"
    apt-get install -y docker.io
    systemctl enable --now docker
    mkdir -p /etc/ptero-wings
    local WINGS_ARCH
    if [[ "$(uname -m)" == "x86_64" ]]; then
        WINGS_ARCH="amd64"
    else
        WINGS_ARCH="arm64"
    fi
    curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH} -o /usr/local/bin/wings
    chmod +x /usr/local/bin/wings
    cat >/etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings
After=docker.service
[Service]
User=root
Restart=always
ExecStart=/usr/local/bin/wings
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now wings
    cecho "Wings Daemon ready and running." "$C_G"
}

### --- OUTPUT CREDENTIALS --- ###
function save_creds() {
    cecho "Writing panel install info to /root/panel-details.txt" "$C_B"
    cat >/root/panel-details.txt <<EOF
Pterodactyl Panel setup summary:
Panel URL: ${PT_SSL_ENABLE,,} == "true" && echo "https://${PT_PANEL_FQDN}" || echo "http://${PT_PANEL_FQDN}"
Admin: $PT_ADMIN
Admin Password: $PT_APASS
First: $PT_FNAME
Last: $PT_LNAME
Email: $PT_EMAIL
Database: $PT_DB_NAME
DBUser: $PT_DB_USER
DBPass: $PT_DB_PASS
DBRoot: $PT_DB_ROOTPASS
EOF
    cecho "Saved /root/panel-details.txt. All done!" "$C_G"
}

### --- CHECK PANEL ONLINE --- ###
function verify_panel() {
    local URL="http://${PT_PANEL_FQDN}"
    [[ "${PT_SSL_ENABLE,,}" == "true" ]] && URL="https://${PT_PANEL_FQDN}"
    cecho "Checking panel status..." "$C_B"
    for i in {1..15}; do
        http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$URL")
        [[ "$http_code" == "200" ]] && cecho "Panel online at $URL" "$C_G" && return 0
        sleep 2
    done
    cecho "Panel did not respond 200 OK, check manually!" "$C_R"
}

### --- MAIN EXECUTION --- ###
trap 'cecho "Install failed at line $LINENO" "$C_R"; exit 99' ERR

check_root
check_osver
get_tools
init_mariadb
fetch_panel
install_composer
setup_panel
config_nginx
get_ssl_cert
start_redis
add_pteroq_service
setup_cronjob
install_wings
save_creds
verify_panel

cecho "INSTALLATION COMPLETE! See /root/panel-details.txt for details." "$C_B"
exit 0
