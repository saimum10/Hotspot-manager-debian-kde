# 📡 Hotspot Manager

> A terminal-based WiFi hotspot management tool for Linux — built by **Saimum**

---

## ✅ Supported OS

Debian · Ubuntu · Kubuntu · Xubuntu · Linux Mint · Kali Linux · Parrot OS · Pop!_OS

> **Note:** Script uses `wlo1` as WiFi interface and `enp3s0` as internet interface by default.
> Edit `WIFI_IFACE` and `INET_IFACE` at the top of the script to match your system.

---

## 📦 Requirements

Installed automatically via **option 6 (Setup)**:

| Package | Purpose |
|---|---|
| `hostapd` | Access point daemon |
| `dnsmasq` | DHCP & DNS server |
| `iptables` | NAT / internet sharing |
| `qrencode` | QR code generation |

**~1.3 MB download / ~4.7 MB installed**

---

## 🚀 How to Use

```bash
cp "Hotspot Manager.desktop" ~/Desktop/
chmod +x ~/Desktop/"Hotspot Manager.desktop"
```

Double-click the icon → **Run option 6 (Setup) first** → then option 1 to start.

> KDE users: right-click the icon → **Allow Launching**

---

## 📋 Menu Options

| # | Option | Description |
|---|---|---|
| 1 | Start Hotspot | Starts AP, sets IP, NAT, and runs hostapd + dnsmasq |
| 2 | Stop Hotspot | Stops all services and restores NetworkManager |
| 3 | Make Permanent | Auto-starts hotspot on every reboot via systemd |
| 4 | Reset Permanent | Removes boot persistence, back to manual mode |
| 5 | Schedule | Auto on/off by time + idle timeout (no devices → auto off) |
| 6 | Setup | Installs packages and writes all config files |
| 7 | Edit Network | Change SSID, password, visibility, or band |
| 8 | Create New Network | Create a new hotspot (replaces current config) |
| 9 | Delete Network | Stops hotspot and deletes all config |
| 10 | Connected Devices | Shows IP, hostname, device type, data usage; supports kick + ban |
| 11 | Bandwidth Monitor | Real-time per-device upload/download speed (press Q to exit) |
| 12 | Whitelist Mode | Restrict access by MAC; enable/disable/view/remove |
| 13 | Toggle Password | Show or hide password in the status header |
| 14 | QR Code | Generate a scannable WiFi QR code in the terminal |
| 0 | Exit | Exit the program (`Ctrl+C` also works) |

---

## 📁 Config Files

| File | Purpose |
|---|---|
| `/etc/hotspot-manager.conf` | SSID, password, band, visibility |
| `/etc/hostapd/hostapd.conf` | Access point config |
| `/etc/hostapd/whitelist.conf` | Allowed MACs |
| `/etc/hostapd/blacklist.conf` | Banned MACs |

---

## ⚙️ Defaults

| | Value |
|---|---|
| WiFi Interface | `wlo1` |
| Internet Interface | `enp3s0` |
| Hotspot IP | `192.168.50.1` |
| DHCP Range | `192.168.50.2 – 192.168.50.20` |
| SSID | `MyHotspot` |
| Password | `12345678` |
| Band | `2.4 GHz` |

---

## 🛠️ Built With

`bash` · `hostapd` · `dnsmasq` · `iptables` · `iw` · `nmcli` · `qrencode` · `hostapd_cli`

---

*Made by Saimum — Linux*
