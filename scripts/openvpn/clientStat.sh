#!/bin/bash
# PiVPN: client status script

STATUS_LOG="/var/log/openvpn-status.log"

if [[ ! -f "${STATUS_LOG}" ]]; then
  err "The file: ${STATUS_LOG} was not found!"
  exit 1
fi

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

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
  printf ": NOTE : The output below is NOT real-time!\n"
  printf ":      : It may be off by a few minutes.\n"
  printf "\n"
  printf "\e[1m::: Client Status List :::\e[0m\n"

  {
    printf "\e[4mName\e[0m  \t  \e[4mRemote IP\e[0m  \t  "
    printf "\e[4mVirtual IP\e[0m  \t  \e[4mBytes Received\e[0m  \t  "
    printf "\e[4mBytes Sent\e[0m  \t  \e[4mConnected Since\e[0m\n"

    if grep -q "^CLIENT_LIST" "${STATUS_LOG}"; then
      if [[ -n "$(type -t numfmt)" ]]; then
        while read -r line; do
          read -r -a array <<< "${line}"

          [[ "${array[0]}" == 'CLIENT_LIST' ]] || continue

          printf "%s  \t  %s  \t  " "${array[1]}" "${array[2]}"
          printf "%s  \t  " "${array[3]}"

          if [[ "${HR}" == 1 ]]; then
            printf "%s  \t  %s" "$(hr "${array[4]}")" "$(hr "${array[5]}")"
          else
            printf "%'d  \t  %'d" "${array[4]}" "${array[5]}"
          fi

          printf "  \t  %s %s %s " "${array[7]}" "${array[8]}" "${array[10]}"
          printf "- %s\n" "${array[9]}"
          printf "\n"
        done < "${STATUS_LOG}"
      else
        awk -F ' ' -v s='CLIENT_LIST' \
          '$1 == s {
            print $2"\t\t"$3"\t"$4"\t"$5"\t\t"$6"\t\t"$8" "$9" "$11" - "$10"\n"
          }' \
          "${STATUS_LOG}"
      fi
    else
      printf "\nNo Clients Connected!\n"
    fi

    printf "\n"
  } | column -t -s $'\t'
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
