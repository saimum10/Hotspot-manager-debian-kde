#!/bin/bash

# ═══════════════════════════════════════════════════════════
#   HOTSPOT MANAGER — Saimum | Debian
# ═══════════════════════════════════════════════════════════

CONF_FILE="/etc/hotspot-manager.conf"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"
WHITELIST_FILE="/etc/hostapd/whitelist.conf"
BLACKLIST_FILE="/etc/hostapd/blacklist.conf"
LEASES_FILE="/var/lib/misc/dnsmasq.leases"
WIFI_IFACE="wlo1"
INET_IFACE="enp3s0"
HOTSPOT_IP="192.168.50.1"
DHCP_RANGE="192.168.50.2,192.168.50.20,255.255.255.0,24h"
SHOW_PASS=false
SLEEP_INHIBIT_PID_FILE="/tmp/hotspot-sleep-inhibit.pid"
SLEEP_MONITOR_PID_FILE="/tmp/hotspot-sleep-monitor.pid"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[1m';   D='\033[0m'
W='\033[1;37m'; M='\033[0;35m'

# ─── CLEAN EXIT ───────────────────────────────────────────
clean_exit() {
    echo -e "\n\n  ${C}Goodbye!${D}\n"
    exit 0
}
trap clean_exit SIGINT SIGTERM

# ─── LOAD CONFIG ──────────────────────────────────────────
load_config() {
    SSID="MyHotspot"
    PASSWORD="12345678"
    HIDDEN_SSID=false
    BAND="2.4"
    WHITELIST_ENABLED=false
    BLOCK_SLEEP=false
    SUDO_NOPASS=false
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
}

# ─── SAVE CONFIG ──────────────────────────────────────────
save_config() {
    sudo bash -c "cat > $CONF_FILE" <<EOF
SSID="$SSID"
PASSWORD="$PASSWORD"
HIDDEN_SSID=${HIDDEN_SSID:-false}
BAND="${BAND:-2.4}"
WHITELIST_ENABLED=${WHITELIST_ENABLED:-false}
BLOCK_SLEEP=${BLOCK_SLEEP:-false}
SUDO_NOPASS=${SUDO_NOPASS:-false}
EOF
}

# ─── BAND SETTINGS ────────────────────────────────────────
get_band_settings() {
    if [[ "${BAND:-2.4}" == "5" ]]; then
        HW_MODE="a"; CHANNEL="36"
    else
        HW_MODE="g"; CHANNEL="6"
    fi
}

# ─── GET STATUS ───────────────────────────────────────────
get_status() {
    HOTSPOT_ACTIVE=false
    IP_DISP="${R}N/A${D}"
    CLIENTS=0
    UPTIME_STR="--"

    if systemctl is-active --quiet hostapd 2>/dev/null; then
        if ip addr show "$WIFI_IFACE" 2>/dev/null | grep -q "$HOTSPOT_IP"; then
            HOTSPOT_ACTIVE=true
            IP_DISP="${G}$HOTSPOT_IP${D}"
            CLIENTS=$(iw dev "$WIFI_IFACE" station dump 2>/dev/null | grep -c "^Station" || echo 0)
            START=$(systemctl show hostapd --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
            if [[ -n "$START" ]]; then
                SE=$(date -d "$START" +%s 2>/dev/null)
                NE=$(date +%s)
                DIF=$((NE - SE))
                UPTIME_STR=$(printf '%dh %02dm' $((DIF/3600)) $((DIF%3600/60)))
            fi
        fi
    fi

    $HOTSPOT_ACTIVE && STATUS_TEXT="${G}● ON${D}" || STATUS_TEXT="${R}● OFF${D}"
    ${WHITELIST_ENABLED:-false} && WL_STATUS="${R}LOCKED${D}" || WL_STATUS="${G}OPEN${D}"
    ${HIDDEN_SSID:-false} && VIS_STATUS="${Y}Hidden${D}" || VIS_STATUS="${G}Visible${D}"

    # Permanent mode status
    if systemctl is-enabled --quiet hotspot-startup.service 2>/dev/null; then
        PERM_STATUS="${G}ON${D}"
    else
        PERM_STATUS="${R}OFF${D}"
    fi

    # Sleep block status
    if [[ -f "$SLEEP_INHIBIT_PID_FILE" ]]; then
        local spid; spid=$(cat "$SLEEP_INHIBIT_PID_FILE" 2>/dev/null)
        if [[ -n "$spid" ]] && kill -0 "$spid" 2>/dev/null; then
            SLEEP_BLOCK_STATUS="${G}ON${D}"
        else
            rm -f "$SLEEP_INHIBIT_PID_FILE"
            rm -f "$SLEEP_MONITOR_PID_FILE" 2>/dev/null
            SLEEP_BLOCK_STATUS="${R}OFF${D}"
        fi
    else
        SLEEP_BLOCK_STATUS="${R}OFF${D}"
    fi
}

# ─── MASK PASSWORD ────────────────────────────────────────
mask_password() {
    $SHOW_PASS && echo "$PASSWORD" || echo "${PASSWORD//?/*}"
}

# ─── COLOR-AWARE PADDING ──────────────────────────────────
pad_right() {
    local str="$1" width="$2"
    local visible; visible=$(printf '%s' "$str" | sed 's/\x1b\[[0-9;]*m//g' | wc -m)
    local spaces=$(( width - visible ))
    [[ $spaces -lt 0 ]] && spaces=0
    printf "%s%${spaces}s" "$str" ""
}

# ─── WRITE HOSTAPD CONF ───────────────────────────────────
write_hostapd_conf() {
    get_band_settings
    local hidden=0
    ${HIDDEN_SSID:-false} && hidden=1

    local acl_block=""
    if ${WHITELIST_ENABLED:-false}; then
        acl_block="macaddr_acl=1
accept_mac_file=$WHITELIST_FILE"
    elif [[ -f "$BLACKLIST_FILE" ]] && [[ -s "$BLACKLIST_FILE" ]]; then
        acl_block="macaddr_acl=0
deny_mac_file=$BLACKLIST_FILE"
    fi

    sudo bash -c "cat > $HOSTAPD_CONF" <<EOF
interface=$WIFI_IFACE
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
utf8_ssid=1
ssid=$SSID
hw_mode=$HW_MODE
channel=$CHANNEL
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ignore_broadcast_ssid=$hidden
$acl_block
EOF
}

# ─── WRITE DNSMASQ CONF ───────────────────────────────────
write_dnsmasq_conf() {
    sudo bash -c "cat > $DNSMASQ_CONF" <<EOF
interface=$WIFI_IFACE
bind-interfaces
dhcp-range=$DHCP_RANGE
EOF
}

# ─── SLEEP BLOCK ──────────────────────────────────────────
enable_sleep_block() {
    # hotspot না চললে sleep block enable হবে না
    if ! systemctl is-active --quiet hostapd 2>/dev/null; then
        echo -e "  ${R}[!] Hotspot চালু নেই — Sleep block enable করা যাবে না।${D}"
        return 1
    fi
    if [[ -f "$SLEEP_INHIBIT_PID_FILE" ]]; then
        local spid; spid=$(cat "$SLEEP_INHIBIT_PID_FILE" 2>/dev/null)
        kill -0 "$spid" 2>/dev/null && return
        rm -f "$SLEEP_INHIBIT_PID_FILE"
    fi
    if ! command -v systemd-inhibit &>/dev/null; then
        echo -e "  ${R}[!] systemd-inhibit পাওয়া যায়নি।${D}"
        return 1
    fi
    # nohup+setsid+disown — সব terminal এ process বেঁচে থাকবে
    nohup setsid systemd-inhibit --what=sleep:idle --who="Hotspot Manager" \
        --why="Hotspot is active" sleep infinity >/dev/null 2>&1 &
    local inh_pid=$!
    disown $inh_pid
    echo "$inh_pid" > "$SLEEP_INHIBIT_PID_FILE"
    _start_sleep_monitor
}

# ─── SLEEP MONITOR (background) ───────────────────────────
# device না থাকলে ৩ মিনিট পর sleep block auto-off
_start_sleep_monitor() {
    # পুরনো monitor বন্ধ করো
    if [[ -f "$SLEEP_MONITOR_PID_FILE" ]]; then
        kill "$(cat "$SLEEP_MONITOR_PID_FILE" 2>/dev/null)" 2>/dev/null
        rm -f "$SLEEP_MONITOR_PID_FILE"
    fi
    # Monitor script লেখো
    cat > /tmp/hotspot-sleep-monitor.sh << MONEOF
#!/bin/bash
IDLE_COUNT=0
INHIBIT_FILE="$SLEEP_INHIBIT_PID_FILE"
MONITOR_FILE="$SLEEP_MONITOR_PID_FILE"
IFACE="$WIFI_IFACE"
while true; do
    sleep 60
    [[ ! -f "\$INHIBIT_FILE" ]] && exit 0
    spid=\$(cat "\$INHIBIT_FILE" 2>/dev/null)
    kill -0 "\$spid" 2>/dev/null || { rm -f "\$INHIBIT_FILE" "\$MONITOR_FILE"; exit 0; }
    # hotspot বন্ধ হলে সাথে সাথে sleep block off
    systemctl is-active --quiet hostapd 2>/dev/null || {
        kill "\$spid" 2>/dev/null
        rm -f "\$INHIBIT_FILE" "\$MONITOR_FILE" /tmp/hotspot-sleep-monitor.sh
        exit 0
    }
    clients=\$(iw dev "\$IFACE" station dump 2>/dev/null | grep -c "^Station" || echo 0)
    if [[ "\$clients" -eq 0 ]]; then
        IDLE_COUNT=\$((IDLE_COUNT + 1))
        if [[ \$IDLE_COUNT -ge 3 ]]; then
            kill "\$spid" 2>/dev/null
            rm -f "\$INHIBIT_FILE" "\$MONITOR_FILE" /tmp/hotspot-sleep-monitor.sh
            exit 0
        fi
    else
        IDLE_COUNT=0
    fi
done
MONEOF
    chmod +x /tmp/hotspot-sleep-monitor.sh
    nohup setsid bash /tmp/hotspot-sleep-monitor.sh >/dev/null 2>&1 &
    local mon_pid=$!
    disown $mon_pid
    echo "$mon_pid" > "$SLEEP_MONITOR_PID_FILE"
}

disable_sleep_block() {
    # Monitor বন্ধ
    if [[ -f "$SLEEP_MONITOR_PID_FILE" ]]; then
        kill "$(cat "$SLEEP_MONITOR_PID_FILE" 2>/dev/null)" 2>/dev/null
        rm -f "$SLEEP_MONITOR_PID_FILE"
    fi
    rm -f /tmp/hotspot-sleep-monitor.sh
    # Inhibitor বন্ধ
    if [[ -f "$SLEEP_INHIBIT_PID_FILE" ]]; then
        local spid; spid=$(cat "$SLEEP_INHIBIT_PID_FILE" 2>/dev/null)
        [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
        rm -f "$SLEEP_INHIBIT_PID_FILE"
    fi
}

toggle_sleep_block() {
    if [[ -f "$SLEEP_INHIBIT_PID_FILE" ]]; then
        local spid; spid=$(cat "$SLEEP_INHIBIT_PID_FILE" 2>/dev/null)
        if [[ -n "$spid" ]] && kill -0 "$spid" 2>/dev/null; then
            disable_sleep_block
            BLOCK_SLEEP=false; save_config
            echo -e "\n  ${Y}[✓] Sleep block বন্ধ — PC এখন স্বাভাবিক sleep করবে।${D}"
            sleep 1.5; return
        fi
        rm -f "$SLEEP_INHIBIT_PID_FILE"
    fi
    enable_sleep_block || { sleep 1.5; return; }
    BLOCK_SLEEP=true; save_config
    echo -e "\n  ${G}[✓] Sleep block চালু — Hotspot ON থাকলে PC sleep যাবে না।${D}"
    sleep 1.5
}

# ─── HEADER ───────────────────────────────────────────────
show_header() {
    get_status
    clear
    echo -e "${C}╔══════════════════════════════════════════════════╗${D}"
    echo -e "${C}║${W}     HOTSPOT MANAGER — Saimum | Debian            ${C}║${D}"
    echo -e "${C}╠══════════════════════════════════════════════════╣${D}"
    echo -e "${C}║${D}  Status  : $(pad_right "$STATUS_TEXT" 38)${C}║${D}"
    echo -e "${C}║${D}  IP      : $(pad_right "$IP_DISP" 38)${C}║${D}"
    printf "${C}║${D}  Clients : ${Y}%-2s${D}  Uptime: ${Y}%-27s${C}║${D}\n" "$CLIENTS" "$UPTIME_STR"
    printf "${C}║${D}  SSID    : ${B}%-38s${D}${C}║${D}\n" "$SSID"
    printf "${C}║${D}  Pass    : ${M}%-38s${D}${C}║${D}\n" "$(mask_password)"
    echo -e "${C}║${D}  Band : ${Y}${BAND:-2.4}GHz${D}  Vis: $(pad_right "$VIS_STATUS" 10)  Access: $(pad_right "$WL_STATUS" 8)${C}║${D}"
    echo -e "${C}║${D}  Permanent  : $(pad_right "$PERM_STATUS" 8)  Sleep Block : $(pad_right "$SLEEP_BLOCK_STATUS" 11)${C}║${D}"
    echo -e "${C}╚══════════════════════════════════════════════════╝${D}"
    echo ""
}

# ─── MENU ─────────────────────────────────────────────────
show_menu() {
    echo -e "  ${B}1.${D}  Start Hotspot"
    echo -e "  ${B}2.${D}  Stop Hotspot"
    echo -e "  ${B}3.${D}  Make Permanent     ${Y}(survive reboot)${D}"
    echo -e "  ${B}4.${D}  Reset Permanent    ${Y}(back to manual)${D}"
    echo -e "  ${B}5.${D}  Schedule           ${C}(auto on/off + idle timeout)${D}"
    echo -e "  ${B}6.${D}  Setup              ${C}(install / sudo password)${D}"
    echo -e "  ${B}7.${D}  Edit Network       ${C}(name / pass / visibility / band)${D}"
    echo -e "  ${B}8.${D}  Create New Network"
    echo -e "  ${B}9.${D}  Delete Network"
    echo -e "  ${B}10.${D} Connected Devices  ${C}(IP / hostname / data / kick)${D}"
    echo -e "  ${B}11.${D} Bandwidth Monitor  ${C}(real-time)${D}"
    echo -e "  ${B}12.${D} Whitelist Mode"
    echo -e "  ${B}13.${D} Toggle Password Visibility"
    echo -e "  ${B}14.${D} QR Code"
    echo -e "  ${B}0.${D}  Exit"
    echo ""
}

# ─── PICK BAND (no card check) ────────────────────────────
pick_band() {
    echo "  Band:"
    echo "    1) 2.4 GHz  (default, wider range)"
    echo "    2) 5 GHz    (faster, shorter range)"
    read -rp "  Choice (Enter to keep [${BAND:-2.4}GHz]): " bc
    case "$bc" in
        1) BAND="2.4" ;;
        2) BAND="5" ;;
    esac
}

# ─── PICK VISIBILITY ──────────────────────────────────────
pick_visibility() {
    echo "  SSID Visibility:"
    echo "    1) Visible  — broadcasts name (normal)"
    echo "    2) Hidden   — not broadcast; device must connect manually"
    local cur; ${HIDDEN_SSID:-false} && cur="Hidden" || cur="Visible"
    read -rp "  Choice (Enter to keep [$cur]): " vc
    case "$vc" in
        1) HIDDEN_SSID=false ;;
        2) HIDDEN_SSID=true  ;;
    esac
}

