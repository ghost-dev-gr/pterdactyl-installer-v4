#!/usr/bin/env bash

########################################################################
#            Pterodactyl Installer, Updater, Remover and More          #
#            Copyright 2022, Malthe K, <me@malthe.cc>                  #
# https://github.com/guldkage/Pterodactyl-Installer/blob/main/LICENSE  #
#  This script is not associated with the official Pterodactyl Panel.  #
#  You may not remove this line                                        #
########################################################################

set -e

LOGFILE="/var/log/pterodactyl-installer.log"
exec > >(tee -a "$LOGFILE") 2>&1

alias php='/usr/bin/php8.3'
dist="$(. /etc/os-release && echo "$ID")"
version="$(. /etc/os-release && echo "$VERSION_ID")"

finish(){
    clear
    echo ""
    echo "[!] Panel and node (wings) installed and running."
    echo "[!] See install log at $LOGFILE"
    echo ""
}

panel_conf(){
    echo "[INFO] Starting panel configuration..."

    [ "$SSL" == true ] && appurl="https://$PANELFQDN" || appurl="http://$PANELFQDN"
    DBPASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
    echo "[INFO] Creating database and user (safe idempotent)..."
    mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DBPASSWORD';"
    mariadb -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
    mariadb -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
    mariadb -u root -e "FLUSH PRIVILEGES;"

    echo "[INFO] Fixing permissions and cleaning cache..."
    cd /var/www/pterodactyl
    mkdir -p storage bootstrap/cache vendor /var/www/.cache/composer/vcs
    chown -R www-data:www-data /var/www/pterodactyl /var/www/.cache
    chmod -R 755 storage bootstrap/cache vendor /var/www/.cache/composer

    # Clean up vendor/composer.lock for fresh Composer install
    rm -rf composer.lock vendor/*

    echo "[INFO] (Re)installing composer dependencies..."
    sudo -u www-data -E composer clear-cache
    sudo -u www-data -E composer install --no-dev --optimize-autoloader --no-interaction

    if [ $? -ne 0 ]; then
        echo "[ERROR] Composer install failed. Dumping permissions and cache:"
        ls -ld /var/www/pterodactyl
        ls -ld /var/www/pterodactyl/vendor
        ls -ld /var/www/.cache
        ls -ld /var/www/.cache/composer
        id www-data
        exit 1
    fi

    echo "[INFO] Generating app key and config cache..."
    sudo -u www-data php artisan key:generate --force

    echo "[INFO] Running artisan environment setup..."
    sudo -u www-data php artisan p:environment:setup --author="$EMAIL" --url="$appurl" --timezone="CET" --telemetry=false --cache="redis" --session="redis" --queue="redis" --redis-host="localhost" --redis-pass="null" --redis-port="6379" --settings-ui=true
    sudo -u www-data php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$DBPASSWORD"
    sudo -u www-data php artisan migrate --seed --force
    sudo -u www-data php artisan p:user:make --email="$EMAIL" --username="$USERNAME" --name-first="$FIRSTNAME" --name-last="$LASTNAME" --password="$PASSWORD" --admin=1

    chown -R www-data:www-data /var/www/pterodactyl/*

    curl -o /etc/systemd/system/pteroq.service https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pteroq.service
    (crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
    systemctl enable --now redis-server
    systemctl enable --now pteroq.service

    if [ "$SSL" == true ]; then
        echo "[INFO] Setting up nginx with SSL for the panel..."
        rm -rf /etc/nginx/sites-enabled/default
        curl -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pterodactyl-nginx-ssl.conf
        sed -i -e "s@<domain>@${PANELFQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
        systemctl stop nginx
        certbot certonly --standalone -d $PANELFQDN --staple-ocsp --no-eff-email -m $EMAIL --agree-tos
        systemctl start nginx
    else
        echo "[INFO] Setting up nginx without SSL for the panel..."
        rm -rf /etc/nginx/sites-enabled/default
        curl -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pterodactyl-nginx.conf
        sed -i -e "s@<domain>@${PANELFQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
        systemctl restart nginx
    fi
}

install_golang() {
  echo "Installing Go 1.22.1..."
  wget https://go.dev/dl/go1.22.1.linux-amd64.tar.gz -O /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
  source /etc/profile
}

add_custom_proxy_to_wings() {
  echo "=> Downloading router_server_proxy.go to /srv/wings/router/"
  mkdir -p /srv/wings/router || { echo "Failed to create /srv/wings/router"; exit 1; }

  curl -fsSL "https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/router_server_proxy.go" -o /srv/wings/router/router_server_proxy.go \
    || { echo "Failed to download router_server_proxy.go"; exit 1; }

  ROUTER_FILE="/srv/wings/router/router.go"
  if [ -f "$ROUTER_FILE" ]; then
    echo "Adding proxy endpoints to router.go..."
    sed -i '/server.POST("\/ws\/deny", postServerDenyWSTokens)/a \
      server.POST("/proxy/create", postServerProxyCreate)\
      server.POST("/proxy/delete", postServerProxyDelete)' "$ROUTER_FILE"
    echo "Proxy endpoints added."
  else
    echo "Router file not found at $ROUTER_FILE - endpoints NOT added!"
  fi

  # Rebuild and restart wings
  cd /srv/wings || exit 1
  systemctl stop wings || echo "Warning: Wings wasn't running, continuing..."
  go get github.com/go-acme/lego/v4 || { echo "Go get failed"; exit 1; }
  go mod tidy || { echo "Go mod tidy failed"; exit 1; }
  go build -o /usr/local/bin/wings || { echo "Go build failed"; exit 1; }
  chmod +x /usr/local/bin/wings
  systemctl start wings || { echo "Failed to start Wings"; exit 1; }
  echo "Wings custom proxy installation and update completed successfully!"
}

wings_install_and_activate(){
    install_golang
    echo "[INFO] Installing Wings (node) with SSL on port 8443..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
    mkdir -p /etc/pterodactyl
    apt-get -y install curl tar unzip

    curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$( [[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
    chmod u+x /usr/local/bin/wings
    curl -o /etc/systemd/system/wings.service https://raw.githubusercontent.com/ghost-dev-gr/pterodactyl-installer-v4/main/configs/wings.service

    echo "[INFO] Requesting SSL certificate for node domain $NODEFQDN..."
    certbot certonly --standalone --preferred-challenges http -d "$NODEFQDN" --agree-tos --no-eff-email -m "$EMAIL"

    systemctl daemon-reload
    systemctl enable --now wings

    echo ""
    echo "[!] Wings installed and started at https://$NODEFQDN:8443"
    echo "[!] To finish node registration:"
    echo "   1. Log in to your panel at https://$PANELFQDN"
    echo "   2. Add a node with FQDN $NODEFQDN, scheme https, port 8443"
    echo "   3. Download the node config from the panel and place it at /etc/pterodactyl/config.yml"
    echo "   4. Restart wings with: systemctl restart wings"
    echo ""
    echo "[!] The above can be automated with API, but needs panel setup first."

    # ----> CUSTOM PATCH: ADD GO CODE
    add_custom_proxy_to_wings
}

panel_install(){
    echo "[INFO] Starting system & dependency install..."

    apt-get update

    apt-get install -y software-properties-common curl apt-transport-https language-pack-en-base ca-certificates gnupg lsb-release gpg

    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8

    apt-add-repository universe -y
    apt-add-repository -y ppa:ondrej/php
    echo "passed ppa"
    # Add MariaDB repo
    sudo mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
    sudo chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
    echo 'passed deb signed'
    curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

    echo 'passed mariadb'
    # ------ Now update to see all new packages ------
    apt-get update

    # ------ Now install all needed packages ------
    apt-get install -y mariadb-server tar unzip git redis-server certbot nginx
    echo 'passed marmariadb-server iadb'
    # Fix utf8mb4 collation (workaround for 22.04)
    sed -i 's/character-set-collations = utf8mb4=uca1400_ai_ci/character-set-collations = utf8mb4=utf8mb4_general_ci/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
    systemctl restart mariadb

    # PHP 8.3 for Ubuntu 22.04 (change here!)
    apt-get install -y php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}

    update-alternatives --set php /usr/bin/php8.3
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    # Node v14 for panel build (node 14.x is what's officially supported for many panels)
    curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -
    apt-get install -y nodejs

    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl || exit 1

    curl -Lo panel.tar.gz https://github.com/ghost-dev-gr/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz
    rm panel.tar.gz
    if [ -d "panel" ]; then
        mv panel/* ./
        mv panel/.* ./
        rmdir panel
    fi
    
    mkdir -p storage bootstrap/cache vendor /var/www/.cache/composer/vcs
    chown -R www-data:www-data /var/www/pterodactyl /var/www/.cache
    chmod -R 755 /var/www/pterodactyl/bootstrap/cache

   
    cp .env.example .env
    php artisan key:generate --force

    panel_conf
}

# Arguments
PANELFQDN="$1"
SSL="$2"
EMAIL="$3"
USERNAME="$4"
FIRSTNAME="$5"
LASTNAME="$6"
PASSWORD="$7"
WINGS="$8"
NODEFQDN="$9"

if [ -z "$PANELFQDN" ] || [ -z "$SSL" ] || [ -z "$EMAIL" ] || [ -z "$USERNAME" ] || [ -z "$FIRSTNAME" ] || [ -z "$LASTNAME" ] || [ -z "$PASSWORD" ] || [ -z "$WINGS" ] || [ -z "$NODEFQDN" ]; then
    echo "Error! The usage of this script is incorrect."
    echo "Usage: $0 <panel_fqdn> <ssl true|false> <email> <username> <firstname> <lastname> <password> <wings true|false> <node_fqdn>"
    exit 1
fi

echo "Checking your OS.."
if [ "$dist" = "ubuntu" ] && [ "$version" = "22.04" ]; then
    echo "[INFO] Welcome to Autoinstall of Pterodactyl Panel & Node"
    echo "Quick summary before the install begins:"
    echo ""
    echo "Panel FQDN (URL): $PANELFQDN"
    echo "SSL: $SSL"
    echo "Preselected webserver: NGINX"
    echo "Email: $EMAIL"
    echo "Username: $USERNAME"
    echo "First name: $FIRSTNAME"
    echo "Last name: $LASTNAME"
    echo "Password: $PASSWORD"
    echo "Wings install: $WINGS"
    echo "Node FQDN: $NODEFQDN"
    echo ""
    echo "[INFO] Starting automatic installation in 5 seconds..."
    sleep 5s
    panel_install
    if [ "$WINGS" == true ]; then
        wings_install_and_activate
    fi
    finish
else
    echo "Your OS, $dist $version, is not supported"
    exit 1
fi
