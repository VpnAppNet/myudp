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

# ================= REAL-TIME ONLINE API (UPDATED) =================
# Flask နှင့် လိုအပ်သော dependencies များသွင်းခြင်း
apt-get update -y >/dev/null 2>&1
apt-get install -y python3 python3-pip iproute2 sqlite3 jq curl >/dev/null 2>&1
pip3 install flask --break-system-packages >/dev/null 2>&1 || pip3 install flask >/dev/null 2>&1

cat > "$API_FILE" <<'PYEOF'
from flask import Flask, jsonify
import subprocess
import re

app = Flask(__name__)

def get_realtime_count():
    try:
        # ss command သုံးပြီး established ဖြစ်နေသော UDP connection များကို ယူသည်
        # Hysteria သည် UDP ကို အဓိကသုံးသောကြောင့် ss -u (udp) ကို စစ်ဆေးသည်
        output = subprocess.check_output(["ss", "-unp", "state", "established"], stderr=subprocess.STDOUT).decode()
        
        # Connection တစ်ခုချင်းစီ၏ Remote Address ကို ရှာဖွေပြီး Unique IP များကို ရေတွက်သည်
        # ၎င်းသည် ချိတ်ဆက်ထားသော လူအရေအတွက် (Unique Users) ကို ပိုမိုတိကျစေသည်
        lines = output.splitlines()
        clients = set()
        for line in lines[1:]: # Skip header
            parts = line.split()
            if len(parts) >= 5:
                remote_addr = parts[5] # Remote Address:Port
                ip = remote_addr.rsplit(':', 1)[0]
                clients.add(ip)
        
        return len(clients)
    except Exception as e:
        return 0

@app.route("/server/online")
def online_old():
    return jsonify({"online": get_realtime_count(), "status": "success"})

@app.route("/udpserver/online_app")
def online_app():
    # အသုံးပြုသူ တောင်းဆိုထားသော URL အသစ်
    count = get_realtime_count()
    return jsonify({
        "connected_users": count,
        "server_status": "online",
        "api_path": "/udpserver/online_app",
        "msg": f"လက်ရှိချိတ်ဆက်ထားသူ {count} ဦးရှိပါသည်"
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=81)
PYEOF

# Create SystemD Service
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=JUE UDP Real-Time Online API
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

# ================= CORE FUNCTIONS =================
fetch_users() {
  sqlite3 "$USER_DB" \
  "SELECT username || ':' || password FROM users WHERE date(expire_date)>=date('now');" \
  | paste -sd, -
}

update_userpass_config() {
  users=$(fetch_users)
  if [ -z "$users" ]; then
    jq ".auth.config = []" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  else
    arr=$(echo "$users" | sed 's/,/" , "/g' | sed 's/^/"/' | sed 's/$/"/')
    jq ".auth.config = [$arr]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  fi
}

restart_server() {
  systemctl restart hysteria-server >/dev/null 2>&1
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
  systemctl stop hysteria-server online-api
  systemctl disable hysteria-server online-api
  rm -rf "$CONFIG_DIR" /usr/local/bin/hysteria "$API_FILE" "$SERVICE_FILE"
  systemctl daemon-reload
  echo -e "${GREEN}✔ ဆာဗာနှင့် API အားလုံး ဖျက်သိမ်းပြီးပါပြီ${NC}"
}

online_user() {
  echo -e "${CYAN}Real-Time Online Link:${NC}"
  echo -e "${YELLOW}http://${SERVER_IP}:81/udpserver/online_app${NC}"
  echo
  echo -e "${PINK}စစ်ဆေးနေသည်...${NC}"
  curl -s "http://127.0.0.1:81/udpserver/online_app" | jq . || echo -e "${RED}API ချိတ်ဆက်၍မရပါ${NC}"
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
  echo "║           JUE-UDP MANAGER (PRO)          ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"
  
  rainbow_colors=("$RED" "$ORANGE" "$YELLOW" "$GREEN" "$CYAN" "$BLUE" "$PURPLE")
  
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
      9) echo -e "${color}👉 9. Online User (Link နှင့်ကြည့်ရန်)${NC}" ;;
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
  echo
  read -p "ဆက်လက်ဆောင်ရွက်ရန် Enter နှိပ်ပါ..."
done