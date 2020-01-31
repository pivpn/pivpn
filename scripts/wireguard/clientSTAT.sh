#!/bin/bash

cd /etc/wireguard/configs
if [ ! -s clients.txt ]; then
    echo "::: There are no clients to list"
    exit 1
fi

hr(){
    numfmt --to=iec-i --suffix=B "$1"
}

if DUMP="$(wg show wg0 dump)"; then
    DUMP="$(tail -n +2 <<< "$DUMP")"
else
    exit 1
fi

printf "\e[1m::: Connected Clients List :::\e[0m\n"

{
printf "\e[4mName\e[0m  \t  \e[4mRemote IP\e[0m  \t  \e[4mVirtual IP\e[0m  \t  \e[4mBytes Received\e[0m  \t  \e[4mBytes Sent\e[0m  \t  \e[4mLast Seen\e[0m\n"

while IFS= read -r LINE; do

    PUBLIC_KEY="$(awk '{ print $1 }' <<< "$LINE")"
    REMOTE_IP="$(awk '{ print $3 }' <<< "$LINE")"
    VIRTUAL_IP="$(awk '{ print $4 }' <<< "$LINE")"
    BYTES_RECEIVED="$(awk '{ print $6 }' <<< "$LINE")"
    BYTES_SENT="$(awk '{ print $7 }' <<< "$LINE")"
    LAST_SEEN="$(awk '{ print $5 }' <<< "$LINE")"
    CLIENT_NAME="$(grep "$PUBLIC_KEY" clients.txt | awk '{ print $1 }')"

    if [ "$LAST_SEEN" -ne 0 ]; then
        printf "%s  \t  %s  \t  %s  \t  %s  \t  %s  \t  %s\n" "$CLIENT_NAME" "$REMOTE_IP" "${VIRTUAL_IP/\/32/}" "$(hr "$BYTES_RECEIVED")" "$(hr "$BYTES_SENT")" "$(date -d @"$LAST_SEEN" '+%b %d %Y - %T')"
    else
        printf "%s  \t  %s  \t  %s  \t  %s  \t  %s  \t  %s\n" "$CLIENT_NAME" "$REMOTE_IP" "${VIRTUAL_IP/\/32/}" "$(hr "$BYTES_RECEIVED")" "$(hr "$BYTES_SENT")" "(not yet)"
    fi

done <<< "$DUMP"

printf "\n"
} | column -t -s $'\t'