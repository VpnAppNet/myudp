#!/bin/bash

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"
SYSTEMD_SERVICE="/etc/systemd/system/hysteria-server.service"

mkdir -p "$CONFIG_DIR"
touch "$USER_DB"

# ===== COLORS =====
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ===== INIT DB =====
sqlite3 "$USER_DB" <<EOF
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password TEXT NOT NULL,
    expire_date TEXT NOT NULL
);
EOF

fetch_users() {
    sqlite3 "$USER_DB" "SELECT username || ':' || password FROM users WHERE date(expire_date) >= date('now');" | paste -sd, -
}

update_userpass_config() {
    local users
    users=$(fetch_users)
    local user_array
    user_array=$(echo "$users" | awk -F, '{for(i=1;i<=NF;i++) printf "\"" $i "\"" ((i==NF) ? "" : ",")}')
    jq ".auth.config = [$user_array]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

restart_server() {
    systemctl restart hysteria-server
    echo -e "${GREEN}✔ ဆာဗာကို ပြန်လည်စတင်ပြီးပါပြီ${NC}"
}

add_user() {
    echo -e "${CYAN}အသုံးပြုသူအမည် ထည့်ပါ:${NC}"
    read -r username
    echo -e "${CYAN}စကားဝှက် ထည့်ပါ:${NC}"
    read -r password
    echo -e "${CYAN}သုံးမည့်ရက်အရေအတွက် (Days):${NC}"
    read -r days

    expire_date=$(date -d "+$days days" +"%Y-%m-%d")

    sqlite3 "$USER_DB" "INSERT INTO users VALUES ('$username','$password','$expire_date');" && {
        echo -e "${GREEN}✔ $username အကောင့်ဖွင့်ပြီးပါပြီ (Expire: $expire_date)${NC}"
        update_userpass_config
        restart_server
    }
}

edit_user() {
    echo -e "${CYAN}ပြင်မည့် Username:${NC}"
    read -r username
    echo -e "${CYAN}စကားဝှက်အသစ်:${NC}"
    read -r password
    echo -e "${CYAN}ထပ်တိုးမည့်ရက်အရေအတွက်:${NC}"
    read -r days

    expire_date=$(date -d "+$days days" +"%Y-%m-%d")

    sqlite3 "$USER_DB" "UPDATE users SET password='$password', expire_date='$expire_date' WHERE username='$username';"
    update_userpass_config
    restart_server
    echo -e "${GREEN}✔ အကောင့်ပြင်ပြီးပါပြီ${NC}"
}

delete_user() {
    echo -e "${CYAN}ဖျက်မည့် Username:${NC}"
    read -r username
    sqlite3 "$USER_DB" "DELETE FROM users WHERE username='$username';"
    update_userpass_config
    restart_server
    echo -e "${GREEN}✔ အကောင့်ဖျက်ပြီးပါပြီ${NC}"
}

show_users() {
    echo -e "${CYAN}Username | Password | Expire Date${NC}"
    echo "----------------------------------------"
    sqlite3 "$USER_DB" "SELECT username, password, expire_date FROM users;"
}

change_domain() {
    echo -e "${CYAN}ဒိုမိန်းအသစ် ထည့်ပါ:${NC}"
    read -r domain
    jq ".server = \"$domain\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

change_obfs() {
    echo -e "${CYAN}Obfs Password အသစ်:${NC}"
    read -r obfs
    jq ".obfs.password = \"$obfs\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

change_up_speed() {
    echo -e "${CYAN}Upload Speed (Mbps):${NC}"
    read -r up
    jq ".up_mbps=$up" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

change_down_speed() {
    echo -e "${CYAN}Download Speed (Mbps):${NC}"
    read -r down
    jq ".down_mbps=$down" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

uninstall_server() {
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -rf "$CONFIG_DIR" "$SYSTEMD_SERVICE" /usr/local/bin/hysteria
    systemctl daemon-reload
    echo -e "${GREEN}✔ ဆာဗာကို ဖျက်သိမ်းပြီးပါပြီ${NC}"
}

show_banner() {
clear
echo -e "${CYAN}__     __  __     ______     __  __     _____     ______${NC}"
echo -e "${GREEN}\\ \\   /\\ \\ /\\ \\   /\\  ___\\   /\\ \\ /\\ \\   /\\  __-.  /\\  == \\${NC}"
echo -e "${YELLOW}_\\_\\  \\ \\ \\_\\ \\  \\ \\  __\\   \\ \\ \\_\\ \\  \\ \\ \\/\\ \\ \\ \\  _-/${NC}"
echo -e "${CYAN} /\\_____\\  \\ \\_____\\  \\ \\_____\\  \\ \\_____\\  \\ \\____- ${NC}"
echo -e "${GREEN} \\/_____/   \\/_____/   \\/_____/   \\/_____/   \\/____/ ${NC}"
}

show_menu() {
echo -e "${YELLOW}"
echo "┌──────────────────────────────┐"
echo "│ 1. အကောင့်အသစ်ဖွင့်မည်        │"
echo "│ 2. စကားဝှက်ပြင်မည်            │"
echo "│ 3. အကောင့်ဖျက်မည်             │"
echo "│ 4. အကောင့်စာရင်းကြည့်မည်      │"
echo "│ 5. ဒိုမိန်းပြန်ပြင်မည်         │"
echo "│ 6. Obfs ပြင်မည်               │"
echo "│ 7. Upload Speed ပြင်မည်       │"
echo "│ 8. Download Speed ပြင်မည်     │"
echo "│ 9. ဆာဗာပြန်စတင်မည်            │"
echo "│10. ဆာဗာဖျက်သိမ်းမည်           │"
echo "│11. ထွက်မည်                   │"
echo "└──────────────────────────────┘"
echo -e "ရွေးချယ်ပါ ➜ ${NC}"
}

show_banner
while true; do
    show_menu
    read -r choice
    case $choice in
        1) add_user ;;
        2) edit_user ;;
        3) delete_user ;;
        4) show_users ;;
        5) change_domain ;;
        6) change_obfs ;;
        7) change_up_speed ;;
        8) change_down_speed ;;
        9) restart_server ;;
        10) uninstall_server; exit ;;
        11) exit ;;
        *) echo -e "${RED}မမှန်ကန်သောရွေးချယ်မှု${NC}" ;;
    esac
    read -p "Enter နှိပ်ပြီး ဆက်လုပ်ပါ..."
done
