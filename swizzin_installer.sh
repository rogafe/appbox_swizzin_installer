#!/bin/bash
set -x

export DEBIAN_FRONTEND=noninteractive

OLD_INSTALLS_EXIST=0

check_password() {
    local username="$1"
    local input_password="$2"

    # Extract the hash from /etc/shadow
    shadow_hash=$(sudo grep "^$username:" /etc/shadow | cut -d':' -f2)

    # Extract the method and salt from the shadow hash
    salt=$(echo "$shadow_hash" | cut -d'$' -f3,4)

    # Generate the hash for the input password using the salt
    input_hash=$(mkpasswd --method=yescrypt --salt="$salt" "$input_password")

    # Compare the generated hash with the hash in the shadow file
    if [ "$input_hash" == "$shadow_hash" ]; then
        echo "Password is correct."
    else
        echo "Password is incorrect."
    fi
}


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

# if [[ ! "$(printf "${USER_PASSWORD}" | openssl passwd -"${a[1]}" -salt "${a[2]}" -stdin)" = "${userline}" ]]; then
#     echo "Password does not match"
#     exit 1
# fi

if ! check_password abc "${USER_PASSWORD}"; then
    echo "Password does not match"
    exit 1
fi

cd /tmp || exit 1

url_output() {
    echo -e "\n\n\n\n\n
Installation of Swizzin successful! Please point your browser to:
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
exec logutil-service /var/log/abc/${NAME}
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
            if [ -d "/home/abc/.config/${i^}" ]; then
                rm -rf /home/abc/.config/"${i^}"
            fi
            if [ -d "/var/log/abc/$i" ]; then
                rm -rf /var/log/abc/"$i"
            fi
        done

        rm -rf /home/abc/abc_installer
    else
        echo "Please remove the old installs and try again, or use this script to remove them."
        exit 1
    fi
fi

sed -i 's/www-data/abc/g' /etc/nginx/nginx.conf
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
VERSION="22.04.1 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 22.04.1 LTS"
VERSION_ID="22.04"
HOME_URL="https://www.ubuntu.com/"
SUPPORT_URL="https://help.ubuntu.com/"
BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
VERSION_CODENAME=jammy
UBUNTU_CODENAME=jammy
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
# BIND_HOST=127.0.0.1

# specify the port overseerr listens to, defaults to 5055
PORT=5055

# Specify base url here or in Overseerr settings -> application
#BASE_URL=/overseerr
EOF
bash /usr/local/bin/swizzin/nginx/deploy apps
EON

ln -fs /lib/systemd/system/systemd-logind.service /etc/systemd/system/dbus-org.freedesktop.login1.service
mkdir -p /etc/services.d/dbus/log
echo "3" >/etc/services.d/dbus/notification-fd
cat <<EOF >/etc/services.d/dbus/log/run
#!/bin/sh
exec logutil-service /var/log/abc/dbus
EOF
chmod +x /etc/services.d/dbus/log/run
RUNNER=$(
    cat <<EOF
#!/bin/execlineb -P
fdmove -c 2 1
/usr/local/bin/systemctl restart dbus
EOF
)
create_service "dbus"

sed -i "s/:1000:/:$USER_ID:/" /etc/passwd

echo 'export PATH=/usr/local/bin:$PATH' >/etc/profile.d/systemctl.sh

export DEBIAN_FRONTEND=dialog

/usr/lib/binfmt.d/WSLInterop.conf

rm -rf /etc/systemd/system/sshd.service
systemctl enable ssh
systemctl start ssh

bash /etc/swizzin/install.sh -u abc -p "${USER_PASSWORD}" -y -s all

url_output
