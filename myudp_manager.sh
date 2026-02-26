#!/bin/bash

# ================= BASIC CONFIG =================
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"

API_FILE="/opt/online_api.py"
SERVICE_FILE="/etc/systemd/system/online-api.service"
NGINX_CONF="/etc/nginx/sites-available/online-api"
NGINX_ENABLE="/etc/nginx/sites-enabled/online-api"
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "YOUR_IP")

mkdir -p "$CONFIG_DIR"
touch "$USER_DB"

# ================= COLORS =================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
PINK='\033[1;35m'
BLUE='\033[1;34m'
ORANGE='\033[38;5;214m'
PURPLE='\033[1;35m'
NC='\033[0m'

# ================= DB INIT + MIGRATION =================
sqlite3 "$USER_DB" <<EOF
CREATE TABLE IF NOT EXISTS users (
  username TEXT PRIMARY KEY,
  password TEXT,
  expire_date TEXT
);
EOF

HAS_EXPIRE=$(sqlite3 "$USER_DB" "PRAGMA table_info(users);" | awk -F'|' '{print $2}' | grep -c expire_date)
if [ "$HAS_EXPIRE" -eq 0 ]; then
  sqlite3 "$USER_DB" "ALTER TABLE users ADD COLUMN expire_date TEXT DEFAULT '2099-12-31';"
fi

# ================= INSTALL DEPENDENCIES =================
apt-get update -y >/dev/null 2>&1
apt-get install -y python3 python3-pip iproute2 jq sqlite3 curl nginx ufw >/dev/null 2>&1
pip3 install flask >/dev/null 2>&1

# ================= FIREWALL: OPEN PORT 81 (if UFW exists) =================
if command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}🔓 UFW ကို တွေ့ရှိပါသည်။ Port 81 ဖွင့်နေပါသည်...${NC}"
    ufw allow 81 >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    echo -e "${GREEN}✔ Port 81 ဖွင့်ပြီးပါပြီ (UFW)${NC}"
else
    echo -e "${YELLOW}⚠ UFW မတွေ့ပါ။ Firewall ကိုယ်တိုင်ဖွင့်ရန်လိုအပ်ပါသည်။${NC}"
fi

# ================= IMPROVED REAL-TIME ONLINE API (only online & limit, online first) =================
cat > "$API_FILE" <<'PYEOF'
from flask import Flask, jsonify
import subprocess
import json
import os
from collections import OrderedDict

app = Flask(__name__)

CONFIG_FILE = "/etc/hysteria/config.json"

def get_hysteria_port():
    """Extract listening port from Hysteria config"""
    try:
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
        listen = config.get('listen', '')
        if ':' in listen:
            return listen.split(':')[-1]
    except:
        pass
    return "36712"  # fallback default port

def count_udp_users(port):
    """Count unique source IPs connected to Hysteria port"""
    try:
        cmd = f"ss -u -n state established sport = :{port}"
        output = subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode()
        lines = output.strip().split('\n')[1:]  # skip header
        sources = set()
        for line in lines:
            parts = line.split()
            if len(parts) >= 6:
                peer = parts[5]  # peer address (ip:port)
                if ':' in peer:
                    ip = peer.rsplit(':', 1)[0]
                    sources.add(ip)
        return len(sources)
    except Exception as e:
        print("Error in count_udp_users:", e)
        return 0

# Route both with and without .json
@app.route("/udpserver/online_app")
@app.route("/udpserver/online_app.json")
def online():
    port = get_hysteria_port()
    count = count_udp_users(port)
    count = min(count, 300)  # limit to 300
    # Use OrderedDict to ensure "online" appears first
    response = OrderedDict()
    response["online"] = count
    response["limit"] = 300
    return jsonify(response)

if __name__ == "__main__":
    # Listen on localhost only, nginx will proxy
    app.run(host="127.0.0.1", port=5000)
PYEOF

