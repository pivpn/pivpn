#!/usr/bin/env bash
# This scripts runs as root

setupVars="/etc/pivpn/wireguard/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

echo -e "::::\t\t\e[4mPiVPN debug\e[0m\t\t ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mLatest commit\e[0m\t\t ::::"
echo -n "Branch: "
git --git-dir /usr/local/src/pivpn/.git rev-parse --abbrev-ref HEAD
git --git-dir /usr/local/src/pivpn/.git log -n 1 --format='Commit: %H%nAuthor: %an%nDate: %ad%nSummary: %s'
printf "=============================================\n"
echo -e "::::\t    \e[4mInstallation settings\e[0m    \t ::::"
# Disabling SC2154 warning, variable is sourced externaly and may vary
# shellcheck disable=SC2154
sed "s/$pivpnHOST/REDACTED/" < ${setupVars}
printf "=============================================\n"
echo -e "::::  \e[4mServer configuration shown below\e[0m   ::::"
cd /etc/wireguard/keys || exit
cp ../wg0.conf ../wg0.tmp
# Replace every key in the server configuration with just its file name
for k in *; do
    sed "s#$(<"$k")#$k#" -i ../wg0.tmp
done
cat ../wg0.tmp
rm ../wg0.tmp
printf "=============================================\n"
echo -e "::::  \e[4mClient configuration shown below\e[0m   ::::"
EXAMPLE="$(head -1 /etc/wireguard/configs/clients.txt | awk '{print $1}')"
if [ -n "$EXAMPLE" ]; then
    cp ../configs/"$EXAMPLE".conf ../configs/"$EXAMPLE".tmp
    for k in *; do
        sed "s#$(<"$k")#$k#" -i ../configs/"$EXAMPLE".tmp
    done
    sed "s/$pivpnHOST/REDACTED/" < ../configs/"$EXAMPLE".tmp
    rm ../configs/"$EXAMPLE".tmp
else
    echo "::: There are no clients yet"
fi

printf "=============================================\n"
echo -e ":::: \t\e[4mRecursive list of files in\e[0m\t ::::\n::::\t\e[4m/etc/wireguard shown below\e[0m\t ::::"
ls -LR /etc/wireguard
printf "=============================================\n"
echo -e "::::\t\t\e[4mSelf check\e[0m\t\t ::::"
/opt/pivpn/self_check.sh "${VPN}"
printf "=============================================\n"
echo -e ":::: Having trouble connecting? Take a look at the FAQ:"
echo -e ":::: \e[1mhttps://docs.pivpn.io/faq\e[0m"
printf "=============================================\n"
echo -e ":::: \e[1mWARNING\e[0m: This script should have automatically masked sensitive       ::::"
echo -e ":::: information, however, still make sure that \e[4mPrivateKey\e[0m, \e[4mPublicKey\e[0m      ::::"
echo -e ":::: and \e[4mPresharedKey\e[0m are masked before reporting an issue. An example key ::::"
echo ":::: that you should NOT see in this log looks like this:                  ::::"
echo ":::: YIAoJVsdIeyvXfGGDDadHh6AxsMRymZTnnzZoAb9cxRe                          ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mDebug complete\e[0m\t\t ::::"
