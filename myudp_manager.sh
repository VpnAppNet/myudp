#!/bin/bash

# ================= BASIC CONFIG =================
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"

API_FILE="/opt/online_api.py"
SERVICE_FILE="/etc/systemd/system/online-api.service"
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

# ================= REAL-TIME ONLINE API (FIXED) =================
apt-get update -y >/dev/null 2>&1
apt-get install -y python3 python3-pip iproute2 ufw psmisc >/dev/null 2>&1
python3 -m pip install flask >/dev/null 2>&1

# Kill any process using port 81 to avoid bind errors
if ss -tlnp | grep -q ":81 "; then
    echo -e "${YELLOW}⚠ Port 81 is in use. Freeing it...${NC}"
    fuser -k 81/tcp 2>/dev/null || true
    sleep 2
fi

# Create API Python file with improved error handling
cat > "$API_FILE" <<'PYEOF'
from flask import Flask, jsonify
import subprocess
import logging
import os
import sys

app = Flask(__name__)

# Setup logging
log_file = "/var/log/online-api.log"
logging.basicConfig(filename=log_file, level=logging.INFO,
                    format='%(asctime)s %(message)s')

def realtime_udp():
    try:
        # Find full path to ss
        try:
            ss_path = subprocess.check_output("which ss", shell=True, stderr=subprocess.DEVNULL).strip().decode()
            if not ss_path:
                ss_path = "ss"
        except:
            ss_path = "ss"

        # Run ss to get established UDP connections
        cmd = [ss_path, "-u", "-n", "state", "established"]
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, universal_newlines=True)
        lines = out.strip().split('\n')
        if len(lines) > 1:
            data_lines = [l for l in lines[1:] if l.strip()]
            count = len(data_lines)
        else:
            count = 0
        # Limit to 300 concurrent users
        return count if count <= 300 else 300
    except subprocess.CalledProcessError as e:
        logging.error(f"ss command failed: {e}")
        return 0
    except Exception as e:
        logging.error(f"Unexpected error in realtime_udp: {e}")
        return 0

@app.route("/udpserver/online_app")
def online():
    return jsonify({"online": realtime_udp(), "mode": "real-time", "limit": 300})

@app.route("/")
def index():
    return jsonify({"status": "API is running", "endpoint": "/udpserver/online_app"})

if __name__ == "__main__":
    # Bind to all interfaces, port 81
    app.run(host="0.0.0.0", port=81, debug=False)
PYEOF

# Create systemd service file
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Real-Time Online User API
After=network.target

[Service]
ExecStart=/usr/bin/python3 $API_FILE
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable online-api >/dev/null 2>&1
systemctl restart online-api >/dev/null 2>&1

# Open port 81 in firewall
if command -v ufw >/dev/null 2>&1; then
    ufw allow 81/tcp >/dev/null 2>&1
    echo -e "${GREEN}✔ UFW: Port 81 opened${NC}"
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport 81 -j ACCEPT >/dev/null 2>&1
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    echo -e "${GREEN}✔ iptables: Port 81 opened${NC}"
fi

# Wait for API to start and verify
echo -e "${CYAN}Verifying API service...${NC}"
sleep 3
if systemctl is-active --quiet online-api; then
    echo -e "${GREEN}✔ API service is running${NC}"
    # Test local response
    if curl -s http://localhost:81/udpserver/online_app > /dev/null; then
        echo -e "${GREEN}✔ API responded locally${NC}"
    else
        echo -e "${RED}✘ API local test failed. Check logs: journalctl -u online-api${NC}"
        journalctl -u online-api --no-pager -n 20
    fi
else
    echo -e "${RED}✘ API service failed to start. Check: systemctl status online-api${NC}"
    systemctl status online-api --no-pager
fi

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
  echo -e "${YELLOW}http://${SERVER_IP}:81/udpserver/online_app${NC}"
  echo
  curl -s "http://${SERVER_IP}:81/udpserver/online_app" || echo "API ERROR"
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
