#!/bin/bash

CHECK_PKG_INSTALLED='dpkg-query -s'

if grep -qsEe "^NAME\=['\"]?Alpine[a-zA-Z ]*['\"]?$" /etc/os-release; then
  CHECK_PKG_INSTALLED='apk --no-cache info -e'
fi

# Must be root to use this tool
if [[ "${EUID}" -ne 0 ]]; then
  if ${CHECK_PKG_INSTALLED} sudo &> /dev/null; then
    export SUDO="sudo"
  else
    err "::: Please install sudo or run this as root."
    exit 1
  fi
fi

scriptDir="/opt/pivpn"
vpn="openvpn"

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

makeOVPNFunc() {
  shift
  ${SUDO} "${scriptDir}/${vpn}/makeOVPN.sh" "$@"
  exit "${?}"
}

listClientsFunc() {
  shift
  ${SUDO} "${scriptDir}/${vpn}/clientStat.sh" "$@"
  exit "${?}"
}

listOVPNFunc() {
  ${SUDO} "${scriptDir}/${vpn}/listOVPN.sh"
  exit "${?}"
}

debugFunc() {
  echo "::: Generating Debug Output"

  ${SUDO} "${scriptDir}/${vpn}/pivpnDebug.sh" | tee /tmp/debug.log

  echo "::: "
  echo "::: Debug output completed above."
  echo "::: Copy saved to /tmp/debug.log"
  echo "::: "
  exit "${?}"
}

removeOVPNFunc() {
  shift
  ${SUDO} "${scriptDir}/${vpn}/removeOVPN.sh" "$@"
  exit "${?}"
}

uninstallFunc() {
  ${SUDO} "${scriptDir}/uninstall.sh" "${vpn}"
  exit "${?}"
}

update() {
  shift
  ${SUDO} "${scriptDir}/update.sh" "$@"
  exit "${?}"
}

backup() {
  ${SUDO} "${scriptDir}/backup.sh" "${vpn}"
  exit "${?}"
}

helpFunc() {
  echo "::: Control all PiVPN specific functions!"
  echo ":::"
  echo "::: Usage: pivpn <command> [option]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  -a, add [nopass]     Create a client ovpn profile, optional nopass"
  echo ":::  -c, clients          List any connected clients to the server"
  echo ":::  -d, debug            Start a debugging session if having trouble"
  echo ":::  -l, list             List all valid and revoked certificates"
  echo ":::  -r, revoke           Revoke a client ovpn profile"
  echo ":::  -h, help             Show this help dialog"
  echo ":::  -u, uninstall        Uninstall PiVPN from your system!"
  echo ":::  -up, update          Updates PiVPN Scripts"
  echo ":::  -bk, backup          Backup Openvpn and ovpns dir"
  exit 0
}

if [[ "$#" == 0 ]]; then
  helpFunc
fi

# Handle redirecting to specific functions based on arguments
case "${1}" in
  "-a" | "add")
    makeOVPNFunc "$@"
    ;;
  "-c" | "clients")
    listClientsFunc "$@"
    ;;
  "-d" | "debug")
    debugFunc
    ;;
  "-l" | "list")
    listOVPNFunc
    ;;
  "-r" | "revoke")
    removeOVPNFunc "$@"
    ;;
  "-h" | "help")
    helpFunc
    ;;
  "-u" | "uninstall")
    uninstallFunc
    ;;
  "-up" | "update")
    update "$@"
    ;;
  "-bk" | "backup")
    backup
    ;;
  *)
    helpFunc
    ;;
esac
