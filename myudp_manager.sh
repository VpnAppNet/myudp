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

# ================= REAL-TIME ONLINE API =================
apt-get update -y >/dev/null 2>&1
apt-get install -y python3 python3-pip iproute2 >/dev/null 2>&1
pip3 install flask >/dev/null 2>&1

cat > "$API_FILE" <<'PYEOF'
from flask import Flask, jsonify
import subprocess

app = Flask(__name__)

def realtime_udp():
    try:
        out = subprocess.check_output(
            ["ss", "-u", "-n", "state", "established"],
            stderr=subprocess.DEVNULL
        ).decode()
        lines = [l for l in out.splitlines() if ":" in l]
        return len(set(lines))
    except:
        return 0

@app.route("/server/online")
def online():
    return jsonify({"online": realtime_udp(), "mode": "real-time"})

app.run(host="0.0.0.0", port=81)
PYEOF

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Real-Time Online User API
After=network.target

[Service]
ExecStart=/usr/bin/python3 $API_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable online-api >/dev/null 2>&1
systemctl restart online-api >/dev/null 2>&1

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
  echo -e "${CYAN}Real-Time Online:${NC}"
  echo -e "${YELLOW}http://${SERVER_IP}:81/server/online${NC}"
  echo
  curl -s "http://${SERVER_IP}:81/server/online" || echo "API ERROR"
}

# ================= BANNER =================
clear
echo -e "${RED}S${GREEN}c${YELLOW}r${CYAN}i${PINK}p${BLUE}t ${RED}B${GREEN}y ${YELLOW}: ${CYAN}J${PINK}U${BLUE}E ${RED}H${GREEN}T${YELLOW}E${CYAN}T${NC}"
echo -e "${CYAN}"
cat << "EOF"
          _____                    _____                    _____                    _____                    _____                  
         /\    \                  /\    \                  /\    \                  /\    \                  /\    \                 
        /::\    \                /::\____\                /::\____\                /::\    \                /::\    \                
        \:::\    \              /:::/    /               /:::/    /               /::::\    \              /::::\    \               
         \:::\    \            /:::/    /               /:::/    /               /::::::\    \            /::::::\    \              
          \:::\    \          /:::/    /               /:::/    /               /:::/\:::\    \          /:::/\:::\    \             
           \:::\    \        /:::/____/               /:::/    /               /:::/  \:::\    \        /:::/__\:::\    \            
           /::::\    \      /::::\    \              /:::/    /               /:::/    \:::\    \      /::::\   \:::\    \           
  _____   /::::::\    \    /::::::\    \   _____    /:::/    /      _____    /:::/    / \:::\    \    /::::::\   \:::\    \          
 /\    \ /:::/\:::\    \  /:::/\:::\    \ /\    \  /:::/____/      /\    \  /:::/    /   \:::\ ___\  /:::/\:::\   \:::\____\         
/::\    /:::/  \:::\____\/:::/  \:::\    /::\____\|:::|    /      /::\____\/:::/____/     \:::|    |/:::/  \:::\   \:::|    |        
\:::\  /:::/    \::/    /\::/    \:::\  /:::/    /|:::|____\     /:::/    /\:::\    \     /:::|____|\::/    \:::\  /:::|____|        
 \:::\/:::/    / \/____/  \/____/ \:::\/:::/    /  \:::\    \   /:::/    /  \:::\    \   /:::/    /  \/_____/\:::\/:::/    /         
  \::::::/    /                    \::::::/    /    \:::\    \ /:::/    /    \:::\    \ /:::/    /            \::::::/    /          
   \::::/    /                      \::::/    /      \:::\    /:::/    /      \:::\    /:::/    /              \::::/    /           
    \::/    /                       /:::/    /        \:::\__/:::/    /        \:::\  /:::/    /                \::/____/            
     \/____/                       /:::/    /          \::::::::/    /          \:::\/:::/    /                  ~~                  
                                  /:::/    /            \::::::/    /            \::::::/    /                                       
                                 /:::/    /              \::::/    /              \::::/    /                                        
                                 \::/    /                \::/____/                \::/____/                                         
                                  \/____/                  ~~                       ~~                                               
                                                                                                        
EOF
echo -e "${NC}"

# ================= MENU =================
menu() {
  echo -e "${BLUE}"
  echo "╔══════════════════════════════════════════╗"
  echo "║           JUE-UDP MANAGER                ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "${YELLOW}👉 1. အကောင့်အသစ်ဖွင့်မည်${NC}"
  echo -e "${YELLOW}👉 2. စကားဝှက် / Expired ပြင်မည်${NC}"
  echo -e "${YELLOW}👉 3. အကောင့်ဖျက်မည်${NC}"
  echo -e "${YELLOW}👉 4. အကောင့်စာရင်းကြည့်မည်${NC}"
  echo -e "${YELLOW}👉 5. ဒိုမိန်းပြန်ပြင်မည်${NC}"
  echo -e "${YELLOW}👉 6. Obfs ပြင်မည်${NC}"
  echo -e "${YELLOW}👉 7. Upload Speed ပြင်မည်${NC}"
  echo -e "${YELLOW}👉 8. Download Speed ပြင်မည်${NC}"
  echo -e "${YELLOW}👉 9. Online User (Real-Time)${NC}"
  echo -e "${YELLOW}👉 10. ဆာဗာပြန်စတင်မည်${NC}"
  echo -e "${YELLOW}👉 11. ဆာဗာဖျက်သိမ်းမည်${NC}"
  echo -e "${YELLOW}👉 12. ထွက်မည်${NC}"
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
