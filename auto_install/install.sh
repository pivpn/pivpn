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

set -e
######## VARIABLES #########

tmpLog="/tmp/pivpn-install.log"
instalLogLoc="/etc/pivpn/install.log"
setupVars=/etc/pivpn/setupVars.conf
useUpdateVars=false

### PKG Vars ###
PKG_MANAGER="apt-get"
PKG_CACHE="/var/lib/apt/lists/"
UPDATE_PKG_CACHE="${PKG_MANAGER} update"
PKG_INSTALL="${PKG_MANAGER} --yes --no-install-recommends install"
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"
PIVPN_DEPS=(openvpn git tar wget grep iptables-persistent dnsutils expect whiptail net-tools)
###          ###

pivpnGitUrl="https://github.com/pivpn/pivpn.git"
pivpnFilesDir="/etc/.pivpn"
easyrsaVer="3.0.4"
easyrsaRel="https://github.com/OpenVPN/easy-rsa/releases/download/${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"

# Raspbian's unattended-upgrades package downloads Debian's config, so this is the link for the proper config 
UNATTUPG_CONFIG="https://github.com/mvo5/unattended-upgrades/archive/1.4.tar.gz"

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

######## Undocumented Flags. Shhh ########
skipSpaceCheck=false
reconfigure=false
runUnattended=false

# Find IP used to route to outside world

IPv4dev=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++)if($i~/dev/)print $(i+1)}')
IPv4addr=$(ip route get 8.8.8.8| awk '{print $7}')
IPv4gw=$(ip route get 8.8.8.8 | awk '{print $3}')

availableInterfaces=$(ip -o link | grep "state UP" | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1)
dhcpcdFile=/etc/dhcpcd.conf

# Next see if we are on a tested and supported OS
function noOS_Support() {
    whiptail --msgbox --backtitle "INVALID OS DETECTED" --title "Invalid OS" "We have not been able to detect a supported OS.
Currently this installer supports Raspbian and Debian (Jessie and Stretch), Devuan (Jessie) and Ubuntu from 14.04 (trusty) to 17.04 (zesty).
If you think you received this message in error, you can post an issue on the GitHub at https://github.com/pivpn/pivpn/issues." ${r} ${c}
    exit 1
}

function maybeOS_Support() {
    if (whiptail --backtitle "Not Supported OS" --title "Not Supported OS" --yesno "You are on an OS that we have not tested but MAY work.
Currently this installer supports Raspbian and Debian (Jessie and Stretch), Devuan (Jessie) and Ubuntu from 14.04 (trusty) to 17.04 (zesty).
Would you like to continue anyway?" ${r} ${c}) then
        echo "::: Did not detect perfectly supported OS but,"
        echo "::: Continuing installation at user's own risk..."
    else
        echo "::: Exiting due to unsupported OS"
        exit 1
    fi
}

# Compatibility
distro_check() {
    # if lsb_release command is on their system
    if hash lsb_release 2>/dev/null; then

        PLAT=$(lsb_release -si)
        OSCN=$(lsb_release -sc) # We want this to be trusty xenial or jessie

    else # else get info from os-release

        source /etc/os-release
        PLAT=$(awk '{print $1}' <<< "$NAME")
        VER="$VERSION_ID"
        declare -A VER_MAP=(["9"]="stretch" ["8"]="jessie" ["18.04"]="bionic" ["16.04"]="xenial" ["14.04"]="trusty")
        OSCN=${VER_MAP["${VER}"]}
    fi

    if [[ ${OSCN} != "bionic" ]]; then
        PIVPN_DEPS+=(dhcpcd5)
    fi

    case ${PLAT} in
        Ubuntu|Raspbian|Debian|Devuan)
        case ${OSCN} in
            trusty|xenial|jessie|stretch)
            ;;
            *)
            maybeOS_Support
            ;;
        esac
        ;;
        *)
        noOS_Support
        ;;
    esac

    echo "${PLAT}" > /tmp/DET_PLATFORM
}

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
    numUsers=$(awk -F':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)
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
    availableUsers=$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)
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
    chooseUserCmd=(whiptail --title "Choose A User" --separate-output --radiolist "Choose (press space to select):" ${r} ${c} ${numUsers})
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
    local firstloop=1

    if [[ $(echo "${availableInterfaces}" | wc -l) -eq 1 ]]; then
      pivpnInterface="${availableInterfaces}"
      echo "${pivpnInterface}" > /tmp/pivpnINT
      return
    fi

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
    chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose An Interface (press space to select):" ${r} ${c} ${interfaceCount})
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
    local ipSettingsCorrect
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
    $SUDO cp /etc/.pivpn/scripts/clientStat.sh /opt/pivpn/clientStat.sh
    $SUDO cp /etc/.pivpn/scripts/listOVPN.sh /opt/pivpn/listOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/removeOVPN.sh /opt/pivpn/removeOVPN.sh
    $SUDO cp /etc/.pivpn/scripts/uninstall.sh /opt/pivpn/uninstall.sh
    $SUDO cp /etc/.pivpn/scripts/pivpnDebug.sh /opt/pivpn/pivpnDebug.sh
    $SUDO cp /etc/.pivpn/scripts/fix_iptables.sh /opt/pivpn/fix_iptables.sh
    $SUDO chmod 0755 /opt/pivpn/{makeOVPN,clientStat,listOVPN,removeOVPN,uninstall,pivpnDebug,fix_iptables}.sh
    $SUDO cp /etc/.pivpn/pivpn /usr/local/bin/pivpn
    $SUDO chmod 0755 /usr/local/bin/pivpn
    $SUDO cp /etc/.pivpn/scripts/bash-completion /etc/bash_completion.d/pivpn
    . /etc/bash_completion.d/pivpn
    # Copy interface setting for debug
    $SUDO cp /tmp/pivpnINT /etc/pivpn/pivpnINTERFACE

    $SUDO echo " done."
}

