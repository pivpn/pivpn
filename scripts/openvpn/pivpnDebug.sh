#!/usr/bin/env bash
# This scripts runs as root

setupVars="/etc/pivpn/openvpn/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

echo -e "::::\t\t\e[4mPiVPN debug\e[0m\t\t ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mLatest commit\e[0m\t\t ::::"
git --git-dir /etc/.pivpn/.git log -n 1
printf "=============================================\n"
echo -e "::::\t    \e[4mInstallation settings\e[0m    \t ::::"
sed "s/$pivpnHOST/REDACTED/" < ${setupVars}
printf "=============================================\n"
echo -e "::::  \e[4mServer configuration shown below\e[0m   ::::"
cat /etc/openvpn/server.conf
printf "=============================================\n"
echo -e "::::  \e[4mClient template file shown below\e[0m   ::::"
sed "s/$pivpnHOST/REDACTED/" < /etc/openvpn/easy-rsa/pki/Default.txt
printf "=============================================\n"
echo -e ":::: \t\e[4mRecursive list of files in\e[0m\t ::::\n::: \e[4m/etc/openvpn/easy-rsa/pki shows below\e[0m :::"
ls -LR /etc/openvpn/easy-rsa/pki/ -Ireqs -Icerts_by_serial
printf "=============================================\n"
echo -e "::::\t\t\e[4mSelf check\e[0m\t\t ::::"
/opt/pivpn/self_check.sh ${VPN}
printf "=============================================\n"
echo -e ":::: Having trouble connecting? Take a look at the FAQ:"
echo -e ":::: \e[1mhttps://github.com/pivpn/pivpn/wiki/FAQ\e[0m"
printf "=============================================\n"
echo -e "::::      \e[4mSnippet of the server log\e[0m      ::::"
tail -20 /var/log/openvpn.log > /tmp/snippet

# Regular expession taken from https://superuser.com/a/202835, it will match invalid IPs
# like 123.456.789.012 but it's fine since the log only contains valid ones.
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
