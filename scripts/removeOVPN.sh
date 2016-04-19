#!/usr/bin/env bash
# PiVPN: revoke client script

INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)
REVOKE_STATUS=$(cat /etc/pivpn/REVOKE_STATUS)
INDEX="/etc/openvpn/easy-rsa/keys/index.txt"

if [ ! -f $INDEX ]; then
        printf "The file: $INDEX \n"
        printf "Was not Found!\n"
        exit 1
fi

printf "\n"
printf " ::\e[4m  Certificate List  \e[0m:: \n"

while read -r line || [[ -n "$line" ]]; do
    status=$(echo $line | awk '{print $1}')
    if [[ $status = "V" ]]; then
        var=$(echo $line | awk '{print $5}' | cut -d'/' -f7)
        var=${var#CN=}
        if [ "$var" != "server" ]; then
            printf "  $var\n"
        fi
    fi
done <$INDEX
printf "\n"

echo "::: Please enter the Name of the client to be revoked from the list above:"
read NAME

cd /etc/openvpn/easy-rsa
source /etc/openvpn/easy-rsa/vars

./revoke-full $NAME
echo "::: Certificate revoked, removing ovpns from /home/$INSTALL_USER/ovpns"
rm /home/$INSTALL_USER/ovpns/$NAME.ovpn
cp /etc/openvpn/easy-rsa/keys/crl.pem /etc/openvpn/crl.pem
echo "::: Completed!"

if [ $REVOKE_STATUS == 0 ]; then
        echo 1 > /etc/pivpn/REVOKE_STATUS
        printf "\nThis seems to be the first time you have revoked a cert.\n"
        printf "We are adding the CRL to the server.conf and restarting openvpn.\n"
        sed -i '/#crl-verify/c\crl-verify /etc/openvpn/crl.pem' /etc/openvpn/server.conf
        systemctl restart openvpn.service
fi
