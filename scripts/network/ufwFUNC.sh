#!/bin/bash

# shellcheck disable=SC2154
addUfwInputRules(){
	# Allow incoming DNS requests through UFW.
	if [ "${USING_PIHOLE}" = 1 ]; then
		ufw insert 1 "${ufwPiholeUdpArgs[@]}"
		ufw insert 1 "${ufwPiholeTcpArgs[@]}"
	fi

	# Insert rules at the beginning of the chain (in case there are other rules that may drop the traffic)
	ufw insert 1 "${ufwInputArgs[@]}"
	ufw insert 1 "${ufw6InputArgs[@]}"
}

checkUfwInputRules(){
	if [ "${USING_PIHOLE}" = 1 ]; then
		iptables -C ufw-user-input "${iptablesPiholeUdpArgs[@]}" &> /dev/null || return 1
		iptables -C ufw-user-input "${iptablesPiholeTcpArgs[@]}" &> /dev/null || return 1
	fi

	iptables -C ufw-user-input "${iptablesInputArgs[@]}" &> /dev/null || return 1
	ip6tables -C ufw-user-input "${ip6tablesInputArgs[@]}" &> /dev/null || return 1
}

removeUfwInputRules(){
	if [ "${USING_PIHOLE}" = 1 ]; then
		ufw delete "${ufwPiholeUdpArgs[@]}"
		ufw delete "${ufwPiholeTcpArgs[@]}"
	fi

	ufw delete "${ufwInputArgs[@]}"
	ufw delete "${ufw6InputArgs[@]}"
}

addUfwForwardRules(){
	ufw route insert 1 "${ufwForwardArgs[@]}"
	if [ "$pivpnenableipv6" == "1" ]; then
		ufw route insert 1 "${ufw6ForwardArgs[@]}"
	fi
}

checkUfwForwardRules(){
	iptables -C ufw-user-forward "${iptablesForwardArgs[@]}" &> /dev/null || return 1
	if [ "$pivpnenableipv6" == "1" ]; then
		ip6tables -C ufw-user-forward "${ip6tablesForwardArgs[@]}" &> /dev/null || return 1
	fi
}

removeUfwForwardRules(){
	ufw route delete "${ufwForwardArgs[@]}"
	if [ "$pivpnenableipv6" == "1" ]; then
		ufw route delete "${ufw6ForwardArgs[@]}"
	fi
}
