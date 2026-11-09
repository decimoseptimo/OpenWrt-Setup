#!/bin/sh

# Load secrets.env from the script's directory or current directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/secrets.env" ]; then
. "$SCRIPT_DIR/secrets.env"
elif [ -f "./secrets.env" ]; then
. ./secrets.env
fi

# Interactive fallback prompts if secrets.env is missing
[ -z "$ROOT_PASS" ] && printf "Enter Root Password: " && read -r ROOT_PASS
[ -z "$WIFI_SSID" ] && printf "Enter Wi-Fi SSID: " && read -r WIFI_SSID
[ -z "$WIFI_PASS" ] && printf "Enter Wi-Fi Password: " && read -r WIFI_PASS
[ -z "$PPPOE_USER" ] && printf "Enter PPPoE Username: " && read -r PPPOE_USER
[ -z "$PPPOE_PASS" ] && printf "Enter PPPoE Password: " && read -r PPPOE_PASS
[ -z "$DUCKDNS_DOMAIN" ] && printf "Enter DuckDNS Subdomain: " && read -r DUCKDNS_DOMAIN
[ -z "$DUCKDNS_TOKEN" ] && printf "Enter DuckDNS Token: " && read -r DUCKDNS_TOKEN

# Enable strict error checking after variable checks
set -e

# Generic fallback parameters (override in secrets.env)
TZ_NAME="${TZ_NAME:-America/Los_Angeles}"
TZ_STRING="${TZ_STRING:-PST8PDT,M3.2.0,M11.1.0}"
COUNTRY_CODE="${COUNTRY_CODE:-US}"
LAN_IP="${LAN_IP:-192.168.1.1}"
SSH_PORT="${SSH_PORT:-2222}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.0.0.1/24}"
WG_CLIENT_IP="${WG_CLIENT_IP:-10.0.0.2/32}"

########################################
# SET SYSTEM PASSWORD & TIMEZONE
echo -e "${ROOT_PASS}\n${ROOT_PASS}" | passwd root

uci set system.@system[0].zonename="$TZ_NAME"
uci set system.@system[0].timezone="$TZ_STRING"
uci commit system
service system reload

########################################
# SET PPPOE ACCESS & WAIT FOR WAN
uci set network.wan.proto='pppoe'
uci set network.wan.username="$PPPOE_USER"
uci set network.wan.password="$PPPOE_PASS"
uci set network.wan.ipv6='auto'
uci commit network
service network reload

echo "Waiting for PPPoE WAN connection to come up..."
for i in $(seq 1 30); do
if ifstatus wan | grep -q '"up": true'; then
echo "WAN is up!"
break
fi
sleep 2
done

########################################
# INSTALL ALL REQUIRED PACKAGES
apk update
apk add openssh-sftp-server ddns-scripts luci-app-ddns ca-bundle curl wireguard-tools luci-proto-wireguard adblock-fast luci-app-adblock-fast gawk grep sed coreutils-sort qrencode

########################################
# SET SSH
uci set dropbear.@dropbear[0].Port="$SSH_PORT"
uci commit dropbear
service dropbear restart

########################################
# SETUP WIFI
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country="$COUNTRY_CODE"
uci set wireless.radio0.channel='6'
uci set wireless.radio0.htmode='HE20'
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country="$COUNTRY_CODE"
uci set wireless.radio1.channel='36'
uci set wireless.radio1.htmode='HE80'
# Configure 2.4 GHz AP
uci set wireless.default_radio0.disabled='0'
uci set wireless.default_radio0.ssid="$WIFI_SSID"
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key="$WIFI_PASS"
# Configure 5 GHz AP
uci set wireless.default_radio1.disabled='0'
uci set wireless.default_radio1.ssid="$WIFI_SSID"
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.key="$WIFI_PASS"

uci commit wireless
wifi reload

########################################
# SETUP ADBLOCK-FAST
uci set adblock-fast.config.enabled='1'
# 1. HaGeZi Multi PRO (Full - ~268k domains)
uci set adblock-fast.hagezi_pro=file_url
uci set adblock-fast.hagezi_pro.name='HaGeZi - Multi PRO'
uci set adblock-fast.hagezi_pro.url='https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro-onlydomains.txt'
uci set adblock-fast.hagezi_pro.action='block'
uci set adblock-fast.hagezi_pro.enabled='1'
# 2. HaGeZi TIF Mini (~190k domains)
uci set adblock-fast.hagezi_tif=file_url
uci set adblock-fast.hagezi_tif.name='HaGeZi - TIF Mini'
uci set adblock-fast.hagezi_tif.url='https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/tif.mini-onlydomains.txt'
uci set adblock-fast.hagezi_tif.action='block'
uci set adblock-fast.hagezi_tif.enabled='1'

