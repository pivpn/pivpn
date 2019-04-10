#!/usr/bin/env bash
# This scripts runs as root
printf ":::\t\t\t\t\t:::\n::\t\tPiVPN Debug\t\t ::\n"
printf ":::\t\t\t\t\t:::\n::\tLatest Commit\t\t\t ::\n:::\t\t\t\t\t:::\n"
git --git-dir /etc/.pivpn/.git log -n 1
printf ":::\t\t\t\t\t:::\n::\tRecursive list of files in\t ::\n"
printf "::\t/etc/openvpn/easy-rsa/pki\t ::\n:::\t\t\t\t\t:::\n"
ls -LR /etc/openvpn/easy-rsa/pki/ -Ireqs -Icerts_by_serial
printf ":::\t\t\t\t\t:::\n::\tOutput of /etc/pivpn/*\t\t ::\n:::\t\t\t\t\t:::\n"
for filename in /etc/pivpn/*; do
    if [[ "${filename}" != "/etc/pivpn/install.log" ]]; then
        echo ":: START $filename ::"
        cat "$filename"
        echo ":: END $filename ::"
    fi
done
printf ":::\t\t\t\t\t:::\n:: /etc/openvpn/easy-rsa/pki/Default.txt ::\n:::\t\t\t\t\t:::\n"
cat /etc/openvpn/easy-rsa/pki/Default.txt
if [[ ${noUFW} -eq 1 ]]; then
    printf ":::\t\t\t\t\t:::\n::\tOutput of iptables\t\t ::\n:::\t\t\t\t\t:::\n"
    iptables -t nat -L -n -v
fi
# Telekom Hybrid Check
wget -O /tmp/hybcheck http://speedport.ip &>/dev/null
if grep -Fq "Speedport Pro" /tmp/hybcheck || grep -Fq "Speedport Hybrid" /tmp/hybcheck
then
    printf ":::\t\t\t\t\t:::\n::\tTelekom Hybrid Check\t\t ::\n:::\t\t\t\t\t:::\n"
    echo "Are you using Telekom Hybrid (found a hybrid compatible router)?"
    echo "If yes and you have problems with the connections you can test the following:"
    echo "Add 'tun-mtu 1316' in /etc/openvpn/easy-rsa/pki/Default.txt to set a hybrid compatible MTU size (new .ovpn files)."
    echo "For already existing .ovpn files 'tun-mtu 1316' can also be inserted there manually."
    echo "With Telekom hybrid connections, you may have to experiment a little with MTU (tun-mtu, link-mtu and mssfix)."
fi
rm /tmp/hybcheck
printf ":::\t\t\t\t\t:::\n::\tDebug Output Complete\t\t ::\n:::\t\t\t\t\t:::\n"
