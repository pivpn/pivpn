#!/usr/bin/env bash
# PiVPN: Uninstall Script

INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)
INSTALL_HOME=$(grep -m1 "^${INSTALL_USER}:" /etc/passwd | cut -d: -f6)
INSTALL_HOME=${INSTALL_HOME%/} # remove possible trailing slash
PLAT=$(cat /etc/pivpn/DET_PLATFORM)
NO_UFW=$(cat /etc/pivpn/NO_UFW)
OLD_UFW=$(cat /etc/pivpn/NO_UFW)
PORT=$(cat /etc/pivpn/INSTALL_PORT)
PROTO=$(cat /etc/pivpn/INSTALL_PROTO)
IPv4dev="$(cat /etc/pivpn/pivpnINTERFACE)"
INPUT_CHAIN_EDITED="$(cat /etc/pivpn/INPUT_CHAIN_EDITED)"
FORWARD_CHAIN_EDITED="$(cat /etc/pivpn/FORWARD_CHAIN_EDITED)"

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(echo $screen_size | awk '{print $1}')
columns=$(echo $screen_size | awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

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
                    [Yy]* ) printf ":::\tRemoving %s..." "$i"; apt-get -y remove --purge "$i" &> /dev/null & spinner $!; printf "done!\n";
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
    apt-get -y autoremove &> /dev/null & spinner $!; printf "done!\n";
    printf "::: Auto cleaning remaining dependencies..."
    apt-get -y autoclean &> /dev/null & spinner $!; printf "done!\n";

    echo ":::"
    # Removing pivpn files
    echo "::: Removing pivpn system files..."

    $SUDO rm -rf /opt/pivpn &> /dev/null
    $SUDO rm -rf /etc/.pivpn &> /dev/null
    $SUDO rm -rf $INSTALL_HOME/ovpns &> /dev/null

    rm -rf /var/log/*pivpn* &> /dev/null
    rm -rf /var/log/*openvpn* &> /dev/null
    if [[ $UINST_OVPN = 1 ]]; then
        rm -rf /etc/openvpn &> /dev/null
        if [[ $PLAT == "Ubuntu" || $PLAT == "Debian" ]]; then
            printf "::: Removing openvpn apt source..."
            rm -rf /etc/apt/sources.list.d/swupdate.openvpn.net.list &> /dev/null
            apt-get -qq update & spinner $!; printf "done!\n";
        fi
    fi
    if [[ $UINST_UNATTUPG = 1 ]]; then
        rm -rf /var/log/unattended-upgrades
        rm -rf /etc/apt/apt.conf.d/*periodic
    fi
    rm -rf /etc/pivpn &> /dev/null
    rm /usr/local/bin/pivpn &> /dev/null
    rm /etc/bash_completion.d/pivpn

    # Disable IPv4 forwarding
    sed -i '/net.ipv4.ip_forward=1/c\#net.ipv4.ip_forward=1' /etc/sysctl.conf
    sysctl -p

    if [[ $NO_UFW -eq 0 ]]; then

        sed -z "s/*nat\n:POSTROUTING ACCEPT \[0:0\]\n-I POSTROUTING -s 10.8.0.0\/24 -o $IPv4dev -j MASQUERADE\nCOMMIT\n\n//" -i /etc/ufw/before.rules
        ufw delete allow "$PORT"/"$PROTO" >/dev/null
        if [ "$OLD_UFW" -eq 1 ]; then
            sed -i "s/\(DEFAULT_FORWARD_POLICY=\).*/\1\"DROP\"/" /etc/default/ufw
        else
            ufw route delete allow in on tun0 from 10.8.0.0/24 out on "$IPv4dev" to any >/dev/null
        fi
        ufw reload >/dev/null
    else
        iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o "${IPv4dev}" -j MASQUERADE

        if [ "$INPUT_CHAIN_EDITED" -eq 1 ]; then
            iptables -D INPUT -i "$IPv4dev" -p "$PROTO" --dport "$PORT" -j ACCEPT
        fi

        if [ "$FORWARD_CHAIN_EDITED" -eq 1 ]; then
            iptables -D FORWARD -d 10.8.0.0/24 -i "$IPv4dev" -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
            iptables -D FORWARD -s 10.8.0.0/24 -i tun0 -o "$IPv4dev" -j ACCEPT
        fi

        iptables-save > /etc/iptables/rules.v4
    fi

    echo ":::"
    printf "::: Finished removing PiVPN from your system.\n"
    printf "::: Reinstall by simpling running\n:::\n:::\tcurl -L https://install.pivpn.io | bash\n:::\n::: at any time!\n:::\n"
}

function askreboot() {
    printf "It is \e[1mstrongly\e[0m recommended to reboot after un-installation.\n"
    read -p "Would you like to reboot now? [y/n]: " -n 1 -r
    echo
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
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