package_check_install() {
    dpkg-query -W -f='${Status}' "${1}" 2>/dev/null | grep -c "ok installed" || ${PKG_INSTALL} "${1}"
}

addSoftwareRepo() {
  # Add the official OpenVPN repo for distros that don't have the latest version in their default repos
  case ${PLAT} in
    Ubuntu|Debian|Devuan)
      case ${OSCN} in
        trusty|xenial|wheezy|jessie)
          wget -qO- https://swupdate.openvpn.net/repos/repo-public.gpg | $SUDO apt-key add -
          echo "deb http://build.openvpn.net/debian/openvpn/stable $OSCN main" | $SUDO tee /etc/apt/sources.list.d/swupdate.openvpn.net.list > /dev/null
          echo -n "::: Adding OpenVPN repo for $PLAT $OSCN ..."
          $SUDO apt-get -qq update & spinner $!
          echo " done!"
          ;;
      esac
      ;;
  esac
}

update_package_cache() {
  #Running apt-get update/upgrade with minimal output can cause some issues with
  #requiring user input

  #Check to see if apt-get update has already been run today
  #it needs to have been run at least once on new installs!
  timestamp=$(stat -c %Y ${PKG_CACHE})
  timestampAsDate=$(date -d @"${timestamp}" "+%b %e")
  today=$(date "+%b %e")


  if [ ! "${today}" == "${timestampAsDate}" ]; then
    #update package lists
    echo ":::"
    echo -n "::: ${PKG_MANAGER} update has not been run today. Running now..."
    $SUDO ${UPDATE_PKG_CACHE} &> /dev/null
    echo " done!"
  fi
}

notify_package_updates_available() {
  # Let user know if they have outdated packages on their system and
  # advise them to run a package update at soonest possible.
  echo ":::"
  echo -n "::: Checking ${PKG_MANAGER} for upgraded packages...."
  updatesToInstall=$(eval "${PKG_COUNT}")
  echo " done!"
  echo ":::"
  if [[ ${updatesToInstall} -eq "0" ]]; then
    echo "::: Your system is up to date! Continuing with PiVPN installation..."
  else
    echo "::: There are ${updatesToInstall} updates available for your system!"
    echo "::: We recommend you update your OS after installing PiVPN! "
    echo ":::"
  fi
}

install_dependent_packages() {
  # Install packages passed in via argument array
  # No spinner - conflicts with set -e
  declare -a argArray1=("${!1}")

  echo iptables-persistent iptables-persistent/autosave_v4 boolean true | $SUDO debconf-set-selections
  echo iptables-persistent iptables-persistent/autosave_v6 boolean false | $SUDO debconf-set-selections

  if command -v debconf-apt-progress &> /dev/null; then
    $SUDO debconf-apt-progress -- ${PKG_INSTALL} "${argArray1[@]}"
  else
    for i in "${argArray1[@]}"; do
      echo -n ":::    Checking for $i..."
      $SUDO package_check_install "${i}" &> /dev/null
      echo " installed!"
    done
  fi
}

