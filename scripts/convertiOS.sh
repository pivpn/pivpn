#!/bin/bash
#
# Convert the original ovpn file of a client to a ovpn file that will work with the "OpenVPN Connect" app for iOS
#
# Script created by TimmThaler > github.com/TimmThaler
# Based on the issue post 364 and the instructions by killermosi
#

fileext="ovpn"
ovpndir="/etc/openvpn/easy-rsa/pki"
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"
ovpnuser=$(cat /etc/pivpn/INSTALL_USER)
ovpnout="/home/$ovpnuser/ovpns"

if [ ! -f "${INDEX}" ]; then
        echo "The file: $INDEX was not found!"
        exit 1
fi

# read clients
client=""
while read -r line || [ -n "$line" ]; do
    STATUS=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | sed -e 's:.*/CN=::')
    if [ "${STATUS}" == "V" ]; then
        client="$clients $NAME . OFF"
    fi
done <${INDEX}

# show list to select a client
whiptail --title "Choose client" --radiolist "Please choose a client to work with ..." 20 78 4 $client 2>"$ovpnout/clientlist"
client=$(cat "$ovpnout/clientlist")
rm -f $ovpnout/clientlist

# copy the client's opvn file to a tmp file
cp "$ovpndir/$client.$fileext" "$ovpnout/$client.tmp.$fileext"

# convert the old rsa key to the new aes256 key with openssl
whiptail --title "Key conversion" --msgbox "For the key conversion from 'rsa' to 'aes256' you will have to type your password three times now." 8 78
echo
openssl rsa -aes256 -in "$ovpnout/$client.tmp.$fileext" -out "$ovpnout/$client.tmp.key"

# read the new created aes key
key=$(cat "$ovpnout/$client.tmp.key")

# replace the rsa key with the new aes key and output to new opvn file
awk -v values="${key}" '/<key>/{p=1;print;printf values; printf "\n"}/<\/key>/{p=0}!p' "$ovpnout/$client.tmp.$fileext" > "$ovpnout/$client.ios.$fileext"

# delete tmp files
rm -f "$ovpnout/$client.tmp.key"
rm -f "$ovpnout/$client.tmp.$fileext"

whiptail --title "Done." --msgbox "Alright, the conversion has finished. You'll find the new iOS OVPN file in $ovpnout" 8 78

