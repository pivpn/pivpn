#!/bin/bash

PLAT=$(cat /etc/os-release | \
		grep -sEe '^NAME\=' | \
		sed -Ee "s/NAME\=[\'\"]?([^ ]*).*/\1/")

setupVars='/etc/pivpn/wireguard/setupVars.conf'

if [ ! -f "${setupVars}" ]
then
	echo '::: Missing setup vars file!'
	exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

helpFunc() {
	echo '::: Disable client conf profiles'
	echo ':::'
	echo '::: Usage: pivpn <-off|off> [-h|--help] [-v] [<client-1> ... [<client-2>] ...] '
	echo ':::'
	echo '::: Commands:'
	echo ':::  [none]               Interactive mode'
	echo ':::  <client>             Client'
	echo ':::  -y,--yes             Disable client(s) without confirmation'
	echo ':::  -v                   Show disabled clients only'
	echo ':::  -h,--help            Show this help dialog'
}

# Parse input arguments
while [ $# -gt 0 ]
do
	case "$1" in
		-h | --help)
			helpFunc
			exit 0
			;;
		-y | --yes)
			CONFIRM=true
			;;
		-v)
			DISPLAY_DISABLED=true
			;;
		*)
			CLIENTS_TO_CHANGE+=("$1")
			;;
	esac

	shift
done

cd /etc/wireguard || \
	exit

if [ ! -s configs/clients.txt ]
then
	echo '::: There are no clients to change'
	exit 1
fi

if [ "${DISPLAY_DISABLED}" == true ]
then
	grep -sEe '\[disabled\] \#\#\# begin' wg0.conf | \
		sed -Ee 's/\#//g; s/begin//'
	exit 1
fi

mapfile -t LIST < <(awk '{print $1}' configs/clients.txt)

if [ "${#CLIENTS_TO_CHANGE[@]}" -eq 0 ]
then
	echo -e '::\e[4m  Client list  \e[0m::'

	len=${#LIST[@]}
	COUNTER=1

	while [ $COUNTER -le $len ]
	do
		printf "%0${#len}s) %s\r\n" "${COUNTER}" "${LIST[(($COUNTER-1))]}"
		((COUNTER++))
	done

	read -r -p 'Please enter the Index/Name of the Client to be removed from the list above: ' CLIENTS_TO_CHANGE

	if [ -z "${CLIENTS_TO_CHANGE}" ]
	then
		echo '::: You can not leave this blank!'
		exit 1
	fi
fi

CHANGED_COUNT=0

for CLIENT_NAME in "${CLIENTS_TO_CHANGE[@]}"
do
	[[ "${CLIENT_NAME}" =~ ^[0-9]+$ ]] && \
		CLIENT_NAME=${LIST[$((CLIENT_NAME -1))]}

	if ! grep -qsEe "^${CLIENT_NAME} " configs/clients.txt
	then
		echo -e "::: \e[1m${CLIENT_NAME}\e[0m does not exist"
	elif grep -qsEe "\#\[disabled\] \#\#\# begin ${CLIENT_NAME}" wg0.conf
	then
		echo -e "::: \e[1m${CLIENT_NAME}\e[0m is already disabled"
	else
		[ -n "${CONFIRM}" ] && \
			REPLY='y' || \
			read -r -p "Confirm you want to disable ${CLIENT_NAME}? [Y/n] "

		if [[ "${REPLY}" =~ ^[Yy]$ ]]
		then
			# Disable the peer section from the server config
			echo "${CLIENT_NAME}"

			sed -iEe "/\#\#\# begin ${CLIENT_NAME}/,/end ${CLIENT_NAME}/ s/^/\#\[disabled\] /" wg0.conf

			echo '::: Updated server config'

			((CHANGED_COUNT++))

			echo "::: Successfully disabled ${CLIENT_NAME}"
		fi
	fi
done

# Restart WireGuard only if some clients were actually deleted
if [ $CHANGED_COUNT -gt 0 ]
then
	if [ "${PLAT}" == 'Alpine' ]
	then
		rc-service wg-quick restart && \
			echo '::: WireGuard reloaded' || \
			echo '::: Failed to reload WireGuard'
	else
		systemctl reload wg-quick@wg0 && \
			echo '::: WireGuard reloaded' || \
			echo '::: Failed to reload WireGuard'
	fi
fi
