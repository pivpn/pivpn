#!/bin/sh

interface=$(ip -o link | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1 | grep -v -w 'lo' | head -1)
ipaddress=$(ip addr show "$interface" | grep -o -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}/[0-9]{2}")
gateway=$(ip route show | awk '/default/ {print $3}')
hostname="pivpn.test"

common(){
    sed -i "s/INTERFACE/$interface/g" "$vpnconfig"
    sed -i "s|IPADDRESS|$ipaddress|g" "$vpnconfig"
    sed -i "s/GATEWAY/$gateway/g" "$vpnconfig"
}
 
openvpn(){
    vpnconfig="ciscripts/ci_openvpn.conf"
    twofour=1
    common
    sed -i "s/2POINT4/$twofour/g" "$vpnconfig"
    cat $vpnconfig
    exit 0
}

wireguard(){
    vpnconfig="ciscripts/ci_wireguard.conf"
    common
    cat $vpnconfig
    exit 0
}

if [ $# -lt 1 ]; then
    echo "specifiy a VPN protocol to prepare"
    exit 1
else
    chmod +x auto_install/install.sh
    sudo hostnamectl set-hostname $hostname
    cat /etc/os-release
    while true; do
        case "$1" in
            -o | --openvpn      ) openvpn 
            ;;
            -w | --wireguard    ) wireguard
            ;;
            *                   ) echo "unknown vpn protocol"; exit 1  
            ;;
        esac
    done
fi