uci commit adblock-fast
service adblock-fast enable
service adblock-fast restart

########################################
# SETUP DUCKDNS
uci set ddns.duckdns=service
uci set ddns.duckdns.enabled='1'
uci set ddns.duckdns.use_ipv6='0'
uci set ddns.duckdns.interface='wan'
uci set ddns.duckdns.service_name='duckdns.org'
uci set ddns.duckdns.lookup_host="${DUCKDNS_DOMAIN}.duckdns.org"
uci set ddns.duckdns.domain="$DUCKDNS_DOMAIN"
uci set ddns.duckdns.username="$DUCKDNS_DOMAIN"
uci set ddns.duckdns.password="$DUCKDNS_TOKEN"
uci set ddns.duckdns.ip_source='network'
uci set ddns.duckdns.ip_network='wan'
uci set ddns.duckdns.use_https='1'
uci set ddns.duckdns.cacert='/etc/ssl/certs/ca-certificates.crt'
uci commit ddns
service ddns restart

########################################
# SETUP WIREGUARD
if [ ! -f /etc/wireguard/server.key ]; then

# Generate Server and Client keys
umask 077
mkdir -p /etc/wireguard
wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
wg genkey | tee /etc/wireguard/client1.key | wg pubkey > /etc/wireguard/client1.pub
wg genpsk > /etc/wireguard/client1.psk
fi

WG_SRV_PRIV=$(cat /etc/wireguard/server.key)
WG_CLI_PRIV=$(cat /etc/wireguard/client1.key)
WG_CLI_PUB=$(cat /etc/wireguard/client1.pub)
WG_CLI_PSK=$(cat /etc/wireguard/client1.psk)

# Configure the WireguardVPN zone
uci -q del_list firewall.@zone[0].network='wg0'
uci set firewall.wg_zone=zone
uci set firewall.wg_zone.name='WireguardVPN'
uci set firewall.wg_zone.input='ACCEPT'
uci set firewall.wg_zone.output='ACCEPT'
uci set firewall.wg_zone.forward='ACCEPT'
uci set firewall.wg_zone.masq='1'
uci set firewall.wg_zone.mtu_fix='1'
uci -q del_list firewall.wg_zone.network='wg0'
uci add_list firewall.wg_zone.network='wg0'

# Forward WireguardVPN -> lan
uci set firewall.wg_lan=forwarding
uci set firewall.wg_lan.src='WireguardVPN'
uci set firewall.wg_lan.dest='lan'
# Forward WireguardVPN -> wan
uci set firewall.wg_wan=forwarding
uci set firewall.wg_wan.src='WireguardVPN'
uci set firewall.wg_wan.dest='wan'
# Forward lan -> WireguardVPN
uci set firewall.lan_wg=forwarding
uci set firewall.lan_wg.src='lan'
uci set firewall.lan_wg.dest='WireguardVPN'

# Configure network
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$WG_SRV_PRIV"
uci set network.wg0.listen_port="$WG_PORT"
uci -q del_list network.wg0.addresses="$WG_SUBNET"
uci add_list network.wg0.addresses="$WG_SUBNET"

# Add peer
uci set network.wgclient1=wireguard_wg0
uci set network.wgclient1.description='Client1'
uci set network.wgclient1.private_key="$WG_CLI_PRIV"
uci set network.wgclient1.public_key="$WG_CLI_PUB"
uci set network.wgclient1.preshared_key="$WG_CLI_PSK"
uci -q del_list network.wgclient1.allowed_ips="$WG_CLIENT_IP"
uci add_list network.wgclient1.allowed_ips="$WG_CLIENT_IP"
uci set network.wgclient1.route_allowed_ips='1'

# Add firewall rule
uci set firewall.wg_in=rule
uci set firewall.wg_in.name='Allow-WireGuard'
uci set firewall.wg_in.src='wan'
uci set firewall.wg_in.proto='udp'
uci set firewall.wg_in.dest_port="$WG_PORT"
uci set firewall.wg_in.target='ACCEPT'

# Enable adblocking on wireguard subnet
uci set dhcp.@dnsmasq[0].localservice='0'

uci commit network
uci commit firewall
uci commit dhcp
service network reload && ifup wg0
service firewall restart
service dnsmasq restart

########################################
# SET LAN IP
uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask='255.255.255.0'
uci commit network
service network reload