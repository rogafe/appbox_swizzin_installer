#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

OLD_INSTALLS_EXIST=0

run_as_root() {
    if ! whoami | grep -q 'root'; then
        echo "This script must be run with sudo, please run:"
        echo "sudo $0"
        exit 1
    fi
}

run_as_root

echo 'Please enter your Debian password (for the username abc):'
read -r USER_PASSWORD

userline=$(sudo awk -v u=abc -F: 'u==$1 {print $2}' /etc/shadow)
IFS='$'
a=($userline)

if [[ ! "$(printf "${USER_PASSWORD}" | openssl passwd -"${a[1]}" -salt "${a[2]}" -stdin)" = "${userline}" ]]; then
    echo "Password does not match"
    exit 1
fi

cd /tmp || exit 1

url_output() {
    echo -e "\n\n\n\n\n
Installation of Swizzin sucessful! Please point your browser to:
\e[4mhttps://${HOSTNAME}/\e[39m\e[0m

This will ask for your login details which are as follows:

\e[4mUsername: abc\e[39m\e[0m
\e[4mPassword: ${USER_PASSWORD}\e[39m\e[0m

If you want to install/remove apps, please type the following into your terminal:
sudo box

Some apps will require you to restart the Ubuntu app, so if you find something isn't working, please try that first!

Enjoy!

    \n\n"
}

create_service() {
    NAME=$1
    mkdir -p /etc/services.d/${NAME}/log
    echo "3" >/etc/services.d/${NAME}/notification-fd
    cat <<EOF >/etc/services.d/${NAME}/log/run
#!/bin/sh
exec logutil-service /var/log/appbox/${NAME}
EOF
    chmod +x /etc/services.d/${NAME}/log/run
    echo "${RUNNER}" >/etc/services.d/${NAME}/run
    chmod +x /etc/services.d/${NAME}/run
    cp -R /etc/services.d/${NAME} /var/run/s6/services
    kill -HUP 1
    until [ -d "/run/s6/services/${NAME}/supervise/" ]; do
        echo
        echo "Waiting for s6 to recognize service..."
        sleep 1
    done
    s6-svc -u /run/s6/services/${NAME}
}

mkdir -p /run/php/

check_old_installs() {
    echo "Checking for old installs..."
    # Create array of old installs
    OLD_INSTALLS=(radarr sonarr sickchill jackett couchpotato nzbget sabnzbdplus ombi lidarr organizr nzbhydra2 bazarr flexget filebot synclounge medusa lazylibrarian pyload ngpost komga ombiv4 readarr overseerr requestrr updatetool flood tautulli unpackerr mylar flaresolverr)

    # Loop through array
    for i in "${OLD_INSTALLS[@]}"; do
        # Check if install exists
        if [ -d "/etc/services.d/$i" ]; then
            OLD_INSTALLS_EXIST=1
        fi
    done
}

check_old_installs

if [ $OLD_INSTALLS_EXIST -eq 1 ]; then
    echo "Old installs detected, this will cause a conflict with the new Swizzin services."
    echo "Would you like to remove them (y/n)?"
    read -r REMOVE_OLD_INSTALLS
    if [ "$REMOVE_OLD_INSTALLS" = "y" ] || [ "$REMOVE_OLD_INSTALLS" = "Y" ] || [ "$REMOVE_OLD_INSTALLS" = "yes" ]; then
        echo "Removing old installs..."
        for i in "${OLD_INSTALLS[@]}"; do
            echo "Removing $i..."
            s6-svc -d /run/s6/services/"$i" || true
            if [ -d "/etc/services.d/$i" ]; then
                rm -rf /etc/services.d/"$i"
            fi
            if [ -d "/var/run/s6/services/$i" ]; then
                rm -rf /var/run/s6/services/"$i"
            fi
            if [ -d "/home/appbox/.config/${i^}" ]; then
                rm -rf /home/appbox/.config/"${i^}"
            fi
            if [ -d "/var/log/appbox/$i" ]; then
                rm -rf /var/log/appbox/"$i"
            fi
        done

        rm -rf /home/appbox/appbox_installer
    else
        echo "Please remove the old installs and try again, or use this script to remove them."
        exit 1
    fi
fi

sed -i 's/www-data/appbox/g' /etc/nginx/nginx.conf
echo -e "\nUpdating mono certs..."
cert-sync --quiet /etc/ssl/certs/ca-certificates.crt
echo -e "\nUpdating apt packages..."
echo >>/etc/apt/apt.conf.d/99verify-peer.conf "Acquire { https::Verify-Peer false }"

# Just do this the first time
if [ -f /etc/systemd/system/dbus-fi.w1.wpa_supplicant1.service ] && [ ! -f /etc/systemd/system/panel.service ]; then
    rm -rf /lib/systemd/system/*
    rm -rf /etc/systemd/system/*
fi

echo "Upgrading system..."
apt-get -qq update
apt-get -qq upgrade -y

wget -q https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py -O /usr/local/bin/systemctl
chmod +x /usr/local/bin/systemctl

systemctl daemon-reload

RUNNER=$(
    cat <<EOF
#!/bin/execlineb -P
# Redirect stderr to stdout.
fdmove -c 2 1
/usr/local/bin/systemctl --init
EOF
)

create_service 'systemd'

echo -e "\nInstalling required packages..."
apt-get -qq install -y git

if [ -d /etc/swizzin ]; then
    rm -rf /etc/swizzin
fi


cat <<EOF >/usr/lib/os-release
NAME="Ubuntu"
VERSION="20.04.1 LTS (Focal Fossa)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 20.04.1 LTS"
VERSION_ID="20.04"
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
VERSION_CODENAME=focal
UBUNTU_CODENAME=focal
EOF

git clone https://github.com/swizzin/swizzin.git /etc/swizzin &>/dev/null
cd /etc/swizzin || exit 1
git fetch origin overseer &>/dev/null
git merge --no-edit origin/overseer &>/dev/null
sed -i '/Type=exec/d' /etc/swizzin/scripts/install/overseerr.sh
sed -i 's/# _nginx/_nginx/g' /etc/swizzin/scripts/install/overseerr.sh
cat >/etc/swizzin/scripts/nginx/overseerr.sh <<EON
#!/usr/bin/env bash
cat > /etc/nginx/apps/overseerr.conf << EOF
location /overseerr {
    set \\\$app "overseerr";
    # Remove /overseerr path to pass to the app
    rewrite ^/overseerr/?(.*)$ /\\\$1 break;
    proxy_pass http://127.0.0.1:5055; # NO TRAILING SLASH
    # Redirect location headers
    proxy_redirect ^ /\\\$app;
    proxy_redirect /setup /\\\$app/setup;
    proxy_redirect /login /\\\$app/login;
    # Sub filters to replace hardcoded paths
    proxy_set_header Accept-Encoding "";
    sub_filter_once off;
    sub_filter_types *;
    sub_filter 'href="/"' 'href="/\\\$app"';
    sub_filter 'href="/login"' 'href="/\\\$app/login"';
    sub_filter 'href:"/"' 'href:"/\\\$app"';
    sub_filter '\/_next' '\/\\\$app\/_next';
    sub_filter '/_next' '/\\\$app/_next';
    sub_filter '/api/v1' '/\\\$app/api/v1';
    sub_filter '/login/plex/loading' '/\\\$app/login/plex/loading';
    sub_filter '/images/' '/\\\$app/images/';
    sub_filter '/apple-' '/\\\$app/apple-';
    sub_filter '/favicon' '/\\\$app/favicon';
    sub_filter '/logo.png' '/\\\$app/logo.png';
    sub_filter '/logo_full.svg' '/\\\$app/logo_full.svg';
    sub_filter '/logo_stacked.svg' '/\\\$app/logo_stacked.svg';
    sub_filter '/site.webmanifest' '/\\\$app/site.webmanifest';
}
EOF
cat > /opt/overseerr/env.conf << EOF
# specify on which interface to listen, by default overseerr listens on all interfaces
HOST=127.0.0.1
EOF
systemctl try-restart overseerr
EON
sed -i '/Continue setting up user/d' /etc/swizzin/scripts/box

echo "Installing php required by some apps..."
apt install -y php7.4-fpm
sed -i 's/www-data/appbox/g' /etc/php/7.4/fpm/pool.d/www.conf
systemctl restart php7.4-fpm

# Hack: Some apps need permissions fixed, chown every 10 mins
if crontab -l | grep -q '/srv'; then
    echo "Crontab already updated"
else
    (crontab -l; echo "*/10 * * * * chown -R appbox:appbox /srv >/dev/null 2>&1") | crontab
fi

/etc/swizzin/setup.sh --unattend nginx panel radarr sonarr --user appbox --pass "$USER_PASSWORD"

cat >/etc/nginx/sites-enabled/default <<NGC
map \$http_host \$port {
        default 80;
        "~^[^:]+:(?<p>d+)$" \$p;
}

server {
	listen 80 default_server;
	listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 [2606:4700:4700::1111] [2606:4700:4700::1001] valid=300s; # Cloudflare
    resolver_timeout 5s;
    ssl_session_cache shared:MozSSL:10m;  # about 40000 sessions
    ssl_buffer_size 4k;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_certificate /etc/ssl/cert.pem;
    ssl_certificate_key /etc/ssl/key.pem;
    ssl_trusted_certificate /etc/ssl/cert.pem;
    proxy_hide_header Strict-Transport-Security;
    add_header Strict-Transport-Security "max-age=63072000" always;

    server_name _;
    location /.well-known {
        alias /srv/.well-known;
        allow all;
        default_type "text/plain";
        autoindex    on;
    }
    server_tokens off;
    root /srv/;
    include /etc/nginx/apps/*.conf;
    location ~ /\.ht {
        deny all;
    }

    location /vnc {
        index vnc.html;
        alias /usr/share/novnc/;
        try_files \$uri \$uri/ /vnc.html;
    }
    location /websockify_audio {
        proxy_http_version 1.1;
        proxy_pass http://localhost:6081/;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 61s;
        proxy_buffering off;
    }
    location /websockify {
        proxy_http_version 1.1;
        proxy_pass http://localhost:6080/;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 61s;
        proxy_buffering off;
    }
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Server \$host;
    proxy_set_header X-Forwarded-Port \$port;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_connect_timeout 300s;
    proxy_read_timeout 3600s;
    client_header_timeout 300s;
    client_body_timeout 300s;
    client_max_body_size 1000M;
    send_timeout 300s;
}
NGC

sed -i 's/FORMS_LOGIN = True/FORMS_LOGIN = False/g' /opt/swizzin/core/config.py
echo 'RATELIMIT_ENABLED = False' >> /opt/swizzin/swizzin.cfg

systemctl restart panel
systemctl restart nginx

url_output
