#!/bin/bash

vpn=$1
setupVars="/etc/pivpn/${vpn}/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
	echo "::: Missing setup vars file!"
	exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

scriptDir="/opt/pivpn"

# shellcheck disable=SC2034
loadFirewallRulesArrays(){
	iptablesNatArgs=( -s "${pivpnNET}/${subnetClass}"     -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule")
	ip6tablesNatArgs=(-s "${pivpnNETv6}/${subnetClassv6}" -o "${IPv6dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule")

	iptablesPiholeUdpArgs=(-i "${pivpnDEV}" -p udp --dport 53 --source "${pivpnNET}/${subnetClass}" -j ACCEPT --comment "${VPN}-pihole-udp-rule")
	iptablesPiholeTcpArgs=(-i "${pivpnDEV}" -p tcp --dport 53 --source "${pivpnNET}/${subnetClass}" -j ACCEPT --comment "${VPN}-pihole-tcp-rule")

	iptablesInputArgs=( -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule")
	ip6tablesInputArgs=(-i "${IPv6dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule")

	iptablesForwardEstabArgs=(-d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}"  -o "${pivpnDEV}" -m conntrack --ctstate "RELATED,ESTABLISHED" -j ACCEPT -m comment --comment "${VPN}-forward-estab-rule")
	iptablesForwardArgs=(     -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}"                                               -j ACCEPT -m comment --comment "${VPN}-forward-rule")

	ip6tablesForwardEstabArgs=(-d "${pivpnNETv6}/${subnetClassv6}" -i "${IPv6dev}"  -o "${pivpnDEV}" -m conntrack --ctstate "RELATED,ESTABLISHED" -j ACCEPT -m comment --comment "${VPN}-forward-estab-rule")
	ip6tablesForwardArgs=(     -s "${pivpnNETv6}/${subnetClassv6}" -i "${pivpnDEV}" -o "${IPv6dev}"                                               -j ACCEPT -m comment --comment "${VPN}-forward-rule")

	ufwPiholeUdpArgs=(allow in on "${pivpnDEV}" to any port 53 proto udp from "${pivpnNET}/${subnetClass}" comment "${VPN}-pihole-udp-rule")
	ufwPiholeTcpArgs=(allow in on "${pivpnDEV}" to any port 53 proto tcp from "${pivpnNET}/${subnetClass}" comment "${VPN}-pihole-udp-rule")

	ufwInputArgs=( allow in on "${IPv4dev}" to any "${pivpnPORT}"/"${pivpnPROTO}" comment "${VPN}-input-rule")
	ufw6InputArgs=(allow in on "${IPv4dev}" to any "${pivpnPORT}"/"${pivpnPROTO}" comment "${VPN}-input-rule")

	ufwForwardArgs=( allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}"     out on "${IPv4dev}" to any comment "${VPN}-forward-rule")
	ufw6ForwardArgs=(allow in on "${pivpnDEV}" from "${pivpnNETv6}/${subnetClassv6}" out on "${IPv6dev}" to any comment "${VPN}-forward-rule")
}

# shellcheck disable=SC1091
loadFunctions(){
	source ${scriptDir}/network/iptablesFUNC.sh
	source ${scriptDir}/network/ufwFUNC.sh
	source ${scriptDir}/network/sysctlFUNC.sh
}

loadFirewallRulesArrays
loadFunctions

option="$2"
case "$option" in
	apply|add)
		setting="$3"
		case "$setting" in
			iptables-nat)
				addIptablesNatRules
				;;
			iptables-input)
				addIptablesInputRules
				;;
			iptables-forward)
				addIptablesForwardRules
				;;
			ufw-input)
				addUfwInputRules
				;;
			ufw-forward)
				addUfwForwardRules
				;;
			sysctl)
				applySysctl
				;;
			*)
				applySysctl
				if [ "${FIREWALL_FRONTEND}" = 'iptables' ]; then
					addIptablesNatRules
					addIptablesInputRules
					addIptablesForwardRules
				elif [ "${FIREWALL_FRONTEND}" = 'ufw' ]; then
					addIptablesNatRules
					addUfwInputRules
					addUfwForwardRules
				else
					if [ -n "${FIREWALL_FRONTEND}" ]; then
						echo ":: [WARN] Unknown firewall frontend ${FIREWALL_FRONTEND}!"
					else
						echo ":: [WARN] Missing firewall frontend!"
					fi
				fi
				;;
		esac
		;;
	check)
		setting="$3"
		case "$setting" in
			iptables-nat)
				checkIptablesNatRules
				;;
			iptables-input)
				checkIptablesInputRules
				;;
			iptables-forward)
				checkIptablesForwardRules
				;;
			ufw-input)
				checkUfwInputRules
				;;
			ufw-forward)
				checkUfwForwardRules
				;;
			sysctl)
				checkSysctl
				;;
			*)
				echo "::: Error: Got an unexpected argument '$3', expected [sysctl|iptables|ufw]"
				exit 1
				;;
		esac
		;;
	reset|remove)
		setting="$3"
		case "$setting" in
			iptables-nat)
				removeIptablesNatRules
				;;
			iptables-input)
				removeIptablesInputRules
				;;
			iptables-forward)
				removeIptablesForwardRules
				;;
			ufw-input)
				removeUfwInputRules
				;;
			ufw-forward)
				removeUfwForwardRules
				;;
			sysctl)
				resetSysctl
				;;
			*)
				resetSysctl
				if [ "${FIREWALL_FRONTEND}" = 'iptables' ]; then
					removeIptablesNatRules
					removeIptablesInputRules
					removeIptablesForwardRules
				elif [ "${FIREWALL_FRONTEND}" = 'ufw' ]; then
					removeIptablesNatRules
					removeUfwInputRules
					removeUfwForwardRules
				else
					if [ -n "${FIREWALL_FRONTEND}" ]; then
						echo ":: [WARN] Unknown firewall frontend ${FIREWALL_FRONTEND}!"
					else
						echo ":: [WARN] Missing firewall frontend!"
					fi
				fi
				;;
		esac
		;;
	*)
		echo "::: Error: Got an unexpected argument '$2', expected [<apply|add>|<reset|remove>]"
		exit 1
		;;
esac