unattendedUpgrades() {
    whiptail --msgbox --backtitle "Security Updates" --title "Unattended Upgrades" "Since this server will have at least one port open to the internet, it is recommended you enable unattended-upgrades.\nThis feature will check daily for security package updates only and apply them when necessary.\nIt will NOT automatically reboot the server so to fully apply some updates you should periodically reboot." ${r} ${c}

    if (whiptail --backtitle "Security Updates" --title "Unattended Upgrades" --yesno "Do you want to enable unattended upgrades of security patches to this server?" ${r} ${c}) then
        UNATTUPG="unattended-upgrades"
    else
        UNATTUPG=""
    fi
}

stopServices() {
    # Stop openvpn
    $SUDO echo ":::"
    $SUDO echo -n "::: Stopping OpenVPN service..."
    case ${PLAT} in
        Ubuntu|Debian|*vuan)
            $SUDO service openvpn stop || true
            ;;
        *)
            $SUDO systemctl stop openvpn.service || true
            ;;
    esac
    $SUDO echo " done."
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
    if [[ "${reconfigure}" == true ]]; then
          echo "::: --reconfigure passed to install script. Not downloading/updating local repos"
    else
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
    fi
}

setCustomProto() {
  # Set the available protocols into an array so it can be used with a whiptail dialog
  if protocol=$(whiptail --title "Protocol" --radiolist \
  "Choose a protocol (press space to select). Please only choose TCP if you know why you need TCP." ${r} ${c} 2 \
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
    DNSChoseCmd=(whiptail --separate-output --radiolist "Select the DNS Provider for your VPN Clients (press space to select). To use your own, select Custom." ${r} ${c} 6)
    DNSChooseOptions=(Google "" on
            OpenDNS "" off
            Level3 "" off
            DNS.WATCH "" off
            Norton "" off
            FamilyShield "" off
            CloudFlare "" off
            Custom "" off)

    if DNSchoices=$("${DNSChoseCmd[@]}" "${DNSChooseOptions[@]}" 2>&1 >/dev/tty)
    then

      if [[ ${DNSchoices} != "Custom" ]]; then

        echo "::: Using ${DNSchoices} servers."
        declare -A DNS_MAP=(["Google"]="8.8.8.8 8.8.4.4" ["OpenDNS"]="208.67.222.222 208.67.220.220" ["Level3"]="209.244.0.3 209.244.0.4" ["DNS.WATCH"]="84.200.69.80 84.200.70.40" ["Norton"]="199.85.126.10 199.85.127.10" ["FamilyShield"]="208.67.222.123 208.67.220.123" ["CloudFlare"]="1.1.1.1 1.0.0.1")

        OVPNDNS1=$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")
        OVPNDNS2=$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")

        $SUDO sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${OVPNDNS1}'\"/' /etc/openvpn/server.conf
        $SUDO sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${OVPNDNS2}'\"/' /etc/openvpn/server.conf

      else

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
      fi

    else
      echo "::: Cancel selected. Exiting..."
      exit 1
    fi
}

confOpenVPN() {
    # Generate a random, alphanumeric identifier of 16 characters for this server so that we can use verify-x509-name later that is unique for this server installation. Source: Earthgecko (https://gist.github.com/earthgecko/3089509)
    NEW_UUID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    SERVER_NAME="server_${NEW_UUID}"

    if [[ ${useUpdateVars} == false ]]; then
        # Ask user for desired level of encryption

        if [[ ${useUpdateVars} == false ]]; then
            if [[ ${PLAT} == "Raspbian" ]] && [[ ${OSCN} != "stretch" ]]; then
                APPLY_TWO_POINT_FOUR=false
            else
                if (whiptail --backtitle "Setup OpenVPN" --title "Installation mode" --yesno --defaultyes "OpenVPN 2.4 brings support for stronger authentication and key exchange using Elliptic Curves, along with encrypted control channel.\n\nIf your clients do run OpenVPN 2.4 or later you can enable these features, otherwise choose 'No' for best compatibility.\n\nNOTE: Current mobile app, that is OpenVPN connect, is supported." ${r} ${c}); then
                    APPLY_TWO_POINT_FOUR=true
                    $SUDO touch /etc/pivpn/TWO_POINT_FOUR
                else
                    APPLY_TWO_POINT_FOUR=false
                fi
            fi
        fi

        if [[ ${runUnattended} == true ]] && [[ ${APPLY_TWO_POINT_FOUR} == true ]]; then
            $SUDO touch /etc/pivpn/TWO_POINT_FOUR
        fi

        if [[ ${APPLY_TWO_POINT_FOUR} == false ]]; then

            ENCRYPT=$(whiptail --backtitle "Setup OpenVPN" --title "RSA encryption strength" --radiolist \
            "Choose your desired level of encryption (press space to select):\n   This is an encryption key that will be generated on your system.  The larger the key, the more time this will take.  For most applications, it is recommended to use 2048 bits.  If you are testing, you can use 1024 bits to speed things up, but do not use this for normal use!  If you are paranoid about ... things... then grab a cup of joe and pick 4096 bits." ${r} ${c} 3 \
            "1024" "Use 1024-bit encryption (testing only)" OFF \
            "2048" "Use 2048-bit encryption (recommended level)" ON \
            "4096" "Use 4096-bit encryption (paranoid level)" OFF 3>&1 1>&2 2>&3)

        else

            declare -A ECDSA_MAP=(["256"]="prime256v1" ["384"]="secp384r1" ["521"]="secp521r1")
            ENCRYPT=$(whiptail --backtitle "Setup OpenVPN" --title "ECDSA encryption strength" --radiolist \
            "Choose your desired level of encryption (press space to select):\n   This is an encryption key that will be generated on your system.  The larger the key, the more time this will take.  For most applications, it is recommended to use 256 bits.  You can increase the number of bits if you care about, however, consider that 256 bits are already as secure as 3072 bit RSA." ${r} ${c} 3 \
            "256" "Use 256-bit encryption (recommended level)" ON \
            "384" "Use 384-bit encryption" OFF \
            "521" "Use 521-bit encryption (paranoid level)" OFF 3>&1 1>&2 2>&3)

        fi

        exitstatus=$?
        if [ $exitstatus != 0 ]; then
            echo "::: Cancel selected. Exiting..."
            exit 1
        fi
    fi

    # If easy-rsa exists, remove it
    if [[ -d /etc/openvpn/easy-rsa/ ]]; then
        $SUDO rm -rf /etc/openvpn/easy-rsa/
    fi

    # Get the PiVPN easy-rsa
    wget -q -O - "${easyrsaRel}" | $SUDO tar xz -C /etc/openvpn && $SUDO mv /etc/openvpn/EasyRSA-${easyrsaVer} /etc/openvpn/easy-rsa
    # fix ownership
    $SUDO chown -R root:root /etc/openvpn/easy-rsa
    $SUDO mkdir /etc/openvpn/easy-rsa/pki

    cd /etc/openvpn/easy-rsa || exit

    # Write out new vars file
    set +e
    IFS= read -d '' String <<"EOF"
if [ -z "$EASYRSA_CALLER" ]; then
    echo "Nope." >&2
    return 1
fi
set_var EASYRSA            "/etc/openvpn/easy-rsa"
set_var EASYRSA_PKI        "$EASYRSA/pki"
set_var EASYRSA_CRL_DAYS   3650
EOF
    echo "${String}" | $SUDO tee vars >/dev/null
    set -e

    # Set certificate type
    if [[ ${APPLY_TWO_POINT_FOUR} == false ]]; then
        echo "set_var EASYRSA_ALGO       rsa" >> vars
        echo "set_var EASYRSA_KEY_SIZE   ${ENCRYPT}" >> vars
    else
        echo "set_var EASYRSA_ALGO       ec" >> vars
        echo "set_var EASYRSA_CURVE      ${ECDSA_MAP["${ENCRYPT}"]}" >> vars
    fi

    # Remove any previous keys
    ${SUDOE} ./easyrsa --batch init-pki

    # Build the certificate authority
    printf "::: Building CA...\n"
    ${SUDOE} ./easyrsa --batch build-ca nopass
    printf "\n::: CA Complete.\n"

    if [[ ${useUpdateVars} == false ]]; then
        if [[ ${APPLY_TWO_POINT_FOUR} == false ]]; then
            whiptail --msgbox --backtitle "Setup OpenVPN" --title "Server Information" "The server key, Diffie-Hellman key, and HMAC key will now be generated." ${r} ${c}
        fi
    fi

    # Build the server
    ${SUDOE} ./easyrsa build-server-full ${SERVER_NAME} nopass

    if [[ ${useUpdateVars} == false ]]; then
      if [[ ${APPLY_TWO_POINT_FOUR} == false ]]; then
        if ([ "$ENCRYPT" -ge "4096" ] && whiptail --backtitle "Setup OpenVPN" --title "Download Diffie-Hellman Parameters" --yesno --defaultno "Download Diffie-Hellman parameters from a public DH parameter generation service?\n\nGenerating DH parameters for a $ENCRYPT-bit key can take many hours on a Raspberry Pi. You can instead download DH parameters from \"2 Ton Digital\" that are generated at regular intervals as part of a public service. Downloaded DH parameters will be randomly selected from their database.\nMore information about this service can be found here: https://2ton.com.au/safeprimes/\n\nIf you're paranoid, choose 'No' and Diffie-Hellman parameters will be generated on your device." ${r} ${c}); then
          DOWNLOAD_DH_PARAM=true
        else
          DOWNLOAD_DH_PARAM=false
        fi
      else
        DOWNLOAD_DH_PARAM=false
      fi
    fi

    if [[ ${APPLY_TWO_POINT_FOUR} == false ]]; then
      if [ "$ENCRYPT" -ge "4096" ] && [[ ${DOWNLOAD_DH_PARAM} == true ]]; then
        # Downloading parameters
        ${SUDOE} curl "https://2ton.com.au/getprimes/random/dhparam/${ENCRYPT}" -o "/etc/openvpn/easy-rsa/pki/dh${ENCRYPT}.pem"
      else
        # Generate Diffie-Hellman key exchange
        ${SUDOE} ./easyrsa gen-dh
        ${SUDOE} mv pki/dh.pem pki/dh${ENCRYPT}.pem
      fi
    fi

    # Generate static HMAC key to defend against DDoS
    ${SUDOE} openvpn --genkey --secret pki/ta.key

    # Generate an empty Certificate Revocation List
    ${SUDOE} ./easyrsa gen-crl
    ${SUDOE} cp pki/crl.pem /etc/openvpn/crl.pem
    ${SUDOE} chown nobody:nogroup /etc/openvpn/crl.pem

    # Write config file for server using the template.txt file
    $SUDO cp /etc/.pivpn/server_config.txt /etc/openvpn/server.conf

    if [[ ${APPLY_TWO_POINT_FOUR} == true ]]; then
      #If they enabled 2.4 use tls-crypt instead of tls-auth to encrypt control channel
      $SUDO sed -i "s/tls-auth \/etc\/openvpn\/easy-rsa\/pki\/ta.key 0/tls-crypt \/etc\/openvpn\/easy-rsa\/pki\/ta.key/" /etc/openvpn/server.conf
    fi

    if [[ ${APPLY_TWO_POINT_FOUR} == true ]]; then
      #If they enabled 2.4 disable dh parameters since the key exchange will use the matching curve from the ECDSA certificate
      $SUDO sed -i "s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/dh none/" /etc/openvpn/server.conf
    else
      # Otherwise set the user encryption key size
      $SUDO sed -i "s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/\1${ENCRYPT}.pem/" /etc/openvpn/server.conf
    fi

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
    cd /etc/apt/apt.conf.d

    if [[ $UNATTUPG == "unattended-upgrades" ]]; then
        $SUDO apt-get --yes --quiet --no-install-recommends install "$UNATTUPG" > /dev/null & spinner $!
        if [[ $PLAT == "Ubuntu" ]]; then
            # Ubuntu 50unattended-upgrades should already just have security enabled
            # so we just need to configure the 10periodic file
            cat << EOT | $SUDO tee 10periodic >/dev/null
    APT::Periodic::Update-Package-Lists "1";
    APT::Periodic::Download-Upgradeable-Packages "1";
    APT::Periodic::AutocleanInterval "5";
    APT::Periodic::Unattended-Upgrade "1";
EOT
        else
            wget -q -O - "$UNATTUPG_CONFIG" | $SUDO tar xz
            $SUDO cp unattended-upgrades-1.4/data/50unattended-upgrades.Raspbian 50unattended-upgrades
            $SUDO rm -rf unattended-upgrades-1.4
            cat << EOT | $SUDO tee 02periodic >/dev/null
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
        if LANG=en_US.UTF-8 $SUDO ufw status | grep -q inactive
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
        case ${PLAT} in
            Ubuntu|Debian|Devuan)
                $SUDO iptables-save | $SUDO tee /etc/iptables/rules.v4 > /dev/null
                ;;
            *)
                $SUDO netfilter-persistent save
                ;;
        esac
    else
        echo 0 > /tmp/noUFW
    fi

    $SUDO cp /tmp/noUFW /etc/pivpn/NO_UFW
}

