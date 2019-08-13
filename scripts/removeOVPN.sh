#!/usr/bin/env bash
# PiVPN: revoke client script

INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)
PLAT=$(cat /etc/pivpn/DET_PLATFORM)
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"

helpFunc() {
    echo "::: Revoke a client ovpn profile"
    echo ":::"
    echo "::: Usage: pivpn <-r|revoke> [-h|--help] [<client-1>] ... [<client-n>] ..."
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Interactive mode"
    echo ":::  <client>             Client(s) to to revoke"
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
            CERTS_TO_REVOKE+=("$1")
            ;;
    esac
    shift
done

if [ ! -f "${INDEX}" ]; then
        printf "The file: %s was not found\n" "$INDEX"
        exit 1
fi

if [[ -z "${CERTS_TO_REVOKE}" ]]; then
    printf "\n"
    printf " ::\e[4m  Certificate List  \e[0m:: \n"
    
    i=0
    while read -r line || [ -n "$line" ]; do
        STATUS=$(echo "$line" | awk '{print $1}')
        if [[ "${STATUS}" = "V" ]]; then
            NAME=$(echo "$line" | sed -e 's:.*/CN=::')
            CERTS[$i]=${NAME}
            if [ "$i" != 0 ]; then
                # Prevent printing "server" certificate
                printf "  %s\n" "$NAME"
            fi
            let i=i+1
        fi
    done <${INDEX}
    printf "\n"
    
    echo "::: Please enter the Name of the client to be revoked from the list above:"
    read -r NAME
    
    if [[ -z "${NAME}" ]]; then
        echo "You can not leave this blank!"
        exit 1
    fi
    
    for((x=1;x<=i;++x)); do
        if [ "${CERTS[$x]}" = "${NAME}" ]; then
            VALID=1
        fi
    done
    
    if [ -z "${VALID}" ]; then
        printf "You didn't enter a valid cert name!\n"
        exit 1
    fi
    
    CERTS_TO_REVOKE=( "${NAME}" )
else
    i=0
    while read -r line || [ -n "$line" ]; do
        STATUS=$(echo "$line" | awk '{print $1}')
        if [[ "${STATUS}" = "V" ]]; then
            NAME=$(echo "$line" | sed -e 's:.*/CN=::')
            CERTS[$i]=${NAME}
            let i=i+1
        fi
    done <${INDEX}
    
    for (( ii = 0; ii < ${#CERTS_TO_REVOKE[@]}; ii++)); do
        VALID=0
        for((x=1;x<=i;++x)); do
            if [ "${CERTS[$x]}" = "${CERTS_TO_REVOKE[ii]}" ]; then
                VALID=1
            fi
        done
        
        if [ "${VALID}" != 1 ]; then
            printf "You passed an invalid cert name: '"%s"'!\n" "${CERTS_TO_REVOKE[ii]}"
            exit 1
        fi
    done
fi

cd /etc/openvpn/easy-rsa || exit

INSTALL_HOME=$(cat /etc/passwd | grep "$INSTALL_USER" | cut -d: -f6)
for (( ii = 0; ii < ${#CERTS_TO_REVOKE[@]}; ii++)); do
    printf "\n::: Revoking certificate '"%s"'.\n" "${CERTS_TO_REVOKE[ii]}"
    ./easyrsa --batch revoke "${CERTS_TO_REVOKE[ii]}"
    ./easyrsa gen-crl
    printf "\n::: Certificate revoked, and CRL file updated.\n"
    printf "::: Removing certs and client configuration for this profile.\n"
    rm -rf "pki/reqs/${CERTS_TO_REVOKE[ii]}.req"
    rm -rf "pki/private/${CERTS_TO_REVOKE[ii]}.key"
    rm -rf "pki/issued/${CERTS_TO_REVOKE[ii]}.crt"
    rm -rf "${INSTALL_HOME}/ovpns/${CERTS_TO_REVOKE[ii]}.ovpn"
    rm -rf "/etc/openvpn/easy-rsa/pki/${CERTS_TO_REVOKE[ii]}.ovpn"
    cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
done
printf "::: Completed!\n"
