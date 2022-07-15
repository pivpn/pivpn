#!/usr/bin/env bash
# PiVPN: client status script

CLIENTS_FILE='/etc/wireguard/configs/clients.txt'

if [ ! -s "${CLIENTS_FILE}" ]
then
    echo '::: There are no clients to list'
    exit 0
fi

scriptusage() {
    echo '::: List any connected clients to the server'
    echo ':::'
    echo '::: Usage: pivpn <-c|clients> [-b|bytes]'
    echo ':::'
    echo '::: Commands:'
    echo ':::  [none]              List clients with human readable format'
    echo ':::  -b, bytes           List clients with dotted decimal notation'
    echo ':::  -h, help            Show this usage dialog'
}

hr() {
    numfmt --to=iec-i --suffix=B "$1"
}

listClients() {
    DUMP=$(wg show wg0 dump) && \
        DUMP=$(tail -n +2 <<< "${DUMP}") || \
        exit 1

    printf '\e[1m::: Connected Clients List :::\e[0m\n'

    {
        printf "\e[4mName\e[0m  \t  \e[4mRemote IP\e[0m  \t  \e[4mVirtual IP\e[0m  \t  \e[4mBytes Received\e[0m  \t  \e[4mBytes Sent\e[0m  \t  \e[4mLast Seen\e[0m\n"

        while IFS= read -r LINE
        do
            if [ -n "${LINE}" ]
            then
                PUBLIC_KEY=$(awk '{ print $1 }' <<< "${LINE}")
                REMOTE_IP=$(awk '{ print $3 }' <<< "${LINE}")
                VIRTUAL_IP=$(awk '{ print $4 }' <<< "${LINE}")
                BYTES_RECEIVED=$(awk '{ print $6 }' <<< "${LINE}")
                BYTES_SENT=$(awk '{ print $7 }' <<< "${LINE}")
                LAST_SEEN=$(awk '{ print $5 }' <<< "${LINE}")
                CLIENT_NAME=$(grep -sEe "${PUBLIC_KEY}" "${CLIENTS_FILE}" | \
                    awk '{ print $1 }')

                if [ $HR -eq 1 ]
                then
                    printf '%s  \t  %s  \t  %s  \t  %s  \t  %s  \t  ' "${CLIENT_NAME}" "${REMOTE_IP}" "${VIRTUAL_IP/\/32/}" $(hr "${BYTES_RECEIVED}") $(hr "${BYTES_SENT}")

                    [ $LAST_SEEN -ne 0 ] && \
                        printf '%s' $(date -d @"${LAST_SEEN}" '+%b %d %Y - %T') || \
                        printf '(not yet)'

                    printf '\n'
                else
                    printf '%s  \t  %s  \t  %s  \t  %'d  \t  %'d  \t  ' "${CLIENT_NAME}" "${REMOTE_IP}" "${VIRTUAL_IP/\/32/}" "${BYTES_RECEIVED}" "${BYTES_SENT}"

                    [ $LAST_SEEN -ne 0 ] && \
                        printf '%s' $(date -d @"${LAST_SEEN}" '+%b %d %Y - %T') || \
                        printf '(not yet)'

                    printf '\n'
                fi
            fi
        done <<< "${DUMP}"

        printf '\n'
    } | \
        column -ts $'\t'

    cd /etc/wireguard || \
        return

    echo '::: Disabled clients :::'

    grep -sEe '[disabled] \#\#\# begin' wg0.conf | \
        sed -Ee 's/\#//g; s/begin//'
}

if [ $# -eq 0 ]
then
    HR=1
    listClients
else
    while true
    do
        case "$1" in
            -b | bytes)
                HR=0
                listClients
                ;;
            -h | help)
                scriptusage
                ;;
            *)
                HR=0
                listClients
                ;;
        esac
    done
fi
