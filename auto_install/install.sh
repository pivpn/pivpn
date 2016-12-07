#!/usr/bin/env bash
# PiVPN: Trivial OpenVPN setup and configuration
# Easiest setup and mangement of OpenVPN on Raspberry Pi
# http://pivpn.io
# Heavily adapted from the pi-hole.net project and...
# https://github.com/StarshipEngineer/OpenVPN-Setup/
#
# Install with this command (from your Pi):
#
# curl -L https://install.pivpn.io | bash
# Make sure you have `curl` installed


######## VARIABLES #########

pivpnGitUrl="https://github.com/pivpn/pivpn.git"
pivpnFilesDir="/etc/.pivpn"
easyrsaVer="3.0.1-pivpn1"
easyrsaRel="https://github.com/pivpn/easy-rsa/releases/download/${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"

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

# Find IP used to route to outside world

IPv4dev=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++)if($i~/dev/)print $(i+1)}')
IPv4addr=$(ip -o -f inet addr show dev "$IPv4dev" | awk '{print $4}' | awk 'END {print}')
IPv4gw=$(ip route get 8.8.8.8 | awk '{print $3}')

availableInterfaces=$(ip -o link | awk '{print $2}' | grep -v "lo" | cut -d':' -f1 | cut -d'@' -f1)
dhcpcdFile=/etc/dhcpcd.conf

######## FIRST CHECK ########
# Must be root to install
echo ":::"
if [[ $EUID -eq 0 ]];then
    echo "::: You are root."
else
    echo "::: sudo will be used for the install."
    # Check if it is actually installed
    # If it isn't, exit because the install cannot complete
    if [[ $(dpkg-query -s sudo) ]];then
        export SUDO="sudo"
        export SUDOE="sudo -E"
    else
        echo "::: Please install sudo or run this as root."
        exit 1
    fi
fi

# Next see if we are on a tested and supported OS
function noOS_Support() {
    whiptail --msgbox --backtitle "INVALID OS DETECTED" --title "Invalid OS" "We have not been able to detect a supported OS.
Currently this installer supports Raspbian jessie, Ubuntu 14.04 (trusty), and Ubuntu 16.04 (xenial).
If you think you received this message in error, you can post an issue on the GitHub at https://github.com/pivpn/pivpn/issues." ${r} ${c}
    exit 1
}