confOVPN() {
    IPv4pub=$(dig +short myip.opendns.com @208.67.222.222)
    if [ $? -ne 0 ] || [ -z "$IPv4pub" ]; then
        echo "dig failed, now trying to curl whatismyip.akamai.com"
        if ! IPv4pub=$(curl -s http://whatismyip.akamai.com)
        then
            echo "whatismyip.akamai.com failed, please check your internet connection/DNS"
            exit $?
        fi
    fi
    $SUDO cp /tmp/pivpnUSR /etc/pivpn/INSTALL_USER
    $SUDO cp /tmp/DET_PLATFORM /etc/pivpn/DET_PLATFORM

    $SUDO cp /etc/.pivpn/Default.txt /etc/openvpn/easy-rsa/pki/Default.txt

    if [[ ${APPLY_TWO_POINT_FOUR} == true ]]; then
      #If they enabled 2.4 remove key-direction options since it's not required
      $SUDO sed -i "/key-direction 1/d" /etc/openvpn/easy-rsa/pki/Default.txt
    fi

    if [[ ${useUpdateVars} == false ]]; then
        METH=$(whiptail --title "Public IP or DNS" --radiolist "Will clients use a Public IP or DNS Name to connect to your server (press space to select)?" ${r} ${c} 2 \
        "$IPv4pub" "Use this public IP" "ON" \
        "DNS Entry" "Use a public DNS" "OFF" 3>&1 1>&2 2>&3)

        exitstatus=$?
        if [ $exitstatus != 0 ]; then
            echo "::: Cancel selected. Exiting..."
            exit 1
        fi

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
    else
        $SUDO sed -i 's/IPv4pub/'"$PUBLICDNS"'/' /etc/openvpn/easy-rsa/pki/Default.txt
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

    if [ ! -d "/home/$pivpnUser/ovpns" ]; then
        $SUDO mkdir "/home/$pivpnUser/ovpns"
    fi
    $SUDO chmod 0777 -R "/home/$pivpnUser/ovpns"
}

confLogging() {
  echo "if \$programname == 'ovpn-server' then /var/log/openvpn.log
if \$programname == 'ovpn-server' then ~" | $SUDO tee /etc/rsyslog.d/30-openvpn.conf > /dev/null

  echo "/var/log/openvpn.log
{
    rotate 4
    weekly
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true
    endscript
}" | $SUDO tee /etc/logrotate.d/openvpn > /dev/null

  # Restart the logging service
  case ${PLAT} in
    Ubuntu|Debian|*vuan)
      $SUDO service rsyslog restart || true
      ;;
    *)
      $SUDO systemctl restart rsyslog.service || true
      ;;
  esac
}

