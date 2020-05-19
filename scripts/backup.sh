#!/bin/bash

backupdir=pivpnbackup
date=$(date +%Y%m%d-%H%M%S)

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(echo "$screen_size" | awk '{print $1}')
columns=$(echo "$screen_size" | awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

                       chooseVPNCmd=(whiptail --backtitle "Setup PiVPN" --title "Installation mode" --separate-output --radiolist "Choose a VPN configuration to backup (press space to select):" "${r}" "${c}" 2)
                        VPNChooseOptions=(WireGuard "" on
                                                                OpenVPN "" off)

                        if VPN=$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 >/dev/tty) ; then
                                echo "::: Using VPN: $VPN"
                                VPN="${VPN,,}"
                        else
                                echo "::: Cancel selected, exiting...."
                                exit 1
                        fi

setupVars="/etc/pivpn/${VPN}/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

checkbackupdir(){

    if [[ ! -d $install_home/$backupdir ]]; then
        mkdir -p "$install_home"/"$backupdir"
    fi

}

backup_openvpn(){

    openvpndir=/etc/openvpn
    ovpnsdir=${install_home}/ovpns
    checkbackupdir
    backupzip=$date-pivpnovpnbackup.tgz
    # shellcheck disable=SC2210
    tar czpf "$install_home"/"$backupdir"/"$backupzip" "$openvpndir" "$ovpnsdir" > /dev/null 2>&1
    echo -e "Backup created in $install_home/$backupdir/$backupzip \nTo restore the backup, follow instructions at:\nhttps://github.com/pivpn/pivpn/wiki/FAQ#how-can-i-migrate-my-configs-to-another-pivpn-instance"

}

backup_wireguard(){

    wireguarddir=/etc/wireguard
    configsdir=${install_home}/configs
    checkbackupdir
    backupzip=$date-pivpnwgbackup.tgz
    tar czpf "$install_home"/"$backupdir"/"$backupzip" "$wireguarddir" "$configsdir" > /dev/null 2>&1
    echo -e "Backup created in $install_home/$backupdir/$backupzip \nTo restore the backup, follow instructions at:\nhttps://github.com/pivpn/pivpn/wiki/FAQ#how-can-i-migrate-my-configs-to-another-pivpn-instance"

}

if [[ ! $EUID -eq 0 ]];then
    if [[ $(dpkg-query -s sudo) ]];then
        export SUDO="sudo"
    else
    echo "::: Please install sudo or run this as root."
    exit 0
  fi
fi

if [[ "${VPN}" == "wireguard" ]]; then
    backup_wireguard
else
    backup_openvpn
fi