function maybeOS_Support() {
    if (whiptail --backtitle "Not Supported OS" --title "Not Supported OS" --yesno "You are on an OS that we have not tested but MAY work.
                Currently this installer supports Raspbian jessie, Ubuntu 14.04 (trusty), and Ubuntu 16.04 (xenial).
                Would you like to continue anyway?" ${r} ${c}) then
                echo "::: Did not detect perfectly supported OS but,"
                echo "::: Continuing installation at user's own risk..."
            else
                echo "::: Exiting due to unsupported OS"
                exit 1
            fi
}

# if lsb_release command is on their system
if hash lsb_release 2>/dev/null; then
    PLAT=$(lsb_release -si)
    OSCN=$(lsb_release -sc) # We want this to be trusty xenial or jessie

    if [[ $PLAT == "Ubuntu" || $PLAT == "Raspbian" || $PLAT == "Debian" ]]; then
        if [[ $OSCN != "trusty" && $OSCN != "xenial" && $OSCN != "jessie" ]]; then
            maybeOS_Support
        fi
    else
        noOS_Support
    fi
# else get info from os-release
elif grep -q debian /etc/os-release; then
    if grep -q jessie /etc/os-release; then
        PLAT="Raspbian"
        OSCN="jessie"
    else
        PLAT="Ubuntu"
        OSCN="unknown"
        maybeOS_Support
    fi
# else we prob don't want to install
else
    noOS_Support
fi

echo "${PLAT}" > /tmp/DET_PLATFORM

####### FUNCTIONS ##########
spinner()
{
    local pid=$1
    local delay=0.50
    local spinstr='/-\|'
    while [ "$(ps a | awk '{print $1}' | grep "${pid}")" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "${spinstr}"
        local spinstr=${temp}${spinstr%"$temp"}
        sleep ${delay}
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

welcomeDialogs() {
    # Display the welcome dialog
    whiptail --msgbox --backtitle "Welcome" --title "PiVPN Automated Installer" "This installer will transform your Raspberry Pi into an OpenVPN server!" ${r} ${c}

    # Explain the need for a static address
    whiptail --msgbox --backtitle "Initiating network interface" --title "Static IP Needed" "The PiVPN is a SERVER so it needs a STATIC IP ADDRESS to function properly.

In the next section, you can choose to use your current network settings (DHCP) or to manually edit them." ${r} ${c}
}

chooseUser() {
    # Explain the local user
    whiptail --msgbox --backtitle "Parsing User List" --title "Local Users" "Choose a local user that will hold your ovpn configurations." ${r} ${c}
    # First, let's check if there is a user available.
    numUsers=$(awk -F':' 'BEGIN {count=0} $3>=500 && $3<=60000 { count++ } END{ print count }' /etc/passwd)
    if [ "$numUsers" -eq 0 ]
    then
        # We don't have a user, let's ask to add one.
        if userToAdd=$(whiptail --title "Choose A User" --inputbox "No non-root user account was found. Please type a new username." ${r} ${c} 3>&1 1>&2 2>&3)
        then
            # See http://askubuntu.com/a/667842/459815
            PASSWORD=$(whiptail  --title "password dialog" --passwordbox "Please enter the new user password" ${r} ${c} 3>&1 1>&2 2>&3)
            CRYPT=$(perl -e 'printf("%s\n", crypt($ARGV[0], "password"))' "${PASSWORD}")
            $SUDO useradd -m -p "${CRYPT}" -s /bin/bash "${userToAdd}"
            if [[ $? = 0 ]]; then
                echo "Succeeded"
                ((numUsers+=1))
            else
                exit 1
            fi
        else
            exit 1
        fi
    fi
    availableUsers=$(awk -F':' '$3>=500 && $3<=60000 {print $1}' /etc/passwd)
    local userArray=()
    local firstloop=1

    while read -r line
    do
        mode="OFF"
        if [[ $firstloop -eq 1 ]]; then
            firstloop=0
            mode="ON"
        fi
        userArray+=("${line}" "" "${mode}")
    done <<< "${availableUsers}"
    chooseUserCmd=(whiptail --title "Choose A User" --separate-output --radiolist "Choose:" ${r} ${c} ${numUsers})
    chooseUserOptions=$("${chooseUserCmd[@]}" "${userArray[@]}" 2>&1 >/dev/tty)
    if [[ $? = 0 ]]; then
        for desiredUser in ${chooseUserOptions}; do
            pivpnUser=${desiredUser}
            echo "::: Using User: $pivpnUser"
            echo "${pivpnUser}" > /tmp/pivpnUSR
        done
    else
        echo "::: Cancel selected, exiting...."
        exit 1
    fi
}

verifyFreeDiskSpace() {
    # If user installs unattended-upgrades we'd need about 60MB so will check for 75MB free
    echo "::: Verifying free disk space..."
    local required_free_kilobytes=76800
    local existing_free_kilobytes=$(df -Pk | grep -m1 '\/$' | awk '{print $4}')

    # - Unknown free disk space , not a integer
    if ! [[ "${existing_free_kilobytes}" =~ ^([0-9])+$ ]]; then
        echo "::: Unknown free disk space!"
        echo "::: We were unable to determine available free disk space on this system."
        echo "::: You may continue with the installation, however, it is not recommended."
        read -r -p "::: If you are sure you want to continue, type YES and press enter :: " response
        case $response in
            [Y][E][S])
                ;;
            *)
                echo "::: Confirmation not received, exiting..."
                exit 1
                ;; 
        esac
    # - Insufficient free disk space
    elif [[ ${existing_free_kilobytes} -lt ${required_free_kilobytes} ]]; then
        echo "::: Insufficient Disk Space!"
        echo "::: Your system appears to be low on disk space. PiVPN recommends a minimum of $required_free_kilobytes KiloBytes."
        echo "::: You only have ${existing_free_kilobytes} KiloBytes free."
        echo "::: If this is a new install on a Raspberry Pi you may need to expand your disk."
        echo "::: Try running 'sudo raspi-config', and choose the 'expand file system option'"
        echo "::: After rebooting, run this installation again. (curl -L https://install.pivpn.io | bash)"

        echo "Insufficient free space, exiting..."
        exit 1
    fi
}


chooseInterface() {
    # Turn the available interfaces into an array so it can be used with a whiptail dialog
    local interfacesArray=()
    # Number of available interfaces
    local interfaceCount
    # Whiptail variable storage
    local chooseInterfaceCmd
    # Temporary Whiptail options storage
    local chooseInterfaceOptions
    # Loop sentinel variable
    local firstLoop=1

    while read -r line; do
        mode="OFF"
        if [[ ${firstloop} -eq 1 ]]; then
            firstloop=0
            mode="ON"
        fi
        interfacesArray+=("${line}" "available" "${mode}")
    done <<< "${availableInterfaces}"

    # Find out how many interfaces are available to choose from
    interfaceCount=$(echo "${availableInterfaces}" | wc -l)
    chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose An Interface (press space to select)" ${r} ${c} ${interfaceCount})
    chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 >/dev/tty)
    if [[ $? = 0 ]]; then
        for desiredInterface in ${chooseInterfaceOptions}; do
            pivpnInterface=${desiredInterface}
            echo "::: Using interface: $pivpnInterface"
            echo "${pivpnInterface}" > /tmp/pivpnINT
        done
    else
        echo "::: Cancel selected, exiting...."
        exit 1
    fi
}

avoidStaticIPv4Ubuntu() {
    # If we are in Ubuntu then they need to have previously set their network, so just use what you have.
    whiptail --msgbox --backtitle "IP Information" --title "IP Information" "Since we think you are not using Raspbian, we will not configure a static IP for you.
If you are in Amazon then you can not configure a static IP anyway. Just ensure before this installer started you had set an elastic IP on your instance." ${r} ${c}
}

