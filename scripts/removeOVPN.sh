#!/usr/bin/env bash
# PiVPN: revoke client script

INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)
REVOKE_STATUS=$(cat /etc/pivpn/REVOKE_STATUS)
PLAT=$(cat /etc/pivpn/DET_PLATFORM)
INDEX="/etc/openvpn/easy-rsa/keys/index.txt"

if [ ! -f "$INDEX" ]; then
        printf "The file: %s was not found\n" "$INDEX"
        exit 1
fi

printf "\n"
printf " ::\e[4m  Certificate List  \e[0m:: \n"

i=0
while read -r line || [ -n "$line" ]; do
    STATUS=$(echo "$line" | awk '{print $1}')
    if [[ "$STATUS" = "V" ]]; then
        NAME=$(echo "$line" | sed -e 's/^.*CN=\([^/]*\)\/.*/\1/')
        CERTS[$i]=$NAME
        if [ "$i" != 0 ]; then
            # Prevent printing "server" certificate
            printf "  %s\n" "$NAME"
        fi
        let i=i+1
    fi
done <$INDEX
printf "\n"

echo "::: Please enter the Name of the client to be revoked from the list above:"
read -r NAME

if [[ -z "$NAME" ]]; then
    echo "::: You can not leave this blank!"
    exit 1
fi

for((x=1;x<=i;++x)); do
    if [ "${CERTS[$x]}" = "${NAME}" ]; then
        VALID=1
    fi
done

if [ -z "$VALID" ]; then
    printf "::: You didn't enter a valid cert name!\n"
    exit 1
fi

cd /etc/openvpn/easy-rsa || exit
source /etc/openvpn/easy-rsa/vars

./revoke-full "$NAME"
echo "::: Certificate revoked, removing ovpns from /home/$INSTALL_USER/ovpns"
rm "/home/$INSTALL_USER/ovpns/$NAME.ovpn"
cp /etc/openvpn/easy-rsa/keys/crl.pem /etc/openvpn/crl.pem
echo "::: Completed!"

if [ "$REVOKE_STATUS" == 0 ]; then
        echo 1 > /etc/pivpn/REVOKE_STATUS
        printf "\nThis seems to be the first time you have revoked a cert.\n"
        printf "We are adding the CRL to the server.conf and restarting openvpn.\n"
        sed -i '/#crl-verify/c\crl-verify /etc/openvpn/crl.pem' /etc/openvpn/server.conf
        if [[ ${PLAT} == "Ubuntu" || ${PLAT} == "Debian" ]]; then
            service openvpn restart
        else
            systemctl restart openvpn.service
        fi
fi
