#!/usr/bin/env bash
# PiVPN: list clients script
# Updated Script to include Expiration Dates and Clean up Escape Seq -- psgoundar

INDEX="/etc/openvpn/easy-rsa/pki/index.txt"
if [ ! -f "${INDEX}" ]; then
        echo "The file: $INDEX was not found!"
        exit 1
fi

/etc/openvpn/easy-rsa/easyrsa update-db >> /var/log/easyrsa_update-db.log 2>1

printf ": NOTE : The first entry should always be your valid server!\n"
printf "\\n"
printf "\\e[1m::: Certificate Status List :::\\e[0m\\n"
{
printf "\\e[4mStatus\\e[0m  \t  \\e[4mName\\e[0m\\e[0m  \t  \\e[4mExpiration\\e[0m\\n"

while read -r line || [ -n "$line" ]; do
    STATUS=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | awk -FCN= '{print $2}')
    EXPD=$(echo "$line" | awk '{if (length($2) == 15) print $2; else print "20"$2}' | cut -b 1-8 | date +"%b %d %Y" -f -)
        
    if [ "${STATUS}" == "V" ]; then
        printf "Valid  \t  %s  \t  %s\\n" "$NAME" "$EXPD"
    elif [ "${STATUS}" == "R" ]; then
        printf "Revoked  \t  %s  \t  %s\\n" "$NAME" "$EXPD"
    elif [ "${STATUS}" == "E" ]; then
        printf "     Expired ::   %s\n" "$NAME"
    else
        printf "Unknown  \t  %s  \t  %s\\n" "$NAME" "$EXPD"
    fi

done <${INDEX}
printf "\\n"
} | column -t -s $'\t'