getStaticIPv4Settings() {
    # Grab their current DNS Server
    IPv4dns=$(nslookup 127.0.0.1 | grep Server: | awk '{print $2}')
    # Ask if the user wants to use DHCP settings as their static IP
    if (whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Do you want to use your current network settings as a static address?
                    IP address:    ${IPv4addr}
                    Gateway:       ${IPv4gw}" ${r} ${c}); then
        # If they choose yes, let the user know that the IP address will not be available via DHCP and may cause a conflict.
        whiptail --msgbox --backtitle "IP information" --title "FYI: IP Conflict" "It is possible your router could still try to assign this IP to a device, which would cause a conflict.  But in most cases the router is smart enough to not do that.
If you are worried, either manually set the address, or modify the DHCP reservation pool so it does not include the IP you want.
It is also possible to use a DHCP reservation, but if you are going to do that, you might as well set a static address." ${r} ${c}
        # Nothing else to do since the variables are already set above
    else
        # Otherwise, we need to ask the user to input their desired settings.
        # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
        # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
        until [[ ${ipSettingsCorrect} = True ]]; do
            # Ask for the IPv4 address
            IPv4addr=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 address" --inputbox "Enter your desired IPv4 address" ${r} ${c} "${IPv4addr}" 3>&1 1>&2 2>&3)
            if [[ $? = 0 ]]; then
            echo "::: Your static IPv4 address:    ${IPv4addr}"
            # Ask for the gateway
            IPv4gw=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 gateway (router)" --inputbox "Enter your desired IPv4 default gateway" ${r} ${c} "${IPv4gw}" 3>&1 1>&2 2>&3)
            if [[ $? = 0 ]]; then
                echo "::: Your static IPv4 gateway:    ${IPv4gw}"
                # Give the user a chance to review their settings before moving on
                if (whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Are these settings correct?
                    IP address:    ${IPv4addr}
                    Gateway:       ${IPv4gw}" ${r} ${c}); then
                    # If the settings are correct, then we need to set the pivpnIP
                    echo "${IPv4addr%/*}" > /tmp/pivpnIP
                    echo "$pivpnInterface" > /tmp/pivpnINT
                    # After that's done, the loop ends and we move on
                    ipSettingsCorrect=True
                else
                    # If the settings are wrong, the loop continues
                    ipSettingsCorrect=False
                fi
            else
                # Cancelling gateway settings window
                ipSettingsCorrect=False
                echo "::: Cancel selected. Exiting..."
                exit 1
            fi
        else
            # Cancelling IPv4 settings window
            ipSettingsCorrect=False
            echo "::: Cancel selected. Exiting..."
            exit 1
        fi
        done
        # End the if statement for DHCP vs. static
    fi
}

setDHCPCD() {
    # Append these lines to dhcpcd.conf to enable a static IP
    echo "interface ${pivpnInterface}
    static ip_address=${IPv4addr}
    static routers=${IPv4gw}
    static domain_name_servers=${IPv4dns}" | $SUDO tee -a ${dhcpcdFile} >/dev/null
}

setStaticIPv4() {
    # Tries to set the IPv4 address
    if [[ -f /etc/dhcpcd.conf ]]; then
        if grep -q "${IPv4addr}" ${dhcpcdFile}; then
            echo "::: Static IP already configured."
            :
        else
            setDHCPCD
            $SUDO ip addr replace dev "${pivpnInterface}" "${IPv4addr}"
            echo ":::"
            echo "::: Setting IP to ${IPv4addr}.  You may need to restart after the install is complete."
            echo ":::"
        fi
    else
        echo "::: Critical: Unable to locate configuration file to set static IPv4 address!"
        exit 1
    fi
}

setNetwork() {
    # Sets the Network IP and Mask correctly
    LOCALMASK=$(ifconfig "${pivpnInterface}" | awk '/Mask:/{ print $4;} ' | cut -c6-)
    LOCALIP=$(ifconfig "${pivpnInterface}" | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
    IFS=. read -r i1 i2 i3 i4 <<< "$LOCALIP"
    IFS=. read -r m1 m2 m3 m4 <<< "$LOCALMASK"
    LOCALNET=$(printf "%d.%d.%d.%d\n" "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))")
}

function valid_ip()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
        && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

installScripts() {
    # Install the scripts from /etc/.pivpn to their various locations
    $SUDO echo ":::"
    $SUDO echo -n "::: Installing scripts to /opt/pivpn..."
    if [ ! -d /opt/pivpn ]; then
        $SUDO mkdir /opt/pivpn
        $SUDO chown "$pivpnUser":root /opt/pivpn
        $SUDO chmod u+srwx /opt/pivpn
    fi
    $SUDO cp /etc/.pivpn/scripts/makeOVPN.sh /opt/pivpn/makeOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/listOVPN.sh /opt/pivpn/listOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/removeOVPN.sh /opt/pivpn/removeOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/uninstall.sh /opt/pivpn/uninstall.sh
    $SUDO cp /etc/.pivpn/scripts/pivpnDebug.sh /opt/pivpn/pivpnDebug.sh
    $SUDO chmod 0755 /opt/pivpn/{makeOVPN,listOVPN,removeOVPN,uninstall,pivpnDebug}.sh
    $SUDO cp /etc/.pivpn/pivpn /usr/local/bin/pivpn
    $SUDO chmod 0755 /usr/local/bin/pivpn
    $SUDO cp /etc/.pivpn/scripts/bash-completion /etc/bash_completion.d/pivpn
    . /etc/bash_completion.d/pivpn

    $SUDO echo " done."
}

unattendedUpgrades() {
    whiptail --msgbox --backtitle "Security Updates" --title "Unattended Upgrades" "Since this server will have at least one port open to the internet, it is recommended you enable unattended-upgrades.\nThis feature will check daily for security package updates only and apply them when necessary.\nIt will NOT automatically reboot the server so to fully apply some updates you should periodically reboot." ${r} ${c}

    if (whiptail --backtitle "Security Updates" --title "Unattended Upgrades" --yesno "Do you want to enable unattended upgrades of security patches to this server?" ${r} ${c}) then
        UNATTUPG="unattended-upgrades"
        $SUDO apt-get --yes --quiet --no-install-recommends install "$UNATTUPG" > /dev/null & spinner $!
    else
        UNATTUPG=""
    fi
}

stopServices() {
    # Stop openvpn
    $SUDO echo ":::"
    $SUDO echo -n "::: Stopping OpenVPN service..."
    if [[ $PLAT == "Ubuntu" || $PLAT == "Debian" ]]; then
        $SUDO service openvpn stop || true
    else
        $SUDO systemctl stop openvpn.service || true
    fi
    $SUDO echo " done."
}

checkForDependencies() {
    #Running apt-get update/upgrade with minimal output can cause some issues with
    #requiring user input (e.g password for phpmyadmin see #218)
    #We'll change the logic up here, to check to see if there are any updates available and
    # if so, advise the user to run apt-get update/upgrade at their own discretion
    #Check to see if apt-get update has already been run today
    # it needs to have been run at least once on new installs!

    timestamp=$(stat -c %Y /var/cache/apt/)
    timestampAsDate=$(date -d @"$timestamp" "+%b %e")
    today=$(date "+%b %e")

    if [[ $PLAT == "Ubuntu" || $PLAT == "Debian" ]]; then
        if [[ $OSCN == "trusty" || $OSCN == "jessie" || $OSCN == "wheezy" ]]; then
            wget -O - https://swupdate.openvpn.net/repos/repo-public.gpg| $SUDO apt-key add -
            echo "deb http://swupdate.openvpn.net/apt $OSCN main" | $SUDO tee /etc/apt/sources.list.d/swupdate.openvpn.net.list > /dev/null
            echo -n "::: Adding OpenVPN repo for $PLAT $OSCN ..."
            $SUDO apt-get -qq update & spinner $!
            echo " done!"
        fi
    fi

    if [ ! "$today" == "$timestampAsDate" ]; then
        #update package lists
        echo ":::"
        echo -n "::: apt-get update has not been run today. Running now..."
        $SUDO apt-get -qq update & spinner $!
        echo " done!"
    fi
    echo ":::"
    echo -n "::: Checking apt-get for upgraded packages...."
    updatesToInstall=$($SUDO apt-get -s -o Debug::NoLocking=true upgrade | grep -c ^Inst)
    echo " done!"
    echo ":::"
    if [[ $updatesToInstall -eq "0" ]]; then
        echo "::: Your pi is up to date! Continuing with PiVPN installation..."
    else
        echo "::: There are $updatesToInstall updates availible for your pi!"
        echo "::: We recommend you run 'sudo apt-get upgrade' after installing PiVPN! "
        echo ":::"
    fi
    echo ":::"
    echo "::: Checking dependencies:"

    dependencies=( openvpn git dhcpcd5 tar wget iptables-persistent dnsutils expect whiptail )
    for i in "${dependencies[@]}"; do
        echo -n ":::    Checking for $i..."
        if [ "$(dpkg-query -W -f='${Status}' "$i" 2>/dev/null | grep -c "ok installed")" -eq 0 ]; then
            echo -n " Not found! Installing...."
            #Supply answers to the questions so we don't prompt user
            if [[ $i = "iptables-persistent" ]]; then
                echo iptables-persistent iptables-persistent/autosave_v4 boolean true | $SUDO debconf-set-selections
                echo iptables-persistent iptables-persistent/autosave_v6 boolean false | $SUDO debconf-set-selections
            fi
            if [[ $i == "expect" ]] || [[ $i == "openvpn" ]]; then
                $SUDO apt-get --yes --quiet --no-install-recommends install "$i" > /dev/null & spinner $!
            else
                $SUDO apt-get --yes --quiet install "$i" > /dev/null & spinner $!
            fi
            echo " done!"
        else
            echo " already installed!"
        fi
    done
}

getGitFiles() {
    # Setup git repos for base files
    echo ":::"
    echo "::: Checking for existing base files..."
    if is_repo "${1}"; then
        update_repo "${1}"
    else
        make_repo "${1}" "${2}"
    fi
}

is_repo() {
    # If the directory does not have a .git folder it is not a repo
    echo -n ":::    Checking $1 is a repo..."
    cd "${1}" &> /dev/null || return 1
    $SUDO git status &> /dev/null && echo " OK!"; return 0 || echo " not found!"; return 1
}

make_repo() {
    # Remove the non-repos interface and clone the interface
    echo -n ":::    Cloning $2 into $1..."
    $SUDO rm -rf "${1}"
    $SUDO git clone -q "${2}" "${1}" > /dev/null & spinner $!
    if [ -z "${TESTING+x}" ]; then
        :
    else
        $SUDO git -C "${1}" checkout test
    fi
    echo " done!"
}

update_repo() {
    # Pull the latest commits
    echo -n ":::     Updating repo in $1..."
    cd "${1}" || exit 1
    $SUDO git stash -q > /dev/null & spinner $!
    $SUDO git pull -q > /dev/null & spinner $!
    if [ -z "${TESTING+x}" ]; then
        :
    else
        ${SUDOE} git checkout test
    fi
    echo " done!"
}

setCustomProto() {
  # Set the available protocols into an array so it can be used with a whiptail dialog
  if protocol=$(whiptail --title "Protocol" --radiolist \
  "Choose a protocol. Please only choose TCP if you know why you need TCP." ${r} ${c} 2 \
  "UDP" "" ON \
  "TCP" "" OFF 3>&1 1>&2 2>&3)
  then
      # Convert option into lowercase (UDP->udp)
      pivpnProto="${protocol,,}"
      echo "::: Using protocol: $pivpnProto"
      echo "${pivpnProto}" > /tmp/pivpnPROTO
  else
      echo "::: Cancel selected, exiting...."
      exit 1
  fi
    # write out the PROTO
    PROTO=$pivpnProto
    $SUDO cp /tmp/pivpnPROTO /etc/pivpn/INSTALL_PROTO
}


setCustomPort() {
    until [[ $PORTNumCorrect = True ]]
        do
            portInvalid="Invalid"

            PROTO=$(cat /etc/pivpn/INSTALL_PROTO)
            if [ "$PROTO" = "udp" ]; then
              DEFAULT_PORT=1194
            else
              DEFAULT_PORT=443
            fi
            if PORT=$(whiptail --title "Default OpenVPN Port" --inputbox "You can modify the default OpenVPN port. \nEnter a new value or hit 'Enter' to retain the default" ${r} ${c} $DEFAULT_PORT 3>&1 1>&2 2>&3)
            then
                if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
                    :
                else
                    PORT=$portInvalid
                fi
            else
                echo "::: Cancel selected, exiting...."
                exit 1
            fi

            if [[ $PORT == "$portInvalid" ]]; then
                whiptail --msgbox --backtitle "Invalid Port" --title "Invalid Port" "You entered an invalid Port number.\n    Please enter a number from 1 - 65535.\n    If you are not sure, please just keep the default." ${r} ${c}
                PORTNumCorrect=False
            else
                if (whiptail --backtitle "Specify Custom Port" --title "Confirm Custom Port Number" --yesno "Are these settings correct?\n    PORT:   $PORT" ${r} ${c}) then
                    PORTNumCorrect=True
                else
                    # If the settings are wrong, the loop continues
                    PORTNumCorrect=False
                fi
            fi
        done
    # write out the port
    echo ${PORT} > /tmp/INSTALL_PORT
    $SUDO cp /tmp/INSTALL_PORT /etc/pivpn/INSTALL_PORT
}

setClientDNS() {
    DNSChoseCmd=(whiptail --separate-output --radiolist "Select the DNS Provider for your VPN Clients. To use your own, select Custom." ${r} ${c} 6)
    DNSChooseOptions=(Google "" on
            OpenDNS "" off
            Level3 "" off
            DNS.WATCH "" off
            Norton "" off
            Custom "" off)

    if DNSchoices=$("${DNSChoseCmd[@]}" "${DNSChooseOptions[@]}" 2>&1 >/dev/tty)
    then
        case ${DNSchoices} in
        Google)
            echo "::: Using Google DNS servers."
            OVPNDNS1="8.8.8.8"
            OVPNDNS2="8.8.4.4"
            # These are already in the file
            ;;
        OpenDNS)
            echo "::: Using OpenDNS servers."
            OVPNDNS1="208.67.222.222"
            OVPNDNS2="208.67.220.220"
            $SUDO sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${OVPNDNS1}'\"/' /etc/openvpn/server.conf
            $SUDO sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${OVPNDNS2}'\"/' /etc/openvpn/server.conf
            ;;
        Level3)
            echo "::: Using Level3 servers."
            OVPNDNS1="209.244.0.3"
            OVPNDNS2="209.244.0.4"
            $SUDO sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${OVPNDNS1}'\"/' /etc/openvpn/server.conf
            $SUDO sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${OVPNDNS2}'\"/' /etc/openvpn/server.conf
            ;;
        DNS.WATCH)
            echo "::: Using DNS.WATCH servers."
            OVPNDNS1="82.200.69.80"
            OVPNDNS2="84.200.70.40"
            $SUDO sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${OVPNDNS1}'\"/' /etc/openvpn/server.conf
            $SUDO sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${OVPNDNS2}'\"/' /etc/openvpn/server.conf
            ;;
        Norton)
            echo "::: Using Norton ConnectSafe servers."
            OVPNDNS1="199.85.126.10"
            OVPNDNS2="199.85.127.10"
            $SUDO sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${OVPNDNS1}'\"/' /etc/openvpn/server.conf
            $SUDO sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${OVPNDNS2}'\"/' /etc/openvpn/server.conf
            ;;
        Custom)
            until [[ $DNSSettingsCorrect = True ]]
            do
                strInvalid="Invalid"

                if OVPNDNS=$(whiptail --backtitle "Specify Upstream DNS Provider(s)"  --inputbox "Enter your desired upstream DNS provider(s), seperated by a comma.\n\nFor example '8.8.8.8, 8.8.4.4'" ${r} ${c} "" 3>&1 1>&2 2>&3)
                then
                    OVPNDNS1=$(echo "$OVPNDNS" | sed 's/[, \t]\+/,/g' | awk -F, '{print$1}')
                    OVPNDNS2=$(echo "$OVPNDNS" | sed 's/[, \t]\+/,/g' | awk -F, '{print$2}')
                    if ! valid_ip "$OVPNDNS1" || [ ! "$OVPNDNS1" ]; then
                        OVPNDNS1=$strInvalid
                    fi
                    if ! valid_ip "$OVPNDNS2" && [ "$OVPNDNS2" ]; then
                        OVPNDNS2=$strInvalid
                    fi
                else
                    echo "::: Cancel selected, exiting...."
                    exit 1
                fi
                if [[ $OVPNDNS1 == "$strInvalid" ]] || [[ $OVPNDNS2 == "$strInvalid" ]]; then
                    whiptail --msgbox --backtitle "Invalid IP" --title "Invalid IP" "One or both entered IP addresses were invalid. Please try again.\n\n    DNS Server 1:   $OVPNDNS1\n    DNS Server 2:   $OVPNDNS2" ${r} ${c}
                    if [[ $OVPNDNS1 == "$strInvalid" ]]; then
                        OVPNDNS1=""
                    fi
                    if [[ $OVPNDNS2 == "$strInvalid" ]]; then
                        OVPNDNS2=""
                    fi
                    DNSSettingsCorrect=False
                else
                    if (whiptail --backtitle "Specify Upstream DNS Provider(s)" --title "Upstream DNS Provider(s)" --yesno "Are these settings correct?\n    DNS Server 1:   $OVPNDNS1\n    DNS Server 2:   $OVPNDNS2" ${r} ${c}) then
                        DNSSettingsCorrect=True
                        $SUDO sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${OVPNDNS1}'\"/' /etc/openvpn/server.conf
                        if [ -z ${OVPNDNS2} ]; then
                            $SUDO sed -i '/\(dhcp-option DNS \)/{n;N;d}' /etc/openvpn/server.conf
                        else
                            $SUDO sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${OVPNDNS2}'\"/' /etc/openvpn/server.conf
                        fi
                    else
                        # If the settings are wrong, the loop continues
                        DNSSettingsCorrect=False
                    fi
                fi
        done
        ;;
    esac
    else
        echo "::: Cancel selected. Exiting..."
        exit 1
    fi
}

