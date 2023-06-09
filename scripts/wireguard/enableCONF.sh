#!/bin/bash

### Constants
setupVars="/etc/pivpn/wireguard/setupVars.conf"

# shellcheck disable=SC1090
source "${setupVars}"

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Enables client conf profiles"
  echo ":::"
  echo -n "::: Usage: pivpn <-on|on> [-h|--help] [-v] "
  echo "[<client-1> ... [<client-2>] ...]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]               Interactive mode"
  echo ":::  <client>             Client"
  echo ":::  -y,--yes             Enable client(s) without confirmation"
  echo ":::  -v                   Show disabled clients only"
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
    -v)
      DISPLAY_DISABLED=true
      ;;
    *)
      CLIENTS_TO_CHANGE+=("${1}")
      ;;
  esac

  shift
done

cd /etc/wireguard || exit

if [[ ! -s configs/clients.txt ]]; then
  err "::: There are no clients to change"
  exit 1
fi

if [[ "${DISPLAY_DISABLED}" ]]; then
  grep '\[disabled\] ### begin' wg0.conf | sed 's/#//g; s/begin//'
  exit 1
fi

mapfile -t LIST < <(awk '{print $1}' configs/clients.txt)

if [[ "${#CLIENTS_TO_CHANGE[@]}" -eq 0 ]]; then
  echo -e "::\e[4m  Client list  \e[0m::"
  len="${#LIST[@]}"
  COUNTER=1

  while [[ "${COUNTER}" -le "${len}" ]]; do
    printf "%0${#len}s) %s\r\n" "${COUNTER}" "${LIST[(($COUNTER - 1))]}"
    ((COUNTER++))
  done

  echo -n "Please enter the Index/Name of the Client to be enabled "
  echo -n "from the list above: "
  read -r CLIENTS_TO_CHANGE

  if [[ -z "${CLIENTS_TO_CHANGE}" ]]; then
    err "::: You can not leave this blank!"
    exit 1
  fi
fi

CHANGED_COUNT=0

for CLIENT_NAME in "${CLIENTS_TO_CHANGE[@]}"; do
  re='^[0-9]+$'

  if [[ "${CLIENT_NAME}" =~ $re ]]; then
    CLIENT_NAME="${LIST[$((CLIENT_NAME - 1))]}"
  fi

  if ! grep -q "^${CLIENT_NAME} " configs/clients.txt; then
    echo -e "::: \e[1m${CLIENT_NAME}\e[0m does not exist"
  else
    if [[ -n "${CONFIRM}" ]]; then
      REPLY="y"
    else
      read -r -p "Confirm you want to enable ${CLIENT_NAME}? [Y/n] "
    fi

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      # Enable the peer section from the server config
      echo "${CLIENT_NAME}"

      sed_pattern="/### begin ${CLIENT_NAME} ###/,"
      sed_pattern="${sed_pattern}/### end ${CLIENT_NAME} ###/ s/#\[disabled\] //"
      sed -e "${sed_pattern}" -i wg0.conf
      unset sed_pattern

      echo "::: Updated server config"
      ((CHANGED_COUNT++))
      echo "::: Successfully enabled ${CLIENT_NAME}"
    fi
  fi
done

# Restart WireGuard only if some clients were actually deleted
if [[ "${CHANGED_COUNT}" -gt 0 ]]; then
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
