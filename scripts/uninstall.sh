#!/usr/bin/env bash
# PiVPN: Uninstall Script

### FIXME: global: config storage, refactor all scripts to adhere to the storage
### FIXME: use variables where appropriate, reduce magic numbers by 99.9%, at least.

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || \
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

PKG_MANAGER='apt-get'
UPDATE_PKG_CACHE="${PKG_MANAGER} update"
PKG_REMOVE="${PKG_MANAGER} -y remove --purge"
dnsmasqConfig='/etc/dnsmasq.d/02-pivpn.conf'
setupVarsFile='setupVars.conf'
setupConfigDir='/etc/pivpn'
pivpnFilesDir='/usr/local/src/pivpn'
pivpnScriptDir='/opt/pivpn'

PLAT=$(cat /etc/os-release | \
		grep -sEe '^NAME\=' | \
		sed -Ee "s/NAME\=[\'\"]?([^ ]*).*/\1/")

if [ "${PLAT}" == 'Alpine' ]
then
	PKG_MANAGER='apk'
	UPDATE_PKG_CACHE="${PKG_MANAGER} update; ${PKG_MANAGER} upgrade --prune"
	PKG_REMOVE="${PKG_MANAGER} --no-cache --purge del -r"
fi

if [ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ] && \
	[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]
then
	vpnStillExists=1

	# Two protocols have been installed, check if the script has passed
	# an argument, otherwise ask the user which one he wants to remove
	if [ $# -ge 1 ]
	then
		VPN="$1"
		echo "::: Uninstalling VPN: ${VPN}"
	else
		chooseVPNCmd=(whiptail --backtitle 'Setup PiVPN' --title 'Uninstall' --separate-output --radiolist 'Both OpenVPN and WireGuard are installed, choose a VPN to uninstall (press space to select):' "${r}" "${c}" 2)
		VPNChooseOptions=(WireGuard '' on)
		VPNChooseOptions+=(OpenVPN '' off)

		if VPN=$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 >/dev/tty)
		then
			echo "::: Uninstalling VPN: ${VPN}"
			VPN="${VPN,,}"
		else
			echo '::: Cancel selected, exiting....'
			exit 1
		fi
	fi

	setupVars="${setupConfigDir}/${VPN}/${setupVarsFile}"
else
	vpnStillExists=0

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

