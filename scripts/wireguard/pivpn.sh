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
    exit 0
}

listConnected(){
    shift
    $SUDO ${scriptdir}/${vpn}/clientSTAT.sh "$@"
    exit 0
}

debug(){
    $SUDO ${scriptdir}/${vpn}/pivpnDEBUG.sh
    exit 0
}

listClients(){
    $SUDO ${scriptdir}/${vpn}/listCONF.sh
    exit 0
}

showQrcode(){
    shift
    $SUDO ${scriptdir}/${vpn}/qrcodeCONF.sh "$@"
    exit 0
}

removeClient(){
    shift
    $SUDO ${scriptdir}/${vpn}/removeCONF.sh "$@"
    exit 0
}

uninstallServer(){
    $SUDO ${scriptdir}/uninstall.sh "${vpn}"
    exit 0
}

updateScripts(){
    shift
    $SUDO ${scriptdir}/update.sh "$@"
    exit 0
}

backup(){
    $SUDO ${scriptdir}/backup.sh "${vpn}"
    exit 0
}

showHelp(){
    echo "::: Control all PiVPN specific functions!"
    echo ":::"
    echo "::: Usage: pivpn <command> [option]"
    echo ":::"
    echo "::: Commands:"
    echo ":::  -a,  add              Create a client conf profile"
    echo ":::  -c,  clients          List any connected clients to the server"
    echo ":::  -d,  debug            Start a debugging session if having trouble"
    echo ":::  -l,  list             List all clients"
    echo ":::  -qr, qrcode           Show the qrcode of a client for use with the mobile app"
    echo ":::  -r,  remove           Remove a client"
    echo ":::  -h,  help             Show this help dialog"
    echo ":::  -u,  uninstall        Uninstall pivpn from your system!"
    echo ":::  -up, update           Updates PiVPN Scripts"
    echo ":::  -bk, backup           Backup VPN configs and user profiles"
    exit 0
}

if [ $# = 0 ]; then
    showHelp
fi

# Handle redirecting to specific functions based on arguments
case "$1" in
"-a"  | "add"                ) makeConf "$@";;
"-c"  | "clients"            ) listConnected "$@";;
"-d"  | "debug"              ) debug;;
"-l"  | "list"               ) listClients;;
"-qr" | "qrcode"             ) showQrcode "$@";;
"-r"  | "remove"             ) removeClient "$@";;
"-h"  | "help"               ) showHelp;;
"-u"  | "uninstall"          ) uninstallServer;;
"-up" | "update"             ) updateScripts "$@" ;;
"-bk" | "backup"             ) backup ;;
*                            ) showHelp;;
esac
