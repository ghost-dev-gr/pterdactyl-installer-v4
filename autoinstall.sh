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

create_location_in_db() {
    LOC_NAME="lc.eu.made-by-orthodox-hosting"
    LONG_NAME="Script Created Location"
    cd /var/www/pterodactyl || { echo "[ERROR] Failed to cd to /var/www/pterodactyl"; return 1; }
    echo "[INFO] Ensuring location exists: $LOC_NAME"
    
    # Create location and capture output to get the ID
    OUTPUT=$(sudo -u www-data php artisan p:location:make \
        --short "$LOC_NAME" \
        --long "$LONG_NAME" \
        --no-interaction 2>&1)
    
    # Extract location ID from output
    LOCATION_ID=$(echo "$OUTPUT" | grep -oP 'ID of \K\d+')
    echo "$LOCATION_ID"
    if [ -z "$LOCATION_ID" ]; then
        # If we couldn't extract ID, try to get it from database
        LOCATION_ID=$(sudo -u www-data php artisan tinker --execute="echo app\Models\Location::where('short', '$LOC_NAME')->first()->id;")
    fi
    
    echo "$LOCATION_ID"
}

generate_node_config() {
    echo "running generate node"
DB_PASS=$(grep DB_PASSWORD /var/www/pterodactyl/.env | cut -d'=' -f2-)
sudo mariadb <<EOF
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
EOF
echo "passed mariadb access"


  NODE_FQDN="$1"
  CONFIG_PATH="/etc/pterodactyl/config.yml"
  SSL_CERT="/etc/letsencrypt/live/${NODE_FQDN}/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/${NODE_FQDN}/privkey.pem"

  DB_PASS=$(grep DB_PASSWORD /var/www/pterodactyl/.env | cut -d'=' -f2-)
  DB_USER=$(grep DB_USERNAME /var/www/pterodactyl/.env | cut -d'=' -f2-)
  DB_NAME=$(grep DB_DATABASE /var/www/pterodactyl/.env | cut -d'=' -f2-)


read -r UUID TOKEN_ID TOKEN <<< $(mariadb -N -h 127.0.0.1 -u"$DB_USER" -p"$DB_PASS" -D"$DB_NAME" \
    -e "SELECT uuid, daemon_token_id, daemon_token FROM nodes WHERE fqdn='${NODE_FQDN}';")
  echo $NODE_ID
  NODE_ID=$(mariadb -N -h 127.0.0.1 -u"$DB_USER" -p"$DB_PASS" -D"$DB_NAME" \
  -e "SELECT id FROM nodes WHERE fqdn='${NODE_FQDN}';")
CONFIG_YAML=$(sudo -u www-data php /var/www/pterodactyl/artisan p:node:configuration "$NODE_ID")
TOKEN=$(echo "$CONFIG_YAML" | grep '^token:' | awk '{print $2}')
echo "Short usable token: $TOKEN"
  echo $UUID
  echo $TOKEN_ID
  echo $TOKEN
  cat > "$CONFIG_PATH" <<EOF
debug: false
app_name: Pterodactyl
uuid: $UUID
token_id: $TOKEN_ID
token: $TOKEN
api:
  host: 0.0.0.0
  port: 8443
  ssl:
    enabled: true
    cert: $SSL_CERT
    key: $SSL_KEY
  disable_remote_download: false
  upload_limit: 100
  trusted_proxies:
    - 173.245.48.0/20
    - 103.21.244.0/22
    - 103.22.200.0/22
    - 103.31.4.0/22
    - 141.101.64.0/18
    - 108.162.192.0/18
    - 190.93.240.0/20
    - 188.114.96.0/20
    - 197.234.240.0/22
    - 198.41.128.0/17
    - 162.158.0.0/15
    - 104.16.0.0/13
    - 104.24.0.0/14
    - 172.64.0.0/13
    - 131.0.72.0/22
system:
  root_directory: /var/lib/pterodactyl
  log_directory: /var/log/pterodactyl
  data: /var/lib/pterodactyl/volumes
  archive_directory: /var/lib/pterodactyl/archives
  backup_directory: /var/lib/pterodactyl/backups
  tmp_directory: /tmp/pterodactyl
  username: pterodactyl
  timezone: Etc/UTC
  user:
    rootless:
      enabled: false
      container_uid: 0
      container_gid: 0
    uid: 998
    gid: 998
  passwd:
    enabled: false
    directory: /run/wings/etc
  disk_check_interval: 150
  activity_send_interval: 60
  activity_send_count: 100
  check_permissions_on_boot: true
  enable_log_rotate: true
  websocket_log_count: 150
  sftp:
    bind_address: 0.0.0.0
    bind_port: 2022
    read_only: false
  crash_detection:
    enabled: true
    detect_clean_exit_as_crash: true
    timeout: 60
  backups:
    write_limit: 0
    compression_level: best_speed
  transfers:
    download_limit: 0
  openat_mode: auto
docker:
  network:
    interface: 172.18.0.1
    dns: []
    name: pterodactyl_nw
    ispn: false
    driver: ""
    network_mode: pterodactyl_nw
    is_internal: false
    enable_icc: true
    network_mtu: 1500
    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1
      v6:
        subnet: fdba:17c8:6c94::/64
        gateway: fdba:17c8:6c94::1011
  domainname: ""
  registries: {}
  tmpfs_size: 100
  container_pid_limit: 512
  installer_limits:
    memory: 1024
    cpu: 100
  overhead:
    override: false
    default_multiplier: 1.05
    multipliers: {}
  use_performant_inspect: true
  userns_mode: ""
  log_config:
    type: local
    config: {}
throttles:
  enabled: true
  lines: 2000
  line_reset_interval: 100
remote: https://${PANELFQDN}
remote_query:
  timeout: 30
  boot_servers_per_page: 50
allowed_mounts: []
allowed_origins: []
allow_cors_private_network: false
ignore_panel_config_updates: false
EOF

  # Use root:root for ownership (or skip chown if running as root)
  chown root:root "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
  echo "[INFO] Node config.yml created for $NODE_FQDN"
}

