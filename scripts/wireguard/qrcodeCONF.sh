#!/bin/bash

helpFunc(){
    echo "::: Show the qrcode of a client for use with the mobile app"
    echo ":::"
    echo "::: Usage: pivpn <-qr|qrcode> [-h|--help] [<client-1>] ... [<client-n>] ..."
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Interactive mode"
    echo ":::  <client>             Client(s) to show"
    echo ":::  -h,--help            Show this help dialog"
}

# Parse input arguments
while test $# -gt 0
do
    _key="$1"
    case "$_key" in
        -h|--help)
            helpFunc
            exit 0
            ;;
        *)
            CLIENTS_TO_SHOW+=("$1")
            ;;
    esac
    shift
done

cd /etc/wireguard/configs
if [ ! -s clients.txt ]; then
    echo "::: There are no clients to show"
    exit 1
fi

LIST=($(awk '{print $1}' clients.txt))
if [ "${#CLIENTS_TO_SHOW[@]}" -eq 0 ]; then

    echo -e "::\e[4m  Client list  \e[0m::"
    len=${#LIST[@]}
    COUNTER=1
    while [ $COUNTER -le ${len} ]; do
        printf "[%0${#len}s] %s\r\n" ${COUNTER} ${LIST[(($COUNTER-1))]}
        ((COUNTER++))
    done

    read -r -p "Please enter the Index/Name of the Client to show: " CLIENTS_TO_SHOW

    if [ -z "${CLIENTS_TO_SHOW}" ]; then
        echo "::: You can not leave this blank!"
        exit 1
    fi
fi

for CLIENT_NAME in "${CLIENTS_TO_SHOW[@]}"; do
    re='^[0-9]+$'
    if [[ ${CLIENT_NAME} =~ $re ]] ; then
        CLIENT_NAME=${LIST[$(($CLIENT_NAME -1))]}
    fi    
    if grep -qw "${CLIENT_NAME}" clients.txt; then
        echo -e "::: Showing client \e[1m${CLIENT_NAME}\e[0m below"
        echo "====================================================================="
        qrencode -t ansiutf8 < "${CLIENT_NAME}.conf"
        echo "====================================================================="
    else
        echo -e "::: \e[1m${CLIENT_NAME}\e[0m does not exist"
    fi
done
