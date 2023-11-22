#!/bin/bash

### Constants
setupVars="/etc/pivpn/wireguard/setupVars.conf"

# shellcheck disable=SC1090
source "${setupVars}"

if [ ! -r /opt/pivpn/ipaddr_utils.sh ]; then
  exit 1
fi
# shellcheck disable=SC1091
source /opt/pivpn/ipaddr_utils.sh

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Remove a client conf profile"
  echo ":::"
  echo -n "::: Usage: pivpn <-r|remove> [-y|--yes] [-h|--help] "
  echo "[<client-1> ... [<client-2>] ...]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]               Interactive mode"
  echo ":::  <client>             Client(s) to remove"
  echo ":::  -y,--yes             Remove Client(s) without confirmation"
  echo ":::  -h,--help            Show this help dialog"
}

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

# Parse input arguments
while [[ "$#" -gt 0 ]]; do
  _key="${1}"

  case "${_key}" in
    -h | --help)
      helpFunc
      exit 0
      ;;
    -y | --yes)
      CONFIRM=true
      ;;
    *)
      CLIENTS_TO_REMOVE+=("${1}")
      ;;
  esac

  shift
done

cd /etc/wireguard || exit

if [[ ! -s configs/clients.txt ]]; then
  err "::: There are no clients to remove"
  exit 1
fi

mapfile -t LIST < <(awk '{print $1}' configs/clients.txt)

if [[ "${#CLIENTS_TO_REMOVE[@]}" -eq 0 ]]; then
  echo -e "::\e[4m  Client list  \e[0m::"
  len="${#LIST[@]}"
  COUNTER=1

  while [[ "${COUNTER}" -le "${len}" ]]; do
    printf "%0${#len}s) %s\r\n" "${COUNTER}" "${LIST[(($COUNTER - 1))]}"
    ((COUNTER++))
  done

  echo -n "Please enter the Index/Name of the Client to be removed "
  echo -n "from the list above: "
  read -r CLIENTS_TO_REMOVE

  if [[ -z "${CLIENTS_TO_REMOVE}" ]]; then
    err "::: You can not leave this blank!"
    exit 1
  fi
fi

DELETED_COUNT=0

for CLIENT_NAME in "${CLIENTS_TO_REMOVE[@]}"; do
  re='^[0-9]+$'

  if [[ "${CLIENT_NAME}" =~ $re ]]; then
    CLIENT_NAME="${LIST[$((CLIENT_NAME - 1))]}"
  fi

  if ! grep -q "^${CLIENT_NAME} " configs/clients.txt; then
    echo -e "::: \e[1m${CLIENT_NAME}\e[0m does not exist"
  else
    REQUESTED="$(sha256sum "configs/${CLIENT_NAME}.conf" | cut -c 1-64)"

    if [[ -n "${CONFIRM}" ]]; then
      REPLY="y"
    else
      read -r -p "Do you really want to delete ${CLIENT_NAME}? [y/N] "
    fi

    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      # Grab the decimal representation of the client IP address
      IPV4_DEC="$(grep "^${CLIENT_NAME} " configs/clients.txt | awk '{print $4}')"
      # The creation date of the client
      CREATION_DATE="$(grep "^${CLIENT_NAME} " configs/clients.txt \
        | awk '{print $3}')"
      # And its public key
      PUBLIC_KEY="$(grep "^${CLIENT_NAME} " configs/clients.txt \
        | awk '{print $2}')"

      # Then remove the client matching the variables above
      sed \
        -e "\#${CLIENT_NAME} ${PUBLIC_KEY} ${CREATION_DATE} ${IPV4_DEC}#d" \
        -i configs/clients.txt

      # Remove the peer section from the server config
      sed_pattern="/### begin ${CLIENT_NAME} ###/,"
      sed_pattern="${sed_pattern}/### end ${CLIENT_NAME} ###/d"
      sed -e "${sed_pattern}" -i wg0.conf
      echo "::: Updated server config"

      rm "configs/${CLIENT_NAME}.conf"
      echo "::: Client config for ${CLIENT_NAME} removed"

      rm "keys/${CLIENT_NAME}_priv"
      rm "keys/${CLIENT_NAME}_pub"
      rm "keys/${CLIENT_NAME}_psk"
      echo "::: Client Keys for ${CLIENT_NAME} removed"

      # Find all .conf files in the home folder of the user matching the
      # checksum of the config and delete them. '-maxdepth 3' is used to
      # avoid traversing too many folders.
      # Disabling SC2154, variable sourced externaly and may vary
      # shellcheck disable=SC2154
      while IFS= read -r -d '' CONFIG; do
        if sha256sum -c <<< "${REQUESTED}  ${CONFIG}" &> /dev/null; then
          rm "${CONFIG}"
        fi
      done < <(find "${install_home}" \
        -maxdepth 3 -type f -name '*.conf' -print0)

      ((DELETED_COUNT++))
      echo "::: Successfully deleted ${CLIENT_NAME}"

      # If using Pi-hole, remove the client from the hosts file
      # Disabling SC2154, variable sourced externaly and may vary
      # shellcheck disable=SC2154
      if [[ -f /etc/pivpn/hosts.wireguard ]]; then
        IPV4_DOT="$(decIPv4ToDot "${IPV4_DEC}")"
        IPV4_HEX="$(decIPv4ToHex "${IPV4_DEC}")"
        sed \
          -e "\#${IPV4_DOT} ${CLIENT_NAME}.pivpn#d" \
          -e "\#${pivpnNETv6}${IPV4_HEX} ${CLIENT_NAME}.pivpn#d" \
          -i /etc/pivpn/hosts.wireguard

        if killall -SIGHUP pihole-FTL; then
          echo "::: Updated hosts file for Pi-hole"
        else
          err "::: Failed to reload pihole-FTL configuration"
        fi
      fi

      unset sed_pattern
    else
      err "Aborting operation"
      exit 1
    fi
  fi
done

# Restart WireGuard only if some clients were actually deleted
if [[ "${DELETED_COUNT}" -gt 0 ]]; then
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
fi