confOpenVPN() {
    # Ask user if want to modify default port
    SERVER_NAME="server"

    # Ask user for desired level of encryption
    ENCRYPT=$(whiptail --backtitle "Setup OpenVPN" --title "Encryption Strength" --radiolist \
    "Choose your desired level of encryption:\n   This is an encryption key that will be generated on your system.  The larger the key, the more time this will take.  For most applications it is recommended to use 2048 bit.  If you are testing or just want to get through it quicker you can use 1024.  If you are paranoid about ... things... then grab a cup of joe and pick 4096." ${r} ${c} 3 \
    "2048" "Use 2048-bit encryption. Recommended level." ON \
    "1024" "Use 1024-bit encryption. Test level." OFF \
    "4096" "Use 4096-bit encryption. Paranoid level." OFF 3>&1 1>&2 2>&3)

    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        echo "::: Cancel selected. Exiting..."
        exit 1
    fi

    # If easy-rsa exists, remove it
    if [[ -d /etc/openvpn/easy-rsa/ ]]; then
        $SUDO rm -rf /etc/openvpn/easy-rsa/
    fi

    # Get the PiVPN easy-rsa
    wget -q -O "/tmp/EasyRSA-${easyrsaVer}" "${easyrsaRel}"
    tar xzf /tmp/EasyRSA-${easyrsaVer} -C /tmp
    $SUDO mv /tmp/EasyRSA-${easyrsaVer}/ /etc/openvpn/easy-rsa/
    $SUDO chown -R root:root /etc/openvpn/easy-rsa
    $SUDO mkdir /etc/openvpn/easy-rsa/pki

    # Write out new vars file
    IFS= read -d '' String <<"EOF"
if [ -z "$EASYRSA_CALLER" ]; then
    echo "Nope." >&2
    return 1
fi
set_var EASYRSA            "/etc/openvpn/easy-rsa"
set_var EASYRSA_PKI        "$EASYRSA/pki"
set_var EASYRSA_KEY_SIZE   2048
set_var EASYRSA_ALGO       rsa
set_var EASYRSA_CURVE      secp384r1
EOF

echo "${String}" | $SUDO tee /etc/openvpn/easy-rsa/vars >/dev/null

    # Edit the KEY_SIZE variable in the vars file to set user chosen key size
    cd /etc/openvpn/easy-rsa || exit
    $SUDO sed -i "s/\(KEY_SIZE\).*/\1   ${ENCRYPT}/" vars

    # Remove any previous keys
    ${SUDOE} ./easyrsa --batch init-pki

    # Build the certificate authority
    printf "::: Building CA...\n"
    ${SUDOE} ./easyrsa --batch build-ca nopass
    printf "\n::: CA Complete.\n"

    whiptail --msgbox --backtitle "Setup OpenVPN" --title "Server Information" "The server key, Diffie-Hellman key, and HMAC key will now be generated." ${r} ${c}

    # Build the server
    ${SUDOE} ./easyrsa build-server-full server nopass

    if ([ "$ENCRYPT" -ge "4096" ] && whiptail --backtitle "Setup OpenVPN" --title "Download Diffie-Hellman Parameters" --yesno --defaultno "Download Diffie-Hellman parameters from a public DH parameter generation service?\n\nGenerating DH parameters for a $ENCRYPT-bit key can take many hours on a Raspberry Pi. You can instead download DH parameters from \"2 Ton Digital\" that are generated at regular intervals as part of a public service. Downloaded DH parameters will be randomly selected from a pool of the last 128 generated.\nMore information about this service can be found here: https://2ton.com.au/dhtool/\n\nIf you're paranoid, choose 'No' and Diffie-Hellman parameters will be generated on your device." ${r} ${c})
then
    # Downloading parameters
    RANDOM_INDEX=$(( RANDOM % 128 ))
    ${SUDOE} curl "https://2ton.com.au/dhparam/${ENCRYPT}/${RANDOM_INDEX}" -o "/etc/openvpn/easy-rsa/pki/dh${ENCRYPT}.pem"
else
    # Generate Diffie-Hellman key exchange
    ${SUDOE} ./easyrsa gen-dh
    ${SUDOE} mv pki/dh.pem pki/dh${ENCRYPT}.pem
fi

    # Generate static HMAC key to defend against DDoS
    ${SUDOE} openvpn --genkey --secret pki/ta.key

    # Write config file for server using the template .txt file
    $SUDO cp /etc/.pivpn/server_config.txt /etc/openvpn/server.conf

    $SUDO sed -i "s/LOCALNET/${LOCALNET}/g" /etc/openvpn/server.conf
    $SUDO sed -i "s/LOCALMASK/${LOCALMASK}/g" /etc/openvpn/server.conf

    # Set the user encryption key size
    $SUDO sed -i "s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/\1${ENCRYPT}.pem/" /etc/openvpn/server.conf

    # if they modified port put value in server.conf
    if [ $PORT != 1194 ]; then
        $SUDO sed -i "s/1194/${PORT}/g" /etc/openvpn/server.conf
    fi

    # if they modified protocol put value in server.conf
    if [ "$PROTO" != "udp" ]; then
        $SUDO sed -i "s/proto udp/proto tcp/g" /etc/openvpn/server.conf
    fi

    # write out server certs to conf file
    $SUDO sed -i "s/\(key \/etc\/openvpn\/easy-rsa\/pki\/private\/\).*/\1${SERVER_NAME}.key/" /etc/openvpn/server.conf
    $SUDO sed -i "s/\(cert \/etc\/openvpn\/easy-rsa\/pki\/issued\/\).*/\1${SERVER_NAME}.crt/" /etc/openvpn/server.conf
}

