#!/usr/bin/env bash
# PiVPN: revoke client script

INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)
REVOKE_STATUS=$(cat /etc/pivpn/REVOKE_STATUS)
PLAT=$(cat /etc/pivpn/DET_PLATFORM)
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"

if [ ! -f "${INDEX}" ]; then
        printf "The file: %s was not found\n" "$INDEX"
        exit 1
fi

printf "\n"
printf " ::\e[4m  Certificate List  \e[0m:: \n"

i=0
while read -r line || [ -n "$line" ]; do
    STATUS=$(echo "$line" | awk '{print $1}')
    if [[ "$STATUS" = "V" ]]; then
        NAME=$(echo "$line" | sed -e 's:.*/CN=::')
        CERTS[$i]=$NAME
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
    echo "::: You can not leave this blank!"
    exit 1
fi

for((x=1;x<=i;++x)); do
    if [ "${CERTS[$x]}" = "${NAME}" ]; then
        VALID=1
    fi
done

if [ -z "${VALID}" ]; then
    printf "::: You didn't enter a valid cert name!\n"
    exit 1
fi

cd /etc/openvpn/easy-rsa || exit

if [ "${REVOKE_STATUS}" == 0 ]; then
        echo 1 > /etc/pivpn/REVOKE_STATUS
        printf "\nThis seems to be the first time you have revoked a cert.\n"
    printf "First we need to initialize the Certificate Revocation List.\n"
        printf "Then add the CRL to your server config and restart openvpn.\n"
    ./easyrsa gen-crl
    cp pki/crl.pem /etc/openvpn/crl.pem
    chown nobody:nogroup /etc/openvpn/crl.pem
        sed -i '/#crl-verify/c\crl-verify /etc/openvpn/crl.pem' /etc/openvpn/server.conf
        if [[ ${PLAT} == "Ubuntu" || ${PLAT} == "Debian" ]]; then
            service openvpn restart
        else
            systemctl restart openvpn.service
        fi
fi

./easyrsa --batch revoke "${NAME}"
./easyrsa gen-crl
printf "\n::: Certificate revoked, and CRL file updated.\n"
printf "::: Removing certs and client configuration for this profile.\n"
rm -rf "pki/reqs/${NAME}.req"
rm -rf "pki/private/${NAME}.key"
rm -rf "pki/issued/${NAME}.crt"
rm -rf "/home/$INSTALL_USER/ovpns/${NAME}.ovpn"
cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
printf "::: Completed!\n"
