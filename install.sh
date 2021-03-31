#!/bin/bash
###
#
# Author: Maël
# Date: 2021/03/14
# Desc:
#   - Install WireGuard without any configuration. Everything will be done through Wireguard-UI
#   - Install WireGuard-UI
#       - For a maximum security it will be use through ssh tunnel (ssh -L 5000:localhost:5000 user@vpn.domain.tld)
#       - Please customise /opt/wgui/db/server/users.json after first login
#   - Configure strict firewall
#       - DROP any ipv4 & ipv6 requests
#       - Allow loopback ipv4 & ipv6
#       - Allow Outgoing SSH, HTTPs, HTTP, DNS, Ping
#       - Allow Ingoing SSH, Wireguard ($wg_port)
#       - Allow everything needed by wireguard
#   - Save iptables rules in /etc/iptables/
#       - Load them at boot via /etc/network/if-up.d/iptables
#
# Sources:
#   - Wireguard:
#       - https://www.wireguard.com
#       - https://github.com/WireGuard
#   - Wireguard-ui:
#       - https://github.com/ngoduykhanh/wireguard-ui
#
###

if ! [ $(id -nu) == "root" ]; then
  echo "Please run this script as root"
  exit 1
fi

if [ "$(lsb_release -is)" != "Debian" ] && [ "$(lsb_release -rs)" != "10" ]
  then
    echo "This script was made for on Debian10 only."
    exit 1
fi

WGUI_LINK="https://github.com/ngoduykhanh/wireguard-ui/releases/download/v0.2.7/wireguard-ui-v0.2.7-linux-amd64.tar.gz"
WGUI_PATH="/opt/wgui"
WGUI_BIN_PATH="/usr/local/bin"
SYSTEMCTL_PATH="/usr/bin/systemctl"
BACKPORTS_REPO="deb https://deb.debian.org/debian/ buster-backports main"

