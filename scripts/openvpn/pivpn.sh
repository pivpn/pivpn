#!/bin/bash

# Must be root to use this tool
if [ ! $EUID -eq 0 ]
then
	if dpkg-query -s sudo
	then
		export SUDO='sudo'
	else
		echo '::: Please install sudo or run this as root.'
		exit 1
	fi
fi

scriptDir='/opt/pivpn'
vpn='openvpn'

debugFunc() {
	echo '::: Generating Debug Output'

	"${SUDO}" "${scriptDir}/${vpn}/pivpnDebug.sh" | \
		tee /tmp/debug.log

	echo '::: '
	echo '::: Debug output completed above.'
	echo '::: Copy saved to /tmp/debug.log'
	echo '::: '
}

helpFunc() {
	echo '::: Control all PiVPN specific functions!'
	echo ':::'
	echo '::: Usage: pivpn <command> [option]'
	echo ':::'
	echo '::: Commands:'
	echo ':::  -a, add [nopass]     Create a client ovpn profile, optional nopass'
	echo ':::  -c, clients          List any connected clients to the server'
	echo ':::  -d, debug            Start a debugging session if having trouble'
	echo ':::  -l, list             List all valid and revoked certificates'
	echo ':::  -r, revoke           Revoke a client ovpn profile'
	echo ':::  -h, help             Show this help dialog'
	echo ':::  -u, uninstall        Uninstall PiVPN from your system!'
	echo ':::  -up, update          Updates PiVPN Scripts'
	echo ':::  -bk, backup          Backup Openvpn and ovpns dir'
	exit 0
}

[ $# -eq 0 ] && \
	helpFunc

# Handle redirecting to specific functions based on arguments
case "$1" in
	-a | add)
		shift

		"${SUDO}" "${scriptDir}/${vpn}/makeOVPN.sh" "$@"
		;;
	-c | clients)
		shift

		"${SUDO}" "${scriptDir}/${vpn}/clientStat.sh" "$@"
		;;
	-d | debug)
		debugFunc
		;;
	-l | list)
		"${SUDO}" "${scriptDir}/${vpn}/listOVPN.sh"
		;;
	-r | revoke)
		shift

		"${SUDO}" "${scriptDir}/${vpn}/removeOVPN.sh" "$@"
		;;
	-u | uninstall)
		"${SUDO}" "${scriptDir}/uninstall.sh" "${vpn}"
		;;
	-up | update)
		shift

		"${SUDO}" "${scriptDir}/update.sh" "$@"
		;;
	-bk | backup)
		"${SUDO}" "${scriptDir}/backup.sh" "${vpn}"
		;;
	*)
		helpFunc
		;;
esac
