#!/bin/bash

cd /etc/wireguard/configs
if [ ! -s clients.txt ]; then
    echo "::: There are no clients to list"
    exit 1
fi

# Present the user with a summary of the clients, fetching info from dates.
FORMATTED+=": \e[4mClient\e[0m&\e[4mCreation date\e[0m :\n"

while read -r LINE; do
    CLIENT_NAME="$(awk '{print $1}' <<< "$LINE")"

    CREATION_DATE="$(awk '{print $2}' <<< "$LINE")"

    # Dates are converted from UNIX time to human readable.
    CD_FORMAT="$(date -d @"$CREATION_DATE" +'%d %b %Y, %H:%M, %Z')"

    FORMATTED+="• $CLIENT_NAME&$CD_FORMAT\n"
done < clients.txt

echo -e "$FORMATTED" | column -t -s '&'