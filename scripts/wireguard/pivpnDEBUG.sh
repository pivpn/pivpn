#!/usr/bin/env bash
# This scripts runs as root

setupVars="/etc/pivpn/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

EXAMPLE="$(head -1 /etc/wireguard/configs/clients.txt | awk '{print $1}')"
ERR=0

echo -e "::::\t\t\e[4mPiVPN debug\e[0m\t\t ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mLatest commit\e[0m\t\t ::::"
git --git-dir /etc/.pivpn/.git log -n 1
printf "=============================================\n"
echo -e "::::\t    \e[4mInstallation settings\e[0m    \t ::::"
sed "s/$pivpnHOST/REDACTED/" <  /etc/pivpn/setupVars.conf
printf "=============================================\n"
echo -e "::::  \e[4mServer configuration shown below\e[0m   ::::"
cd /etc/wireguard/keys
cp ../wg0.conf ../wg0.tmp
# Replace every key in the server configuration with just its file name
for k in *; do
    sed "s#$(cat "$k")#$k#" -i ../wg0.tmp
done
cat ../wg0.tmp
rm ../wg0.tmp
printf "=============================================\n"
echo -e "::::  \e[4mClient configuration shown below\e[0m   ::::"
if [ -n "$EXAMPLE" ]; then
    cp ../configs/"$EXAMPLE".conf ../configs/"$EXAMPLE".tmp
    for k in *; do
        sed "s#$(cat "$k")#$k#" -i ../configs/"$EXAMPLE".tmp
    done
    sed "s/$pivpnHOST/REDACTED/" < ../configs/"$EXAMPLE".tmp
    rm ../configs/"$EXAMPLE".tmp
else
    echo "::: There are no clients yet"
fi

printf "=============================================\n"
echo -e ":::: \t\e[4mRecursive list of files in\e[0m\t ::::\n::::\e\t[4m/etc/wireguard shown below\e[0m\t ::::"
ls -LR /etc/wireguard
printf "=============================================\n"
echo -e "::::\t\t\e[4mSelf check\e[0m\t\t ::::"

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 1 ]; then
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

    if iptables -t nat -C POSTROUTING -s 10.6.0.0/24 -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null; then
        echo ":: [OK] Iptables MASQUERADE rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
            iptables -t nat -I POSTROUTING -s 10.6.0.0/24 -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
            iptables-save > /etc/iptables/rules.v4
            echo "Done"
        fi
    fi

    if [ "$INPUT_CHAIN_EDITED" -eq 1 ]; then

        if iptables -C INPUT -i "$IPv4dev" -p udp --dport "$pivpnPORT" -j ACCEPT -m comment --comment "${VPN}-input-rule" &> /dev/null; then
            echo ":: [OK] Iptables INPUT rule set"
        else
            ERR=1
            read -r -p ":: [ERR] Iptables INPUT rule is not set, attempt fix now? [Y/n] " REPLY
            if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
                iptables -I INPUT 1 -i "$IPv4dev" -p udp --dport "$pivpnPORT" -j ACCEPT -m comment --comment "${VPN}-input-rule"
                iptables-save > /etc/iptables/rules.v4
                echo "Done"
            fi
        fi
    fi

    if [ "$FORWARD_CHAIN_EDITED" -eq 1 ]; then

        if iptables -C FORWARD -s 10.6.0.0/24 -i wg0 -o "$IPv4dev" -j ACCEPT -m comment --comment "${VPN}-forward-rule" &> /dev/null; then
            echo ":: [OK] Iptables FORWARD rule set"
        else
            ERR=1
            read -r -p ":: [ERR] Iptables FORWARD rule is not set, attempt fix now? [Y/n] " REPLY
            if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
                iptables -I FORWARD 1 -d 10.6.0.0/24 -i "$IPv4dev" -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
                iptables -I FORWARD 2 -s 10.6.0.0/24 -i wg0 -o "$IPv4dev" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
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

    if iptables -t nat -C POSTROUTING -s 10.6.0.0/24 -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null; then
        echo ":: [OK] Iptables MASQUERADE rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
            sed "/delete these required/i *nat\n:POSTROUTING ACCEPT [0:0]\n-I POSTROUTING -s 10.6.0.0/24 -o $IPv4dev -j MASQUERADE -m comment --comment ${VPN}-nat-rule\nCOMMIT\n" -i /etc/ufw/before.rules
            ufw reload
            echo "Done"
        fi
    fi

    if iptables -C ufw-user-input -p udp --dport "${pivpnPORT}" -j ACCEPT &> /dev/null; then
        echo ":: [OK] Ufw input rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Ufw input rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
            ufw insert 1 allow "$pivpnPORT"/udp
            ufw reload
            echo "Done"
        fi
    fi

    if iptables -C ufw-user-forward -i wg0 -o "${IPv4dev}" -s 10.6.0.0/24 -j ACCEPT &> /dev/null; then
        echo ":: [OK] Ufw forwarding rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Ufw forwarding rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
            ufw route insert 1 allow in on wg0 from 10.6.0.0/24 out on "$IPv4dev" to any
            ufw reload
            echo "Done"
        fi
    fi

fi

if systemctl is-active -q wg-quick@wg0; then
    echo ":: [OK] WireGuard is running"
else
    ERR=1
    read -r -p ":: [ERR] WireGuard is not running, try to start now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
        systemctl start wg-quick@wg0
        echo "Done"
    fi
fi

if systemctl is-enabled -q wg-quick@wg0; then
    echo ":: [OK] WireGuard is enabled (it will automatically start on reboot)"
else
    ERR=1
    read -r -p ":: [ERR] WireGuard is not enabled, try to enable now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
        systemctl enable wg-quick@wg0
        echo "Done"
    fi
fi

# grep -w (whole word) is used so port 11940 won't match when looking for 1194
if netstat -uanp | grep -w "${pivpnPORT}" | grep -q 'udp'; then
    echo ":: [OK] WireGuard is listening on port ${pivpnPORT}/udp"
else
    ERR=1
    read -r -p ":: [ERR] WireGuard is not listening, try to restart now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]] || [[ -z ${REPLY} ]]; then
        systemctl restart wg-quick@wg0
        echo "Done"
    fi
fi

if [ "$ERR" -eq 1 ]; then
    echo -e "[INFO] Run \e[1mpivpn -d\e[0m again to see if we detect issues"
fi
printf "=============================================\n"
echo -e ":::: \e[1mWARNING\e[0m: This script should have automatically masked sensitive       ::::"
echo -e ":::: information, however, still make sure that \e[4mPrivateKey\e[0m, \e[4mPublicKey\e[0m      ::::"
echo -e ":::: and \e[4mPresharedKey\e[0m are masked before reporting an issue. An example key ::::"
echo ":::: that you should NOT see in this log looks like this:                  ::::"
echo ":::: YIAoJVsdIeyvXfGGDDadHh6AxsMRymZTnnzZoAb9cxRe                          ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mDebug complete\e[0m\t\t ::::"