# ─── GET IP/HOSTNAME FROM LEASES ──────────────────────────
get_client_info() {
    local mac="${1,,}"
    local ip="N/A" hostname="unknown"
    if [[ -f "$LEASES_FILE" ]]; then
        local line
        line=$(grep -i "$mac" "$LEASES_FILE" 2>/dev/null | head -1)
        if [[ -n "$line" ]]; then
            ip=$(echo "$line" | awk '{print $3}')
            hostname=$(echo "$line" | awk '{print $4}')
            [[ "$hostname" == "*" || -z "$hostname" ]] && hostname="unknown"
        fi
    fi
    # Guess device type from hostname
    local device_type=""
    local hn_lower="${hostname,,}"
    if [[ "$hn_lower" =~ android ]]; then device_type="Android"
    elif [[ "$hn_lower" =~ iphone ]]; then device_type="iPhone"
    elif [[ "$hn_lower" =~ ipad ]]; then device_type="iPad"
    elif [[ "$hn_lower" =~ windows|win ]]; then device_type="Windows PC"
    elif [[ "$hn_lower" =~ mac|apple ]]; then device_type="Mac"
    elif [[ "$hn_lower" =~ linux ]]; then device_type="Linux"
    fi
    [[ -n "$device_type" ]] && hostname="$hostname ($device_type)"
    echo "$ip|$hostname"
}

