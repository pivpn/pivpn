#!/usr/bin/env bash
# PiVPN: client status script

STATUS_LOG="/var/log/openvpn-status.log"

function hr() {
        numfmt --to=iec-i --suffix=B "$1"
}

printf "\n"
if [ ! -f "${STATUS_LOG}" ]; then
        echo "The file: $STATUS_LOG was not found!"
        exit 1
fi

printf ": NOTE : The output below is NOT real-time!\n"
printf ":      : It may be off by a few minutes.\n"
printf "\n"
printf "\e[1m::: Client Status List :::\e[0m\n"
printf "\t\t\t\t\t\t\t\tBytes\t\tBytes\t\n"
printf "\e[4mName\e[0m\t\t\t\e[4mRemote IP\e[0m\t\t\e[4mVirtual IP\e[0m\t\e[4mReceived\e[0m\t\e[4mSent\e[0m\t\t\e[4mConnected Since\e[0m \n"
if grep -q "^CLIENT_LIST" "${STATUS_LOG}"; then
        if [ -n $(type -t numfmt) ]; then
                while read -r line; do
                        read -r -a array <<< $line
                        [[ ${array[0]} = CLIENT_LIST ]] || continue
                        printf "%s\t\t%s\t%s\t%s\t\t%s\t\t%s %s %s - %s" ${array[1]} ${array[2]} ${array[3]} $(hr ${array[4]}) $(hr ${array[5]}) ${array[7]} ${array[8]} ${array[10]} ${array[9]}
                done <$STATUS_LOG
        else
                awk -F' ' -v s='CLIENT_LIST' '$1 == s {print $2"\t\t"$3"\t"$4"\t"$5"\t\t"$6"\t\t"$8" "$9" "$11" - "$10"\n"}' ${STATUS_LOG}
        fi
else
    printf "\nNo Clients Connected!\n"
fi
printf "\n"