confUnattendedUpgrades() {
    if [[ $UNATTUPG == "unattended-upgrades" ]]; then
        if [[ $PLAT == "Ubuntu" ]]; then
            # Ubuntu 50unattended-upgrades should already just have security enabled
            # so we just need to configure the 10periodic file
            cat << EOT | $SUDO tee /etc/apt/apt.conf.d/10periodic >/dev/null
    APT::Periodic::Update-Package-Lists "1";
    APT::Periodic::Download-Upgradeable-Packages "1";
    APT::Periodic::AutocleanInterval "5";
    APT::Periodic::Unattended-Upgrade "1";
EOT
        else
            $SUDO sed -i '/\(o=Raspbian,n=jessie\)/c\"o=Raspbian,n=jessie,l=Raspbian-Security";\' /etc/apt/apt.conf.d/50unattended-upgrades
            cat << EOT | $SUDO tee /etc/apt/apt.conf.d/02periodic >/dev/null
    APT::Periodic::Enable "1";
    APT::Periodic::Update-Package-Lists "1";
    APT::Periodic::Download-Upgradeable-Packages "1";
    APT::Periodic::Unattended-Upgrade "1";
    APT::Periodic::AutocleanInterval "7";
    APT::Periodic::Verbose "0";
EOT
        fi
    fi

}

