# OpenWrt initial setup

This guide is for setting up OpenWrt from a fresh install. It features an opionated provisioning with DuckDNS, Adblock-fast & WireGuard. Optionally a sing-box server with Shadowsocks & XTLS-Reality protocols. Skip to the last part if you only care about proxy setup. 

If you need a proxy client, take a look at home-proxy, although not an official package, the manual installation steps from its repo are good.

CLI provisioning is recommended (UCI), but I also briefly discuss GUI setup (LUCI) were I link to the official guides.

DISCLAIMER: I've written this mainly for my personal use, as a former Gargoyle-router user, I put it out there as it may be useful for someone else.

##### OpenWrt's default configuration

ip 192.168.1.1, user root, no password

## UCI setup (recommended)

```bash
git clone https://github.com/decimoseptimo/OpenWrt-Setup.git
cd OpenWrt-Setup
mv secrets.env.example secrets.env
# Fill-in secrets in secrets.env
sh provision.sh
```

## GUI setup

Set system password
Set timezone
Change lan ip 192.168.1.1/24
[Setup wireless networks and attach to lan network](https://openwrt.org/docs/guide-quick-start/basic_wifi) 

##### [Setup ddns](https://openwrt.org/docs/guide-user/services/ddns/client)

Add luci-app-ddns, curl, and ca-bundle packages
Add new service `Services > Dynamic DNS >  Add new services...`
*Set `IP address source > URL` and `URL > an ip lookup provider`

##### Setup SSH on port :2222 & enable SFTP

*Enable port forwarding at gateway
Set port 2222 (will avoid bots from spamming :22)
Add ssh key(s)
Test connection (lan)
Disable password auth
Add firewall traffic rule
Test connection (wan)
Add openssh-sftp-server package
Test sftp client (I recommend vscode's remote bridge)

##### [Setup Adblocker](https://openwrt.org/docs/guide-user/services/ad-blocking)

I went with Adblock-Fast because it has a GUI, but probably Adblock-lean is tad faster.

Add package `apk add luci-app-adblock-fast` 
Add recommended packages `apk --force-overwrite add gawk grep sed coreutils-sort`
Enable `Hagezi pro-onlydomains` block list (ads)
Add & enable [Hagezi tif.medium-onlydomains](https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/wildcard/tif.medium-onlydomains.txt) block list (security)
Enable & start the AdBlock-Fast service
Enable `Automatic List Update`

##### [Setup wireguard server on 51820](https://openwrt.org/docs/guide-user/services/vpn/wireguard/server#luci_web_interface_instructions)

*Enable port forwarding at gateway
Add luci-proto-wireguard package
Restart network
Add wg interface
Add peers
Add firewall zone
Add firewall traffic rule

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-WireGuard'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='51820'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

Test peers connection

##### Setup proxies on :8080 (Shadowsocks) & :4433 (XTLS-Reality)

*Enable port forwarding at gateway
Add firewall rule

```bash
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Proxies'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='8080 4433'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
/etc/init.d/firewall restart
```

Add sing-box server

```
apk update
apk install sing-box
```

Configure `/etc/sing-box/config.json`, sample with shadowsocks single user & reality multi user:

```JSON
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-in",
      "listen": "::",
      "listen_port": 8080,
      "network": "tcp",
      "method": "2022-blake3-aes-128-gcm",
      "password": "SS_PASSWORD",
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    },
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": 4433,
      "users": [
        {
          "name": "USER_NAME",
          "uuid": "USER_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.apple.com",
            "server_port": 433
          },
          "private_key": "REALITY_PRIVATE_KEY",
          "short_id": [
            "REALITY_SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
```

Write connection urls

**For Reality**

URL format
*vless://[UUID]@[ROUTER_IP]:443?type=tcp&security=reality&pbk=[PUBLIC_KEY]&fp=chrome&sni=www.apple.com&sid=[SHORT_ID]&flow=xtls-rprx-vision#[REMARK_NAME]*

Generate UUID
`sing-box generate uuid`

Generate keys
`sing-box generate reality-keypair`

Generate short id
`sing-box generate rand --hex 8`

**For shadowsocks**

URL format

*ss://[BASE64_ENCODED_CREDENTIALS]@[SERVER_IP]:[PORT]#[REMARK_NAME]*

Single user BASE64_ENCODED_CREDENTIALS
`echo -n "2022-blake3-aes-128-gcm:SERVER_PASSWORD" | base64`

Multi user BASE64_ENCODED_CREDENTIALS
`echo -n "2022-blake3-aes-128-gcm:SERVER_PASSWORD:USER_PASSWORD" | base64`

Test connections

Stop sing-box

```JSON
/etc/init.d/sing-box stop
killall sing-box
```

After editing, test configuration & run interactively

```JSON
sing-box check -c /etc/sing-box/config.json
sing-box run -c /etc/sing-box/config.json
```

If running gives error

```bash
INFO[0000] inbound/shadowsocks[shadowsocks-in]: tcp server started at [::]:8080
FATAL[0000] start service: start inbound/vless[reality-in]: listen tcp 0.0.0.0:443: bind: address already in use
```

That means Luci is blocking port :443, we just need to move it to its alternative port :8443

```bash
uci set uhttpd.main.listen_https='0.0.0.0:8443'
uci add_list uhttpd.main.listen_https='[::]:8443'
uci commit uhttpd
/etc/init.d/uhttpd restart
```

Load urls onto hiddify desktop, android... and connect.
If all went well, stop the service, and do these preparations...

```bash
uci set sing-box.main.enabled='1'
uci set sing-box.main.user='root'
uci commit sing-box
```

...to run it demonized

```bash
/etc/init.d/sing-box enable
/etc/init.d/sing-box start
```

##### IPv6 issue

At the moment i was setting this up, i was behind another router (double NAT). Hence IPv6 was not working, and I was limited to IPv4. In this case it's recommended to disable IPv6 althogether instead of letting it fallback.

Add this node to `/etc/sing-box/config.json` to reject IPv6 immediately

```json
  "route": {
    "rules": [
      {
        "ip_cidr": [
          "::/0"
        ],
        "action": "reject"
      }
    ]
  },
```

In XTLS-Reality this was not an issue, but apparently shadowsocks is a dumber protocol, and some services requesting IPv6 stubbornly were not resolving. Particularly some webpages, and the google search on android was returning "you are offline". I solved this in hiddify app `settings > DNS > Remote DNS domain strategy > IPv4 only` and reboot the app.

\* If another router is present providing WAN access to our OpenWrt router (double NAT).
