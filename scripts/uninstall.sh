#!/usr/bin/env bash
# PiVPN: Uninstall Script

### FIXME: global: config storage, refactor all scripts to adhere to the storage
### FIXME: use variables where appropriate, reduce magic numbers by 99.9%, at least.

PKG_MANAGER="apt-get"
UPDATE_PKG_CACHE="${PKG_MANAGER} update"
dnsmasqConfig="/etc/dnsmasq.d/02-pivpn.conf"

# if the variable is set up, says where the config is
if [ -z $PIVPNCONFIGLOC ]
then
  setupVars="/etc/pivpn/setupVars.conf"
else
  setupVars="${PIVPNCONFIGLOC}/setupVars.conf"
fi

if [ ! -f "${setupVars}" ]; then
	echo "::: Missing setup vars file!"
	exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(echo "$screen_size" | awk '{print $1}')
columns=$(echo "$screen_size" | awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

### FIXME: introduce global lib
spinner(){
	local pid=$1
	local delay=0.50
	local spinstr='/-\|'
	while ps a | awk '{print $1}' | grep -q "$pid"; do
		local temp=${spinstr#?}
		printf " [%c]  " "$spinstr"
		local spinstr=$temp${spinstr%"$temp"}
		sleep $delay
		printf "\\b\\b\\b\\b\\b\\b"
	done
	printf "    \\b\\b\\b\\b"
}

removeAll(){
	# Stopping and disabling services
	echo "::: Stopping and disabling services..."

	if [ "$VPN" = "wireguard" ]; then
		systemctl stop wg-quick@wg0
		systemctl disable wg-quick@wg0 &> /dev/null
	elif [ "$VPN" = "openvpn" ]; then
		systemctl stop openvpn
		systemctl disable openvpn &> /dev/null
	fi

	# Removing firewall rules.
	echo "::: Removing firewall rules..."

	if [ "$USING_UFW" -eq 1 ]; then

    ### FIXME: SC2154
		ufw delete allow "${pivpnPORT}"/"${pivpnPROTO}" > /dev/null
    ### FIXME: SC2154
		ufw route delete allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any > /dev/null
		sed -z "s/*nat\\n:POSTROUTING ACCEPT \\[0:0\\]\\n-I POSTROUTING -s ${pivpnNET}\\/${subnetClass} -o ${IPv4dev} -j MASQUERADE -m comment --comment ${VPN}-nat-rule\\nCOMMIT\\n\\n//" -i /etc/ufw/before.rules
		iptables -t nat -D POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
		ufw reload &> /dev/null

	elif [ "$USING_UFW" -eq 0 ]; then

		if [ "$INPUT_CHAIN_EDITED" -eq 1 ]; then
			iptables -D INPUT -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule"
		fi

		if [ "$FORWARD_CHAIN_EDITED" -eq 1 ]; then
			iptables -D FORWARD -d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
			iptables -D FORWARD -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
		fi

		iptables -t nat -D POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
		iptables-save > /etc/iptables/rules.v4

	fi

	# Disable IPv4 forwarding
	sed -i '/net.ipv4.ip_forward=1/c\#net.ipv4.ip_forward=1' /etc/sysctl.conf
	sysctl -p

	# Purge dependencies
	echo "::: Purge dependencies..."

	for i in "${INSTALLED_PACKAGES[@]}"; do
		while true; do
			read -rp "::: Do you wish to remove $i from your system? [Y/n]: " yn
			case $yn in
				[Yy]* ) if [ "${i}" = "wireguard" ]; then

							# On Debian and Raspbian, remove the bullseye repo. On Ubuntu, remove the PPA.
							if [ "$PLAT" = "Debian" ] || [ "$PLAT" = "Raspbian" ]; then
								rm -f /etc/apt/sources.list.d/pivpn-bullseye.list
								rm -f /etc/apt/preferences.d/pivpn-limit-bullseye
							elif [ "$PLAT" = "Ubuntu" ]; then
								add-apt-repository ppa:wireguard/wireguard -r -y
							fi
							echo "::: Updating package cache..."
							${UPDATE_PKG_CACHE} &> /dev/null & spinner $!

						elif [ "${i}" = "unattended-upgrades" ]; then

							rm -rf /var/log/unattended-upgrades
							rm -rf /etc/apt/apt.conf.d/*periodic
							rm -rf /etc/apt/apt.conf.d/*unattended-upgrades

						elif [ "${i}" = "openvpn" ]; then

							if [ "$PLAT" = "Debian" ] || [ "$PLAT" = "Ubuntu" ]; then
								rm -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list
								echo "::: Updating package cache..."
								${UPDATE_PKG_CACHE} &> /dev/null & spinner $!
							fi
							deluser openvpn
							rm -f /etc/rsyslog.d/30-openvpn.conf
							rm -f /etc/logrotate.d/openvpn

						fi
						printf ":::\\tRemoving %s..." "$i"; $PKG_MANAGER -y remove --purge "$i" &> /dev/null & spinner $!; printf "done!\\n";
						break
						;;
				[Nn]* ) printf ":::\\tSkipping %s\\n" "$i";
						break
						;;
				* ) printf "::: You must answer yes or no!\\n";;
			esac
		done
	done

	# Take care of any additional package cleaning
	printf "::: Auto removing remaining dependencies..."
	$PKG_MANAGER -y autoremove &> /dev/null & spinner $!; printf "done!\\n";
	printf "::: Auto cleaning remaining dependencies..."
	$PKG_MANAGER -y autoclean &> /dev/null & spinner $!; printf "done!\\n";

	echo ":::"
	# Removing pivpn files
	echo "::: Removing pivpn system files..."

	if [ -f "$dnsmasqConfig" ]; then
		rm -f "$dnsmasqConfig"
		pihole restartdns
	fi

	rm -rf ${pivpnoptFilesDir}
	rm -rf ${pivpnetcFilesDir}
	rm -rf ${setupVars}  # remove only this pivpn setupVars
	rm -f /var/log/*pivpn*
	rm -f ${pivpnlocalbinFilesDir}
	rm -f /etc/bash_completion.d/${newcommandname}

	echo ":::"
	echo "::: Removing VPN configuration files..."

	if [ "$VPN" = "wireguard" ]; then
		rm -f /etc/wireguard/wg0.conf
		rm -rf /etc/wireguard/configs
		rm -rf /etc/wireguard/keys
    ### FIXME SC2154
		rm -rf "$install_home/configs"
	elif [ "$VPN" = "openvpn" ]; then
		rm -rf /var/log/*openvpn*
		rm -f /etc/openvpn/server.conf
		rm -f /etc/openvpn/crl.pem
		rm -rf /etc/openvpn/easy-rsa
		rm -rf /etc/openvpn/ccd
		rm -rf "$install_home/ovpns"
	fi

	echo ":::"
	printf "::: Finished removing PiVPN from your system.\\n"
	printf "::: Reinstall by simpling running\\n:::\\n:::\\tcurl -L https://install.pivpn.io | bash\\n:::\\n::: at any time!\\n:::\\n"
}

askreboot(){
	printf "It is \\e[1mstrongly\\e[0m recommended to reboot after un-installation.\\n"
	read -p "Would you like to reboot now? [y/n]: " -n 1 -r
	echo
	if [[ ${REPLY} =~ ^[Yy]$ ]]; then
		printf "\\nRebooting system...\\n"
		sleep 3
		shutdown -r now
	fi
}

######### SCRIPT ###########
echo "::: Preparing to remove packages, be sure that each may be safely removed depending on your operating system."
echo "::: (SAFE TO REMOVE ALL ON RASPBIAN)"
while true; do
	read -rp "::: Do you wish to completely remove PiVPN configuration and installed packages from your system? (You will be prompted for each package) [y/n]: " yn
	case $yn in
		[Yy]* ) removeAll; askreboot; break;;

		[Nn]* ) printf "::: Not removing anything, exiting...\\n"; break;;
	esac
done
