#!/usr/bin/env bash
#
# Try `install_jueudp.sh --help` for usage.
#
# (c) 2023 Jue Htet
#

set -e

############################
# BASIC CONFIG
############################
DOMAIN="eg.jueudp.com"
PROTOCOL="udp"
UDP_PORT=":36712"
OBFS="jaideevpn"
PASSWORD="jaideevpn"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_ARGS=("$@")

EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/hysteria"
USER_DB="$CONFIG_DIR/udpusers.db"

REPO_URL="https://github.com/apernet/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
API_BASE_URL="https://api.github.com/repos/apernet/hysteria"

CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

SYSTEMD_SERVICE="$SYSTEMD_SERVICES_DIR/hysteria-server.service"

mkdir -p "$CONFIG_DIR"
touch "$USER_DB"

############################
# ENV
############################
OPERATING_SYSTEM=""
ARCHITECTURE=""
HYSTERIA_USER=""
HYSTERIA_HOME_DIR=""
VERSION=""
FORCE=""
LOCAL_FILE=""
FORCE_NO_ROOT=""
FORCE_NO_SYSTEMD=""

############################
# UTILS
############################
has_command(){ type -P "$1" >/dev/null 2>&1; }
curl(){ command curl "${CURL_FLAGS[@]}" "$@"; }
mktemp(){ command mktemp "hyservinst.XXXXXXXXXX"; }

note(){ echo -e "$SCRIPT_NAME: note: $1"; }
warning(){ echo -e "$SCRIPT_NAME: warning: $1"; }
error(){ echo -e "$SCRIPT_NAME: error: $1"; }

############################
# ENV CHECKS
############################
check_permission(){
    [[ "$UID" -eq 0 ]] && return
    if has_command sudo; then
        exec sudo env "$0" "${SCRIPT_ARGS[@]}"
    else
        error "Run as root"
        exit 1
    fi
}

check_environment(){
    [[ "$(uname)" == "Linux" ]] || { error "Linux only"; exit 1; }
    has_command curl || apt install -y curl
    has_command sqlite3 || apt install -y sqlite3
    has_command jq || apt install -y jq
}

############################
# DB
############################
setup_db(){
sqlite3 "$USER_DB" <<EOF
CREATE TABLE IF NOT EXISTS users (
username TEXT PRIMARY KEY,
password TEXT NOT NULL
);
EOF
}

fetch_users(){
sqlite3 "$USER_DB" "SELECT username||':'||password FROM users;" | paste -sd, -
}

############################
# HYSTERIA
############################
download_hysteria(){
    local tmp
    tmp=$(mktemp)
    curl "$REPO_URL/releases/download/v1.3.5/hysteria-linux-amd64" -o "$tmp"
    install -Dm755 "$tmp" "$EXECUTABLE_INSTALL_PATH"
    rm -f "$tmp"
}

write_config(){
users=$(fetch_users)
cat >"$CONFIG_FILE"<<EOF
{
 "server":"$DOMAIN",
 "listen":"$UDP_PORT",
 "protocol":"$PROTOCOL",
 "insecure":true,
 "obfs":"$OBFS",
 "auth":{
   "mode":"passwords",
   "config":[ "$users" ]
 }
}
EOF
}

install_systemd(){
cat >"$SYSTEMD_SERVICE"<<EOF
[Unit]
Description=Hysteria UDP
After=network.target

[Service]
ExecStart=$EXECUTABLE_INSTALL_PATH server --config $CONFIG_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server
}

############################
# MANAGER
############################
install_manager(){
curl -o /usr/local/bin/jueudp_manager.sh https://raw.githubusercontent.com/Juessh/Juevpnscript/main/jueudp_manager.sh
chmod +x /usr/local/bin/jueudp_manager.sh
ln -sf /usr/local/bin/jueudp_manager.sh /usr/local/bin/jueudp
}

#################################################
# JUE-UDP REALTIME ONLINE USERS (ADD-ON)
#################################################
jueudp_online_api(){

    has_command nginx || apt install -y nginx

    mkdir -p /var/www/html/server

cat >/usr/local/bin/jueudp_online.sh <<'EOF'
#!/usr/bin/env bash
PORT=36712
OUT="/var/www/html/server/online_app.json"
LIMIT=250
ONLINE=$(ss -anu -p | grep hysteria | grep ":$PORT" | wc -l)
echo "{\"onlines\":\"$ONLINE\",\"limit\":\"$LIMIT\"}" > "$OUT"
EOF

chmod +x /usr/local/bin/jueudp_online.sh

cat >/etc/systemd/system/jueudp-online.service <<EOF
[Unit]
Description=JUE UDP Online Counter
[Service]
Type=oneshot
ExecStart=/usr/local/bin/jueudp_online.sh
EOF

cat >/etc/systemd/system/jueudp-online.timer <<EOF
[Timer]
OnBootSec=10
OnUnitActiveSec=15
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now jueudp-online.timer

cat >/etc/nginx/sites-available/jueudp-online <<EOF
server {
 listen 82;
 root /var/www/html;
 location /server/ {
   default_type application/json;
   add_header Access-Control-Allow-Origin *;
 }
}
EOF

ln -sf /etc/nginx/sites-available/jueudp-online /etc/nginx/sites-enabled/jueudp-online
nginx -t && systemctl restart nginx
}

############################
# INSTALL
############################
perform_install(){
setup_db
download_hysteria
write_config
install_systemd
install_manager
jueudp_online_api
echo "DONE"
echo "ONLINE API: http://SERVER_IP:82/server/online_app.json"
}

############################
# MAIN
############################
main(){
check_permission
check_environment
perform_install
}

main "$@"