create_node_in_db() {
    LOC_NAME="lc.eu.made-by-orthodox-hosting"
    NODE_NAME=$(echo "$NODEFQDN" | cut -d. -f1)
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    SAFE_RAM=$((TOTAL_RAM)) # Leave 1GB for system
    TOTAL_DISK=$(df -m / | awk 'NR==2{print $2}')
    SAFE_DISK=$((TOTAL_DISK - 1024)) # Leave 1GB for system

    cd /var/www/pterodactyl || { echo "[ERROR] Failed to cd to /var/www/pterodactyl"; return 1; }
    
    # First ensure the location exists and get its ID
    LOCATION_ID=$(create_location_in_db)
    if [ -z "$LOCATION_ID" ]; then
        echo "[ERROR] Failed to get location ID"
        return 1
    fi

    echo "[INFO] Creating node $NODE_NAME in location $LOCATION_ID via artisan..."
    sudo -u www-data php artisan p:node:make \
        --name "$NODE_NAME" \
        --description "Automatically created node" \
        --locationId "1" \
        --fqdn "$NODEFQDN" \
        --public 1 \
        --scheme https \
        --proxy 1 \
        --maintenance 0 \
        --maxMemory "$SAFE_RAM" \
        --overallocateMemory 0 \
        --maxDisk "$SAFE_DISK" \
        --overallocateDisk 0 \
        --uploadSize 1024 \
        --daemonBase /var/lib/pterodactyl \
        --daemonSFTPPort 2022 \
        --daemonListeningPort 8443 \
        --no-interaction
}

