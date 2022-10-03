#!/bin/bash
# PiVPN: client status script

CLIENTS_FILE="/etc/wireguard/configs/clients.txt"

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

if [[ ! -s "${CLIENTS_FILE}" ]]; then
  err "::: There are no clients to list"
  exit 0
fi

scriptusage() {
  echo "::: List any connected clients to the server"
  echo ":::"
  echo "::: Usage: pivpn <-c|clients> [-b|bytes]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]              List clients with human readable format"
  echo ":::  -b, bytes           List clients with dotted decimal notation"
  echo ":::  -h, help            Show this usage dialog"
}

hr() {
  numfmt --to=iec-i --suffix=B "${1}"
}

listClients() {
  if DUMP="$(wg show wg0 dump)"; then
    DUMP="$(tail -n +2 <<< "${DUMP}")"
  else
    exit 1
  fi

  printf "\e[1m::: Connected Clients List :::\e[0m\n"

  {
    printf "\e[4mName\e[0m  \t  \e[4mRemote IP\e[0m  \t  \e[4mVirtual IP\e[0m"
    printf "\t  \e[4mBytes Received\e[0m  \t  \e[4mBytes Sent\e[0m  "
    printf "\t  \e[4mLast Seen\e[0m\n"

    while IFS= read -r LINE; do
      if [[ -n "${LINE}" ]]; then
        PUBLIC_KEY="$(awk '{ print $1 }' <<< "${LINE}")"
        REMOTE_IP="$(awk '{ print $3 }' <<< "${LINE}")"
        VIRTUAL_IP="$(awk '{ print $4 }' <<< "${LINE}")"
        BYTES_RECEIVED="$(awk '{ print $6 }' <<< "${LINE}")"
        BYTES_SENT="$(awk '{ print $7 }' <<< "${LINE}")"
        LAST_SEEN="$(awk '{ print $5 }' <<< "${LINE}")"
        CLIENT_NAME="$(grep "${PUBLIC_KEY}" "${CLIENTS_FILE}" \
          | awk '{ print $1 }')"
        printf "%s  \t  %s  \t  %s  \t  " \
          "${CLIENT_NAME}" \
          "${REMOTE_IP}" \
          "${VIRTUAL_IP/\/32/}"

        if [[ "${HR}" == 1 ]]; then
          printf "%s  \t  %s  \t  " \
            "$(hr "${BYTES_RECEIVED}")" \
            "$(hr "${BYTES_SENT}")"
        else
          printf "%s  \t  %s  \t  " "${BYTES_RECEIVED}" "${BYTES_SENT}"
        fi

        if [[ "${LAST_SEEN}" -ne 0 ]]; then
          printf "%s" "$(date -d @"${LAST_SEEN}" '+%b %d %Y - %T')"
        else
          printf "(not yet)"
        fi

        printf "\n"
      fi
    done <<< "${DUMP}"

    printf "\n"
  } | column -ts $'\t'

  cd /etc/wireguard || return

  echo "::: Disabled clients :::"
  grep '\[disabled\] ### begin' wg0.conf | sed 's/#//g; s/begin//'
}

if [[ "$#" -eq 0 ]]; then
  HR=1
  listClients
else
  while true; do
    case "${1}" in
      -b | bytes)
        HR=0
        listClients
        exit 0
        ;;
      -h | help)
        scriptusage
        exit 0
        ;;
      *)
        HR=0
        listClients
        exit 0
        ;;
    esac
  done
fi
