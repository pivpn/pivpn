#!/bin/bash

# Must be root to use this tool
if [ $EUID -ne 0 ];then
  	if dpkg-query -s sudo &> /dev/null; then
        export SUDO="sudo"
  	else
    	echo "::: Please install sudo or run this as root."
    	exit 1
  fi
fi

scriptdir="/opt/pivpn"
vpn="wireguard"

makeConf(){
    shift
    $SUDO ${scriptdir}/${vpn}/makeCONF.sh "$@"
    exit "$?"
}

listConnected(){
    shift
    $SUDO ${scriptdir}/${vpn}/clientSTAT.sh "$@"
    exit "$?"
}

debug(){
    shift
    echo "::: Generating Debug Output"
    $SUDO ${scriptdir}/${vpn}/pivpnDEBUG.sh "$@" | tee /tmp/debug.log
    echo "::: "
    echo "::: Debug output completed above."
    echo "::: Copy saved to /tmp/debug.log"
    echo "::: "
    exit "$?"
}

listClients(){
    shift
    $SUDO ${scriptdir}/${vpn}/listCONF.sh "$@"
    exit "$?"
}

showQrcode(){
    shift
    $SUDO ${scriptdir}/${vpn}/qrcodeCONF.sh "$@"
    exit "$?"
}

removeClient(){
    shift
    $SUDO ${scriptdir}/${vpn}/removeCONF.sh "$@"
    exit "$?"
}

disableClient(){
    shift
    $SUDO ${scriptdir}/${vpn}/disableCONF.sh "$@"
    exit "$?"
}

enableClient(){
    shift
    $SUDO ${scriptdir}/${vpn}/enableCONF.sh "$@"
    exit "$?"
}

uninstallServer(){
    $SUDO ${scriptdir}/uninstall.sh "${vpn}"
    exit "$?"
}

updateScripts(){
    shift
    $SUDO ${scriptdir}/update.sh "$@"
    exit "$?"
}

backup(){
    $SUDO ${scriptdir}/backup.sh "${vpn}"
    exit "$?"
}

showHelp(){
    echo "::: Control all PiVPN specific functions!"
    echo ":::"
    echo "::: Usage: pivpn [config] <command> [option]"
    echo -e ":::\n"
    echo "::: Config:"
    echo ":::    -co, --config        Use a custom setupVar config."
    echo -e ":::    Uses /etc/pivpn/wireguard/setupVars.conf by default.\n"
    echo "::: Commands:"
    echo ":::    -a, add              Create a client conf profile"
    echo ":::    -c, clients          List any connected clients to the server"
    echo ":::    -d, debug            Start a debugging session if having trouble"
    echo ":::    -l, list             List all clients"
    echo ":::   -qr, qrcode           Show the qrcode of a client for use with the mobile app"
    echo ":::    -r, remove           Remove a client"
    echo ":::  -off, off              Disable a user"
    echo ":::   -on, on               Enable a user"
    echo ":::    -h, help             Show this help dialog"
    echo ":::    -u, uninstall        Uninstall pivpn from your system!"
    echo ":::   -up, update           Updates PiVPN Scripts"
    echo ":::   -bk, backup           Backup VPN configs and user profiles"
    exit 0
}

if [ $# = 0 ]; then
    showHelp
fi

# Handle custom config
case "$1" in
"-co"|"--conf"|"--config")
    CUSTOM_CONFIG="--config $2"
    echo "Using Custom config $2"
    shift 2
;;
esac

# Handle redirecting to specific functions based on arguments
case "$1" in

"-a"   | "add"                ) makeConf "$@" $CUSTOM_CONFIG;;
"-c"   | "clients"            ) listConnected "$@" $CUSTOM_CONFIG;;
"-d"   | "debug"              ) debug "$@" $CUSTOM_CONFIG;;
"-l"   | "list"               ) listClients "$@" $CUSTOM_CONFIG;;
"-qr"  | "qrcode"             ) showQrcode "$@" $CUSTOM_CONFIG;;
"-r"   | "remove"             ) removeClient "$@" $CUSTOM_CONFIG;;
"-off" | "off"                ) disableClient "$@" $CUSTOM_CONFIG;;
"-on"  | "on"                 ) enableClient "$@" $CUSTOM_CONFIG;;
"-h"   | "help"               ) showHelp;;
"-u"   | "uninstall"          ) uninstallServer;;
"-up"  | "update"             ) updateScripts "$@" $CUSTOM_CONFIG ;;
"-bk"  | "backup"             ) backup ;;
*                             ) showHelp;;
esac
