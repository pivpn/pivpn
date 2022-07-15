#!/bin/bash

######## Some vars that might be empty
# but need to be defined for checks
pivpnPERSISTENTKEEPALIVE=''
pivpnDNS2=''

setupVars='/etc/pivpn/wireguard/setupVars.conf'

if [ ! -f "${setupVars}" ]
then
	echo '::: Missing setup vars file!'
	exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

helpFunc() {
	echo '::: Create a client conf profile'
	echo ':::'
	echo '::: Usage: pivpn <-a|add> [-n|--name <arg>] [-h|--help]'
	echo ':::'
	echo '::: Commands:'
	echo ':::  [none]               Interactive mode'
	echo ":::  -n,--name            Name for the Client (default: '${HOSTNAME}')"
	echo ':::  -h,--help            Show this help dialog'
}

# Parse input arguments
while [ $# -gt 0 ]
do
	case "$1" in
		-n | --name | --name=*)
			_val="${1##--name=}"

			if [ "${_val}" == "$1" ]
			then
				if [ $# -lt 2]
				then
					echo "::: Missing value for the optional argument '$1'."
					exit 1
				fi

				_val="$2"
				shift
			fi

			CLIENT_NAME="${_val}"
			;;
		-h | --help)
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
mkdir -p "${install_home}/configs"
chown "${install_user}:${install_user}" "${install_home}/configs"
chmod 750 "${install_home}/configs"

cd /etc/wireguard || \
	exit

[ -z "${CLIENT_NAME}" ] && \
	read -r -p 'Enter a Name for the Client: ' CLIENT_NAME

if ! [[ "${CLIENT_NAME}" =~ ^[a-zA-Z0-9\.\@\_\-]+$ ]]
then
	echo 'Name can only contain alphanumeric characters and these characters (.-@_).'
	exit 1
fi

if [ "${CLIENT_NAME:0:1}" == '-' ]
then
	echo 'Name cannot start with -'
	exit 1
fi

if [[ "${CLIENT_NAME}" =~ ^[0-9]+$ ]]
then
	echo 'Names cannot be integers.'
	exit 1
fi

if [ -z "${CLIENT_NAME}" ]
then
	echo '::: You cannot leave the name blank.'
	exit 1
fi

if [ -f "configs/${CLIENT_NAME}.conf" ]
then
	echo '::: A client with this name already exists'
	exit 1
fi

client_private_key=$(wg genkey | \
	tee "keys/${CLIENT_NAME}_priv")

client_public_key=$(echo "${client_private_key}" | \
	wg pubkey | \
	tee "keys/${CLIENT_NAME}_pub")

client_psk=$(wg genpsk | \
	tee "keys/${CLIENT_NAME}_psk")

echo '::: Client Keys generated'

# Find an unused number for the last octet of the client IP
for i in $(seq 2 254)
do
	if ! grep -qsEe " ${i}$" configs/clients.txt
	then
		COUNT="${i}"
		echo "${CLIENT_NAME}" $(< "keys/${CLIENT_NAME}_pub") $(date +%s) "${COUNT}" >> configs/clients.txt
		break
	fi
done

# Disabling SC2154, variables sourced externaly
# shellcheck disable=SC2154
NET_REDUCED="${pivpnNET::-2}"

# shellcheck disable=SC2154
echo '[Interface]' > "configs/${CLIENT_NAME}.conf"
echo "PrivateKey = ${client_private_key}" >> "configs/${CLIENT_NAME}.conf"
echo -n "Address = ${NET_REDUCED}.${COUNT}/${subnetClass}" >> "configs/${CLIENT_NAME}.conf"
[ $pivpnenableipv6 -eq 1 ] && \
	echo ",${pivpnNETv6}${COUNT}/${subnetClassv6}" >> "configs/${CLIENT_NAME}.conf" || \
	echo >> "configs/${CLIENT_NAME}.conf"
# shellcheck disable=SC2154
echo -n "DNS = ${pivpnDNS1}" >> "configs/${CLIENT_NAME}.conf"
[ -n "${pivpnDNS2}" ] && \
	echo ", ${pivpnDNS2}" >> "configs/${CLIENT_NAME}.conf" || \
	echo >> "configs/${CLIENT_NAME}.conf"
echo >> "configs/${CLIENT_NAME}.conf"

server_public_key=$(cat keys/server_pub)

# shellcheck disable=SC2154
echo '[Peer]' >> "configs/${CLIENT_NAME}.conf"
echo "PublicKey = ${server_public_key}" >> "configs/${CLIENT_NAME}.conf"
echo "PresharedKey = ${client_psk}" >> "configs/${CLIENT_NAME}.conf"
echo "Endpoint = ${pivpnHOST}:${pivpnPORT}" >> "configs/${CLIENT_NAME}.conf"
echo "AllowedIPs = ${ALLOWED_IPS}" >> "configs/${CLIENT_NAME}.conf"
[ -n "${pivpnPERSISTENTKEEPALIVE}" ] && \
	echo "PersistentKeepalive = ${pivpnPERSISTENTKEEPALIVE}" >> "configs/${CLIENT_NAME}.conf"

echo '::: Client config generated'

echo "### begin ${CLIENT_NAME} ###" >> wg0.conf
echo '[Peer]' >> wg0.conf
echo "PublicKey = ${client_public_key}" >> wg0.conf
echo "PresharedKey = ${client_psk}" >> wg0.conf
echo -n "AllowedIPs = ${NET_REDUCED}.${COUNT}/32" >> wg0.conf
[ $pivpnenableipv6 -eq 1 ] && \
	echo ",${pivpnNETv6}${COUNT}/128" >> wg0.conf || \
	echo >> wg0.conf
echo "### end ${CLIENT_NAME} ###" >> wg0.conf

echo '::: Updated server config'

if [ -f /etc/pivpn/hosts.wireguard ]
then
	echo "${NET_REDUCED}.${COUNT} ${CLIENT_NAME}.pivpn" >> /etc/pivpn/hosts.wireguard

	[ $pivpnenableipv6 -eq 1 ] && \
		echo "${pivpnNETv6}${COUNT} ${CLIENT_NAME}.pivpn" >> /etc/pivpn/hosts.wireguard

	killall -s HUP pihole-FTL && \
		echo '::: Updated hosts file for Pi-hole' || \
		echo '::: Failed to reload pihole-FTL configuration'
fi

systemctl reload wg-quick@wg0 && \
	echo '::: WireGuard reloaded' || \
	echo '::: Failed to reload WireGuard'

cp "configs/${CLIENT_NAME}.conf" "${install_home}/configs/${CLIENT_NAME}.conf"

chown "${install_user}:${install_user}" "${install_home}/configs/${CLIENT_NAME}.conf"
chmod 640 "${install_home}/configs/${CLIENT_NAME}.conf"

echo '======================================================================'
echo -e "::: Done! \e[1m${CLIENT_NAME}.conf successfully created!\e[0m"
echo "::: ${CLIENT_NAME}.conf was copied to ${install_home}/configs for easy transfer."
echo '::: Please use this profile only on one device and create additional'
echo -e '::: profiles for other devices. You can also use \e[1mpivpn -qr\e[0m'
echo '::: to generate a QR Code you can scan with the mobile app.'
echo '======================================================================'
