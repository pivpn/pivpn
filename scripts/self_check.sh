#!/bin/bash

# dual protocol, VPN type supplied as $1
VPN=$1
setupVars="/etc/pivpn/${VPN}/setupVars.conf"
ERR=0

if [ ! -f "${setupVars}" ]; then
	echo "::: Missing setup vars file!"
	exit 1
fi

# SC1090 disabled as setupVars file differs from system to system
# shellcheck disable=SC1090
source "${setupVars}"

scriptDir="/opt/pivpn"

if [ "$VPN" = "wireguard" ]; then
	VPN_SERVICE="wg-quick@wg0"
	VPN_PRETTY_NAME="WireGuard"
elif [ "$VPN" = "openvpn" ]; then
	VPN_SERVICE="openvpn"
	VPN_PRETTY_NAME="OpenVPN"
fi

if ${scriptDir}/network/networkCONF.sh "${VPN}" check sysctl; then
	echo ":: [OK] IP forwarding is enabled"
else
	ERR=1
	read -r -p ":: [ERR] IP forwarding is not enabled, attempt fix now? [Y/n] " REPLY
	if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
		${scriptDir}/network/networkCONF.sh "${VPN}" apply sysctl
		echo "Done"
	fi
fi

# Disabled SC Warnings for SC2154, values for variables are sourced from setupVars
# shellcheck disable=SC2154
if [ "${FIREWALL_FRONTEND}" = 'iptables' ]; then

	if ${scriptDir}/network/networkCONF.sh "${VPN}" check iptables-nat; then
		echo ":: [OK] Iptables MASQUERADE rule set"
	else
		ERR=1
		read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			${scriptDir}/network/networkCONF.sh "${VPN}" add iptables-nat
		fi
	fi

	if ${scriptDir}/network/networkCONF.sh "${VPN}" check iptables-input; then
		echo ":: [OK] Iptables INPUT rules set"
	else
		ERR=1
		read -r -p ":: [ERR] Iptables INPUT rules are not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			${scriptDir}/network/networkCONF.sh "${VPN}" add iptables-input
		fi
	fi

	if ${scriptDir}/network/networkCONF.sh "${VPN}" check iptables-forward; then
		echo ":: [OK] Iptables FORWARD rules set"
	else
		ERR=1
		read -r -p ":: [ERR] Iptables FORWARD rules are not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			${scriptDir}/network/networkCONF.sh "${VPN}" add iptables-forward
		fi
	fi

elif [ "${FIREWALL_FRONTEND}" = 'ufw' ]; then

	if ${scriptDir}/network/networkCONF.sh "${VPN}" check iptables-nat; then
		echo ":: [OK] Iptables MASQUERADE rule set"
	else
		ERR=1
		read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			${scriptDir}/network/networkCONF.sh "${VPN}" add iptables-nat
		fi
	fi

	if ${scriptDir}/network/networkCONF.sh "${VPN}" check ufw-input; then
		echo ":: [OK] UFW INPUT rules set"
	else
		ERR=1
		read -r -p ":: [ERR] UFW INPUT rules are not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			${scriptDir}/network/networkCONF.sh "${VPN}" add ufw-input
		fi
	fi

	if ${scriptDir}/network/networkCONF.sh "${VPN}" check ufw-forward; then
		echo ":: [OK] UFW FORWARD rules set"
	else
		ERR=1
		read -r -p ":: [ERR] UFW FORWARD rules are not set, attempt fix now? [Y/n] " REPLY
		if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
			${scriptDir}/network/networkCONF.sh "${VPN}" add ufw-forward
		fi
	fi

else
	if [ -n "${FIREWALL_FRONTEND}" ]; then
		echo ":: [WARN] Unknown firewall frontend ${FIREWALL_FRONTEND}!"
	else
		echo ":: [WARN] Missing firewall frontend!"
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
