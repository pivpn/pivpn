#!/bin/bash

applySysctl(){
	# Enable forwarding of internet traffic
	sysctl "net.ipv4.ip_forward=1"

	# shellcheck disable=SC2154
	if [ "${pivpnenableipv6}" -eq 1 ]; then
		sysctl "net.ipv6.conf.all.forwarding=1"

		if [ -d "/proc/sys/net/ipv6/conf/${IPv6dev}" ]; then
			sysctl "net.ipv6.conf.${IPv6dev}.accept_ra=2"
		else
			echo "Warning, won't override Router Advertisements behaviour since the configured ${IPv6dev} interface doesn't exist"
		fi
	fi
}

checkSysctl(){
	[ "$(</proc/sys/net/ipv4/ip_forward)" -eq 1 ] || return 1

	if [ "${pivpnenableipv6}" -eq 1 ]; then
		[ "$(</proc/sys/net/ipv6/conf/all/forwarding)" -eq 1 ] || return 1
		[ "$(<"/proc/sys/net/ipv6/conf/${IPv6dev}/accept_ra")" -eq 2 ] || return 1
	fi
}

resetSysctl(){
	sysctl "net.ipv4.ip_forward=0"

	if [ "${pivpnenableipv6}" -eq 1 ]; then
		sysctl "net.ipv6.conf.all.forwarding=0"

		if [ -d "/proc/sys/net/ipv6/conf/${IPv6dev}" ]; then
			sysctl "net.ipv6.conf.${IPv6dev}.accept_ra=1"
		else
			echo "Warning, won't reset IPv6 Router Advertisements behaviour since the configured ${IPv6dev} interface doesn't exist"
		fi
	fi
}
