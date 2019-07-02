#!/usr/bin/env bash
# This scripts runs as root

PORT=$(cat /etc/pivpn/INSTALL_PORT)
PROTO=$(cat /etc/pivpn/INSTALL_PROTO)
IPv4dev="$(cat /etc/pivpn/pivpnINTERFACE)"
REMOTE="$(grep 'remote ' /etc/openvpn/easy-rsa/pki/Default.txt | awk '{print $2}')"
ERR=0

echo -e "::::\t\t\e[4mPiVPN debug\e[0m\t\t ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mLatest commit\e[0m\t\t ::::"
git --git-dir /etc/.pivpn/.git log -n 1
printf "=============================================\n"
echo -e "::::\t    \e[4mInstallation settings\e[0m    \t ::::"
# Use the wildcard so setupVars.conf.update.bak from the previous install is not shown
for filename in /etc/pivpn/*; do
    if [[ "$filename" != "/etc/pivpn/setupVars.conf"* ]]; then
        echo "$filename -> $(cat "$filename")"
    fi
done
printf "=============================================\n"
echo -e "::::\t\e[4msetupVars file shown below\e[0m\t ::::"
sed "s/$REMOTE/REMOTE/" < /etc/pivpn/setupVars.conf
printf "=============================================\n"
echo -e "::::  \e[4mServer configuration shown below\e[0m   ::::"
cat /etc/openvpn/server.conf
printf "=============================================\n"
echo -e "::::  \e[4mClient template file shown below\e[0m   ::::"
sed "s/$REMOTE/REMOTE/" < /etc/openvpn/easy-rsa/pki/Default.txt
printf "=============================================\n"
echo -e ":::: \t\e[4mRecursive list of files in\e[0m\t ::::\n::: \e[4m/etc/openvpn/easy-rsa/pki shows below\e[0m :::"
ls -LR /etc/openvpn/easy-rsa/pki/ -Ireqs -Icerts_by_serial
printf "=============================================\n"
echo -e "::::\t\t\e[4mSelf check\e[0m\t\t ::::"

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 1 ]; then
    echo ":: [OK] IP forwarding is enabled"
else
    ERR=1
    read -r -p ":: [ERR] IP forwarding is not enabled, attempt fix now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
        sysctl -p
        echo "Done"
    fi
fi

if [ "$(cat /etc/pivpn/NO_UFW)" -eq 1 ]; then

    if iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "${IPv4dev}" -j MASQUERADE &> /dev/null; then
        echo ":: [OK] Iptables MASQUERADE rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            iptables -t nat -F
            iptables -t nat -I POSTROUTING -s 10.8.0.0/24 -o "${IPv4dev}" -j MASQUERADE
            iptables-save > /etc/iptables/rules.v4
            echo "Done"
        fi
    fi

    if [ "$(cat /etc/pivpn/INPUT_CHAIN_EDITED)" -eq 1 ]; then
        if iptables -C INPUT -i "$IPv4dev" -p "$PROTO" --dport "$PORT" -j ACCEPT &> /dev/null; then
            echo ":: [OK] Iptables INPUT rule set"
        else
            ERR=1
            read -r -p ":: [ERR] Iptables INPUT rule is not set, attempt fix now? [Y/n] " REPLY
            if [[ ${REPLY} =~ ^[Yy]$ ]]; then
                iptables -I INPUT 1 -i "$IPv4dev" -p "$PROTO" --dport "$PORT" -j ACCEPT
                iptables-save > /etc/iptables/rules.v4
                echo "Done"
            fi
        fi
    fi

    if [ "$(cat /etc/pivpn/FORWARD_CHAIN_EDITED)" -eq 1 ]; then
        if iptables -C FORWARD -s 10.8.0.0/24 -i tun0 -o "$IPv4dev" -j ACCEPT &> /dev/null; then
            echo ":: [OK] Iptables FORWARD rule set"
        else
            ERR=1
            read -r -p ":: [ERR] Iptables FORWARD rule is not set, attempt fix now? [Y/n] " REPLY
            if [[ ${REPLY} =~ ^[Yy]$ ]]; then
                iptables -I FORWARD 1 -d 10.8.0.0/24 -i "$IPv4dev" -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
                iptables -I FORWARD 2 -s 10.8.0.0/24 -i tun0 -o "$IPv4dev" -j ACCEPT
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
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            ufw enable
        fi
    fi

    if iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "${IPv4dev}" -j MASQUERADE &> /dev/null; then
        echo ":: [OK] Iptables MASQUERADE rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            sed "/delete these required/i *nat\n:POSTROUTING ACCEPT [0:0]\n-I POSTROUTING -s 10.8.0.0/24 -o $IPv4dev -j MASQUERADE\nCOMMIT\n" -i /etc/ufw/before.rules
            ufw reload
            echo "Done"
        fi
    fi

    if iptables -C ufw-user-input -p "${PROTO}" --dport "${PORT}" -j ACCEPT &> /dev/null; then
        echo ":: [OK] Ufw input rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Ufw input rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            ufw insert 1 allow "$PORT"/"$PROTO"
            ufw reload
            echo "Done"
        fi
    fi

    if iptables -C ufw-user-forward -i tun0 -o "${IPv4dev}" -s 10.8.0.0/24 -j ACCEPT &> /dev/null; then
        echo ":: [OK] Ufw forwarding rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Ufw forwarding rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            ufw route insert 1 allow in on tun0 from 10.8.0.0/24 out on "$IPv4dev" to any
            ufw reload
            echo "Done"
        fi
    fi

fi

if systemctl is-active -q openvpn; then
    echo ":: [OK] OpenVPN is running"
else
    ERR=1
    read -r -p ":: [ERR] OpenVPN is not running, try to start now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        systemctl start openvpn
        echo "Done"
    fi
fi

if systemctl is-enabled -q openvpn; then
    echo ":: [OK] OpenVPN is enabled (it will automatically start on reboot)"
else
    ERR=1
    read -r -p ":: [ERR] OpenVPN is not enabled, try to enable now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        systemctl enable openvpn
        echo "Done"
    fi
fi

# grep -w (whole word) is used so port 111940 with now match when looking for 1194
if netstat -uanpt | grep openvpn | grep -w "${PORT}" | grep -q "${PROTO}"; then
    echo ":: [OK] OpenVPN is listening on port ${PORT}/${PROTO}"
else
    ERR=1
    read -r -p ":: [ERR] OpenVPN is not listening, try to restart now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        systemctl restart openvpn
        echo "Done"
    fi
fi

if [ "$ERR" -eq 1 ]; then
    echo -e "[INFO] Run \e[1mpivpn -d\e[0m again to see if we detect issues"
fi

printf "=============================================\n"
echo -e "::::      \e[4mSnippet of the server log\e[0m      ::::"
tail -20 /var/log/openvpn.log > /tmp/snippet

# Regular expession taken from https://superuser.com/a/202835, it will match invalid IPs
# like 123.456.789.012 but it's fine because the log only contains valid ones.
declare -a IPS_TO_HIDE=($(grepcidr -v 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 /tmp/snippet | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | uniq))
for IP in "${IPS_TO_HIDE[@]}"; do
    sed -i "s/$IP/REDACTED/g" /tmp/snippet
done

cat /tmp/snippet
rm /tmp/snippet
printf "=============================================\n"
echo -e "::::\t\t\e[4mDebug complete\e[0m\t\t ::::"

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
