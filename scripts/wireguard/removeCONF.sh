#!/bin/bash

setupVars="/etc/pivpn/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

helpFunc(){
    echo "::: Remove a client conf profile"
    echo ":::"
    echo "::: Usage: pivpn <-r|remove> [-h|--help] [<client-1>] ... [<client-n>] ..."
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Interactive mode"
    echo ":::  <client>             Client(s) to remove"
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
            CLIENTS_TO_REMOVE+=("$1")
            ;;
    esac
    shift
done

cd /etc/wireguard
if [ ! -s configs/clients.txt ]; then
    echo "::: There are no clients to remove"
    exit 1
fi

if [ "${#CLIENTS_TO_REMOVE[@]}" -eq 0 ]; then

    echo -e "::\e[4m  Client list  \e[0m::"
    LIST=($(awk '{print $1}' configs/clients.txt))
    COUNTER=1
    while [ $COUNTER -le ${#LIST[@]} ]; do
        echo "• ${LIST[(($COUNTER-1))]}"
        ((COUNTER++))
    done

    read -r -p "Please enter the Name of the Client to be removed from the list above: " CLIENTS_TO_REMOVE

    if [ -z "${CLIENTS_TO_REMOVE}" ]; then
        echo "::: You can not leave this blank!"
        exit 1
    fi
fi

DELETED_COUNT=0

for CLIENT_NAME in "${CLIENTS_TO_REMOVE[@]}"; do

    if ! grep -qw "${CLIENT_NAME}" configs/clients.txt; then
        echo -e "::: \e[1m${CLIENT_NAME}\e[0m does not exist"
    else
        REQUESTED="$(sha256sum "configs/${CLIENT_NAME}.conf" | cut -c 1-64)"
        read -r -p "Do you really want to delete $CLIENT_NAME? [Y/n] "

        if [[ $REPLY =~ ^[Yy]$ ]]; then

            # Grab the least significant octed of the client IP address
            COUNT=$(grep "${CLIENT_NAME}" configs/clients.txt | awk '{print $4}')
            # The creation date of the client
            CREATION_DATE="$(grep "${CLIENT_NAME}" configs/clients.txt | awk '{print $3}')"
            # And its public key
            PUBLIC_KEY="$(grep "${CLIENT_NAME}" configs/clients.txt | awk '{print $2}')"

            # Then remove the client matching the variables above
            sed "\#${CLIENT_NAME} ${PUBLIC_KEY} ${CREATION_DATE} ${COUNT}#d" -i configs/clients.txt

            # Remove the peer section from the server config
            sed "/# begin ${CLIENT_NAME}/,/# end ${CLIENT_NAME}/d" -i wg0.conf
            echo "::: Updated server config"

            rm "configs/${CLIENT_NAME}.conf"
            echo "::: Client config for ${CLIENT_NAME} removed"

            rm "keys/${CLIENT_NAME}_priv"
            rm "keys/${CLIENT_NAME}_pub"
            rm "keys/${CLIENT_NAME}_psk"
            echo "::: Client Keys for ${CLIENT_NAME} removed"

            # Find all .conf files in the home folder of the user matching the checksum of the
            # config and delete them. '-maxdepth 3' is used to avoid traversing too many folders.
            find "${install_home}" -maxdepth 3 -type f -name '*.conf' -print0 | while IFS= read -r -d '' CONFIG; do
                if sha256sum -c <<< "${REQUESTED}  ${CONFIG}" &> /dev/null; then
                    rm "${CONFIG}"
                fi
            done

            ((DELETED_COUNT++))
            echo "::: Successfully deleted ${CLIENT_NAME}"

            # If using Pi-hole, remove the client from the hosts file
            if [ -f /etc/pivpn/hosts.wireguard ]; then
                NET_REDUCED="${pivpnNET::-2}"
                sed "\#${NET_REDUCED}.${COUNT} ${CLIENT_NAME}.pivpn#d" -i /etc/pivpn/hosts.wireguard
                if killall -SIGHUP pihole-FTL; then
                    echo "::: Updated hosts file for Pi-hole"
                else
                    echo "::: Failed to reload pihole-FTL configuration"
                fi
            fi

        fi
    fi

done

# Restart WireGuard only if some clients were actually deleted
if [ "${DELETED_COUNT}" -gt 0 ]; then
    if systemctl restart wg-quick@wg0; then
        echo "::: WireGuard restarted"
    else
        echo "::: Failed to restart WireGuard"
    fi
fi