finalExports() {
    # Update variables in setupVars.conf file
    if [ -e "${setupVars}" ]; then
        $SUDO sed -i.update.bak '/pivpnUser/d;/UNATTUPG/d;/pivpnInterface/d;/IPv4dns/d;/IPv4addr/d;/IPv4gw/d;/pivpnProto/d;/PORT/d;/ENCRYPT/d;/DOWNLOAD_DH_PARAM/d;/PUBLICDNS/d;/OVPNDNS1/d;/OVPNDNS2/d;' "${setupVars}"
    fi
    {
        echo "pivpnUser=${pivpnUser}"
        echo "UNATTUPG=${UNATTUPG}"
        echo "pivpnInterface=${pivpnInterface}"
        echo "IPv4dns=${IPv4dns}"
        echo "IPv4addr=${IPv4addr}"
        echo "IPv4gw=${IPv4gw}"
        echo "pivpnProto=${pivpnProto}"
        echo "PORT=${PORT}"
        echo "ENCRYPT=${ENCRYPT}"
        echo "APPLY_TWO_POINT_FOUR=${APPLY_TWO_POINT_FOUR}"
        echo "DOWNLOAD_DH_PARAM=${DOWNLOAD_DH_PARAM}"
        echo "PUBLICDNS=${PUBLICDNS}"
        echo "OVPNDNS1=${OVPNDNS1}"
        echo "OVPNDNS2=${OVPNDNS2}"
    } | $SUDO tee "${setupVars}" > /dev/null
}


