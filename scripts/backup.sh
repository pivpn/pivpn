#!/bin/bash
# PiVPN: Backup Script

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2> /dev/null || \
	echo 24 80)
rows=$(echo "${screen_size}" | \
	awk '{print $1}')
columns=$(echo "${screen_size}" | \
	awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

backupdir=pivpnbackup
date=$(date +%Y%m%d-%H%M%S)
setupVarsFile='setupVars.conf'
setupConfigDir='/etc/pivpn'

CHECK_PKG_INSTALLED='dpkg-query -s'

[ $(cat /etc/os-release | \
		grep -sEe '^NAME\=' | \
		sed -Ee "s/NAME\=[\'\"]?([^ ]*).*/\1/") == 'Alpine' ] && \
	CHECK_PKG_INSTALLED='apk --no-cache info -e'

if [ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ] && \
	[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]
then
	# Two protocols have been installed, check if the script has passed
	# an argument, otherwise ask the user which one he wants to remove
	if [ $# -ge 1 ]
	then
		VPN="$1"
		echo "::: Backing up VPN: ${VPN}"
	else
		chooseVPNCmd=(whiptail --backtitle 'Setup PiVPN' --title 'Backup' --separate-output --radiolist 'Both OpenVPN and WireGuard are installed, choose a VPN to backup (press space to select):' "${r}" "${c}" 2)
		VPNChooseOptions=(WireGuard '' on)
		VPNChooseOptions+=(OpenVPN '' off)

		if VPN=$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2> /dev/stdout > /dev/tty)
		then
			echo "::: Backing up VPN: ${VPN}"
			VPN="${VPN,,}"
		else
			echo '::: Cancel selected, exiting....'
			exit 1
		fi
	fi

	setupVars="${setupConfigDir}/${VPN}/${setupVarsFile}"
else
	[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ] && \
		setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"

	[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ] && \
		setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
fi

if [ ! -f "${setupVars}" ]
then
	echo '::: Missing setup vars file!'
	exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

checkbackupdir() {
	# Disabling shellcheck error $install_home sourced from $setupVars
	# shellcheck disable=SC2154
    [ -d "${install_home}/${backupdir}" ] || \
        mkdir -p "${install_home}/${backupdir}"
}

backup() {
	local VPN_directory
	local VPN_config_directory
	local VPN_backup_name

	[ "${VPN}" == 'wireguard' ] && \
		VPN_directory=/etc/wireguard || \
		VPN_directory=/etc/openvpn

	[ "${VPN}" == 'wireguard' ] && \
		VPN_config_directory="${install_home}/configs" || \
		VPN_config_directory="${install_home}/ovpns"

	[ "${VPN}" == 'wireguard' ] && \
		VPN_backup_name="${date}-pivpnwgbackup.tgz" || \
		VPN_backup_name="${date}-pivpnovpnbackup.tgz"

    checkbackupdir

    # shellcheck disable=SC2210
    tar -czpf "${install_home}/${backupdir}/${VPN_backup_name}" "${VPN_directory}" "${VPN_config_directory}" > /dev/null 2> /dev/stdout

    echo -e "Backup created in ${install_home}/${backupdir}/${VPN_backup_name} \nTo restore the backup, follow instructions at:\nhttps://docs.pivpn.io/openvpn/#migrating-pivpn-openvpn\n"
}

if [ $EUID -ne 0 ]
then
    if "${CHECK_PKG_INSTALLED}" sudo
	then
        export SUDO='sudo'
    else
		echo '::: Please install sudo or run this as root.'
		exit 1
	fi
fi

backup