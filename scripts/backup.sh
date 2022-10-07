#!/bin/bash
# PiVPN: Backup Script

### Constants
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

backupdir=pivpnbackup
date="$(date +%Y%m%d-%H%M%S)"
setupVarsFile="setupVars.conf"
setupConfigDir="/etc/pivpn"

CHECK_PKG_INSTALLED='dpkg-query -s'

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

checkbackupdir() {
  # Disabling shellcheck error $install_home sourced from $setupVars
  # shellcheck disable=SC2154
  mkdir -p "${install_home}/${backupdir}"
}

backup_openvpn() {
  openvpndir=/etc/openvpn
  ovpnsdir="${install_home}/ovpns"
  backupzip="${date}-pivpnovpnbackup.tgz"

  checkbackupdir
  # shellcheck disable=SC2210
  tar czpf "${install_home}/${backupdir}/${backupzip}" "${openvpndir}" \
    "${ovpnsdir}" > /dev/null 2>&1

  echo -e "Backup created in ${install_home}/${backupdir}/${backupzip} "
  echo -e "To restore the backup, follow instructions at:"
  echo -ne "https://docs.pivpn.io/openvpn/"
  echo -e "#migrating-pivpn-openvpn"
}

backup_wireguard() {
  wireguarddir=/etc/wireguard
  configsdir="${install_home}/configs"
  backupzip="${date}-pivpnwgbackup.tgz"

  checkbackupdir
  tar czpf "${install_home}/${backupdir}/${backupzip}" "${wireguarddir}" \
    "${configsdir}" > /dev/null 2>&1

  echo -e "Backup created in ${install_home}/${backupdir}/${backupzip} "
  echo -e "To restore the backup, follow instructions at:"
  echo -ne "https://docs.pivpn.io/openvpn/"
  echo -e "wireguard/#migrating-pivpn-wireguard"
}

### Script
if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]] \
  && [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
  # Two protocols have been installed, check if the script has passed
  # an argument, otherwise ask the user which one he wants to remove
  if [[ "$#" -ge 1 ]]; then
    VPN="${1}"
    echo "::: Backing up VPN: ${VPN}"
  else
    chooseVPNCmd=(whiptail
      --backtitle "Setup PiVPN"
      --title "Backup"
      --separate-output
      --radiolist "Both OpenVPN and WireGuard are installed, choose a VPN to \
backup (press space to select):"
      "${r}" "${c}" 2)
    VPNChooseOptions=(WireGuard "" on
      OpenVPN "" off)

    if VPN="$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 \
      > /dev/tty)"; then
      echo "::: Backing up VPN: ${VPN}"
      VPN="${VPN,,}"
    else
      err "::: Cancel selected, exiting...."
      exit 1
    fi
  fi

  setupVars="${setupConfigDir}/${VPN}/${setupVarsFile}"
else
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

if [[ "${PLAT}" == 'Alpine' ]]; then
  CHECK_PKG_INSTALLED='apk --no-cache info -e'
fi

if [[ "${EUID}" -ne 0 ]]; then
  if ${CHECK_PKG_INSTALLED} sudo &> /dev/null; then
    export SUDO="sudo"
  else
    err "::: Please install sudo or run this as root."
    exit 1
  fi
fi

if [[ "${VPN}" == "wireguard" ]]; then
  backup_wireguard
else
  backup_openvpn
fi
