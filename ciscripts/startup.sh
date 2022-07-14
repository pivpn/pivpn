#!/bin/sh

interface=$(ip -o link | \
    awk '{print $2}' | \
    cut -d ':' -f 1 | \
    cut -d '@' -f 1 | \
    grep -vwsEe 'lo' | \
    head -1)
ipaddress=$(ip addr show "${interface}" | \
    grep -osEe '([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}')
gateway=$(ip route show | \
    awk '/default/ {print $3}')
hostname='pivpn.test'

common() {
    sed -iEe "s/INTERFACE/${interface}/g" "${vpnconfig}"
    sed -iEe "s/IPADDRESS/${ipaddress}/g" "${vpnconfig}"
    sed -iEe "s/GATEWAY/${gateway}/g" "${vpnconfig}"
}
 
openvpn() {
    local vpnconfig

    vpnconfig='ciscripts/ci_openvpn.conf'

    common

    sed -iEe 's/2POINT4/1/g' "${vpnconfig}"

    cat "${vpnconfig}"
    exit 0
}

wireguard() {
    local vpnconfig

    vpnconfig='ciscripts/ci_wireguard.conf'

    common

    cat "${vpnconfig}"
    exit 0
}

if [ $# -lt 1 ]
then
    echo 'specifiy a VPN protocol to prepare'
    exit 1
else
    chmod +x auto_install/install.sh

    sudo hostnamectl set-hostname "${hostname}"

    cat /etc/os-release

    while true
    do
        case "$1" in
            -o | --openvpn)
                openvpn 
                ;;
            -w | --wireguard)
                wireguard
                ;;
            *)
                echo 'unknown vpn protocol'
                exit 1  
                ;;
        esac
    done
fi
