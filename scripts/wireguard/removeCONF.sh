#!/bin/bash

setupVars='/etc/pivpn/wireguard/setupVars.conf'

if [ ! -f "${setupVars}" ]
then
    echo '::: Missing setup vars file!'
    exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

helpFunc() {
    echo '::: Remove a client conf profile'
    echo ':::'
    echo '::: Usage: pivpn <-r|remove> [-y|--yes] [-h|--help] [<client-1>] ... [<client-n>] ...'
    echo ':::'
    echo '::: Commands:'
    echo ':::  [none]               Interactive mode'
    echo ':::  <client>             Client(s) to remove'
    echo ':::  -y,--yes             Remove Client(s) without confirmation'
    echo ':::  -h,--help            Show this help dialog'
}

# Parse input arguments
while [ $# -gt 0 ]
do
    case "$1" in
        -h | --help)
            helpFunc
            exit 0
            ;;
        -y | --yes)
            CONFIRM=true
            ;;
        *)
            CLIENTS_TO_REMOVE+=("$1")
            ;;
    esac

    shift
done

cd /etc/wireguard || \
    exit

if [ ! -s configs/clients.txt ]
then
    echo '::: There are no clients to remove'
    exit 1
fi

mapfile -t LIST < <(awk '{print $1}' configs/clients.txt)

if [ "${#CLIENTS_TO_REMOVE[@]}" -eq 0 ]
then
    echo -e '::\e[4m  Client list  \e[0m::'

    len=${#LIST[@]}
    COUNTER=1

    while [ $COUNTER -le $len ]
    do
        printf "%0${#len}s) %s\r\n" "${COUNTER}" "${LIST[(($COUNTER-1))]}"
        ((COUNTER++))
    done

    read -r -p 'Please enter the Index/Name of the Client to be removed from the list above: ' CLIENTS_TO_REMOVE

    if [ -z "${CLIENTS_TO_REMOVE}" ]
    then
        echo '::: You can not leave this blank!'
        exit 1
    fi
fi

DELETED_COUNT=0

for CLIENT_NAME in "${CLIENTS_TO_REMOVE[@]}"
do
    [[ "${CLIENT_NAME}" =~ ^[0-9]+$ ]] && \
        CLIENT_NAME=${LIST[$((CLIENT_NAME -1))]}

    if ! grep -qsEe "^${CLIENT_NAME} " configs/clients.txt
    then
        echo -e "::: \e[1m${CLIENT_NAME}\e[0m does not exist"
    else
        REQUESTED=$(sha256sum "configs/${CLIENT_NAME}.conf" | \
            cut -c 1-64)

        [ -n "${CONFIRM}" ] && \
            REPLY='y' || \
            read -r -p "Do you really want to delete ${CLIENT_NAME}? [y/N] "

        if [[ "${REPLY}" =~ ^[Yy]$ ]]
        then
            # Grab the least significant octed of the client IP address
            COUNT=$(grep -sEe "^${CLIENT_NAME} " configs/clients.txt | \
                awk '{print $4}')
            # The creation date of the client
            CREATION_DATE=$(grep -sEe "^${CLIENT_NAME} " configs/clients.txt | \
                awk '{print $3}')
            # And its public key
            PUBLIC_KEY=$(grep -sEe "^${CLIENT_NAME} " configs/clients.txt | \
                awk '{print $2}')

            # Then remove the client matching the variables above
            sed -iEe "/${CLIENT_NAME} ${PUBLIC_KEY} ${CREATION_DATE} ${COUNT}/d" configs/clients.txt

            # Remove the peer section from the server config
            sed -iEe "/\#\#\# begin ${CLIENT_NAME} \#\#\#/,/\#\#\# end ${CLIENT_NAME} \#\#\#/d" wg0.conf

            echo '::: Updated server config'

            rm "configs/${CLIENT_NAME}.conf"

            echo "::: Client config for ${CLIENT_NAME} removed"

            rm "keys/${CLIENT_NAME}_priv" "keys/${CLIENT_NAME}_pub" "keys/${CLIENT_NAME}_psk"

            echo "::: Client Keys for ${CLIENT_NAME} removed"

            # Find all .conf files in the home folder of the user matching the checksum of the
            # config and delete them. '-maxdepth 3' is used to avoid traversing too many folders.
            # Disabling SC2154, variable sourced externaly and may vary
            # shellcheck disable=SC2154
            find "${install_home}" -maxdepth 3 -type f -name '*.conf' -print0 | \
                while IFS= read -r -d '' CONFIG
                do
                    sha256sum -c <<< "${REQUESTED}  ${CONFIG}" &> /dev/null && \
                        rm "${CONFIG}"
                done

            ((DELETED_COUNT++))

            echo "::: Successfully deleted ${CLIENT_NAME}"

            # If using Pi-hole, remove the client from the hosts file
            # Disabling SC2154, variable sourced externaly and may vary
            # shellcheck disable=SC2154
            if [ -f /etc/pivpn/hosts.wireguard ]
            then
                NET_REDUCED="${pivpnNET::-2}"
                sed -iEe "/${NET_REDUCED}.${COUNT} ${CLIENT_NAME}.pivpn/d" -e "/${pivpnNETv6}${COUNT} ${CLIENT_NAME}.pivpn/d" /etc/pivpn/hosts.wireguard

                killall -s HUP pihole-FTL && \
                    echo '::: Updated hosts file for Pi-hole' || \
                    echo '::: Failed to reload pihole-FTL configuration'
            fi
        else
            echo 'Aborting operation'
            exit 1
        fi
    fi
done

# Restart WireGuard only if some clients were actually deleted
if [ $DELETED_COUNT -gt 0 ]
then
    systemctl reload wg-quick@wg0 && \
        echo '::: WireGuard reloaded' || \
        echo '::: Failed to reload WireGuard'
fi
