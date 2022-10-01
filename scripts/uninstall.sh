#!/bin/bash
# PiVPN: Uninstall Script

### FIXME:
###   global: config storage, refactor all scripts to adhere to the storage
### FIXME:
###   use variables where appropriate, reduce magic numbers by 99.9%, at least.

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size="$(stty size 2> /dev/null || echo 24 80)"
rows="$(echo "${screen_size}" | awk '{print $1}')"
columns="$(echo "${screen_size}" | awk '{print $2}')"

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$((rows / 2))
c=$((columns / 2))
# Unless the screen is tiny
r=$((r < 20 ? 20 : r))
c=$((c < 70 ? 70 : c))

PKG_MANAGER="apt-get"
PKG_REMOVE="${PKG_MANAGER} -y remove --purge"
dnsmasqConfig="/etc/dnsmasq.d/02-pivpn.conf"
setupVarsFile="setupVars.conf"
setupConfigDir="/etc/pivpn"
pivpnFilesDir="/usr/local/src/pivpn"
pivpnScriptDir="/opt/pivpn"

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

PLAT="$(grep -sEe '^NAME\=' /etc/os-release \
  | sed -E -e "s/NAME\=[\'\"]?([^ ]*).*/\1/")"

if [[ "${PLAT}" == 'Alpine' ]]; then
  PKG_MANAGER='apk'
  PKG_REMOVE="${PKG_MANAGER} --no-cache --purge del -r"
fi

UPDATE_PKG_CACHE="${PKG_MANAGER} update"

if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]] \
  && [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
  vpnStillExists=1

  # Two protocols have been installed, check if the script has passed
  # an argument, otherwise ask the user which one he wants to remove
  if [[ "$#" -ge 1 ]]; then
    VPN="${1}"
    echo "::: Uninstalling VPN: ${VPN}"
  else
    chooseVPNCmd=(whiptail
      --backtitle "Setup PiVPN"
      --title "Uninstall"
      --separate-output
      --radiolist "Both OpenVPN and WireGuard are installed, \
choose a VPN to uninstall (press space to select):"
      "${r}" "${c}" 2)
    VPNChooseOptions=(WireGuard "" on
      OpenVPN "" off)

    if VPN="$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 \
      > /dev/tty)"; then
      echo "::: Uninstalling VPN: ${VPN}"
      VPN="${VPN,,}"
    else
      err "::: Cancel selected, exiting...."
      exit 1
    fi
  fi

  setupVars="${setupConfigDir}/${VPN}/${setupVarsFile}"
else
  vpnStillExists=0

  if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"
  elif [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
  fi
fi

if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

### FIXME: introduce global lib
spinner() {
  local pid="${1}"
  local delay=0.50
  local spinstr='/-\|'

  while ps a | awk '{print $1}' | grep -q "${pid}"; do
    local temp="${spinstr#?}"
    printf " [%c]  " "${spinstr}"
    local spinstr="${temp}${spinstr%"$temp"}"
    sleep "${delay}"
    printf "\\b\\b\\b\\b\\b\\b"
  done

  printf "    \\b\\b\\b\\b"
}

removeAll() {
  # Stopping and disabling services
  echo "::: Stopping and disabling services..."

  if [[ "${PLAT}" == 'Alpine' ]]; then
    if [[ "${VPN}" == "wireguard" ]]; then
      rc-service wg-quick stop
      rc-update del wg-quick default &> /dev/null
    elif [[ "${VPN}" == "openvpn" ]]; then
      rc-service openvpn stop
      rc-update del openvpn default &> /dev/null
    fi
  else
    if [[ "${VPN}" == "wireguard" ]]; then
      systemctl stop wg-quick@wg0
      systemctl disable wg-quick@wg0 &> /dev/null
    elif [[ "${VPN}" == "openvpn" ]]; then
      systemctl stop openvpn
      systemctl disable openvpn &> /dev/null
    fi
  fi

  # Removing firewall rules.
  echo "::: Removing firewall rules..."

  if [[ "${USING_UFW}" -eq 1 ]]; then
    ### Ignoring SC2154, value sourced from setupVars file
    # shellcheck disable=SC2154
    ufw delete allow "${pivpnPORT}/${pivpnPROTO}" > /dev/null
    ### Ignoring SC2154, value sourced from setupVars file
    # shellcheck disable=SC2154
    ufw route delete allow in on "${pivpnDEV}" \
      from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any > /dev/null
    ufw delete allow in on "${pivpnDEV}" to any port 53 \
      from "${pivpnNET}/${subnetClass}" > /dev/null

    sed_pattern='/-I POSTROUTING'
    sed_pattern="${sed_pattern} -s ${pivpnNET}\\/${subnetClass}"
    sed_pattern="${sed_pattern} -o ${IPv4dev}"
    sed_pattern="${sed_pattern} -j MASQUERADE"
    sed_pattern="${sed_pattern} -m comment"
    sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/d"
    sed "${sed_pattern}" -i /etc/ufw/before.rules
    unset sed_pattern

    iptables \
      -t nat \
      -D POSTROUTING \
      -s "${pivpnNET}/${subnetClass}" \
      -o "${IPv4dev}" \
      -j MASQUERADE \
      -m comment \
      --comment "${VPN}-nat-rule"

    ufw reload &> /dev/null
  elif [[ "${USING_UFW}" -eq 0 ]]; then
    if [[ "${INPUT_CHAIN_EDITED}" -eq 1 ]]; then
      iptables \
        -D INPUT \
        -i "${IPv4dev}" \
        -p "${pivpnPROTO}" \
        --dport "${pivpnPORT}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-input-rule"
    fi

    if [[ "${FORWARD_CHAIN_EDITED}" -eq 1 ]]; then
      iptables \
        -D FORWARD \
        -d "${pivpnNET}/${subnetClass}" \
        -i "${IPv4dev}" \
        -o "${pivpnDEV}" \
        -m conntrack \
        --ctstate RELATED,ESTABLISHED \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"

      iptables \
        -D FORWARD \
        -s "${pivpnNET}/${subnetClass}" \
        -i "${pivpnDEV}" \
        -o "${IPv4dev}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
    fi

    iptables \
      -t nat \
      -D POSTROUTING \
      -s "${pivpnNET}/${subnetClass}" \
      -o "${IPv4dev}" \
      -j MASQUERADE \
      -m comment \
      --comment "${VPN}-nat-rule"

    iptables-save > /etc/iptables/rules.v4
  fi

  # Disable IPv4 forwarding
  if [[ "${vpnStillExists}" -eq 0 ]]; then
    sed -i '/net.ipv4.ip_forward=1/c\#net.ipv4.ip_forward=1' /etc/sysctl.conf
    sysctl -p
  fi

  # Purge dependencies
  echo "::: Purge dependencies..."

  for i in "${INSTALLED_PACKAGES[@]}"; do
    while true; do
      read -rp "::: Do you wish to remove ${i} from your system? [Y/n]: " yn

      case "${yn}" in
        [Yy]*)
          if [[ "${PLAT}" == 'Alpine' ]]; then
            if [[ "${i}" == 'openvpn' ]]; then
              deluser openvpn
              rm -f /etc/rsyslog.d/30-openvpn.conf /etc/logrotate.d/openvpn
            fi
          else
            if [[ "${i}" == "wireguard-tools" ]]; then
              # The bullseye repo may not exist if wireguard was available at
              # the time of installation.
              tmp_path='/etc/apt/sources.list.d/pivpn-bullseye-repo.list'

              if [[ -f "${tmp_path}" ]]; then
                echo "::: Removing Debian Bullseye repo..."

                rm -f "${tmp_path}"
                rm -f /etc/apt/preferences.d/pivpn-limit-bullseye

                echo "::: Updating package cache..."

                ${UPDATE_PKG_CACHE} &> /dev/null &
                spinner "$!"
              fi

              tmp_path='/etc/systemd/system/wg-quick@.service.d/override.conf'

              if [[ -f "${tmp_path}" ]]; then
                rm -f "${tmp_path}"
              fi

              unset tmp_path
            elif [[ "${i}" == "unattended-upgrades" ]]; then
              rm -rf /var/log/unattended-upgrades /etc/apt/apt.conf.d/*periodic
              rm -rf /etc/apt/apt.conf.d/*unattended-upgrades
            elif [[ "${i}" == "openvpn" ]]; then
              if [[ -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list ]]; then
                echo "::: Removing OpenVPN software repo..."

                rm -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list

                echo "::: Updating package cache..."

                ${UPDATE_PKG_CACHE} &> /dev/null &
                spinner "$!"
              fi

              deluser openvpn
              rm -f /etc/rsyslog.d/30-openvpn.conf /etc/logrotate.d/openvpn
            fi
          fi

          printf ":::\\tRemoving %s..." "${i}"

          ${PKG_REMOVE} "${i}" &> /dev/null &
          spinner "$!"

          printf "done!\\n"
          break
          ;;
        [Nn]*)
          printf ":::\\tSkipping %s\\n" "${i}"
          break
          ;;
        *)
          err "::: You must answer yes or no!"
          ;;
      esac
    done
  done

  if [[ "${PLAT}" != 'Alpine' ]]; then
    # Take care of any additional package cleaning
    printf "::: Auto removing remaining dependencies..."

    "${PKG_MANAGER}" -y autoremove &> /dev/null &
    spinner "$!"

    printf "done!\\n"
    printf "::: Auto cleaning remaining dependencies..."

    "${PKG_MANAGER}" -y autoclean &> /dev/null &
    spinner "$!"

    printf "done!\\n"
  fi

  if [[ -f "${dnsmasqConfig}" ]]; then
    rm -f "${dnsmasqConfig}"
    pihole restartdns
  fi

  echo ":::"
  echo "::: Removing VPN configuration files..."

  if [[ "${VPN}" == "wireguard" ]]; then
    rm -f /etc/wireguard/wg0.conf
    rm -rf /etc/wireguard/configs
    rm -rf /etc/wireguard/keys
    ### Ignoring SC2154, value sourced from setupVars file
    # shellcheck disable=SC2154
    rm -rf "${install_home}/configs"
  elif [[ "${VPN}" == "openvpn" ]]; then
    rm -rf /var/log/*openvpn*
    rm -f /etc/openvpn/server.conf
    rm -f /etc/openvpn/crl.pem
    rm -rf /etc/openvpn/easy-rsa
    rm -rf /etc/openvpn/ccd
    rm -rf "${install_home}/ovpns"
  fi

  if [[ "${vpnStillExists}" -eq 0 ]]; then
    echo ":::"
    echo "::: Removing pivpn system files..."

    rm -rf "${setupConfigDir}"
    rm -rf "${pivpnFilesDir}"
    rm -f /var/log/*pivpn*
    rm -f /etc/bash_completion.d/pivpn

    unlink "${pivpnScriptDir}"
    unlink /usr/local/bin/pivpn
  else
    if [[ "${VPN}" == 'wireguard' ]]; then
      othervpn='openvpn'
    else
      othervpn='wireguard'
    fi

    echo ":::"
    echo "::: Other VPN ${othervpn} still present, so not"
    echo "::: removing pivpn system files"
    rm -f "${setupConfigDir}/${VPN}/${setupVarsFile}"

    # Restore single pivpn script and bash completion for the remaining VPN
    ${SUDO} unlink /usr/local/bin/pivpn

    ${SUDO} ln \
      -sT "${pivpnFilesDir}/scripts/${othervpn}/pivpn.sh" \
      /usr/local/bin/pivpn

    ${SUDO} ln \
      -sT "${pivpnFilesDir}/scripts/${othervpn}/bash-completion" \
      /etc/bash_completion.d/pivpn

    # shellcheck disable=SC1091
    . /etc/bash_completion.d/pivpn
  fi

  echo ":::"
  printf "::: Finished removing PiVPN from your system.\\n"
  printf "::: Reinstall by simply running\\n:::\\n:::\\t"
  printf "curl -L https://install.pivpn.io | "
  printf "bash\\n:::\\n::: at any time!\\n:::\\n"
}

askreboot() {
  printf "It is \\e[1mstrongly\\e[0m recommended to reboot "
  printf "after un-installation.\\n"

  read -p "Would you like to reboot now? [y/n]: " -n 1 -r

  echo

  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    printf "\\nRebooting system...\\n"
    sleep 3
    reboot
  fi
}

######### SCRIPT ###########
echo -n "::: Preparing to remove packages, be sure that each may be safely "
echo "removed depending on your operating system."
echo "::: (SAFE TO REMOVE ALL ON RASPBIAN)"

while true; do
  echo -n "::: Do you wish to completely remove PiVPN configuration and "
  echo -n "installed packages from your system? "
  echo -n "(You will be prompted for each package) [y/n]: "
  read -r yn

  case "${yn}" in
    [Yy]*)
      removeAll
      askreboot
      break
      ;;
    [Nn]*)
      err "::: Not removing anything, exiting..."
      break
      ;;
  esac
done