# ═══════════════════════════════════════════════════════════
# 1 — START
# ═══════════════════════════════════════════════════════════
start_hotspot() {
    echo ""
    echo -e "${Y}[*] Starting hotspot...${D}"
    write_hostapd_conf
    write_dnsmasq_conf
    sudo nmcli device set "$WIFI_IFACE" managed no 2>/dev/null
    sudo ip link set "$WIFI_IFACE" up
    sudo ip addr add "$HOTSPOT_IP/24" dev "$WIFI_IFACE" 2>/dev/null
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sudo iptables -t nat -D POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null
    sudo iptables -t nat -A POSTROUTING -o "$INET_IFACE" -j MASQUERADE
    sudo systemctl restart hostapd
    sudo systemctl restart dnsmasq
    sleep 1
    if systemctl is-active --quiet hostapd && ip addr show "$WIFI_IFACE" | grep -q "$HOTSPOT_IP"; then
        local note=""
        ${HIDDEN_SSID:-false} && note=" ${Y}[Hidden — manual connect required]${D}"
        echo -e "${G}[✓] Hotspot started! SSID: $SSID | Band: ${BAND:-2.4}GHz${D}${note}"
        ${BLOCK_SLEEP:-false} && enable_sleep_block
    else
        echo -e "${R}[✗] Failed. Check: sudo journalctl -u hostapd -n 20${D}"
    fi
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# 2 — STOP
# ═══════════════════════════════════════════════════════════
stop_hotspot() {
    echo ""
    echo -e "${Y}[*] Stopping hotspot...${D}"
    sudo systemctl stop hostapd
    sudo systemctl stop dnsmasq
    sudo ip addr del "$HOTSPOT_IP/24" dev "$WIFI_IFACE" 2>/dev/null
    sudo iptables -t nat -F POSTROUTING 2>/dev/null
    sudo nmcli device set "$WIFI_IFACE" managed yes 2>/dev/null
    disable_sleep_block
    echo -e "${G}[✓] Hotspot stopped.${D}"
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# 3 — MAKE PERMANENT
# ═══════════════════════════════════════════════════════════
make_permanent() {
    echo ""
    echo -e "${Y}[*] Enabling permanent hotspot on boot...${D}"
    sudo bash -c "cat > /usr/local/bin/hotspot-startup.sh" <<EOF
#!/bin/bash
sleep 5
nmcli device set $WIFI_IFACE managed no 2>/dev/null
ip link set $WIFI_IFACE up
ip addr add $HOTSPOT_IP/24 dev $WIFI_IFACE 2>/dev/null
sysctl -w net.ipv4.ip_forward=1 > /dev/null
iptables -t nat -D POSTROUTING -o $INET_IFACE -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -o $INET_IFACE -j MASQUERADE
systemctl restart hostapd
systemctl restart dnsmasq
EOF
    sudo chmod +x /usr/local/bin/hotspot-startup.sh
    sudo bash -c "cat > /etc/systemd/system/hotspot-startup.service" <<EOF
[Unit]
Description=Hotspot Network Startup
After=network.target NetworkManager.service hostapd.service dnsmasq.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hotspot-startup.sh
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
    # Sleep/resume: systemd service (reliable) + legacy hook (fallback)
    sudo mkdir -p /etc/systemd/system-sleep
    sudo bash -c "cat > /etc/systemd/system-sleep/hotspot-resume.sh" <<EOF
#!/bin/bash
case "\$1" in
    post) sleep 5 && /usr/local/bin/hotspot-startup.sh & ;;
esac
EOF
    sudo chmod +x /etc/systemd/system-sleep/hotspot-resume.sh
    sudo bash -c "cat > /etc/systemd/system/hotspot-resume.service" <<EOF
[Unit]
Description=Hotspot Restore after Sleep/Resume
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/bin/bash -c 'sleep 4 && /usr/local/bin/hotspot-startup.sh'

[Install]
WantedBy=sleep.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable hotspot-resume.service > /dev/null 2>&1

    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable hotspot-startup.service > /dev/null 2>&1
    sudo systemctl enable hostapd > /dev/null 2>&1
    sudo systemctl enable dnsmasq > /dev/null 2>&1
    if command -v netfilter-persistent &>/dev/null; then
        sudo netfilter-persistent save > /dev/null 2>&1
    else
        sudo apt-get install -y iptables-persistent > /dev/null 2>&1
        sudo netfilter-persistent save > /dev/null 2>&1
    fi
    echo -e "${G}[✓] Hotspot will auto-start on every boot.${D}"
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# 4 — RESET PERMANENT
# ═══════════════════════════════════════════════════════════
reset_permanent() {
    echo ""
    echo -e "${Y}[*] Removing permanent config...${D}"
    sudo systemctl disable hotspot-startup.service 2>/dev/null
    sudo systemctl disable hostapd 2>/dev/null
    sudo systemctl disable dnsmasq 2>/dev/null
    sudo rm -f /etc/systemd/system/hotspot-startup.service
    sudo rm -f /usr/local/bin/hotspot-startup.sh
    sudo rm -f /etc/systemd/system-sleep/hotspot-resume.sh
    sudo systemctl disable hotspot-resume.service 2>/dev/null
    sudo rm -f /etc/systemd/system/hotspot-resume.service
    sudo sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    command -v netfilter-persistent &>/dev/null && sudo netfilter-persistent flush 2>/dev/null
    sudo systemctl daemon-reload
    echo -e "${G}[✓] Permanent mode removed.${D}"
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# 5 — SCHEDULE
# ═══════════════════════════════════════════════════════════
manage_schedule() {
    while true; do
        clear
        echo -e "${C}╔══════════════════════════════════════════════════╗${D}"
        echo -e "${C}║${W}             Schedule — Auto On / Off             ${C}║${D}"
        echo -e "${C}╚══════════════════════════════════════════════════╝${D}"
        echo ""

        ON_CRON=$(sudo crontab -l 2>/dev/null | grep "# hotspot-on$")
        OFF_CRON=$(sudo crontab -l 2>/dev/null | grep "# hotspot-off$")
        IDLE_CRON=$(sudo crontab -l 2>/dev/null | grep "# hotspot-idle")

        if [[ -n "$ON_CRON" ]]; then
            ON_M=$(echo "$ON_CRON" | awk '{print $1}')
            ON_H=$(echo "$ON_CRON" | awk '{print $2}')
            printf "  Auto ON      : ${G}%02d:%02d${D}\n" "$ON_H" "$ON_M"
        else
            echo -e "  Auto ON      : ${Y}Not set${D}"
        fi

        if [[ -n "$OFF_CRON" ]]; then
            OFF_M=$(echo "$OFF_CRON" | awk '{print $1}')
            OFF_H=$(echo "$OFF_CRON" | awk '{print $2}')
            printf "  Auto OFF     : ${R}%02d:%02d${D}\n" "$OFF_H" "$OFF_M"
        else
            echo -e "  Auto OFF     : ${Y}Not set${D}"
        fi

        if [[ -n "$IDLE_CRON" ]]; then
            IDLE_MINS=$(echo "$IDLE_CRON" | grep -oP '\d+ min' | grep -oP '\d+')
            echo -e "  Idle timeout : ${Y}${IDLE_MINS} min (no devices → auto off)${D}"
        else
            echo -e "  Idle timeout : ${Y}Not set${D}"
        fi

        if [[ -f "$SLEEP_INHIBIT_PID_FILE" ]]; then
            local spid; spid=$(cat "$SLEEP_INHIBIT_PID_FILE" 2>/dev/null)
            if [[ -n "$spid" ]] && kill -0 "$spid" 2>/dev/null; then
                echo -e "  Sleep block  : ${G}ON — PC ঘুমাবে না${D}"
            else
                rm -f "$SLEEP_INHIBIT_PID_FILE"
                echo -e "  Sleep block  : ${R}OFF${D}"
            fi
        else
            echo -e "  Sleep block  : ${R}OFF${D}"
        fi

        echo ""
        echo -e "  ${B}1.${D} Set Auto ON  time"
        echo -e "  ${B}2.${D} Set Auto OFF time"
        echo -e "  ${B}3.${D} Set Idle Timeout  ${C}(auto-off if no devices)${D}"
        echo -e "  ${B}4.${D} Clear all schedules"
        echo -e "  ${B}5.${D} Toggle Sleep Block  ${C}(hotspot ON থাকলে PC sleep যাবে না)${D}"
        echo -e "  ${B}0.${D} Back"
        echo ""
        read -rp "  Choice: " sc

        case "$sc" in
            1)
                read -rp "  ON — Hour   (0-23): " sh
                read -rp "  ON — Minute (0-59): " sm
                if [[ "$sh" =~ ^[0-9]+$ && "$sm" =~ ^[0-9]+$ && $sh -le 23 && $sm -le 59 ]]; then
                    (sudo crontab -l 2>/dev/null | grep -v "# hotspot-on$") | sudo crontab -
                    CMD="nmcli device set $WIFI_IFACE managed no; ip link set $WIFI_IFACE up; ip addr add $HOTSPOT_IP/24 dev $WIFI_IFACE 2>/dev/null; sysctl -w net.ipv4.ip_forward=1>/dev/null; iptables -t nat -A POSTROUTING -o $INET_IFACE -j MASQUERADE 2>/dev/null; systemctl restart hostapd; systemctl restart dnsmasq"
                    (sudo crontab -l 2>/dev/null; echo "$sm $sh * * * bash -c '$CMD' # hotspot-on") | sudo crontab -
                    printf "  ${G}[✓] Auto ON set to %02d:%02d${D}\n" "$sh" "$sm"
                else
                    echo -e "  ${R}Invalid time.${D}"
                fi
                sleep 1.5 ;;
            2)
                read -rp "  OFF — Hour   (0-23): " sh
                read -rp "  OFF — Minute (0-59): " sm
                if [[ "$sh" =~ ^[0-9]+$ && "$sm" =~ ^[0-9]+$ && $sh -le 23 && $sm -le 59 ]]; then
                    (sudo crontab -l 2>/dev/null | grep -v "# hotspot-off$") | sudo crontab -
                    CMD="systemctl stop hostapd; systemctl stop dnsmasq; ip addr del $HOTSPOT_IP/24 dev $WIFI_IFACE 2>/dev/null; nmcli device set $WIFI_IFACE managed yes"
                    (sudo crontab -l 2>/dev/null; echo "$sm $sh * * * bash -c '$CMD' # hotspot-off") | sudo crontab -
                    printf "  ${G}[✓] Auto OFF set to %02d:%02d${D}\n" "$sh" "$sm"
                else
                    echo -e "  ${R}Invalid time.${D}"
                fi
                sleep 1.5 ;;
            3)
                echo ""
                echo "  Idle Timeout — auto-off if no devices connected:"
                echo "    1) 5 minutes"
                echo "    2) 10 minutes"
                echo "    3) 15 minutes"
                echo "    4) 30 minutes"
                read -rp "  Choice: " ic
                case "$ic" in
                    1) IDLE=5 ;;  2) IDLE=10 ;; 3) IDLE=15 ;; 4) IDLE=30 ;;
                    *) echo -e "  ${R}Invalid.${D}"; sleep 1; continue ;;
                esac
                (sudo crontab -l 2>/dev/null | grep -v "# hotspot-idle") | sudo crontab -
                IDLE_CMD="PATH=/sbin:/usr/sbin:/bin:/usr/bin; clients=\$(iw dev $WIFI_IFACE station dump 2>/dev/null | grep -c ^Station); [ \"\$clients\" -eq 0 ] && systemctl stop hostapd && systemctl stop dnsmasq && ip addr del $HOTSPOT_IP/24 dev $WIFI_IFACE 2>/dev/null && nmcli device set $WIFI_IFACE managed yes"
                (sudo crontab -l 2>/dev/null; echo "*/$IDLE * * * * bash -c '$IDLE_CMD' # hotspot-idle ($IDLE min)") | sudo crontab -
                echo -e "  ${G}[✓] Idle timeout set to $IDLE minutes.${D}"
                sleep 1.5 ;;
            4)
                (sudo crontab -l 2>/dev/null | grep -v "# hotspot-on$\|# hotspot-off$\|# hotspot-idle") | sudo crontab -
                echo -e "  ${G}[✓] All schedules cleared.${D}"
                sleep 1.5 ;;
            5) toggle_sleep_block ;;
            0) break ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