# I suggest replacing some of these names.

#accountForRefactor() {
#    # At some point in the future this list can be pruned, for now we'll need it to ensure updates don't break.
#
#    # Refactoring of install script has changed the name of a couple of variables. Sort them out here.
#    sed -i 's/pivpnUser/PIVPN_USER/g' ${setupVars}
#    #sed -i 's/UNATTUPG/UNATTUPG/g' ${setupVars}
#    sed -i 's/pivpnInterface/PIVPN_INTERFACE/g' ${setupVars}
#    sed -i 's/IPv4dns/IPV4_DNS/g' ${setupVars}
#    sed -i 's/IPv4addr/IPV4_ADDRESS/g' ${setupVars}
#    sed -i 's/IPv4gw/IPV4_GATEWAY/g' ${setupVars}
#    sed -i 's/pivpnProto/TRANSPORT_LAYER/g' ${setupVars}
#    #sed -i 's/PORT/PORT/g' ${setupVars}
#    #sed -i 's/ENCRYPT/ENCRYPT/g' ${setupVars}
#    #sed -i 's/DOWNLOAD_DH_PARAM/DOWNLOAD_DH_PARAM/g' ${setupVars}
#    sed -i 's/PUBLICDNS/PUBLIC_DNS/g' ${setupVars}
#    sed -i 's/OVPNDNS1/OVPN_DNS_1/g' ${setupVars}
#    sed -i 's/OVPNDNS2/OVPN_DNS_2/g' ${setupVars}
#}

