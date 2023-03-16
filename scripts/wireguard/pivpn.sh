#!/bin/bash

### Constants

CHECK_PKG_INSTALLED='dpkg-query -s'
scriptdir="/opt/pivpn"
vpn="wireguard"

if grep -qsEe "^NAME\=['\"]?Alpine[a-zA-Z ]*['\"]?$" /etc/os-release; then
  CHECK_PKG_INSTALLED='apk --no-cache info -e'
fi

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

makeConf() {
  shift
  ${SUDO} "${scriptdir}/${vpn}/makeCONF.sh" "$@"
  exit "${?}"
}

listConnected() {
  shift
  ${SUDO} "${scriptdir}/${vpn}/clientSTAT.sh" "$@"
  exit "${?}"
}

debug() {
  echo "::: Generating Debug Output"

  ${SUDO} "${scriptdir}/${vpn}/pivpnDEBUG.sh" | tee /tmp/debug.log
  e="${?}"

  echo "::: "
  echo "::: Debug output completed above."
  echo "::: Copy saved to /tmp/debug.log"
  echo "::: "
  exit "${e}"
}

listClients() {
  ${SUDO} "${scriptdir}/${vpn}/listCONF.sh"
  exit "${?}"
}

showQrcode() {
  shift
  ${SUDO} "${scriptdir}/${vpn}/qrcodeCONF.sh" "$@"
  exit "${?}"
}

removeClient() {
  shift
  ${SUDO} "${scriptdir}/${vpn}/removeCONF.sh" "$@"
  exit "${?}"
}

disableClient() {
  shift
  ${SUDO} "${scriptdir}/${vpn}/disableCONF.sh" "$@"
  exit "${?}"
}

enableClient() {
  shift
  ${SUDO} "${scriptdir}/${vpn}/enableCONF.sh" "$@"
  exit "${?}"
}

uninstallServer() {
  ${SUDO} "${scriptdir}/uninstall.sh" "${vpn}"
  exit "${?}"
}

updateScripts() {
  shift
  ${SUDO} "${scriptdir}/update.sh" "$@"
  exit "${?}"
}

backup() {
  ${SUDO} "${scriptdir}/backup.sh" "${vpn}"
  exit "${?}"
}

showHelp() {
  echo "::: Control all PiVPN specific functions!"
  echo ":::"
  echo "::: Usage: pivpn <command> [option]"
  echo ":::"
  echo "::: Commands:"
  echo ":::    -a, add              Create a client conf profile"
  echo ":::    -c, clients          List any connected clients to the server"
  echo ":::    -d, debug            Start a debugging session if having trouble"
  echo ":::    -l, list             List all clients"
  echo -n ":::   -qr, qrcode           Show the qrcode of a client for use "
  echo "with the mobile app"
  echo ":::    -r, remove           Remove a client"
  echo ":::  -off, off              Disable a client"
  echo ":::   -on, on               Enable a client"
  echo ":::    -h, help             Show this help dialog"
  echo ":::    -u, uninstall        Uninstall pivpn from your system!"
  echo ":::   -up, update           Updates PiVPN Scripts"
  echo ":::   -bk, backup           Backup VPN configs and user profiles"
  exit 0
}

### Script
# Must be root to use this tool
if [[ "${EUID}" -ne 0 ]]; then
  if ${CHECK_PKG_INSTALLED} sudo &> /dev/null; then
    export SUDO="sudo"
  else
    err "::: Please install sudo or run this as root."
    exit 1
  fi
fi

if [[ "$#" == 0 ]]; then
  showHelp
fi

# Handle redirecting to specific functions based on arguments
case "${1}" in
  "-a" | "add")
    makeConf "$@"
    ;;
  "-c" | "clients")
    listConnected "$@"
    ;;
  "-d" | "debug")
    debug
    ;;
  "-l" | "list")
    listClients
    ;;
  "-qr" | "qrcode")
    showQrcode "$@"
    ;;
  "-r" | "remove")
    removeClient "$@"
    ;;
  "-off" | "off")
    disableClient "$@"
    ;;
  "-on" | "on")
    enableClient "$@"
    ;;
  "-h" | "help")
    showHelp
    ;;
  "-u" | "uninstall")
    uninstallServer
    ;;
  "-up" | "update")
    updateScripts "$@"
    ;;
  "-bk" | "backup")
    backup
    ;;
  *)
    showHelp
    ;;
esac
