#!/usr/bin/env bash
# PiVPN: list clients script

INDEX="/etc/openvpn/easy-rsa/keys/index.txt"
printf "\n"
if [ ! -f "$INDEX" ]; then
        echo "The file: $INDEX was not found!"
        exit 1
fi

printf ": NOTE : The first entry should always be your valid server!\n"
printf "\n"
printf "\e[1m::: Certificate Status List :::\e[0m\n"
printf " ::\e[4m  Status  \e[0m||\e[4m   Name   \e[0m:: \n"

while read -r line || [ -n "$line" ]; do
    STATUS=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | sed -e 's/^.*CN=\([^/]*\)\/.*/\1/')
    if [ "$STATUS" = "V" ]; then
        printf "     Valid   ::   %s\n" "$NAME"
    elif [ "$STATUS" = "R" ]; then
        printf "     Revoked ::   %s\n" "$NAME"
    else
        printf "     Unknown ::   %s\n" "$NAME"
    fi
done <$INDEX
printf "\n"
