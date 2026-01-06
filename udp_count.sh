#!/usr/bin/env bash
#
# JUE-UDP + REALTIME ONLINE API
# ALL IP ACCESS (0.0.0.0:8099)
# SINGLE FULL SCRIPT
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

API_PORT=8099
API_BIND="0.0.0.0"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_ARGS=("$@")

EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"

REPO_URL="https://github.com/apernet/hysteria"

mkdir -p "$CONFIG_DIR"
touch "$USER_DB"

############################
# UTILS
############################
has_command(){ type -P "$1" >/dev/null 2>&1; }
curl(){ command curl -L -f "$@"; }
mktemp(){ command mktemp "hyservinst.XXXXXXXX"; }

############################
# PERMISSION
############################
check_permission(){
    [[ "$UID" -eq 0 ]] && return
    exec sudo env "$0" "${SCRIPT_ARGS[@]}"
}

############################
# ENV
############################
check_environment(){
    apt update
    for p in curl sqlite3 jq python3 ss; do
        has_command "$p" || apt install -y "$p"
    done
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
  "insecure": true,
  "obfs":"$OBFS",
  "auth":{
    "mode":"passwords",
    "config":[ "$users" ]
  }
}
EOF
}

install_hysteria_service(){
cat >/etc/systemd/system/hysteria-server.service<<EOF
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
systemctl enable --now hysteria-server
}

############################
# ONLINE COUNTER
############################
install_online_counter(){

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
}

############################
# API SERVER (ALL IP)
############################
install_api_server(){

cat >/etc/systemd/system/jueudp-api.service <<EOF
[Unit]
Description=JUE UDP Online API (All IP)

[Service]
ExecStart=/usr/bin/python3 -m http.server $API_PORT --bind $API_BIND --directory /var/www/html
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now jueudp-api
}

############################
# INSTALL
############################
perform_install(){
setup_db
download_hysteria
write_config
install_hysteria_service
install_online_counter
install_api_server

echo
echo "✅ INSTALL COMPLETE"
echo "🌐 API ACCESS (ANY IP / DOMAIN):"
echo "http://SERVER_IP:$API_PORT/server/online_app.json"
echo
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
