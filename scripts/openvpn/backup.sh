#!/bin/bash
setupVars="/etc/pivpn/setupVars.conf"
backupdir=pivpnbackup
openvpndir=/etc/openvpn
ovpnsdir=${install_home}/ovpns
date=$(date +%Y-%m-%d-%H%M%S)

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

backup_openvpn(){
  if [[ ! -d $install_home/$backupdir ]]; then
     mkdir $install_home/$backupdir
  fi
  cp -r $openvpndir $ovpnsdir $backupdir 2&>1
  backupzip=$date-pivpnbackup.tgz
  tar -czf $backupzip -C ${install_home} $backupdir 2&>1
  echo -e "Backup crated to $install_home/$backupdir/$backupzip \nTo restore the backup, follow instructions at:\nhttps://github.com/pivpn/pivpn/wiki/FAQ#how-can-i-migrate-my-configs-to-another-pivpn-instance"
}


if [[ ! $EUID -eq 0 ]];then
  if [[ $(dpkg-query -s sudo) ]];then
        export SUDO="sudo"
  else
    echo "::: Please install sudo or run this as root."
    exit 0
  fi
fi

backup_openvpn