function main() {

while [[ $ENDPOINT == "" ]]; do
  echo "---"
  read -p "Enpoint (IP or FQDN): " ENDPOINT
done
while ! [[ $WG_PORT =~ ^[0-9]+$ ]]; do
  echo "---"
  read -p "Wireguard port ? [51820]: " WG_PORT
  WG_PORT=${WG_PORT:-"51820"}
done
while ! [[ $WG_NETWORK =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; do
  echo "---"
  read -p "Wireguard network ? [10.252.1.0/24]: " WG_NETWORK
  WG_NETWORK=${WG_NETWORK:-"10.252.1.0/24"}
done
while [[ $WG_INTERFACE == "" ]]; do
  echo "---"
  read -p "Wireguard interface ? [wg0]: " WG_INTERFACE
  WG_INTERFACE=${WG_INTERFACE:-"wg0"}
done
while [[ $SYS_INTERFACE == "" ]]; do
  echo "---"
  read -p "System network interface ? [eth0]: " SYS_INTERFACE
  SYS_INTERFACE=${SYS_INTERFACE:-"eth0"}
done
while ! [[ $SSH_PORT =~ ^[0-9]+$ ]]; do
  echo "---"
  read -p "SSH port ? [22]: " SSH_PORT
  SSH_PORT=${SSH_PORT:-"22"}
done

install
network_conf
firewall_conf
wg_conf
wgui_conf

echo "########################################################################"
echo "                            Setup done."
echo ""
echo "  - Your iptables rules was saved just in case in:"
echo "      - /etc/iptables/rules.v4.bak"
echo "      - /etc/iptables/rules.v6.bak"
echo ""
echo ""
echo "  - To access your wireguard-ui please open a new ssh connexion"
echo "      - ssh -L 5000:localhost:5000 user@myserver.domain.tld"
echo "      - And browse to http://localhost:5000"
echo ""
echo "########################################################################"
}

function install() {

  if ! grep -q "^$BACKPORTS_REPO" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
    echo ""
    echo "### Enable debian-backports"
    echo "deb https://deb.debian.org/debian/ buster-backports main" >> /etc/apt/sources.list
  fi

  echo ""
  echo "### Update & Upgrade"
  apt update && apt full-upgrade -y

  echo ""
  echo "### Installing WireGuard"
  apt install linux-headers-$(uname --kernel-release) wireguard -y

  echo ""
  echo "### Installing Wireguard-UI"
  mkdir -m 077 $WGUI_PATH
  wget -qO - $WGUI_LINK | tar xzf - -C $WGUI_PATH
  ln -s $WGUI_PATH/wireguard-ui $WGUI_BIN_PATH/wireguard-ui
}

function network_conf() {
  echo ""
  echo "### Enable ipv4 Forwarding"
  sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  sysctl -p
}

function firewall_conf() {
  echo ""
  echo "### Firewall configuration"

  if [ "$(which iptables)" = "" ]; then
    echo ""
    echo "### iptables is required. Let's install it."
    apt install iptables -y
  fi

  if ! [ -d /etc/iptables ]; then
    mkdir -m 755 /etc/iptables
  fi

  /sbin/iptables-save > /etc/iptables/rules.v4.bak
  /sbin/ip6tables-save > /etc/iptables/rules.v6.bak

  RULES_4=(
  "INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
  "INPUT -i lo -m comment --comment localhost-network -j ACCEPT"
  "INPUT -i $WG_INTERFACE -m comment --comment wireguard-network -j ACCEPT"
  "INPUT -p tcp -m tcp --dport $SSH_PORT -j ACCEPT"
  "INPUT -p icmp -m icmp --icmp-type 8 -m comment --comment Allow-ping -j ACCEPT"
  "INPUT -p udp -m udp --dport $WG_PORT -m comment --comment external-port-wireguard -j ACCEPT"
  "FORWARD -s $WG_NETWORK -i $WG_INTERFACE -o $SYS_INTERFACE -m comment --comment Wireguard-traffic-from-$WG_INTERFACE-to-$SYS_INTERFACE -j ACCEPT"
  "FORWARD -d $WG_NETWORK -i $SYS_INTERFACE -o $WG_INTERFACE -m comment --comment Wireguard-traffic-from-$SYS_INTERFACE-to-$WG_INTERFACE -j ACCEPT"
  "FORWARD -d $WG_NETWORK -i $WG_INTERFACE -o $WG_INTERFACE -m comment --comment Wireguard-traffic-inside-$WG_INTERFACE -j ACCEPT"
  "OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
  "OUTPUT -o lo -m comment --comment localhost-network -j ACCEPT"
  "OUTPUT -o $WG_INTERFACE -m comment --comment wireguard-network -j ACCEPT"
  "OUTPUT -p tcp -m tcp --dport 443 -j ACCEPT"
  "OUTPUT -p tcp -m tcp --dport 80 -j ACCEPT"
  "OUTPUT -p tcp -m tcp --dport 22 -j ACCEPT"
  "OUTPUT -p udp -m udp --dport 53 -j ACCEPT"
  "OUTPUT -p tcp -m tcp --dport 53 -j ACCEPT"
  "OUTPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT"
  "POSTROUTING -t nat -s $WG_NETWORK -o $SYS_INTERFACE -m comment --comment wireguard-nat-rule -j MASQUERADE"
  )

  RULES_6=(
  "INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
  "INPUT -i lo -m comment --comment localhost-network -j ACCEPT"
  "OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
  "OUTPUT -o lo -m comment --comment localhost-network -j ACCEPT"
  )

  for e in "${RULES_4[@]}"; do
    iptables -C $e > /dev/null 2>&1 || iptables -A $e
  done
  for e in "${RULES_6[@]}"; do
    ip6tables -C $e > /dev/null 2>&1 || ip6tables -A $e
  done

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP

  /sbin/iptables-save > /etc/iptables/rules.v4
  /sbin/ip6tables-save > /etc/iptables/rules.v6

  echo "#!/bin/sh
  /sbin/iptables-restore < /etc/iptables/rules.v4
  /sbin/ip6tables-restore < /etc/iptables/rules.v6" > /etc/network/if-up.d/iptables
  chmod 755 /etc/network/if-up.d/iptables

}

function wg_conf() {
  echo ""
  echo "### Making default Wireguard conf"
  umask 077 /etc/wireguard/
  touch /etc/wireguard/$WG_INTERFACE.conf
  systemctl enable wg-quick@$WG_INTERFACE.service
}

function wgui_conf() {

  echo ""
  echo "### Wiregard-ui Services"
  echo "[Unit]
  Description=Wireguard UI
  After=network.target

  [Service]
  Type=simple
  WorkingDirectory=$WGUI_PATH
  ExecStart=$WGUI_BIN_PATH/wireguard-ui

  [Install]
  WantedBy=multi-user.target" > /etc/systemd/system/wgui_http.service

  systemctl enable wgui_http.service
  systemctl start wgui_http.service

  echo "[Unit]
  Description=Restart WireGuard
  After=network.target

  [Service]
  Type=oneshot
  ExecStart=$SYSTEMCTL_PATH restart wg-quick@$WG_INTERFACE.service" > /etc/systemd/system/wgui.service

  echo "[Unit]
  Description=Watch /etc/wireguard/$WG_INTERFACE.conf for changes

  [Path]
  PathModified=/etc/wireguard/$WG_INTERFACE.conf

  [Install]
  WantedBy=multi-user.target" > /etc/systemd/system/wgui.path

  systemctl enable wgui.{path,service}
  systemctl start wgui.{path,service}
}
main