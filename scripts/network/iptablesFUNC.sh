#!/bin/bash

# shellcheck disable=SC2154
addIptablesNatRules(){
	# Only add the NAT rule if it isn't already there
	if ! iptables -t nat -C POSTROUTING "${iptablesNatArgs[@]}" &> /dev/null; then
		iptables -t nat -I POSTROUTING "${iptablesNatArgs[@]}"
	fi

	if [ "$pivpnenableipv6" == "1" ]; then
		if ! ip6tables -t nat -C POSTROUTING "${ip6tablesNatArgs[@]}" &> /dev/null; then
			ip6tables -t nat -I POSTROUTING "${ip6tablesNatArgs[@]}"
		fi
	fi
}

checkIptablesNatRules(){
	iptables -t nat -C POSTROUTING "${iptablesNatArgs[@]}" &> /dev/null || return 1

	if [ "$pivpnenableipv6" == "1" ]; then
		ip6tables -t nat -C POSTROUTING "${ip6tablesNatArgs[@]}" &> /dev/null || return 1
	fi
}

removeIptablesNatRules(){
	if iptables -t nat -C POSTROUTING "${iptablesNatArgs[@]}" &> /dev/null; then
		iptables -t nat -D POSTROUTING "${iptablesNatArgs[@]}"
	fi

	if [ "$pivpnenableipv6" == "1" ]; then
		if ip6tables -t nat -C POSTROUTING "${ip6tablesNatArgs[@]}" &> /dev/null; then
			ip6tables -t nat -D POSTROUTING "${ip6tablesNatArgs[@]}"
		fi
	fi
}

addIptablesInputRules(){
	# Rules are added to the top of the chain (using -I) so they take precedence over rules that may already be there.
	if [ "${USING_PIHOLE}" = 1 ]; then
		if ! iptables -C INPUT "${iptablesPiholeUdpArgs[@]}" &> /dev/null; then
			iptables -I INPUT "${iptablesPiholeUdpArgs[@]}"
		fi
		if ! iptables -C INPUT "${iptablesPiholeTcpArgs[@]}" &> /dev/null; then
			iptables -I INPUT "${iptablesPiholeTcpArgs[@]}"
		fi
	fi

	if ! iptables -C INPUT "${iptablesInputArgs[@]}" &> /dev/null; then
		iptables -I INPUT "${iptablesInputArgs[@]}"
	fi

	if [ "$pivpnenableipv6" == "1" ]; then
		if ! ip6tables -C INPUT "${ip6tablesInputArgs[@]}" &> /dev/null; then
			ip6tables -I INPUT "${ip6tablesInputArgs[@]}"
		fi
	fi
}

checkIptablesInputRules(){
	if [ "${USING_PIHOLE}" = 1 ]; then
		iptables -C INPUT "${iptablesPiholeUdpArgs[@]}" &> /dev/null || return 1
		iptables -C INPUT "${iptablesPiholeTcpArgs[@]}" &> /dev/null || return 1
	fi

	iptables -C INPUT "${iptablesInputArgs[@]}" &> /dev/null || return 1
	if [ "$pivpnenableipv6" == "1" ]; then
		ip6tables -C INPUT "${ip6tablesInputArgs[@]}" &> /dev/null || return 1
	fi
}

removeIptablesInputRules(){
	if [ "${USING_PIHOLE}" = 1 ]; then
		if iptables -C INPUT "${iptablesPiholeUdpArgs[@]}" &> /dev/null; then
			iptables -D INPUT "${iptablesPiholeUdpArgs[@]}"
		fi
		if iptables -C INPUT "${iptablesPiholeTcpArgs[@]}" &> /dev/null; then
			iptables -D INPUT "${iptablesPiholeTcpArgs[@]}"
		fi
	fi

	if iptables -C INPUT "${iptablesInputArgs[@]}" &> /dev/null; then
		iptables -D INPUT "${iptablesInputArgs[@]}"
	fi

	if [ "$pivpnenableipv6" == "1" ]; then
		if ip6tables -C INPUT "${ip6tablesInputArgs[@]}" &> /dev/null; then
			ip6tables -D INPUT "${ip6tablesInputArgs[@]}"
		fi
	fi
}

addIptablesForwardRules(){
	if ! iptables -C FORWARD "${iptablesForwardArgs[@]}" &> /dev/null; then
		iptables -I FORWARD "${iptablesForwardArgs[@]}"
	fi

	if ! iptables -C FORWARD "${iptablesForwardEstabArgs[@]}" &> /dev/null; then
		iptables -I FORWARD "${iptablesForwardEstabArgs[@]}"
	fi

	if [ "$pivpnenableipv6" == "1" ]; then
		if ! ip6tables -C FORWARD "${ip6tablesForwardArgs[@]}" &> /dev/null; then
			ip6tables -I FORWARD "${ip6tablesForwardArgs[@]}"
		fi

		if ! ip6tables -C FORWARD "${ip6tablesForwardEstabArgs[@]}" &> /dev/null; then
			ip6tables -I FORWARD "${ip6tablesForwardEstabArgs[@]}"
		fi
	fi
}

checkIptablesForwardRules(){
	iptables -C FORWARD "${iptablesForwardArgs[@]}" &> /dev/null || return 1
	iptables -C FORWARD "${iptablesForwardEstabArgs[@]}" &> /dev/null || return 1

	if [ "$pivpnenableipv6" == "1" ]; then
		ip6tables -C FORWARD "${ip6tablesForwardArgs[@]}" &> /dev/null || return 1
		ip6tables -C FORWARD "${ip6tablesForwardEstabArgs[@]}" &> /dev/null || return 1
	fi
}

removeIptablesForwardRules(){
	if iptables -C FORWARD "${iptablesForwardArgs[@]}" &> /dev/null; then
		iptables -D FORWARD "${iptablesForwardArgs[@]}"
	fi

	if iptables -C FORWARD "${iptablesForwardEstabArgs[@]}" &> /dev/null; then
		iptables -D FORWARD "${iptablesForwardEstabArgs[@]}"
	fi

	if [ "$pivpnenableipv6" == "1" ]; then
		if ip6tables -C FORWARD "${ip6tablesForwardArgs[@]}" &> /dev/null; then
			ip6tables -D FORWARD "${ip6tablesForwardArgs[@]}"
		fi

		if ip6tables -C FORWARD "${ip6tablesForwardEstabArgs[@]}" &> /dev/null; then
			ip6tables -D FORWARD "${ip6tablesForwardEstabArgs[@]}"
		fi
	fi
}