# 6 — SETUP
# ═══════════════════════════════════════════════════════════
_install_configure() {
    echo ""
    echo -e "${Y}[*] Running full setup...${D}"
    echo -e "${C}[1/6] Updating package list...${D}"
    sudo apt-get update -qq
    echo -e "${C}[2/6] Installing hostapd, dnsmasq, iptables...${D}"
    sudo apt-get install -y hostapd dnsmasq iptables
    echo -e "${C}[3/6] Installing qrencode...${D}"
    sudo apt-get install -y qrencode
    echo -e "${C}[4/6] Unmasking hostapd...${D}"
    sudo systemctl unmask hostapd
    echo -e "${C}[5/6] Writing configs...${D}"
    write_hostapd_conf
    write_dnsmasq_conf
    echo -e "${C}[6/6] Linking hostapd config...${D}"
    sudo sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
    grep -q 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' /etc/default/hostapd || \
        echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee -a /etc/default/hostapd > /dev/null
    [[ ! -f "$WHITELIST_FILE" ]] && sudo touch "$WHITELIST_FILE"
    [[ ! -f "$BLACKLIST_FILE" ]] && sudo touch "$BLACKLIST_FILE"
    save_config
    echo ""
    echo -e "${G}[✓] Setup complete.${D}"
    echo ""
    read -rp "  Press Enter to continue..."
}

