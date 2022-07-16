#!/bin/bash

CHECK_PKG_INSTALLED='dpkg-query -s'

[ $(cat /etc/os-release | \
		grep -sEe '^NAME\=' | \
		sed -Ee "s/NAME\=[\'\"]?([^ ]*).*/\1/") == 'Alpine' ] && \
	CHECK_PKG_INSTALLED='apk --no-cache info -e'

# Must be root to use this tool
if [ $EUID -ne 0 ]
then
  	if "${CHECK_PKG_INSTALLED}" sudo &> /dev/null
    then
        export SUDO='sudo'
  	else
    	echo '::: Please install sudo or run this as root.'
    	exit 1
    fi
fi

scriptdir='/opt/pivpn'
vpn='wireguard'

debug() {
    echo '::: Generating Debug Output'

    "${SUDO}" "${scriptdir}/${vpn}/pivpnDEBUG.sh" | \
        tee /tmp/debug.log

    echo '::: '
    echo '::: Debug output completed above.'
    echo '::: Copy saved to /tmp/debug.log'
    echo '::: '
}

showHelp() {
    echo '::: Control all PiVPN specific functions!'
    echo ':::'
    echo '::: Usage: pivpn <command> [option]'
    echo ':::'
    echo '::: Commands:'
    echo ':::    -a, add              Create a client conf profile'
    echo ':::    -c, clients          List any connected clients to the server'
    echo ':::    -d, debug            Start a debugging session if having trouble'
    echo ':::    -l, list             List all clients'
    echo ':::   -qr, qrcode           Show the qrcode of a client for use with the mobile app'
    echo ':::    -r, remove           Remove a client'
    echo ':::  -off, off              Disable a client'
    echo ':::   -on, on               Enable a client'
    echo ':::    -h, help             Show this help dialog'
    echo ':::    -u, uninstall        Uninstall pivpn from your system!'
    echo ':::   -up, update           Updates PiVPN Scripts'
    echo ':::   -bk, backup           Backup VPN configs and user profiles'
    exit 0
}

[ $# -eq 0 ] && \
    showHelp

# Handle redirecting to specific functions based on arguments
case "$1" in
    -a | add)
        shift

        "${SUDO}" "${scriptdir}/${vpn}/makeCONF.sh" "$@"
        ;;
    -c | clients)
        shift

        "${SUDO}" "${scriptdir}/${vpn}/clientSTAT.sh" "$@"
        ;;
    -d | debug)
        debug
        ;;
    -l | list)
        "${SUDO}" "${scriptdir}/${vpn}/listCONF.sh"
        ;;
    -qr | qrcode)
        shift

        "${SUDO}" "${scriptdir}/${vpn}/qrcodeCONF.sh" "$@"
        ;;
    -r | remove)
        shift

        "${SUDO}" "${scriptdir}/${vpn}/removeCONF.sh" "$@"
        ;;
    -off | off)
        shift

        "${SUDO}" "${scriptdir}/${vpn}/disableCONF.sh" "$@"
        ;;
    -on | on)
        shift

        "${SUDO}" "${scriptdir}/${vpn}/enableCONF.sh" "$@"
        ;;
    -u | uninstall)
        "${SUDO}" "${scriptdir}/uninstall.sh" "${vpn}"
        ;;
    -up | update)
        shift

        "${SUDO}" "${scriptdir}/update.sh" "$@"
        ;;
    -bk | backup)
        "${SUDO}" "${scriptdir}/backup.sh" "${vpn}"
        ;;
    *)
        showHelp
        ;;
esac