confNetwork() {
    # Enable forwarding of internet traffic
    $SUDO sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
    $SUDO sysctl -p

    # if ufw enabled, configure that
    if hash ufw 2>/dev/null; then
        if $SUDO ufw status | grep -q inactive
        then
            noUFW=1
        else
            echo "::: Detected UFW is enabled."
            echo "::: Adding UFW rules..."
            $SUDO cp /etc/.pivpn/ufw_add.txt /tmp/ufw_add.txt
            $SUDO sed -i 's/IPv4dev/'"$IPv4dev"'/' /tmp/ufw_add.txt
            $SUDO sed -i "s/\(DEFAULT_FORWARD_POLICY=\).*/\1\"ACCEPT\"/" /etc/default/ufw
            $SUDO sed -i -e '/delete these required/r /tmp/ufw_add.txt' -e//N /etc/ufw/before.rules
            $SUDO ufw allow "${PORT}/${PROTO}"
            $SUDO ufw allow from 10.8.0.0/24
            $SUDO ufw reload
            echo "::: UFW configuration completed."
        fi
    else
        noUFW=1
    fi
    # else configure iptables
    if [[ $noUFW -eq 1 ]]; then
        echo 1 > /tmp/noUFW
        $SUDO iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$IPv4dev" -j MASQUERADE
        if [[ $PLAT == "Ubuntu" || $PLAT == "Debian" ]]; then
            $SUDO iptables-save | $SUDO tee /etc/iptables/rules.v4 > /dev/null
        else
            $SUDO netfilter-persistent save
        fi
    else
        echo 0 > /tmp/noUFW
    fi

    $SUDO cp /tmp/noUFW /etc/pivpn/NO_UFW
}