_toggle_sudo_password() {
    echo ""
    # আসল username বের করো (sudo দিয়ে চললেও)
    local REAL_USER
    REAL_USER=$(logname 2>/dev/null || who am i 2>/dev/null | awk '{print $1}')
    if [[ -z "$REAL_USER" ]]; then
        echo -e "  ${R}[✗] আসল username detect করা যায়নি।${D}"
        echo ""
        read -rp "  Press Enter to continue..."
        return
    fi

    local SUDOERS_FILE="/etc/sudoers.d/hotspot-manager"
    local SCRIPT_PATH="/home/${REAL_USER}/.local/bin/hotspot-manager.sh"

    if [[ "${SUDO_NOPASS:-false}" == "true" ]]; then
        # এখন OFF — sudoers file delete করো
        sudo rm -f "$SUDOERS_FILE"
        SUDO_NOPASS=false
        save_config
        echo -e "  ${G}[✓] Password চালু — এখন থেকে sudo password চাইবে।${D}"
    else
        # এখন ON — sudoers file বানাও
        echo "${REAL_USER} ALL=(ALL) NOPASSWD: /bin/bash ${SCRIPT_PATH}" | \
            sudo tee "$SUDOERS_FILE" > /dev/null
        # syntax check — ভুল থাকলে সাথে সাথে delete করো
        if ! sudo visudo -cf "$SUDOERS_FILE" > /dev/null 2>&1; then
            sudo rm -f "$SUDOERS_FILE"
            echo -e "  ${R}[✗] sudoers syntax error — file delete করা হয়েছে।${D}"
            echo ""
            read -rp "  Press Enter to continue..."
            return
        fi
        sudo chmod 440 "$SUDOERS_FILE"
        SUDO_NOPASS=true
        save_config
        echo -e "  ${G}[✓] Password বন্ধ — এখন থেকে sudo password চাইবে না।${D}"
    fi
    echo ""
    read -rp "  Press Enter to continue..."
}

