#!/bin/bash

######## Some vars that might be empty
# but need to be defined for checks
pivpnPERSISTENTKEEPALIVE=""
pivpnDNS2=""

setupVars="/etc/pivpn/wireguard/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

# shellcheck disable=SC1090
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

# Disabling SC2154, variables sourced externaly
# shellcheck disable=SC2154
# The home folder variable was sourced from the settings file.
if [ ! -d "${install_home}/configs" ]; then
    mkdir "${install_home}/configs"
    chown "${install_user}":"${install_user}" "${install_home}/configs"
    chmod 0750 "${install_home}/configs"
fi

cd /etc/wireguard || exit

if [ -z "${CLIENT_NAME}" ]; then
    read -r -p "Enter a Name for the Client: " CLIENT_NAME
fi

if [[ "${CLIENT_NAME}" =~ [^a-zA-Z0-9.@_-] ]]; then
    echo "Name can only contain alphanumeric characters and these characters (.-@_)."
    exit 1
fi

if [[ "${CLIENT_NAME:0:1}" == "-" ]]; then
    echo "Name cannot start with -"
    exit 1
fi

if [[ "${CLIENT_NAME}" =~ ^[0-9]+$ ]]; then
    echo "Names cannot be integers."
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
        echo "${CLIENT_NAME} $(<keys/"${CLIENT_NAME}"_pub) $(date +%s) ${COUNT}" >> configs/clients.txt
        break
    fi
done

# Disabling SC2154, variables sourced externaly
# shellcheck disable=SC2154
NET_REDUCED="${pivpnNET::-2}"

# shellcheck disable=SC2154
if [ "$pivpnenableipv6" == "1" ]; then
echo "[Interface]
PrivateKey = $(cat "keys/${CLIENT_NAME}_priv")
Address = ${NET_REDUCED}.${COUNT}/${subnetClass},${pivpnNETv6}${COUNT}/${subnetClassv6}" > "configs/${CLIENT_NAME}.conf"
else
echo "[Interface]
PrivateKey = $(cat "keys/${CLIENT_NAME}_priv")
Address = ${NET_REDUCED}.${COUNT}/${subnetClass}" > "configs/${CLIENT_NAME}.conf"
fi

# shellcheck disable=SC2154
echo -n "DNS = ${pivpnDNS1}" >> "configs/${CLIENT_NAME}.conf"
if [ -n "${pivpnDNS2}" ]; then
    echo ", ${pivpnDNS2}" >> "configs/${CLIENT_NAME}.conf"
else
    echo >> "configs/${CLIENT_NAME}.conf"
fi
echo >> "configs/${CLIENT_NAME}.conf"

# shellcheck disable=SC2154
echo "[Peer]
PublicKey = $(cat keys/server_pub)
PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")
Endpoint = ${pivpnHOST}:${pivpnPORT}
AllowedIPs = ${ALLOWED_IPS}" >> "configs/${CLIENT_NAME}.conf"

if [ -n "${pivpnPERSISTENTKEEPALIVE}" ]; then
    echo "PersistentKeepalive = ${pivpnPERSISTENTKEEPALIVE}" >> "configs/${CLIENT_NAME}.conf"
fi
echo "::: Client config generated"

if [ "$pivpnenableipv6" == "1" ]; then
echo "### begin ${CLIENT_NAME} ###
[Peer]
PublicKey = $(cat "keys/${CLIENT_NAME}_pub")
PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")
AllowedIPs = ${NET_REDUCED}.${COUNT}/32,${pivpnNETv6}${COUNT}/128
### end ${CLIENT_NAME} ###" >> wg0.conf
else
echo "### begin ${CLIENT_NAME} ###
[Peer]
PublicKey = $(cat "keys/${CLIENT_NAME}_pub")
PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")
AllowedIPs = ${NET_REDUCED}.${COUNT}/32
### end ${CLIENT_NAME} ###" >> wg0.conf
fi

echo "::: Updated server config"

if [ -f /etc/pivpn/hosts.wireguard ]; then
    echo "${NET_REDUCED}.${COUNT} ${CLIENT_NAME}.pivpn" >> /etc/pivpn/hosts.wireguard
    if [ "$pivpnenableipv6" == "1" ]; then
        echo "${pivpnNETv6}${COUNT} ${CLIENT_NAME}.pivpn" >> /etc/pivpn/hosts.wireguard
    fi
    if killall -SIGHUP pihole-FTL; then
        echo "::: Updated hosts file for Pi-hole"
    else
        echo "::: Failed to reload pihole-FTL configuration"
    fi
fi

if [ "${PLAT}" == 'Alpine' ]; then
    if rc-service wg-quick restart; then
        echo "::: WireGuard reloaded"
    else
        echo "::: Failed to reload WireGuard"
    fi
else
    if systemctl reload wg-quick@wg0; then
        echo "::: WireGuard reloaded"
    else
        echo "::: Failed to reload WireGuard"
    fi
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