# ================= CREATE SYSTEMD SERVICE =================
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Real-Time Online User API
After=network.target

[Service]
ExecStart=/usr/bin/python3 $API_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable online-api >/dev/null 2>&1
systemctl restart online-api >/dev/null 2>&1

# ================= CONFIGURE NGINX AS REVERSE PROXY =================
# Remove default nginx site if it uses port 81 (to avoid conflict)
if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# Create nginx config for online API
cat > "$NGINX_CONF" <<EOF
server {
    listen 81;
    server_name _;  # Replace with your domain if needed

    location /udpserver/online_app {
        proxy_pass http://127.0.0.1:5000/udpserver/online_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /udpserver/online_app.json {
        proxy_pass http://127.0.0.1:5000/udpserver/online_app.json;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# Enable the site
ln -sf "$NGINX_CONF" "$NGINX_ENABLE"

# Test nginx config and reload
nginx -t && systemctl reload nginx

# ================= CORE FUNCTIONS (ORIGINAL) =================
fetch_users() {
  sqlite3 "$USER_DB" \
  "SELECT username || ':' || password FROM users WHERE date(expire_date)>=date('now');" \
  | paste -sd, -
}

update_userpass_config() {
  users=$(fetch_users)
  arr=$(echo "$users" | awk -F, '{for(i=1;i<=NF;i++) printf "\"" $i "\"" ((i==NF)?"":",")}')
  jq ".auth.config = [$arr]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

restart_server() {
  systemctl restart hysteria-server
  echo -e "${GREEN}✔ ဆာဗာပြန်စတင်ပြီးပါပြီ${NC}"
}

add_user() {
  echo -e "${CYAN}Username:${NC}"; read u
  echo -e "${CYAN}Password:${NC}"; read p
  echo -e "${CYAN}Days:${NC}"; read d
  exp=$(date -d "+$d days" +"%Y-%m-%d")
  sqlite3 "$USER_DB" "INSERT OR REPLACE INTO users VALUES ('$u','$p','$exp');"
  update_userpass_config
  restart_server
}

edit_user() {
  echo -e "${CYAN}Username:${NC}"; read u
  echo -e "${CYAN}New Password:${NC}"; read p
  echo -e "${CYAN}Days:${NC}"; read d
  exp=$(date -d "+$d days" +"%Y-%m-%d")
  sqlite3 "$USER_DB" \
  "UPDATE users SET password='$p',expire_date='$exp' WHERE username='$u';"
  update_userpass_config
  restart_server
}

delete_user() {
  echo -e "${CYAN}Username:${NC}"; read u
  sqlite3 "$USER_DB" "DELETE FROM users WHERE username='$u';"
  update_userpass_config
  restart_server
}

show_users() {
  echo -e "${CYAN}USERNAME | PASSWORD | EXPIRE${NC}"
  sqlite3 "$USER_DB" "SELECT username,password,expire_date FROM users;"
}

change_domain() {
  echo -e "${CYAN}New Domain:${NC}"; read d
  jq ".server=\"$d\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  restart_server
}

change_obfs() {
  echo -e "${CYAN}New Obfs:${NC}"; read o
  jq ".obfs.password=\"$o\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  restart_server
}

change_up_speed() {
  echo -e "${CYAN}Upload Mbps:${NC}"; read u
  jq ".up_mbps=$u" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  restart_server
}

change_down_speed() {
  echo -e "${CYAN}Download Mbps:${NC}"; read d
  jq ".down_mbps=$d" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  restart_server
}

uninstall_server() {
  systemctl stop hysteria-server
  systemctl disable hysteria-server
  rm -rf "$CONFIG_DIR" /usr/local/bin/hysteria
  systemctl daemon-reload
  echo -e "${GREEN}✔ ဆာဗာဖျက်သိမ်းပြီးပါပြီ${NC}"
}

online_user() {
  echo -e "${CYAN}Real-Time Online (limited to 300):${NC}"
  echo -e "${YELLOW}http://${SERVER_IP}:81/udpserver/online_app.json${NC}"
  echo -e "${YELLOW}(or without .json)${NC}"
  echo
  # Try to fetch and display raw response
  echo "Response from API:"
  curl -s "http://${SERVER_IP}:81/udpserver/online_app.json" || echo "API ERROR or not reachable"
  echo
}

# ================= BANNER =================
clear
echo -e "${RED}S${GREEN}c${YELLOW}r${CYAN}i${PINK}p${BLUE}t ${RED}B${GREEN}y ${YELLOW}: ${CYAN}J${PINK}U${BLUE}E ${RED}H${GREEN}T${YELLOW}E${CYAN}T${NC}"
echo -e "${CYAN}"
cat << "EOF"
                          ___                    ___     
    ___                  /\  \                  /\__\    
   /\__\                 \:\  \                /:/ _/_   
  /:/__/                  \:\  \              /:/ /\__\  
 /::\  \              ___  \:\  \            /:/ /:/ _/_ 
 \/\:\  \            /\  \  \:\__\          /:/_/:/ /\__\
  ~~\:\  \           \:\  \ /:/  /          \:\/:/ /:/  /
     \:\__\           \:\  /:/  /            \::/_/:/  / 
     /:/  /            \:\/:/  /              \:\/:/  /  
    /:/  /              \::/  /                \::/  /   
    \/__/                \/__/                  \/__/    
EOF
echo -e "${NC}"

# ================= MENU =================
menu() {
  echo -e "${GREEN}"
  echo "╔══════════════════════════════════════════╗"
  echo "║           JUE-UDP MANAGER                ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"
  
  # Rainbow colors array
  rainbow_colors=("$RED" "$ORANGE" "$YELLOW" "$GREEN" "$CYAN" "$BLUE" "$PURPLE")
  
  # Menu items with rainbow colors
  for i in {1..12}; do
    color_index=$(( (i-1) % ${#rainbow_colors[@]} ))
    color="${rainbow_colors[$color_index]}"
    case $i in
      1) echo -e "${color}👉 1. အကောင့်အသစ်ဖွင့်မည်${NC}" ;;
      2) echo -e "${color}👉 2. စကားဝှက် / Expired ပြင်မည်${NC}" ;;
      3) echo -e "${color}👉 3. အကောင့်ဖျက်မည်${NC}" ;;
      4) echo -e "${color}👉 4. အကောင့်စာရင်းကြည့်မည်${NC}" ;;
      5) echo -e "${color}👉 5. ဒိုမိန်းပြန်ပြင်မည်${NC}" ;;
      6) echo -e "${color}👉 6. Obfs ပြင်မည်${NC}" ;;
      7) echo -e "${color}👉 7. Upload Speed ပြင်မည်${NC}" ;;
      8) echo -e "${color}👉 8. Download Speed ပြင်မည်${NC}" ;;
      9) echo -e "${color}👉 9. Online User (Real-Time)${NC}" ;;
      10) echo -e "${color}👉 10. ဆာဗာပြန်စတင်မည်${NC}" ;;
      11) echo -e "${color}👉 11. ဆာဗာဖျက်သိမ်းမည်${NC}" ;;
      12) echo -e "${color}👉 12. ထွက်မည်${NC}" ;;
    esac
  done
  
  echo
  echo -e "${YELLOW}ရွေးချယ်ပါ ➜ ${NC}"
}

# ================= MAIN LOOP =================
while true; do
  menu
  read c
  case $c in
    1) add_user ;;
    2) edit_user ;;
    3) delete_user ;;
    4) show_users ;;
    5) change_domain ;;
    6) change_obfs ;;
    7) change_up_speed ;;
    8) change_down_speed ;;
    9) online_user ;;
    10) restart_server ;;
    11) uninstall_server ;;
    12) exit ;;
    *) echo "Invalid" ;;
  esac
  read -p "Enter နှိပ်ပါ..."
done
