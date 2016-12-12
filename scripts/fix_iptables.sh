#!/usr/bin/env bash
# PiVPN: Fix iptables script
# called by pivpnDebug.sh

IPv4dev=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++)if($i~/dev/)print $(i+1)}')
iptables -t nat -F
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${IPv4dev} -j MASQUERADE
iptables-save > /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4
