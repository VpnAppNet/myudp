#!/bin/bash

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"

mkdir -p "$CONFIG_DIR"
touch "$USER_DB"

# ===== COLORS =====
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ===== DB INIT + AUTO MIGRATION =====
sqlite3 "$USER_DB" <<'EOF'
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password TEXT
);
EOF

HAS_EXPIRE=$(sqlite3 "$USER_DB" "PRAGMA table_info(users);" | awk -F'|' '{print $2}' | grep -c expire_date)
if [[ "$HAS_EXPIRE" -eq 0 ]]; then
    sqlite3 "$USER_DB" "ALTER TABLE users ADD COLUMN expire_date TEXT DEFAULT '2099-12-31';"
fi

# ===== CORE FUNCTIONS =====
fetch_users() {
    sqlite3 "$USER_DB" \
    "SELECT username || ':' || password FROM users WHERE date(expire_date) >= date('now');" | paste -sd, -
}

update_userpass_config() {
    users=$(fetch_users)
    user_array=$(echo "$users" | awk -F, '{for(i=1;i<=NF;i++) printf "\"" $i "\"" ((i==NF) ? "" : ",")}')
    jq ".auth.config = [$user_array]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

restart_server() {
    systemctl restart hysteria-server
    echo -e "${GREEN}✔ ဆာဗာကို ပြန်စတင်ပြီးပါပြီ${NC}"
}

add_user() {
    echo -e "${CYAN}အသုံးပြုသူအမည် :${NC}"
    read -r username
    echo -e "${CYAN}စကားဝှက် :${NC}"
    read -r password
    echo -e "${CYAN}သုံးမည့်ရက်အရေအတွက် (Days):${NC}"
    read -r days
    expire_date=$(date -d "+$days days" +"%Y-%m-%d")

    sqlite3 "$USER_DB" "
    INSERT OR REPLACE INTO users (username,password,expire_date)
    VALUES ('$username','$password','$expire_date');
    "
    update_userpass_config
    restart_server
}

edit_user() {
    echo -e "${CYAN}ပြင်မည့် Username :${NC}"
    read -r u
    echo -e "${CYAN}စကားဝှက်အသစ် :${NC}"
    read -r p
    echo -e "${CYAN}ထပ်တိုးမည့်ရက် (Days):${NC}"
    read -r d
    exp=$(date -d "+$d days" +"%Y-%m-%d")
    sqlite3 "$USER_DB" \
    "UPDATE users SET password='$p', expire_date='$exp' WHERE username='$u';"
    update_userpass_config
    restart_server
}

delete_user() {
    echo -e "${CYAN}ဖျက်မည့် Username :${NC}"
    read -r u
    sqlite3 "$USER_DB" "DELETE FROM users WHERE username='$u';"
    update_userpass_config
    restart_server
}

show_users() {
    echo -e "${CYAN}USERNAME | PASSWORD | EXPIRE DATE${NC}"
    echo "------------------------------------------"
    sqlite3 "$USER_DB" "SELECT username,password,expire_date FROM users;"
}

change_domain() {
    echo -e "${CYAN}ဒိုမိန်းအသစ် :${NC}"
    read -r d
    jq ".server = \"$d\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

change_obfs() {
    echo -e "${CYAN}Obfs Password အသစ် :${NC}"
    read -r o
    jq ".obfs.password = \"$o\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

change_up_speed() {
    echo -e "${CYAN}Upload Speed (Mbps) :${NC}"
    read -r u
    jq ".up_mbps=$u" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

change_down_speed() {
    echo -e "${CYAN}Download Speed (Mbps) :${NC}"
    read -r d
    jq ".down_mbps=$d" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    restart_server
}

# ===== BANNER =====
banner_frame_1() {
echo -e "${CYAN}──╔╦╗─╔╦═══╗${NC}"
echo -e "${GREEN}──║║║─║║╔══╝${NC}"
echo -e "${YELLOW}──║║║─║║╚══╗${NC}"
echo -e "${CYAN}╔╗║║║─║║╔══╝${NC}"
echo -e "${GREEN}║╚╝║╚═╝║╚══╗${NC}"
echo -e "${YELLOW}╚══╩═══╩═══╝${NC}"
echo -e "${YELLOW}        🅙🅤🅔-${CYAN}🅤🅓🅟${NC}"
}

banner_frame_2() {
echo -e "${YELLOW}╔╗─╔╦═══╦═══╗${NC}"
echo -e "${CYAN}║║─║╠╗╔╗║╔═╗║${NC}"
echo -e "${GREEN}║║─║║║║║║╚═╝║${NC}"
echo -e "${YELLOW}║║─║║║║║║╔══╝${NC}"
echo -e "${CYAN}║╚═╝╠╝╚╝║║${NC}"
echo -e "${GREEN}╚═══╩═══╩╝${NC}"
echo -e "${GREEN}        🅙🅤🅔-${YELLOW}🅤🅓🅟${NC}"
}

show_banner() {
clear; banner_frame_1; sleep 0.15
clear; banner_frame_2; sleep 0.15
clear; banner_frame_1
}

# ===== FULL MENU =====
show_menu() {
echo -e "${YELLOW}"
echo "┌──────────────────────────────┐"
echo "│ 1. အကောင့်အသစ်ဖွင့်မည်        │"
echo "│ 2. စကားဝှက် / Expired ပြင်မည် │"
echo "│ 3. အကောင့်ဖျက်မည်             │"
echo "│ 4. အကောင့်စာရင်းကြည့်မည်      │"
echo "│ 5. ဒိုမိန်းပြန်ပြင်မည်         │"
echo "│ 6. Obfs ပြင်မည်               │"
echo "│ 7. Upload Speed ပြင်မည်       │"
echo "│ 8. Download Speed ပြင်မည်     │"
echo "│ 9. ဆာဗာပြန်စတင်မည်            │"
echo "│10. ထွက်မည်                   │"
echo "└──────────────────────────────┘"
echo -e "ရွေးချယ်ပါ ➜ ${NC}"
}

# ===== MAIN =====
show_banner
while true; do
    show_menu
    read -r c
    case $c in
        1) add_user ;;
        2) edit_user ;;
        3) delete_user ;;
        4) show_users ;;
        5) change_domain ;;
        6) change_obfs ;;
        7) change_up_speed ;;
        8) change_down_speed ;;
        9) restart_server ;;
        10) exit ;;
        *) echo -e "${RED}မမှန်ကန်သောရွေးချယ်မှု${NC}" ;;
    esac
    read -p "Enter နှိပ်ပြီး ဆက်လုပ်ပါ..."
done