### FIXME: introduce global lib
spinner() {
	local pid="$1"
	local delay=0.50
	local spinstr='/-\|'

	while ps a | \
		awk '{print $1}' | \
		grep -qsEe "${pid}"
	do
		local temp=${spinstr#?}
		local spinstr="${temp}${spinstr%$temp}"

		printf ' [%c]  ' "${spinstr}"

		sleep "${delay}"

		printf '\\b\\b\\b\\b\\b\\b'
	done

	printf '    \\b\\b\\b\\b'
}

removeAll() {
	local service_name
	# Stopping and disabling services
	echo '::: Stopping and disabling services...'

	if [ "${VPN}" == 'wireguard' ]
	then
		[ "${PLAT}" == 'Alpine' ] && \
			service_name='wg-quick' || \
			service_name='wg-quick@wg0'
	fi

	[ "${VPN}" == 'openvpn' ] && \
		service_name='openvpn'

	if [ "${PLAT}" == 'Alpine' ]
	then
		rc-service "${service_name}" stop
		rc-update del "${service_name}" default &> /dev/null
	else
		systemctl stop "${service_name}"
		systemctl disable "${service_name}" &> /dev/null
	fi

	# Removing firewall rules.
	echo '::: Removing firewall rules...'

	if [ $USING_UFW -eq 1 ]
	then
		### Ignoring SC2154, value sourced from setupVars file
		# shellcheck disable=SC2154
		ufw delete allow "${pivpnPORT}/${pivpnPROTO}" > /dev/null
    	### Ignoring SC2154, value sourced from setupVars file
		# shellcheck disable=SC2154
		ufw route delete allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any > /dev/null
		ufw delete allow in on "${pivpnDEV}" to any port 53 from "${pivpnNET}/${subnetClass}" >/dev/null

		sed -iEe "/\-I POSTROUTING \-s ${pivpnNET}\/${subnetClass} \-o ${IPv4dev} \-j MASQUERADE \-m comment \-\-comment ${VPN}\-nat\-rule/d" /etc/ufw/before.rules

		iptables -t nat -D POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"

		ufw reload &> /dev/null
	else
		if [ $INPUT_CHAIN_EDITED -eq 1 ]
		then
			iptables -D INPUT -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule"
		fi

		if [ $FORWARD_CHAIN_EDITED -eq 1 ]
		then
			iptables -D FORWARD -d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
			iptables -D FORWARD -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
		fi

		iptables -t nat -D POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
		iptables-save > /etc/iptables/rules.v4
	fi

	# Disable IPv4 forwarding
	if [ $vpnStillExists -eq 0 ]
	then
		sed -iEe '/net\.ipv4\.ip_forward\=1/c\\#net\.ipv4\.ip_forward\=1' /etc/sysctl.conf
		sysctl -p
	fi

	# Purge dependencies
	echo '::: Purge dependencies...'

	for i in "${INSTALLED_PACKAGES[@]}"
	do
		while true
		do
			read -rp "::: Do you wish to remove ${i} from your system? [Y/n]: " yn

			case "${yn}" in
				[Yy]*)
					if [ "${PLAT}" != 'Alpine' ]
					then
						if [ "${i}" == 'wireguard-tools' ]
						then
							# The bullseye repo may not exist if wireguard was available at the
							# time of installation.
							if [ -f /etc/apt/sources.list.d/pivpn-bullseye-repo.list ]
							then
								echo '::: Removing Debian Bullseye repo...'

								rm -f /etc/apt/sources.list.d/pivpn-bullseye-repo.list
								rm -f /etc/apt/preferences.d/pivpn-limit-bullseye

								echo '::: Updating package cache...'

								"${UPDATE_PKG_CACHE}" &> /dev/null && \
									spinner "$!"
							fi

							[ -f /etc/systemd/system/wg-quick@.service.d/override.conf ] && \
								rm -f /etc/systemd/system/wg-quick@.service.d/override.conf
						elif [ "${i}" == 'unattended-upgrades' ]
						then
							rm -rf /var/log/unattended-upgrades
							rm -rf /etc/apt/apt.conf.d/*periodic
							rm -rf /etc/apt/apt.conf.d/*unattended-upgrades
						elif [ "${i}" == 'openvpn' ]
						then
							if [ -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list ]
							then
								echo '::: Removing OpenVPN software repo...'

								rm -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list

								echo '::: Updating package cache...'

								"${UPDATE_PKG_CACHE}" &> /dev/null && \
									spinner "$!"
							fi

							deluser openvpn

							rm -f /etc/rsyslog.d/30-openvpn.conf
							rm -f /etc/logrotate.d/openvpn

						fi
					fi

					printf ':::\\tRemoving %s...' "${i}"

					"${PKG_REMOVE}" "${i}" &> /dev/null && \
						spinner "$!"

					printf 'done!\\n'
					break
					;;
				[Nn]*)
					printf ':::\\tSkipping %s\\n' "${i}"
					break
					;;
				*)
					printf '::: You must answer yes or no!\\n'
					;;
			esac
		done
	done

	if [ "${PLAT}" != 'Alpine' ]
	then
		# Take care of any additional package cleaning
		printf '::: Auto removing remaining dependencies...'

		"${PKG_MANAGER}" -y autoremove &> /dev/null && \
			spinner "$!"

		printf 'done!\\n'
		printf '::: Auto cleaning remaining dependencies...'

		"${PKG_MANAGER}" -y autoclean &> /dev/null && \
			spinner "$!"

		printf 'done!\\n'
	fi

	if [ -f "${dnsmasqConfig}" ]
	then
		rm -f "${dnsmasqConfig}"

		pihole restartdns
	fi

	echo ':::'
	echo '::: Removing VPN configuration files...'

	if [ "${VPN}" == 'wireguard' ]
	then
		rm -f /etc/wireguard/wg0.conf
   		### Ignoring SC2154, value sourced from setupVars file
		# shellcheck disable=SC2154
		rm -rf /etc/wireguard/configs /etc/wireguard/keys "${install_home}/configs"
	elif [ "${VPN}" == 'openvpn' ]
	then
		rm -f /etc/openvpn/server.conf /etc/openvpn/crl.pem
		rm -rf /var/log/*openvpn* /etc/openvpn/easy-rsa /etc/openvpn/ccd "${install_home}/ovpns"
	fi

	if [ $vpnStillExists -eq 0 ]
	then
		echo ':::'
		echo '::: Removing pivpn system files...'

		rm -rf "${setupConfigDir}" "${pivpnFilesDir}"
		rm -f /var/log/*pivpn* /etc/bash_completion.d/pivpn

		unlink "${pivpnScriptDir}"
		unlink /usr/local/bin/pivpn
	else
		[ "${VPN}" == 'wireguard' ] && \
			othervpn='openvpn' || \
			othervpn='wireguard'

		echo ':::'
		echo "::: Other VPN ${othervpn} still present, so not"
		echo '::: removing pivpn system files'

		rm -f "${setupConfigDir}/${VPN}/${setupVarsFile}"

		# Restore single pivpn script and bash completion for the remaining VPN
		"${SUDO}" unlink /usr/local/bin/pivpn

		"${SUDO}" ln -sT "${pivpnFilesDir}/scripts/${othervpn}/pivpn.sh" /usr/local/bin/pivpn
		"${SUDO}" ln -sT "${pivpnFilesDir}/scripts/${othervpn}/bash-completion" /etc/bash_completion.d/pivpn

		# shellcheck disable=SC1091
		. /etc/bash_completion.d/pivpn
	fi

	echo ':::'
	printf '::: Finished removing PiVPN from your system.\\n'
	printf '::: Reinstall by simply running\\n:::\\n:::\\tcurl -L https://install.pivpn.io | bash\\n:::\\n::: at any time!\\n:::\\n'
}

askreboot() {
	printf 'It is \\e[1mstrongly\\e[0m recommended to reboot after un-installation.\\n'

	read -p 'Would you like to reboot now? [y/n]: ' -n 1 -r

	echo

	if [ "${REPLY}" =~ ^[Yy]$ ]
	then
		printf '\\nRebooting system...\\n'

		sleep 3

		[ "${PLAT}" == 'Alpine' ] && \
			reboot || \
			shutdown -r now
	fi
}

######### SCRIPT ###########
echo '::: Preparing to remove packages, be sure that each may be safely removed depending on your operating system.'
echo '::: (SAFE TO REMOVE ALL ON RASPBIAN)'

while true
do
	read -rp '::: Do you wish to completely remove PiVPN configuration and installed packages from your system? (You will be prompted for each package) [y/n]: ' yn
	
	case "${yn}" in
		[Yy]*)
			removeAll
			askreboot
			break
			;;
		[Nn]*)
			printf '::: Not removing anything, exiting...\\n'
			break
			;;
	esac
done
