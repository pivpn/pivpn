#!/bin/bash

# shellcheck disable=SC2154

# Ufw does not store comments using the iptables' comment module, so when checking if the rule esists
# with "iptables -C chain rule_array", the arguments composing a comment in rule_array must be removed,
# otherwise there won't be a match.
removeIptablesComments(){
	local arr=( "$@" )
	local len="${#arr[@]}"
	local new=( "${arr[@]:0:(($len-4))}" )
	echo "${new[@]}"
}

addUfwInputRules(){
	# Allow incoming DNS requests through UFW.
	if [ "${USING_PIHOLE}" = 1 ]; then
		ufw prepend "${ufwPiholeUdpArgs[@]}"
		ufw prepend "${ufwPiholeTcpArgs[@]}"
	fi

	# Insert rules at the beginning of the chain (in case there are other rules that may drop the traffic)
	ufw prepend "${ufwInputArgs[@]}"
	ufw prepend "${ufw6InputArgs[@]}"
}

checkUfwInputRules(){
	if [ "${USING_PIHOLE}" = 1 ]; then
		read -r -a _iptablesPiholeUdpArgs < <(removeIptablesComments "${iptablesPiholeUdpArgs[@]}")
		iptables -C ufw-user-input "${_iptablesPiholeUdpArgs[@]}" &> /dev/null || return 1

		read -r -a _iptablesPiholeTcpArgs < <(removeIptablesComments "${iptablesPiholeTcpArgs[@]}")
		iptables -C ufw-user-input "${_iptablesPiholeTcpArgs[@]}" &> /dev/null || return 1
	fi

	read -r -a _iptablesInputArgs < <(removeIptablesComments "${iptablesInputArgs[@]}")
	iptables -C ufw-user-input "${_iptablesInputArgs[@]}" &> /dev/null || return 1

	if [ "$pivpnenableipv6" == "1" ]; then
		read -r -a _ip6tablesInputArgs < <(removeIptablesComments "${ip6tablesInputArgs[@]}")
		ip6tables -C ufw6-user-input "${_ip6tablesInputArgs[@]}" &> /dev/null || return 1
	fi
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
	ufw route prepend "${ufwForwardArgs[@]}"
	if [ "$pivpnenableipv6" == "1" ]; then
		ufw route prepend "${ufw6ForwardArgs[@]}"
	fi
}

checkUfwForwardRules(){
	read -r -a _iptablesForwardArgs < <(removeIptablesComments "${iptablesForwardArgs[@]}")
	iptables -C ufw-user-forward "${_iptablesForwardArgs[@]}" &> /dev/null || return 1

	if [ "$pivpnenableipv6" == "1" ]; then
		read -r -a _ip6tablesForwardArgs < <(removeIptablesComments "${ip6tablesForwardArgs[@]}")
		ip6tables -C ufw6-user-forward "${_ip6tablesForwardArgs[@]}" &> /dev/null || return 1
	fi
}

removeUfwForwardRules(){
	ufw route delete "${ufwForwardArgs[@]}"
	if [ "$pivpnenableipv6" == "1" ]; then
		ufw route delete "${ufw6ForwardArgs[@]}"
	fi
}
