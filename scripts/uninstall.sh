#!/usr/bin/env bash
# PiVPN: Uninstall Script

PKG_MANAGER="apt-get"
WG_SNAPSHOT="0.0.20191012"
setupVars="/etc/pivpn/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
	echo "::: Missing setup vars file!"
	exit 1
fi

source "${setupVars}"

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(echo $screen_size | awk '{print $1}')
columns=$(echo $screen_size | awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

spinner(){
	local pid=$1
	local delay=0.50
	local spinstr='/-\|'
	while [ "$(ps a | awk '{print $1}' | grep "$pid")" ]; do
		local temp=${spinstr#?}
		printf " [%c]  " "$spinstr"
		local spinstr=$temp${spinstr%"$temp"}
		sleep $delay
		printf "\b\b\b\b\b\b"
	done
	printf "    \b\b\b\b"
}

removeAll(){
	# Stopping and disabling services
	echo "::: Stopping and disabling services..."

	if [ "$VPN" = "WireGuard" ]; then
		systemctl stop wg-quick@wg0
		systemctl disable wg-quick@wg0 &> /dev/null
	elif [ "$VPN" = "OpenVPN" ]; then
		systemctl stop openvpn
		systemctl disable openvpn &> /dev/null
	fi

	# Removing firewall rules.
	echo "::: Removing firewall rules..."

	if [ "$VPN" = "WireGuard" ]; then
		pivpnDEV="wg0"
		pivpnNET="10.6.0.0/24"
	elif [ "$VPN" = "OpenVPN" ]; then
		pivpnDEV="tun0"
		pivpnNET="10.8.0.0/24"
	fi

	if [ "$USING_UFW" -eq 1 ]; then

		ufw delete allow "${pivpnPORT}"/udp > /dev/null
		ufw route delete allow in on "$pivpnDEV" from "$pivpnNET" out on "${IPv4dev}" to any > /dev/null
		sed -z "s/*nat\n:POSTROUTING ACCEPT \[0:0\]\n-I POSTROUTING -s 10.6.0.0\/24 -o ${IPv4dev} -j MASQUERADE\nCOMMIT\n\n//" -i /etc/ufw/before.rules
		ufw reload &> /dev/null

	elif [ "$USING_UFW" -eq 0 ]; then

		if [ "$INPUT_CHAIN_EDITED" -eq 1 ]; then
			iptables -D INPUT -i "${IPv4dev}" -p udp --dport "${pivpnPORT}" -j ACCEPT
		fi

		if [ "$FORWARD_CHAIN_EDITED" -eq 1 ]; then
			iptables -D FORWARD -d "$pivpnNET" -i "${IPv4dev}" -o "$pivpnDEV" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
			iptables -D FORWARD -s "$pivpnNET" -i "$pivpnDEV" -o "${IPv4dev}" -j ACCEPT
		fi

		iptables -t nat -D POSTROUTING -s "$pivpnNET" -o "${IPv4dev}" -j MASQUERADE
		iptables-save > /etc/iptables/rules.v4

	fi

	# Disable IPv4 forwarding
	sed -i '/net.ipv4.ip_forward=1/c\#net.ipv4.ip_forward=1' /etc/sysctl.conf
	sysctl -p

	# Purge dependencies
	echo "::: Purge dependencies..."

	for i in "${TO_INSTALL[@]}"; do
		while true; do
			read -rp "::: Do you wish to remove $i from your system? [Y/n]: " yn
			case $yn in
				[Yy]* ) if [ "${i}" = "wireguard" ]; then

							if [ "$(uname -m)" = "armv7l" ] || [ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "i686" ]; then
								rm /etc/apt/sources.list.d/unstable.list
								rm /etc/apt/preferences.d/limit-unstable
								$PKG_MANAGER update &> /dev/null
							fi
							rm -rf /etc/wireguard
							rm -rf $install_home/configs

						elif [ "${i}" = "wireguard-dkms" ]; then

							# If we installed wireguard-dkms and we are on armv6l, then we manually need
							# to remove the kernel module and skip the apt uninstallation (since it's not an
							# actual package)
							if [ "$(uname -m)" = "armv6l" ]; then
								dkms remove wireguard/"${WG_SNAPSHOT}" --all
								rm -rf /usr/src/wireguard-*
								break
							fi

						elif [ "${i}" = "dirmngr" ]; then

							# If dirmngr was installed, then we had previously installed wireguard on armv7l
							# so we remove the repository keys
							apt-key remove E1CF20DDFFE4B89E802658F1E0B11894F66AEC98 80D15823B7FD1561F9F7BCDDDC30D7C23CBBABEE &> /dev/null

						elif [ "${i}" = "openvpn" ]; then

							rm -rf /var/log/*openvpn*
							rm -rf /etc/openvpn
							rm -rf $install_home/ovpns

						elif [ "${i}" = "unattended-upgrades" ]; then

							rm -rf /var/log/unattended-upgrades
							rm -rf /etc/apt/apt.conf.d/*periodic
							rm -rf /etc/apt/apt.conf.d/*unattended-upgrades

						fi
						printf ":::\tRemoving %s..." "$i"; $PKG_MANAGER -y remove --purge "$i" &> /dev/null & spinner $!; printf "done!\n";
						break
						;;
				[Nn]* ) printf ":::\tSkipping %s\n" "$i";
						break
						;;
				* ) printf "::: You must answer yes or no!\n";;
			esac
		done
	done

	# Take care of any additional package cleaning
	printf "::: Auto removing remaining dependencies..."
	$PKG_MANAGER -y autoremove &> /dev/null & spinner $!; printf "done!\n";
	printf "::: Auto cleaning remaining dependencies..."
	$PKG_MANAGER -y autoclean &> /dev/null & spinner $!; printf "done!\n";

	echo ":::"
	# Removing pivpn files
	echo "::: Removing pivpn system files..."

	if [ -f /etc/dnsmasq.d/02-pivpn.conf ]; then
		rm /etc/dnsmasq.d/02-pivpn.conf
		pihole restartdns
	fi

	rm -rf /opt/pivpn
	rm -rf /etc/.pivpn
	rm -rf /etc/pivpn
	rm -rf /var/log/*pivpn*
	rm /usr/local/bin/pivpn
	rm /etc/bash_completion.d/pivpn

	echo ":::"
	printf "::: Finished removing PiVPN from your system.\n"
	printf "::: Reinstall by simpling running\n:::\n:::\tcurl -L https://install.pivpn.io | bash\n:::\n::: at any time!\n:::\n"
}

askreboot(){
	printf "It is \e[1mstrongly\e[0m recommended to reboot after un-installation.\n"
	read -p "Would you like to reboot now? [y/n]: " -n 1 -r
	echo
	if [[ ${REPLY} =~ ^[Yy]$ ]]; then
		printf "\nRebooting system...\n"
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

		[Nn]* ) printf "::: Not removing anything, exiting...\n"; break;;
	esac
done