installPiVPN() {
    stopServices
    $SUDO mkdir -p /etc/pivpn/
    confUnattendedUpgrades
    installScripts
    setCustomProto
    setCustomPort
    confOpenVPN
    confNetwork
    confOVPN
    setClientDNS
    confLogging
    finalExports
}

updatePiVPN() {
    #accountForRefactor
    stopServices
    confUnattendedUpgrades
    installScripts

    # setCustomProto
    # write out the PROTO
    PROTO=$pivpnProto
    $SUDO cp /tmp/pivpnPROTO /etc/pivpn/INSTALL_PROTO

    #setCustomPort
    # write out the port
    $SUDO cp /tmp/INSTALL_PORT /etc/pivpn/INSTALL_PORT

    confOpenVPN
    confNetwork
    confOVPN

    # ?? Is this always OK? Also if you only select one DNS server ??
    $SUDO sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${OVPNDNS1}'\"/' /etc/openvpn/server.conf
    $SUDO sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${OVPNDNS2}'\"/' /etc/openvpn/server.conf

    finalExports #re-export setupVars.conf to account for any new vars added in new versions
}


displayFinalMessage() {
    # Final completion message to user
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

update_dialogs() {
    # reconfigure
    if [ "${reconfigure}" = true ]; then
        opt1a="Repair"
        opt1b="This will retain existing settings"
        strAdd="You will remain on the same version"
    else
        opt1a="Update"
        opt1b="This will retain existing settings."
        strAdd="You will be updated to the latest version."
    fi
    opt2a="Reconfigure"
    opt2b="This will allow you to enter new settings"

    UpdateCmd=$(whiptail --title "Existing Install Detected!" --menu "\n\nWe have detected an existing install.\n\nPlease choose from the following options: \n($strAdd)" ${r} ${c} 2 \
    "${opt1a}"  "${opt1b}" \
    "${opt2a}"  "${opt2b}" 3>&2 2>&1 1>&3) || \
    { echo "::: Cancel selected. Exiting"; exit 1; }

    case ${UpdateCmd} in
        ${opt1a})
            echo "::: ${opt1a} option selected."
            useUpdateVars=true
            ;;
        ${opt2a})
            echo "::: ${opt2a} option selected"
            useUpdateVars=false
            ;;
    esac
}

clone_or_update_repos() {
    if [[ "${reconfigure}" == true ]]; then
        echo "::: --reconfigure passed to install script. Not downloading/updating local repos"
    else
        # Get Git files
        getGitFiles ${pivpnFilesDir} ${pivpnGitUrl} || \
        { echo "!!! Unable to clone ${pivpnGitUrl} into ${pivpnFilesDir}, unable to continue."; \
            exit 1; \
        }
    fi
}

