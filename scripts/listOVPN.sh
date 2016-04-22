#!/usr/bin/env bash
# PiVPN: list clients script

INDEX="/etc/openvpn/easy-rsa/keys/index.txt"
printf "\n"
if [ ! -f $INDEX ]; then
        printf "The file: $INDEX \n"
        printf "Was not Found!\n"
        exit 1
fi

printf ": NOTE : The first entry should always be your valid server!\n"
printf "\n"
printf "\e[1m::: Certificate Status List :::\e[0m\n"
printf " ::\e[4m  Status  \e[0m||\e[4m   Name   \e[0m:: \n"

while read -r line || [[ -n "$line" ]]; do
    status=$(echo $line | awk '{print $1}')
    if [[ $status = "V" ]]; then
        printf "     Valid   :: "
        var=$(echo $line | awk '{print $5}' | cut -d'/' -f7)
        var=${var#CN=}
        printf "  $var\n"
    fi
    if [[ $status = "R" ]]; then
        printf "     Revoked :: "
        var=$(echo $line | awk '{print $6}' | cut -d'/' -f7)
        var=${var#CN=}
        printf "  $var\n"
    fi
done <$INDEX
printf "\n"
