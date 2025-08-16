#!/bin/bash
# This scripts runs as root
### Contants
setupVars="/etc/pivpn/openvpn/setupVars.conf"

# shellcheck disable=SC1090
source "${setupVars}"

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

echo -e "::::\t\t\e[4mPiVPN debug\e[0m\t\t ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mLatest commit\e[0m\t\t ::::"
echo -n "Branch: "

git --git-dir /usr/local/src/pivpn/.git rev-parse --abbrev-ref HEAD
git \
  --git-dir /usr/local/src/pivpn/.git log -n 1 \
  --format='Commit: %H%nAuthor: %an%nDate: %ad%nSummary: %s'

printf "=============================================\n"
echo -e "::::\t    \e[4mInstallation settings\e[0m    \t ::::"

# shellcheck disable=SC2154
sed "s/${pivpnHOST}/REDACTED/" < "${setupVars}"

printf "=============================================\n"
echo -e "::::  \e[4mServer configuration shown below\e[0m   ::::"

cat /etc/openvpn/server.conf

printf "=============================================\n"
echo -e "::::  \e[4mClient template file shown below\e[0m   ::::"

sed "s/${pivpnHOST}/REDACTED/" < /etc/openvpn/easy-rsa/pki/Default.txt

printf "=============================================\n"
echo -e ":::: \t\e[4mRecursive list of files in\e[0m\t ::::\n"
echo -e "::: \e[4m/etc/openvpn/easy-rsa/pki shows below\e[0m :::"

ls -LR /etc/openvpn/easy-rsa/pki/ -Ireqs -Icerts_by_serial

printf "=============================================\n"
echo -e "::::\t\t\e[4mSelf check\e[0m\t\t ::::"

/opt/pivpn/self_check.sh "${VPN}"

printf "=============================================\n"
echo -e ":::: Having trouble connecting? Take a look at the FAQ:"
echo -e ":::: \e[1mhttps://docs.pivpn.io/faq\e[0m"
printf "=============================================\n"

if [[ "${PLAT}" != 'Alpine' ]]; then
  echo -e "::::      \e[4mSnippet of the server log\e[0m      ::::"
  if [ -f /var/log/openvpn.log ]; then
    OVPNLOG="$(tail -n 20 /var/log/openvpn.log)"
  else
    OVPNLOG="$(journalctl -t ovpn-server -n 20)"
  fi

  # Regular expession taken from https://superuser.com/a/202835,
  # it will match invalid IPs like 123.456.789.012 but it's fine
  # since the log only contains valid ones.
  declare -a IPS_TO_HIDE=("$(echo "${OVPNLOG}" \
    | grepcidr -v 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
    | uniq)")

  for IP in "${IPS_TO_HIDE[@]}"; do
    OVPNLOG="${OVPNLOG//"$IP"/REDACTED}"
  done

  echo "${OVPNLOG}"
  printf "=============================================\n"
fi

echo -e "::::\t\t\e[4mDebug complete\e[0m\t\t ::::"