confOVPN() {
    if ! IPv4pub=$(dig +short myip.opendns.com @resolver1.opendns.com)
    then
        echo "dig failed, now trying to curl eth0.me"
        if ! IPv4pub=$(curl eth0.me)
        then
            echo "eth0.me failed, please check your internet connection/DNS"
            exit $?
        fi
    fi
    $SUDO cp /tmp/pivpnUSR /etc/pivpn/INSTALL_USER
    $SUDO cp /tmp/DET_PLATFORM /etc/pivpn/DET_PLATFORM

    # Set status that no certs have been revoked
    echo 0 > /tmp/REVOKE_STATUS
    $SUDO cp /tmp/REVOKE_STATUS /etc/pivpn/REVOKE_STATUS

    METH=$(whiptail --title "Public IP or DNS" --radiolist "Will clients use a Public IP or DNS Name to connect to your server?" ${r} ${c} 2 \
    "$IPv4pub" "Use this public IP" "ON" \
    "DNS Entry" "Use a public DNS" "OFF" 3>&1 1>&2 2>&3)

    exitstatus=$?
    if [ $exitstatus != 0 ]; then
        echo "::: Cancel selected. Exiting..."
        exit 1
    fi

    $SUDO cp /etc/.pivpn/Default.txt /etc/openvpn/easy-rsa/pki/Default.txt

    if [ "$METH" == "$IPv4pub" ]; then
        $SUDO sed -i 's/IPv4pub/'"$IPv4pub"'/' /etc/openvpn/easy-rsa/pki/Default.txt
    else
        until [[ $publicDNSCorrect = True ]]
        do
            PUBLICDNS=$(whiptail --title "PiVPN Setup" --inputbox "What is the public DNS name of this Server?" ${r} ${c} 3>&1 1>&2 2>&3)
            exitstatus=$?
            if [ $exitstatus != 0 ]; then
            echo "::: Cancel selected. Exiting..."
            exit 1
            fi
            if (whiptail --backtitle "Confirm DNS Name" --title "Confirm DNS Name" --yesno "Is this correct?\n\n Public DNS Name:  $PUBLICDNS" ${r} ${c}) then
                publicDNSCorrect=True
                $SUDO sed -i 's/IPv4pub/'"$PUBLICDNS"'/' /etc/openvpn/easy-rsa/pki/Default.txt
            else
                publicDNSCorrect=False

            fi
        done
    fi

    # if they modified port put value in Default.txt for clients to use
    if [ $PORT != 1194 ]; then
        $SUDO sed -i -e "s/1194/${PORT}/g" /etc/openvpn/easy-rsa/pki/Default.txt
    fi

    # if they modified protocol put value in Default.txt for clients to use
    if [ "$PROTO" != "udp" ]; then
        $SUDO sed -i -e "s/proto udp/proto tcp/g" /etc/openvpn/easy-rsa/pki/Default.txt
    fi

    # verify server name to strengthen security
    $SUDO sed -i "s/SRVRNAME/${SERVER_NAME}/" /etc/openvpn/easy-rsa/pki/Default.txt

    $SUDO mkdir "/home/$pivpnUser/ovpns"
    $SUDO chmod 0777 -R "/home/$pivpnUser/ovpns"
}

