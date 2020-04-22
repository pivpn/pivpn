#!/bin/bash

setupVars="/etc/pivpn/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

helpFunc(){
    echo "::: Create a client conf profile"
    echo ":::"
    echo "::: Usage: pivpn <-a|add> [-n|--name <arg>] [-h|--help]"
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Interactive mode"
    echo ":::  -n,--name            Name for the Client (default: '$HOSTNAME')"
    echo ":::  -h,--help            Show this help dialog"
}

# Parse input arguments
while test $# -gt 0; do
    _key="$1"
    case "$_key" in
        -n|--name|--name=*)
            _val="${_key##--name=}"
            if test "$_val" = "$_key"; then
                test $# -lt 2 && echo "::: Missing value for the optional argument '$_key'." && exit 1
                _val="$2"
                shift
            fi
            CLIENT_NAME="$_val"
            ;;
        -h|--help)
            helpFunc
            exit 0
            ;;
        *)
            echo "::: Error: Got an unexpected argument '$1'"
            helpFunc
            exit 1
            ;;
    esac
    shift
done

# The home folder variable was sourced from the settings file.
if [ ! -d "${install_home}/configs" ]; then
    mkdir "${install_home}/configs"
    chown "${install_user}":"${install_user}" "${install_home}/configs"
    chmod 0750 "${install_home}/configs"
fi

cd /etc/wireguard

if [ -z "${CLIENT_NAME}" ]; then
    read -r -p "Enter a Name for the Client: " CLIENT_NAME
fi

if [[ "${CLIENT_NAME}" =~ [^a-zA-Z0-9.@_-] ]]; then
    echo "Name can only contain alphanumeric characters and these characters (.-@_)."
    exit 1
fi

if [ -z "${CLIENT_NAME}" ]; then
    echo "::: You cannot leave the name blank."
    exit 1
fi

if [ -f "configs/${CLIENT_NAME}.conf" ]; then
    echo "::: A client with this name already exists"
    exit 1
fi

wg genkey | tee "keys/${CLIENT_NAME}_priv" | wg pubkey > "keys/${CLIENT_NAME}_pub"
wg genpsk | tee "keys/${CLIENT_NAME}_psk" &> /dev/null
echo "::: Client Keys generated"

# Find an unused number for the last octet of the client IP
for i in {2..254}; do
    if ! grep -q " $i$" configs/clients.txt; then
        COUNT="$i"
        echo "${CLIENT_NAME} $(<keys/${CLIENT_NAME}_pub) $(date +%s) ${COUNT}" >> configs/clients.txt
        break
    fi
done

NET_REDUCED="${pivpnNET::-2}"

echo -n "[Interface]
PrivateKey = $(cat "keys/${CLIENT_NAME}_priv")
Address = ${NET_REDUCED}.${COUNT}/${subnetClass}
DNS = ${pivpnDNS1}" > "configs/${CLIENT_NAME}.conf"

if [ -n "${pivpnDNS2}" ]; then
    echo ", ${pivpnDNS2}" >> "configs/${CLIENT_NAME}.conf"
else
    echo >> "configs/${CLIENT_NAME}.conf"
fi
echo >> "configs/${CLIENT_NAME}.conf"

echo "[Peer]
PublicKey = $(cat keys/server_pub)
PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")
Endpoint = ${pivpnHOST}:${pivpnPORT}
AllowedIPs = 0.0.0.0/0, ::0/0" >> "configs/${CLIENT_NAME}.conf"
echo "::: Client config generated"

echo "# begin ${CLIENT_NAME}
[Peer]
PublicKey = $(cat "keys/${CLIENT_NAME}_pub")
PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")
AllowedIPs = ${NET_REDUCED}.${COUNT}/32
# end ${CLIENT_NAME}" >> wg0.conf
echo "::: Updated server config"

if [ -f /etc/pivpn/hosts.wireguard ]; then
    echo "${NET_REDUCED}.${COUNT} ${CLIENT_NAME}.pivpn" >> /etc/pivpn/hosts.wireguard
    if killall -SIGHUP pihole-FTL; then
        echo "::: Updated hosts file for Pi-hole"
    else
        echo "::: Failed to reload pihole-FTL configuration"
    fi
fi

if systemctl restart wg-quick@wg0; then
    echo "::: WireGuard restarted"
else
    echo "::: Failed to restart WireGuard"
fi

cp "configs/${CLIENT_NAME}.conf" "${install_home}/configs/${CLIENT_NAME}.conf"
chown "${install_user}":"${install_user}" "${install_home}/configs/${CLIENT_NAME}.conf"
chmod 640 "${install_home}/configs/${CLIENT_NAME}.conf"

echo "======================================================================"
echo -e "::: Done! \e[1m${CLIENT_NAME}.conf successfully created!\e[0m"
echo "::: ${CLIENT_NAME}.conf was copied to ${install_home}/configs for easy transfer."
echo "::: Please use this profile only on one device and create additional"
echo -e "::: profiles for other devices. You can also use \e[1mpivpn -qr\e[0m"
echo "::: to generate a QR Code you can scan with the mobile app."
echo "======================================================================"