do_setup() {
    while true; do
        show_header
        echo -e "  ${B}─── Setup ────────────────────────────────────${D}"
        echo ""
        local pass_status
        [[ "${SUDO_NOPASS:-false}" == "true" ]] && pass_status="${R}OFF${D}" || pass_status="${G}ON${D}"
        echo -e "  ${B}1.${D}  Install & Configure   ${C}(packages, hostapd, dnsmasq)${D}"
        echo -e "  ${B}2.${D}  Sudo Password         ${C}[currently: ${pass_status}${C}]${D}"
        echo ""
        echo -e "  ${B}0.${D}  Back"
        echo ""
        read -rp "  Choice: " sc
        case "$sc" in
            1) _install_configure ;;
            2) _toggle_sudo_password ;;
            0) return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
# 7 — EDIT NETWORK
# ═══════════════════════════════════════════════════════════
edit_network() {
    echo ""
    echo -e "${C}─── Edit Current Network ─────────────────────${D}"
    local cur_vis; ${HIDDEN_SSID:-false} && cur_vis="Hidden" || cur_vis="Visible"
    echo -e "  SSID       : ${B}$SSID${D}"
    echo -e "  Password   : ${M}$(mask_password)${D}"
    echo -e "  Visibility : ${B}$cur_vis${D}"
    echo -e "  Band       : ${Y}${BAND:-2.4}GHz${D}"
    echo ""
    read -rp "  New SSID (Enter to keep [$SSID]): " ns
    [[ -n "$ns" ]] && SSID="$ns"
    read -rsp "  New Password (Enter to keep): " np; echo ""
    [[ -n "$np" ]] && PASSWORD="$np"
    echo ""
    pick_visibility
    pick_band
    save_config
    write_hostapd_conf
    echo ""
    echo -e "${G}[✓] Network updated. Restart hotspot to apply.${D}"
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# 8 — CREATE NEW NETWORK
# ═══════════════════════════════════════════════════════════
create_network() {
    echo ""
    echo -e "${C}─── Create New Hotspot Network ───────────────${D}"
    echo -e "  ${Y}(Replaces current stored network)${D}"
    echo ""
    read -rp "  Network Name (SSID): " ns
    read -rsp "  Password (min 8 chars): " np; echo ""
    if [[ ${#ns} -eq 0 ]]; then
        echo -e "${R}[✗] SSID cannot be empty.${D}"
    elif [[ ${#np} -lt 8 ]]; then
        echo -e "${R}[✗] Password too short (min 8 chars).${D}"
    else
        SSID="$ns"; PASSWORD="$np"
        echo ""
        pick_visibility
        pick_band
        save_config
        write_hostapd_conf
        echo ""
        echo -e "${G}[✓] Network '$SSID' created. Use option 1 to start.${D}"
    fi
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# 9 — DELETE NETWORK
# ═══════════════════════════════════════════════════════════
delete_network() {
    echo ""
    echo -e "${R}─── Delete Hotspot Network ───────────────────${D}"
    echo -e "  ${R}[!] Stops hotspot and deletes all config.${D}"
    echo ""
    read -rp "  Type 'yes' to confirm: " confirm
    if [[ "$confirm" == "yes" ]]; then
        sudo systemctl stop hostapd 2>/dev/null
        sudo systemctl stop dnsmasq 2>/dev/null
        sudo ip addr del "$HOTSPOT_IP/24" dev "$WIFI_IFACE" 2>/dev/null
        sudo iptables -t nat -F POSTROUTING 2>/dev/null
        sudo nmcli device set "$WIFI_IFACE" managed yes 2>/dev/null
        sudo rm -f "$HOSTAPD_CONF" "$CONF_FILE" "$WHITELIST_FILE" "$BLACKLIST_FILE"
        SSID="MyHotspot"; PASSWORD="12345678"
        HIDDEN_SSID=false; BAND="2.4"; WHITELIST_ENABLED=false
        echo -e "${G}[✓] Network deleted. Run Setup (6) to reconfigure.${D}"
    else
        echo -e "${Y}  Cancelled.${D}"
    fi
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# 10 — CONNECTED DEVICES (IP, hostname, data, kick/ban)
# ═══════════════════════════════════════════════════════════
show_devices() {
    while true; do
        clear
        echo -e "${C}╔══════════════════════════════════════════════════╗${D}"
        echo -e "${C}║${W}              Connected Devices                   ${C}║${D}"
        echo -e "${C}╚══════════════════════════════════════════════════╝${D}"
        echo ""

        local dump
        dump=$(iw dev "$WIFI_IFACE" station dump 2>/dev/null)

        if [[ -z "$dump" ]]; then
            echo -e "  ${Y}No devices currently connected.${D}"
            echo ""
            read -rp "  Press Enter to go back..."
            return
        fi

        declare -a MACS=()
        local count=0 mac="" cur_tx=0 cur_rx=0

        while IFS= read -r line; do
            if [[ "$line" =~ ^Station ]]; then
                (( count++ ))
                mac=$(echo "$line" | awk '{print $2}')
                MACS+=("$mac")

                local info; info=$(get_client_info "$mac")
                local ip; ip=$(echo "$info" | cut -d'|' -f1)
                local hostname; hostname=$(echo "$info" | cut -d'|' -f2)

                echo -e "  ${G}[$count]${D} MAC     : ${B}$mac${D}"
                echo -e "      IP      : ${C}$ip${D}"
                echo -e "      Device  : ${W}$hostname${D}"
            elif [[ "$line" =~ "signal:" ]]; then
                local sig; sig=$(echo "$line" | awk '{print $2, $3}')
                echo -e "      Signal  : $sig"
            elif [[ "$line" =~ "tx bytes:" ]]; then
                cur_tx=$(echo "$line" | awk '{print $3}')
            elif [[ "$line" =~ "rx bytes:" ]]; then
                cur_rx=$(echo "$line" | awk '{print $3}')
                local tx_m rx_m
                tx_m=$(awk "BEGIN{printf \"%.2f\",$cur_tx/1048576}")
                rx_m=$(awk "BEGIN{printf \"%.2f\",$cur_rx/1048576}")
                echo -e "      Data    : ${Y}↑ ${tx_m}MB TX${D}  ${C}↓ ${rx_m}MB RX${D}"
                echo ""
            fi
        done <<< "$dump"

        echo -e "  Total: ${Y}$count${D} device(s)"
        echo ""
        echo -e "  ${B}K.${D} Kick + Ban a device"
        echo -e "  ${B}R.${D} Refresh"
        echo -e "  ${B}0.${D} Back"
        echo ""
        read -rp "  Choice: " dchoice

        case "${dchoice^^}" in
            K)
                if [[ $count -eq 0 ]]; then
                    echo -e "  ${Y}No devices to kick.${D}"; sleep 1; continue
                fi
                read -rp "  Enter device number to kick+ban [1-$count]: " knum
                if [[ "$knum" =~ ^[0-9]+$ && $knum -ge 1 && $knum -le $count ]]; then
                    local kmac="${MACS[$((knum-1))]}"
                    # Kick via hostapd_cli
                    sudo hostapd_cli -p /var/run/hostapd -i "$WIFI_IFACE" deauthenticate "$kmac" 2>/dev/null || \
                        sudo iw dev "$WIFI_IFACE" station del "$kmac" 2>/dev/null
                    # Add to blacklist
                    [[ ! -f "$BLACKLIST_FILE" ]] && sudo touch "$BLACKLIST_FILE"
                    if ! grep -qi "^$kmac$" "$BLACKLIST_FILE" 2>/dev/null; then
                        echo "$kmac" | sudo tee -a "$BLACKLIST_FILE" > /dev/null
                    fi
                    # Reload hostapd config with updated blacklist
                    write_hostapd_conf
                    sudo systemctl restart hostapd 2>/dev/null
                    echo -e "  ${G}[✓] $kmac kicked and banned.${D}"
                    echo -e "  ${Y}  Device cannot reconnect (blacklisted).${D}"
                else
                    echo -e "  ${R}Invalid selection.${D}"
                fi
                sleep 2 ;;
            R) continue ;;
            0) break ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
# 11 — BANDWIDTH MONITOR
# ═══════════════════════════════════════════════════════════
bandwidth_monitor() {
    clear
    echo -e "${C}╔══════════════════════════════════════════════════╗${D}"
    echo -e "${C}║${W}      Bandwidth Monitor  [Press Q to exit]         ${C}║${D}"
    echo -e "${C}╚══════════════════════════════════════════════════╝${D}"
    declare -A prev_tx prev_rx
    while true; do
        read -t 0.1 -n 1 key && [[ "${key,,}" == "q" ]] && break
        local dump
        dump=$(iw dev "$WIFI_IFACE" station dump 2>/dev/null)
        tput cup 4 0
        tput ed
        if [[ -z "$dump" ]]; then
            echo -e "  ${Y}No devices connected.${D}"
        else
            local count=0 mac="" cur_tx=0 cur_rx=0
            while IFS= read -r line; do
                if [[ "$line" =~ ^Station ]]; then
                    (( count++ ))
                    mac=$(echo "$line" | awk '{print $2}')
                elif [[ "$line" =~ "tx bytes:" ]]; then
                    cur_tx=$(echo "$line" | awk '{print $3}')
                elif [[ "$line" =~ "rx bytes:" ]]; then
                    cur_rx=$(echo "$line" | awk '{print $3}')
                    local dtx drx
                    dtx=$(( cur_tx - ${prev_tx[$mac]:-$cur_tx} ))
                    drx=$(( cur_rx - ${prev_rx[$mac]:-$cur_rx} ))
                    prev_tx[$mac]=$cur_tx; prev_rx[$mac]=$cur_rx
                    local tx_k rx_k tx_m rx_m
                    tx_k=$(awk "BEGIN{printf \"%.1f\",$dtx/1024}")
                    rx_k=$(awk "BEGIN{printf \"%.1f\",$drx/1024}")
                    tx_m=$(awk "BEGIN{printf \"%.2f\",$cur_tx/1048576}")
                    rx_m=$(awk "BEGIN{printf \"%.2f\",$cur_rx/1048576}")
                    local info; info=$(get_client_info "$mac")
                    local hostname; hostname=$(echo "$info" | cut -d'|' -f2 | cut -d'(' -f1 | xargs)
                    printf "  ${G}[%-17s]${D} ${W}%-15s${D}  ↑${Y}%7s KB/s${D}  ↓${C}%7s KB/s${D}  Total:${Y}%6sMB${D}/${C}%6sMB${D}\n" \
                        "$mac" "$hostname" "$tx_k" "$rx_k" "$tx_m" "$rx_m"
                fi
            done <<< "$dump"
            echo ""
            printf "  Devices: ${Y}%s${D}   [Refresh every 1s — Q to exit]\n" "$count"
        fi
        sleep 1
    done
}

# ═══════════════════════════════════════════════════════════
# 12 — WHITELIST
# ═══════════════════════════════════════════════════════════
manage_whitelist() {
    while true; do
        clear
        echo -e "${C}╔══════════════════════════════════════════════════╗${D}"
        echo -e "${C}║${W}                  Whitelist Mode                  ${C}║${D}"
        echo -e "${C}╚══════════════════════════════════════════════════╝${D}"
        echo ""
        local wl_count=0
        [[ -f "$WHITELIST_FILE" ]] && wl_count=$(grep -c . "$WHITELIST_FILE" 2>/dev/null || echo 0)

        if ${WHITELIST_ENABLED:-false}; then
            echo -e "  Status  : ${R}LOCKED${D} — Only whitelisted MACs can connect"
            echo -e "  Allowed : ${Y}$wl_count${D} device(s)"
            echo ""
            echo -e "  ${B}1.${D} ${G}Disable Whitelist${D}"
        else
            echo -e "  Status  : ${G}OPEN${D}   — Any device can connect"
            echo -e "  Listed  : ${Y}$wl_count${D} device(s) in whitelist"
            echo ""
            echo -e "  ${B}1.${D} ${R}Enable Whitelist${D}   (connected devices auto-added)"
        fi
        echo -e "  ${B}2.${D} View whitelist"
        echo -e "  ${B}3.${D} Remove MAC from whitelist"
        echo -e "  ${B}0.${D} Back"
        echo ""
        read -rp "  Choice: " wch

        case "$wch" in
            1)
                if ${WHITELIST_ENABLED:-false}; then
                    WHITELIST_ENABLED=false
                    save_config; write_hostapd_conf
                    sudo systemctl restart hostapd 2>/dev/null
                    echo -e "\n  ${G}[✓] Whitelist DISABLED.${D}"; sleep 2
                else
                    [[ ! -f "$WHITELIST_FILE" ]] && sudo touch "$WHITELIST_FILE"
                    echo ""
                    echo -e "  ${Y}[*] Auto-adding connected devices...${D}"
                    local dump
                    dump=$(iw dev "$WIFI_IFACE" station dump 2>/dev/null)
                    if [[ -n "$dump" ]]; then
                        while IFS= read -r line; do
                            if [[ "$line" =~ ^Station ]]; then
                                local cmac; cmac=$(echo "$line" | awk '{print $2}')
                                if ! grep -qi "^$cmac$" "$WHITELIST_FILE" 2>/dev/null; then
                                    echo "$cmac" | sudo tee -a "$WHITELIST_FILE" > /dev/null
                                    echo -e "  ${G}  + Added: $cmac${D}"
                                else
                                    echo -e "  ${Y}  ~ Already listed: $cmac${D}"
                                fi
                            fi
                        done <<< "$dump"
                    fi
                    wl_count=$(grep -c . "$WHITELIST_FILE" 2>/dev/null || echo 0)
                    if [[ "$wl_count" -eq 0 ]]; then
                        echo -e "\n  ${R}[!] Whitelist empty — no device will connect.${D}"
                        read -rp "  Enable anyway? (yes/no): " yn
                        [[ "$yn" != "yes" ]] && { echo -e "  ${Y}Cancelled.${D}"; sleep 1; continue; }
                    fi
                    WHITELIST_ENABLED=true
                    save_config; write_hostapd_conf
                    sudo systemctl restart hostapd 2>/dev/null
                    echo -e "\n  ${G}[✓] Whitelist ENABLED. $wl_count device(s) allowed.${D}"
                    echo -e "  ${Y}  New devices cannot connect until whitelist is disabled.${D}"
                    sleep 2
                fi ;;
            2)
                echo ""
                echo -e "${C}─── Whitelisted MACs ─────────────────────────${D}"
                if [[ ! -f "$WHITELIST_FILE" ]] || [[ ! -s "$WHITELIST_FILE" ]]; then
                    echo -e "  ${Y}Whitelist is empty.${D}"
                else
                    local i=0
                    while IFS= read -r me; do
                        [[ -z "$me" ]] && continue
                        (( i++ ))
                        echo -e "  ${G}[$i]${D} $me"
                    done < "$WHITELIST_FILE"
                fi
                echo ""
                read -rp "  Press Enter to continue..." ;;
            3)
                echo ""
                echo -e "${C}─── Remove MAC from Whitelist ────────────────${D}"
                if [[ ! -f "$WHITELIST_FILE" ]] || [[ ! -s "$WHITELIST_FILE" ]]; then
                    echo -e "  ${Y}Whitelist is empty.${D}"
                    sleep 1; continue
                fi
                local i=0
                declare -a WL_ENTRIES=()
                while IFS= read -r me; do
                    [[ -z "$me" ]] && continue
                    (( i++ ))
                    WL_ENTRIES+=("$me")
                    echo -e "  ${G}[$i]${D} $me"
                done < "$WHITELIST_FILE"
                echo ""
                read -rp "  Enter number to remove (0 to cancel): " rnum
                if [[ "$rnum" =~ ^[0-9]+$ && $rnum -ge 1 && $rnum -le $i ]]; then
                    local to_remove="${WL_ENTRIES[$((rnum-1))]}"
                    sudo sed -i "/^$to_remove$/Id" "$WHITELIST_FILE"
                    write_hostapd_conf
                    sudo systemctl restart hostapd 2>/dev/null
                    echo -e "  ${G}[✓] Removed: $to_remove${D}"
                else
                    echo -e "  ${Y}Cancelled.${D}"
                fi
                sleep 1.5 ;;
            0) break ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
# 13 — TOGGLE PASSWORD
# ═══════════════════════════════════════════════════════════
toggle_password() {
    if $SHOW_PASS; then
        SHOW_PASS=false
        echo -e "\n  ${Y}Password hidden.${D}"
    else
        SHOW_PASS=true
        echo -e "\n  ${G}Password: ${B}$PASSWORD${D}"
    fi
    sleep 1.5
}

# ═══════════════════════════════════════════════════════════
# 14 — QR CODE
# ═══════════════════════════════════════════════════════════
show_qr() {
    echo ""
    if ! command -v qrencode &>/dev/null; then
        echo -e "${R}[!] qrencode not installed. Run Setup (option 6) first.${D}"
    else
        echo -e "${C}─── WiFi QR Code ─────────────────────────────${D}"
        echo -e "  SSID  : ${B}$SSID${D}"
        echo -e "  Band  : ${Y}${BAND:-2.4}GHz${D}"
        local hidden_flag=""
        if ${HIDDEN_SSID:-false}; then
            hidden_flag=";H:true"
            echo -e "  ${Y}[Hidden network — H:true flag included in QR]${D}"
        fi
        echo ""
        qrencode -t UTF8 "WIFI:S:${SSID};T:WPA;P:${PASSWORD}${hidden_flag};;"
        echo ""
        if ${HIDDEN_SSID:-false}; then
            echo -e "  ${Y}Note: Your device must support hidden network QR scan.${D}"
            echo -e "  ${Y}On most phones: scan QR, then manually confirm network name.${D}"
        else
            echo -e "  Scan with phone camera or WiFi app to connect."
        fi
    fi
    echo ""
    read -rp "  Press Enter to continue..."
}

# ═══════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════
load_config

while true; do
    show_header
    show_menu
    read -rp "  Enter choice: " choice
    echo ""
    case "$choice" in
        1)  start_hotspot ;;
        2)  stop_hotspot ;;
        3)  make_permanent ;;
        4)  reset_permanent ;;
        5)  manage_schedule ;;
        6)  do_setup ;;
        7)  edit_network ;;
        8)  create_network ;;
        9)  delete_network ;;
        10) show_devices ;;
        11) bandwidth_monitor ;;
        12) manage_whitelist ;;
        13) toggle_password ;;
        14) show_qr ;;
        0)  clean_exit ;;
        *)  echo -e "  ${R}Invalid option.${D}"; sleep 1 ;;
    esac
done