installPiVPN() {
    stopServices
    confUnattendedUpgrades
    $SUDO mkdir -p /etc/pivpn/
    getGitFiles ${pivpnFilesDir} ${pivpnGitUrl}
    installScripts
    setCustomProto
    setCustomPort
    confOpenVPN
    confNetwork
    confOVPN
    setClientDNS
}

displayFinalMessage() {
    # Final completion message to user
    if [[ $PLAT == "Ubuntu" || $PLAT == "Debian" ]]; then
        $SUDO service openvpn start
    else
        $SUDO systemctl enable openvpn.service
        $SUDO systemctl start openvpn.service
    fi

    whiptail --msgbox --backtitle "Make it so." --title "Installation Complete!" "Now run 'pivpn add' to create the ovpn profiles.
Run 'pivpn help' to see what else you can do!
The install log is in /etc/pivpn." ${r} ${c}
    if (whiptail --title "Reboot" --yesno --defaultno "It is strongly recommended you reboot after installation.  Would you like to reboot now?" ${r} ${c}); then
        whiptail --title "Rebooting" --msgbox "The system will now reboot." ${r} ${c}
        printf "\nRebooting system...\n"
        $SUDO sleep 3
        $SUDO shutdown -r now
    fi
}

######## SCRIPT ############
# Install the packages (we do this first because we need whiptail)
checkForDependencies
# Start the installer
welcomeDialogs

# Verify there is enough disk space for the install
verifyFreeDiskSpace

# Find interfaces and let the user choose one
chooseInterface

# Only try to set static on Raspbian, otherwise let user do it
if [[ $PLAT != "Raspbian" ]]; then
    avoidStaticIPv4Ubuntu
else
    getStaticIPv4Settings
    setStaticIPv4
fi

setNetwork

# Choose the user for the ovpns
chooseUser

# Ask if unattended-upgrades will be enabled
unattendedUpgrades

# Install
installPiVPN


displayFinalMessage

echo "::: Install Complete..."
