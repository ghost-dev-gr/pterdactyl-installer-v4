#!/usr/bin/env bash

########################################################################
#            Pterodactyl Installer, Updater, Remover and More          #
#            Copyright 2022, Malthe K, <me@malthe.cc>                  # 
# https://github.com/guldkage/Pterodactyl-Installer/blob/main/LICENSE  #
#  This script is not associated with the official Pterodactyl Panel.  #
#  You may not remove this line                                        #
########################################################################

dist="$(. /etc/os-release && echo "$ID")"
version="$(. /etc/os-release && echo "$VERSION_ID")"

# Usage: ./install.sh <panel_fqdn> <ssl true|false> <email> <username> <firstname> <lastname> <password> <wings true|false> <node_fqdn>

finish(){
    clear
    echo ""
    echo "[!] Panel installed."
    echo ""
}

panel_conf(){
    [ "$SSL" == true ] && appurl="https://$PANELFQDN" || appurl="http://$PANELFQDN"
    DBPASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
    mariadb -u root -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DBPASSWORD';"
    mariadb -u root -e "CREATE DATABASE panel;"
    mariadb -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
    mariadb -u root -e "FLUSH PRIVILEGES;"
    php artisan p:environment:setup --author="$EMAIL" --url="$appurl" --timezone="CET" --telemetry=false --cache="redis" --session="redis" --queue="redis" --redis-host="localhost" --redis-pass="null" --redis-port="6379" --settings-ui=true
    php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$DBPASSWORD"
    php artisan migrate --seed --force
    php artisan p:user:make --email="$EMAIL" --username="$USERNAME" --name-first="$FIRSTNAME" --name-last="$LASTNAME" --password="$PASSWORD" --admin=1
    chown -R www-data:www-data /var/www/pterodactyl/*
    curl -o /etc/systemd/system/pteroq.service https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pteroq.service
    (crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
    systemctl enable --now redis-server
    systemctl enable --now pteroq.service

    if [ "$WINGS" == true ]; then
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash
        systemctl enable --now docker
        mkdir -p /etc/pterodactyl
        apt-get -y install curl tar unzip
        curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$( [[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
        curl -o /etc/systemd/system/wings.service https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/wings.service
        chmod u+x /usr/local/bin/wings

        # Pull config example and patch it with FQDNs
        curl -o /etc/pterodactyl/config.yml https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/config.example.yml
        sed -i "s@<panel_domain>@${PANELFQDN}@g" /etc/pterodactyl/config.yml
        sed -i "s@<node_domain>@${NODEFQDN}@g" /etc/pterodactyl/config.yml
    fi

    if [ "$SSL" == true ]; then
        rm -rf /etc/nginx/sites-enabled/default
        curl -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pterodactyl-nginx-ssl.conf
        sed -i -e "s@<domain>@${PANELFQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
        systemctl stop nginx
        certbot certonly --standalone -d $PANELFQDN --staple-ocsp --no-eff-email -m $EMAIL --agree-tos
        systemctl start nginx
        finish
    else
        rm -rf /etc/nginx/sites-enabled/default
        curl -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/pterodactyl-nginx.conf
        sed -i -e "s@<domain>@${PANELFQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
        systemctl restart nginx
        finish
    fi
}

panel_install(){
    echo ""
    apt update
    apt install certbot -y

    # Ubuntu 22.04 setup only
    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release
    curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y mariadb-server tar unzip git redis-server

    # Fix utf8mb4 collation
    sed -i 's/character-set-collations = utf8mb4=uca1400_ai_ci/character-set-collations = utf8mb4=utf8mb4_general_ci/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
    systemctl restart mariadb

    # PHP 8.3 for Ubuntu 22.04
    apt -y install php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl || exit 1
    curl -Lo panel.tar.gz https://github.com/ghost-dev-gr/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/
    cp .env.example .env
    composer install --no-dev --optimize-autoloader --no-interaction
    php artisan key:generate --force
    apt install nginx -y
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
    echo "Welcome to Autoinstall of Pterodactyl Panel"
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
    echo "Starting automatic installation in 5 seconds"
    sleep 5s
    panel_install
else
    echo "Your OS, $dist $version, is not supported"
    exit 1
fi