######## SCRIPT ############

main() {

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

    # Check for supported distribution
    distro_check

    # Check arguments for the undocumented flags
    for var in "$@"; do
        case "$var" in
            "--reconfigure"  ) reconfigure=true;;
            "--i_do_not_follow_recommendations"   ) skipSpaceCheck=false;;
            "--unattended"     ) runUnattended=true;;
        esac
    done

    if [[ -f ${setupVars} ]]; then
        if [[ "${runUnattended}" == true ]]; then
            echo "::: --unattended passed to install script, no whiptail dialogs will be displayed"
            useUpdateVars=true
        else
            update_dialogs
        fi
    fi

    # Start the installer
    # Verify there is enough disk space for the install
    if [[ "${skipSpaceCheck}" == true ]]; then
        echo "::: --i_do_not_follow_recommendations passed to script, skipping free disk space verification!"
    else
        verifyFreeDiskSpace
    fi

    # Install the packages (we do this first because we need whiptail)
    addSoftwareRepo

    update_package_cache

    # Notify user of package availability
    notify_package_updates_available

    # Install packages used by this installation script
    install_dependent_packages PIVPN_DEPS[@]

    if [[ ${useUpdateVars} == false ]]; then
        # Display welcome dialogs
        welcomeDialogs

        # Find interfaces and let the user choose one
        chooseInterface

        # Only try to set static on Raspbian, otherwise let user do it
        if [[ $PLAT != "Raspbian" ]]; then
            avoidStaticIPv4Ubuntu
        else
            getStaticIPv4Settings
            setStaticIPv4
        fi

        # Choose the user for the ovpns
        chooseUser

        # Ask if unattended-upgrades will be enabled
        unattendedUpgrades

        # Clone/Update the repos
        clone_or_update_repos

        # Install and log everything to a file
        installPiVPN | tee ${tmpLog}

        echo "::: Install Complete..."
    else
        # Source ${setupVars} for use in the rest of the functions.
        source ${setupVars}

        echo "::: Using IP address: $IPv4addr"
        echo "${IPv4addr%/*}" > /tmp/pivpnIP
        echo "::: Using interface: $pivpnInterface"
        echo "${pivpnInterface}" > /tmp/pivpnINT
        echo "::: Using User: $pivpnUser"
        echo "${pivpnUser}" > /tmp/pivpnUSR
        echo "::: Using protocol: $pivpnProto"
        echo "${pivpnProto}" > /tmp/pivpnPROTO
        echo "::: Using port: $PORT"
        echo ${PORT} > /tmp/INSTALL_PORT
        echo ":::"

        # Only try to set static on Raspbian
        case ${PLAT} in
          Rasp*)
            setStaticIPv4 # This might be a problem if a user tries to modify the ip in the config file and then runs an update because of the way we check for previous configuration in /etc/dhcpcd.conf
            ;;
          *)
            echo "::: IP Information"
            echo "::: Since we think you are not using Raspbian, we will not configure a static IP for you."
            echo "::: If you are in Amazon then you can not configure a static IP anyway."
            echo "::: Just ensure before this installer started you had set an elastic IP on your instance."
            ;;
          esac

        # Clone/Update the repos
        clone_or_update_repos


        updatePiVPN | tee ${tmpLog}
    fi

    #Move the install log into /etc/pivpn for storage
    $SUDO mv ${tmpLog} ${instalLogLoc}

    echo "::: Restarting services..."
    # Start services
    case ${PLAT} in
        Ubuntu|Debian|*vuan)
            $SUDO service openvpn start
            ;;
        *)
            $SUDO systemctl enable openvpn.service
            $SUDO systemctl start openvpn.service
            ;;
    esac

    echo "::: done."

    if [[ "${useUpdateVars}" == false ]]; then
        displayFinalMessage
    fi

    echo ":::"
    if [[ "${useUpdateVars}" == false ]]; then
        echo "::: Installation Complete!"
        echo "::: Now run 'pivpn add' to create an ovpn profile for each of your devices."
        echo "::: Run 'pivpn help' to see what else you can do!"
        echo "::: It is strongly recommended you reboot after installation."
    else
        echo "::: Update complete!"
    fi

    echo ":::"
    echo "::: The install log is located at: ${instalLogLoc}"
}

if [[ "${PIVPN_TEST}" != true ]] ; then
  main "$@"
fi
