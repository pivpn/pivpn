#!/bin/bash

# dual protocol, VPN type supplied as $1

setupVars="/etc/pivpn/${VPN}/setupVars.conf"
ERR=0

if [ ! -f "${setupVars}" ]; then
	echo "::: Missing setup vars file!"
	exit 1
fi

source "${setupVars}"

if [ "$VPN" = "wireguard" ]; then
	VPN_SERVICE="wg-quick@wg0"
	VPN_PRETTY_NAME="WireGuard"
elif [ "$VPN" = "openvpn" ]; then
	VPN_SERVICE="openvpn"
	VPN_PRETTY_NAME="OpenVPN"
fi

if [ "$(</proc/sys/net/ipv4/ip_forward)" -eq 1 ]; then
	echo ":: [OK] IP forwarding is enabled"
else
	ERR=1
	read -r -p ":: [ERR] IP forwarding is not enabled, attempt fix now? [Y/n] " REPLY
	if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
		sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
		sysctl -p
		echo "Done"
	fi
fi

if [ "$USING_UFW" -eq 0 ]; then

	if iptables -t nat -C POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null; then
		echo ":: [OK] Iptables MASQUERADE rule set"
	else
		ERR=1
		read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			iptables -t nat -I POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
			iptables-save > /etc/iptables/rules.v4
			echo "Done"
		fi
	fi

	if [ "$INPUT_CHAIN_EDITED" -eq 1 ]; then

		if iptables -C INPUT -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule" &> /dev/null; then
			echo ":: [OK] Iptables INPUT rule set"
		else
			ERR=1
			read -r -p ":: [ERR] Iptables INPUT rule is not set, attempt fix now? [Y/n] " REPLY
			if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
				iptables -I INPUT 1 -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule"
				iptables-save > /etc/iptables/rules.v4
				echo "Done"
			fi
		fi
	fi

	if [ "$FORWARD_CHAIN_EDITED" -eq 1 ]; then

		if iptables -C FORWARD -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule" &> /dev/null; then
			echo ":: [OK] Iptables FORWARD rule set"
		else
			ERR=1
			read -r -p ":: [ERR] Iptables FORWARD rule is not set, attempt fix now? [Y/n] " REPLY
			if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
				iptables -I FORWARD 1 -d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
				iptables -I FORWARD 2 -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
				iptables-save > /etc/iptables/rules.v4
				echo "Done"
			fi
		fi
	fi

else

	if LANG="en_US.UTF-8" ufw status | grep -qw 'active'; then
		echo ":: [OK] Ufw is enabled"
	else
		ERR=1
		read -r -p ":: [ERR] Ufw is not enabled, try to enable now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			ufw enable
		fi
	fi

	if iptables -t nat -C POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null; then
		echo ":: [OK] Iptables MASQUERADE rule set"
	else
		ERR=1
		read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			sed "/delete these required/i *nat\n:POSTROUTING ACCEPT [0:0]\n-I POSTROUTING -s ${pivpnNET}/${subnetClass} -o ${IPv4dev} -j MASQUERADE -m comment --comment ${VPN}-nat-rule\nCOMMIT\n" -i /etc/ufw/before.rules
			ufw reload
			echo "Done"
		fi
	fi

	if iptables -C ufw-user-input -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT &> /dev/null; then
		echo ":: [OK] Ufw input rule set"
	else
		ERR=1
		read -r -p ":: [ERR] Ufw input rule is not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			ufw insert 1 allow "${pivpnPORT}"/"${pivpnPROTO}"
			ufw reload
			echo "Done"
		fi
	fi

	if iptables -C ufw-user-forward -i "${pivpnDEV}" -o "${IPv4dev}" -s "${pivpnNET}/${subnetClass}" -j ACCEPT &> /dev/null; then
		echo ":: [OK] Ufw forwarding rule set"
	else
		ERR=1
		read -r -p ":: [ERR] Ufw forwarding rule is not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			ufw route insert 1 allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any
			ufw reload
			echo "Done"
		fi
	fi

fi

if systemctl is-active -q "${VPN_SERVICE}"; then
	echo ":: [OK] ${VPN_PRETTY_NAME} is running"
else
	ERR=1
	read -r -p ":: [ERR] ${VPN_PRETTY_NAME} is not running, try to start now? [Y/n] " REPLY
	if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
		systemctl start "${VPN_SERVICE}"
		echo "Done"
	fi
fi

if systemctl is-enabled -q "${VPN_SERVICE}"; then
	echo ":: [OK] ${VPN_PRETTY_NAME} is enabled (it will automatically start on reboot)"
else
	ERR=1
	read -r -p ":: [ERR] ${VPN_PRETTY_NAME} is not enabled, try to enable now? [Y/n] " REPLY
	if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
		systemctl enable "${VPN_SERVICE}"
		echo "Done"
	fi
fi

# grep -w (whole word) is used so port 11940 won't match when looking for 1194
if netstat -antu | grep -wqE "${pivpnPROTO}.*${pivpnPORT}"; then
	echo ":: [OK] ${VPN_PRETTY_NAME} is listening on port ${pivpnPORT}/${pivpnPROTO}"
else
	ERR=1
	read -r -p ":: [ERR] ${VPN_PRETTY_NAME} is not listening, try to restart now? [Y/n] " REPLY
	if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
		systemctl restart "${VPN_SERVICE}"
		echo "Done"
	fi
fi

if [ "$ERR" -eq 1 ]; then
	echo -e "[INFO] Run \e[1mpivpn -d\e[0m again to see if we detect issues"
fi
