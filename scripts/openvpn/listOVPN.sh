#!/usr/bin/env bash
# PiVPN: list clients script
# Updated Script to include Expiration Dates and Clean up Escape Seq -- psgoundar

INDEX="/etc/openvpn/easy-rsa/pki/index.txt"
if [ ! -f "${INDEX}" ]; then
        echo "The file: $INDEX was not found!"
        exit 1
fi

EASYRSA="/etc/openvpn/easy-rsa/easyrsa"
if [ ! -f "${EASYRSA}" ]; then
        echo "The file: $EASYRSA was not found!"
        exit 1
fi

$EASYRSA update-db >> /dev/null 2>&1

printf ": NOTE : The first entry is your server, which should always be valid!\n"
printf "\\n"
printf "\\e[1m::: Certificate Status List :::\\e[0m\\n"
{
printf "\\e[4mStatus\\e[0m  \t  \\e[4mName\\e[0m\\e[0m  \t  \\e[4mExpiration\\e[0m\\n"

while read -r line || [ -n "$line" ]; do
    STATUS=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | awk -FCN= '{print $2}')
    EXPD=$(echo "$line" | awk '{if (length($2) == 15) print $2; else print "20"$2}' | cut -b 1-8 | date +"%b %d %Y" -f -)

    if [ "${STATUS}" == "V" ]; then
        printf "Valid  \t  %s  \t  %s\\n" "$(echo -e "$NAME")" "$EXPD"
    elif [ "${STATUS}" == "R" ]; then
        printf "Revoked  \t  %s  \t  %s\\n" "$(echo -e "$NAME")" "$EXPD"
    elif [ "${STATUS}" == "E" ]; then
        printf "Expired  \t  %s  \t  %s\\n" "$(echo -e "$NAME")" "$EXPD"
    else
        printf "Unknown  \t  %s  \t  %s\\n" "$(echo -e "$NAME")" "$EXPD"
    fi

done <${INDEX}
printf "\\n"
} | column -t -s $'\t'
