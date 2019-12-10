#!/bin/bash

cd /etc/wireguard/configs
if [ ! -s clients.txt ]; then
    echo "::: There are no clients to list"
    exit 1
fi

{
# Present the user with a summary of the clients, fetching info from dates.
printf ": \e[4mClient\e[0m  \t  \e[4mCreation date\e[0m :\n"

while read -r LINE; do
    CLIENT_NAME="$(awk '{print $1}' <<< "$LINE")"

    CREATION_DATE="$(awk '{print $2}' <<< "$LINE")"

    # Dates are converted from UNIX time to human readable.
    CD_FORMAT="$(date -d @"$CREATION_DATE" +'%d %b %Y, %H:%M, %Z')"

    printf "• $CLIENT_NAME  \t  $CD_FORMAT\n"
done < clients.txt

printf "\n"
} | column -t -s $'\t'
