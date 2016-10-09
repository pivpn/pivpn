#!/usr/bin/env bash
# PiVPN: Uninstall Script

# Must be root to uninstall
if [[ $EUID -eq 0 ]];then
    echo "::: You are root."
else
    echo "::: Sudo will be used for the uninstall."
  # Check if it is actually installed
  # If it isn't, exit because the unnstall cannot complete
  if [[ $(dpkg-query -s sudo) ]];then
        export SUDO="sudo"
  else
    echo "::: Please install sudo or run this as root."
    exit 1
  fi
fi

INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)
PLAT=$(cat /etc/pivpn/DET_PLATFORM)
NO_UFW=$(cat /etc/pivpn/NO_UFW)
PORT=$(cat /etc/pivpn/INSTALL_PORT)
PROTO=$(cat /etc/pivpn/INSTALL_PROTO)

# Find the rows and columns
rows=$(tput lines)
columns=$(tput cols)

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))

spinner()
{
    local pid=$1
    local delay=0.50
    local spinstr='/-\|'
    while [ "$(ps a | awk '{print $1}' | grep "$pid")" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

function removeAll {
    # Purge dependencies
echo ":::"
    dependencies=( openvpn easy-rsa git iptables-persistent dnsutils expect unattended-upgrades )
    for i in "${dependencies[@]}"; do
        if [ "$(dpkg-query -W --showformat='${Status}\n' "$i" 2> /dev/null | grep -c "ok installed")" -eq 1 ]; then
            while true; do
                read -rp "::: Do you wish to remove $i from your system? [y/n]: " yn
                case $yn in
                    [Yy]* ) printf ":::\tRemoving %s..." "$i"; $SUDO apt-get -y remove --purge "$i" &> /dev/null & spinner $!; printf "done!\n";
                            if [ "$i" == "openvpn" ]; then UINST_OVPN=1 ; fi
                            if [ "$i" == "unattended-upgrades" ]; then UINST_UNATTUPG=1 ; fi
                            break;;
                    [Nn]* ) printf ":::\tSkipping %s\n" "$i"; break;;
                    * ) printf "::: You must answer yes or no!\n";;
                esac
            done
        else
            printf ":::\tPackage %s not installed... Not removing.\n" "$i"
        fi
    done

    # Take care of any additional package cleaning
    printf "::: Auto removing remaining dependencies..."
    $SUDO apt-get -y autoremove &> /dev/null & spinner $!; printf "done!\n";
    printf "::: Auto cleaning remaining dependencies..."
    $SUDO apt-get -y autoclean &> /dev/null & spinner $!; printf "done!\n";

    echo ":::"
    # Removing pivpn files
    echo "::: Removing pivpn system files..."
    $SUDO rm -rf /opt/pivpn &> /dev/null
    $SUDO rm -rf /etc/.pivpn &> /dev/null
    $SUDO rm -rf /home/$INSTALL_USER/ovpns &> /dev/null

    $SUDO rm -rf /var/log/*pivpn* &> /dev/null
    $SUDO rm -rf /var/log/*openvpn* &> /dev/null
    if [[ $UINST_OVPN = 1 ]]; then
        $SUDO rm -rf /etc/openvpn &> /dev/null
        if [[ $PLAT == "Ubuntu" || $PLAT == "Debian" ]]; then
            printf "::: Removing openvpn apt source..."
            $SUDO rm -rf /etc/apt/sources.list.d/swupdate.openvpn.net.list &> /dev/null
            $SUDO apt-get -qq update & spinner $!; printf "done!\n";
        fi
    fi
    if [[ $UINST_UNATTUPG = 1 ]]; then
        $SUDO rm -rf /var/log/unattended-upgrades
        $SUDO rm -rf /etc/apt/apt.conf.d/*periodic
    fi
    $SUDO rm -rf /etc/pivpn &> /dev/null
    $SUDO rm /usr/local/bin/pivpn &> /dev/null
    $SUDO rm /etc/bash_completion.d/pivpn

    # Disable IPv4 forwarding
    sed -i '/net.ipv4.ip_forward=1/c\#net.ipv4.ip_forward=1' /etc/sysctl.conf
    sysctl -p

    if [[ $NO_UFW -eq 0 ]]; then
        $SUDO sed -i "s/\(DEFAULT_FORWARD_POLICY=\).*/\1\"DROP\"/" /etc/default/ufw
        $SUDO sed -i '/START OPENVPN RULES/,/END OPENVPN RULES/ d' /etc/ufw/before.rules
        $SUDO ufw delete allow from 10.8.0.0/24 >/dev/null
        $SUDO ufw delete allow ${PORT}/${PROTO} >/dev/null
        $SUDO ufw reload
    fi

    echo ":::"
    printf "::: Finished removing PiVPN from your system.\n"
    printf "::: Reinstall by simpling running\n:::\n:::\tcurl -L https://install.pivpn.io | bash\n:::\n::: at any time!\n:::\n"
}

function askreboot() {
    printf "It is \e[1mstrongly\e[0m recommended to reboot after un-installation.\n"
    read -p "Would you like to reboot now? [y/n]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        printf "\nRebooting system...\n"
        sleep 3
        shutdown -r now
    fi
}

######### SCRIPT ###########
echo "::: Preparing to remove packages, be sure that each may be safely removed depending on your operating system."
echo "::: (SAFE TO REMOVE ALL ON RASPBIAN)"
while true; do
    read -rp "::: Do you wish to completely remove PiVPN configuration and installed packages from your system? (You will be prompted for each package) [y/n]: " yn
    case $yn in
        [Yy]* ) removeAll; askreboot; break;;

        [Nn]* ) printf "::: Not removing anything, exiting...\n"; break;;
    esac
done