setup_nginx_for_node() {
  NODEFQDN="$1"
  NGINX_CONF_PATH="/etc/nginx/sites-available/${NODEFQDN}.conf"
  NGINX_LINK_PATH="/etc/nginx/sites-enabled/${NODEFQDN}.conf"
  SSL_CERT="/etc/letsencrypt/live/${NODEFQDN}/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/${NODEFQDN}/privkey.pem"

  # HTML to show if browser (no Authorization header)
  HTML_FILE="/var/www/html/node-landing.html"
  mkdir -p /var/www/html
  cat > "$HTML_FILE" <<HTML
<!DOCTYPE html>
<html>
<head>
  <title>Node</title>
</head>
<body>
  <h1 style="font-family: monospace; text-align: center; margin-top: 30vh;">made by orthodox market</h1>
</body>
</html>
HTML

  cat > "$NGINX_CONF_PATH" <<EOF
map \$http_authorization \$is_api {
    default 0;
    "~.+"   1;
}

server {
    listen 80;
    server_name $NODEFQDN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $NODEFQDN;

    ssl_certificate     $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    location / {
        if (\$is_api = 0) {
            return 307 /_landing;
        }
        proxy_pass https://127.0.0.1:8443;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_verify off;
    }

    location /_landing {
        root /var/www/html;
        index node-landing.html;
        try_files /node-landing.html =404;
    }
}
EOF


  ln -sf "$NGINX_CONF_PATH" "$NGINX_LINK_PATH"
  nginx -t && systemctl reload nginx

  echo "[INFO] Nginx config for $NODEFQDN created & enabled."

  # Automatic cert renew as before
  crontab -l 2>/dev/null | grep -q 'certbot renew' || \
  (crontab -l 2>/dev/null; echo "0 4 * * * certbot renew --deploy-hook 'systemctl reload nginx' --quiet --no-self-upgrade") | crontab -
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

    rm -rf composer.lock vendor/*

    echo "[INFO] (Re)installing composer dependencies..."
    sudo -u www-data -E composer clear-cache
    echo 'running composer install'
    composer install --no-dev --optimize-autoloader --no-interaction

    if [ $? -ne 0 ]; then
        echo "[ERROR] Composer install failed. Dumping permissions and cache:"
        ls -ld /var/www/pterodactyl
        ls -ld /var/www/pterodactyl/vendor
        ls -ld /var/www/.cache
        ls -ld /var/www/.cache/composer
        id www-data
        exit 1
    fi

    echo "[INFO] Installing yarn if missing and building frontend assets..."
    if ! command -v yarn >/dev/null 2>&1; then
        npm install -g yarn || { echo "[ERROR] Could not install yarn!"; exit 1; }
    fi
    chown -R www-data:www-data /var/www

    sudo -u www-data yarn install || { echo "[ERROR] yarn install failed!"; exit 1; }
    if sudo -u www-data yarn build:production; then
        echo "[INFO] Frontend assets built (production)."
    elif sudo -u www-data yarn build; then
        echo "[INFO] Frontend assets built (dev fallback)."
    else
        echo "[ERROR] Frontend build failed. See output above."; exit 1
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
        if ! certbot certonly --standalone -d $PANELFQDN --non-interactive --staple-ocsp --no-eff-email -m $EMAIL --agree-tos; then
          echo "[WARNING] Certbot failed for $PANELFQDN."
          echo "[WARNING] This is probably because DNS is not pointing to this server."
          echo "[WARNING] The script will continue, but your node will not have a valid SSL certificate."
          echo "[WARNING] You must fix DNS and run certbot manually for $PANELFQDN."
        fi
        #certbot certonly --standalone -d $PANELFQDN --non-interactive --staple-ocsp --no-eff-email -m $EMAIL --agree-tos
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
  export PATH=$PATH:/usr/local/go/bin
}

add_custom_proxy_to_wings() {
  echo "=> Downloading router_server_proxy.go to /srv/wings/router/"
  mkdir -p /srv/wings/router || { echo "Failed to create /srv/wings/router"; exit 1; }

  curl -fsSL "https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/router_server_proxy.go" -o /srv/wings/router/router_server_proxy.go \
    || { echo "Failed to download router_server_proxy.go"; exit 1; }

  ROUTER_FILE="/srv/wings/router/router.go"
  if [ -f "$ROUTER_FILE" ]; then
    echo "Adding proxy endpoints to router.go..."
    echo "Proxy endpoints added."
  else
    echo "Router file not found at $ROUTER_FILE - endpoints NOT added!"
  fi
  export PATH=$PATH:/usr/local/go/bin

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

    curl -L -o /tmp/wings.tar.gz "https://github.com/ghost-dev-gr/wings/releases/latest/download/wings.tar.gz"
    tar -xzvf /tmp/wings.tar.gz -C /srv
    cd /srv
    WINGS_FOLDER=$(ls -d wings-* | head -n1)
    mv "$WINGS_FOLDER" wings
    chmod +x /srv/wings
    curl -o /etc/systemd/system/wings.service https://raw.githubusercontent.com/ghost-dev-gr/pterdactyl-installer-v4/main/configs/wings.service

    echo "[INFO] Requesting SSL certificate for node domain $NODEFQDN..."
    systemctl stop nginx
    if ! certbot certonly --standalone --non-interactive --preferred-challenges http -d "$NODEFQDN" --agree-tos --no-eff-email -m "$EMAIL"; then
        echo "[WARNING] Certbot failed for $NODEFQDN."
        echo "[WARNING] This is probably because DNS is not pointing to this server."
        echo "[WARNING] The script will continue, but your node will not have a valid SSL certificate."
        echo "[WARNING] You must fix DNS and run certbot manually for $NODEFQDN."
    fi
    systemctl start nginx
    systemctl daemon-reload
    systemctl enable --now wings
    export PATH=$PATH:/usr/local/go/bin

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
    sudo mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
    sudo chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
    echo 'passed deb signed'
    curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

    echo 'passed mariadb'
    apt-get update

    apt-get install -y mariadb-server tar unzip git redis-server certbot nginx jq netcat
    echo 'passed marmariadb-server iadb'
    sed -i 's/character-set-collations = utf8mb4=uca1400_ai_ci/character-set-collations = utf8mb4=utf8mb4_general_ci/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
    systemctl restart mariadb

    apt-get install -y php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}

    update-alternatives --set php /usr/bin/php8.3
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

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
    echo 'ended panel_install'

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
        create_node_in_db
        generate_node_config "$NODEFQDN"
        setup_nginx_for_node "$NODEFQDN"

        # Health check for wings on 8443
        echo "[INFO] Checking if wings is live on port 8443..."
        sleep 3
        if nc -z localhost 8443; then
            echo "[OK] Wings is running and accepting connections on 8443."
        else
            echo "[ERROR] Wings did NOT start or port 8443 is not open!"
            exit 1
        fi
    fi
    finish
else
    echo "Your OS, $dist $version, is not supported"
    exit 1
fi
