#!/bin/bash

# Some vars that might be empty but need to be defined for checks
pivpnPERSISTENTKEEPALIVE=""
pivpnDNS2=""

setupVars="/etc/pivpn/wireguard/setupVars.conf"
# shellcheck disable=SC2154
userGroup="${install_user}:${install_user}"

if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Create a client conf profile"
  echo ":::"
  echo "::: Usage: pivpn <-a|add> [-n|--name <arg>] [-h|--help]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]               Interactive mode"
  echo ":::  -n,--name            Name for the Client (default: '${HOSTNAME}')"
  echo ":::  -h,--help            Show this help dialog"
}

# Parse input arguments
while [[ "$#" -gt 0 ]]; do
  _key="${1}"

  case "${_key}" in
    -n | --name | --name=*)
      _val="${_key##--name=}"

      if [[ "${_val}" == "${_key}" ]]; then
        [[ "$#" -lt 2 ]] \
          && err "::: Missing value for the optional argument '${_key}'." \
          && exit 1

        _val="${2}"
        shift
      fi

      CLIENT_NAME="${_val}"
      ;;
    -h | --help)
      helpFunc
      exit 0
      ;;
    *)
      err "::: Error: Got an unexpected argument '${1}'"
      helpFunc
      exit 1
      ;;
  esac

  shift
done

# Disabling SC2154, variables sourced externaly
# shellcheck disable=SC2154
# The home folder variable was sourced from the settings file.
if [[ ! -d "${install_home}/configs" ]]; then
  mkdir "${install_home}/configs"
  chown "${userGroup}" "${install_home}/configs"
  chmod 0750 "${install_home}/configs"
fi

cd /etc/wireguard || exit

if [[ -z "${CLIENT_NAME}" ]]; then
  read -r -p "Enter a Name for the Client: " CLIENT_NAME
elif [[ "${CLIENT_NAME}" =~ [^a-zA-Z0-9.@_-] ]]; then
  err "Name can only contain alphanumeric characters and these symbols (.-@_)."
  exit 1
elif [[ "${CLIENT_NAME:0:1}" == "-" ]]; then
  err "Name cannot start with -"
  exit 1
elif [[ "${CLIENT_NAME}" =~ ^[0-9]+$ ]]; then
  err "Names cannot be integers."
  exit 1
elif [[ -z "${CLIENT_NAME}" ]]; then
  err "::: You cannot leave the name blank."
  exit 1
elif [[ -f "configs/${CLIENT_NAME}.conf" ]]; then
  err "::: A client with this name already exists"
  exit 1
fi

wg genkey \
  | tee "keys/${CLIENT_NAME}_priv" \
  | wg pubkey > "keys/${CLIENT_NAME}_pub"
wg genpsk | tee "keys/${CLIENT_NAME}_psk" &> /dev/null
echo "::: Client Keys generated"

# Find an unused number for the last octet of the client IP
for i in {2..254}; do
  if ! grep -q " ${i}$" configs/clients.txt; then
    COUNT="${i}"
    echo "${CLIENT_NAME} $(< keys/"${CLIENT_NAME}"_pub) $(date +%s) ${COUNT}" \
      | tee -a configs/clients.txt > /dev/null
    break
  fi
done

# Disabling SC2154, variables sourced externaly
# shellcheck disable=SC2154
NET_REDUCED="${pivpnNET::-2}"

# shellcheck disable=SC2154
{
  echo '[Interface]'
  echo "PrivateKey = $(cat "keys/${CLIENT_NAME}_priv")"
  echo -n "Address = ${NET_REDUCED}.${COUNT}/${subnetClass}"

  if [[ "${pivpnenableipv6}" == 1 ]]; then
    echo ",${pivpnNETv6}${COUNT}/${subnetClassv6}"
  else
    echo
  fi

  echo -n "DNS = ${pivpnDNS1}"

  if [[ -n "${pivpnDNS2}" ]]; then
    echo ", ${pivpnDNS2}"
  else
    echo
  fi

  echo
  echo '[Peer]'
  echo "PublicKey = $(cat keys/server_pub)"
  echo "PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")"
  echo "Endpoint = ${pivpnHOST}:${pivpnPORT}"
  echo "AllowedIPs = ${ALLOWED_IPS}"

  if [[ -n "${pivpnPERSISTENTKEEPALIVE}" ]]; then
    echo "PersistentKeepalive = ${pivpnPERSISTENTKEEPALIVE}"
  fi
} > "configs/${CLIENT_NAME}.conf"

echo "::: Client config generated"

{
  echo "### begin ${CLIENT_NAME} ###"
  echo '[Peer]'
  echo "PublicKey = $(cat "keys/${CLIENT_NAME}_pub")"
  echo "PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")"
  echo -n "AllowedIPs = ${NET_REDUCED}.${COUNT}/32"

  if [[ "${pivpnenableipv6}" == 1 ]]; then
    echo ",${pivpnNETv6}${COUNT}/128"
  else
    echo
  fi

  echo "### end ${CLIENT_NAME} ###"
} >> wg0.conf

echo "::: Updated server config"

if [[ -f /etc/pivpn/hosts.wireguard ]]; then
  echo "${NET_REDUCED}.${COUNT} ${CLIENT_NAME}.pivpn" \
    | tee -a /etc/pivpn/hosts.wireguard > /dev/null

  if [[ "${pivpnenableipv6}" == 1 ]]; then
    echo "${pivpnNETv6}${COUNT} ${CLIENT_NAME}.pivpn" \
      | tee -a /etc/pivpn/hosts.wireguard > /dev/null
  fi

  if killall -SIGHUP pihole-FTL; then
    echo "::: Updated hosts file for Pi-hole"
  else
    err "::: Failed to reload pihole-FTL configuration"
  fi
fi

if [[ "${PLAT}" == 'Alpine' ]]; then
  if rc-service wg-quick restart; then
    echo "::: WireGuard reloaded"
  else
    err "::: Failed to reload WireGuard"
  fi
else
  if systemctl reload wg-quick@wg0; then
    echo "::: WireGuard reloaded"
  else
    err "::: Failed to reload WireGuard"
  fi
fi

cp "configs/${CLIENT_NAME}.conf" "${install_home}/configs/${CLIENT_NAME}.conf"
chown "${userGroup}" "${install_home}/configs/${CLIENT_NAME}.conf"
chmod 640 "${install_home}/configs/${CLIENT_NAME}.conf"

echo "======================================================================"
echo -e "::: Done! \e[1m${CLIENT_NAME}.conf successfully created!\e[0m"
echo -n "::: ${CLIENT_NAME}.conf was copied to ${install_home}/configs for easy"
echo "transfer."
echo "::: Please use this profile only on one device and create additional"
echo -e "::: profiles for other devices. You can also use \e[1mpivpn -qr\e[0m"
echo "::: to generate a QR Code you can scan with the mobile app."
echo "======================================================================"
