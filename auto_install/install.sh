#!/usr/bin/env bash
# PiVPN: Trivial OpenVPN or WireGuard setup and configuration
# Easiest setup and mangement of OpenVPN or WireGuard on Raspberry Pi
# http://pivpn.io
# Heavily adapted from the pi-hole.net project and...
# https://github.com/StarshipEngineer/OpenVPN-Setup/
#
# Install with this command (from your Pi):
#
# curl -L https://install.pivpn.io | bash
# Make sure you have `curl` installed

######## VARIABLES #########
setupVars=/etc/pivpn/setupVars.conf
pivpnFilesDir="/etc/.pivpn"

### PKG Vars ###
PKG_MANAGER="apt-get"
PKG_CACHE="/var/lib/apt/lists/"
UPDATE_PKG_CACHE="${PKG_MANAGER} update"
PKG_INSTALL="${PKG_MANAGER} --yes --no-install-recommends install"
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"

# Dependencies that are required by the script, regardless of the VPN protocol chosen
BASE_DEPS=(git tar wget grep iptables-persistent dnsutils whiptail net-tools)

# Dependencies that where actually installed by the script. For example if the script requires
# grep and dnsutils but dnsutils is already installed, we save grep here. This way when uninstalling
# PiVPN we won't prompt to remove packages that may have been installed by the user for other reasons
TO_INSTALL=()

pivpnGitUrl="https://github.com/pivpn/pivpn.git"
easyrsaVer="3.0.6"
easyrsaRel="https://github.com/OpenVPN/easy-rsa/releases/download/v${easyrsaVer}/EasyRSA-unix-v${easyrsaVer}.tgz"

# Raspbian's unattended-upgrades package downloads Debian's config, so this is the link for the proper config
UNATTUPG_RELEASE="1.14"
UNATTUPG_CONFIG="https://github.com/mvo5/unattended-upgrades/archive/${UNATTUPG_RELEASE}.tar.gz"

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(echo $screen_size | awk '{print $1}')
columns=$(echo $screen_size | awk '{print $2}')

runUnattended=false

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

# Find IP used to route to outside world
IPv4addr=$(ip route get 8.8.8.8| awk '{print $7}')
IPv4gw=$(ip route get 8.8.8.8 | awk '{print $3}')

availableInterfaces=$(ip -o link | grep "state UP" | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1)
dhcpcdFile=/etc/dhcpcd.conf

# Next see if we are on a tested and supported OS
noOSSupport(){
	if [ "${runUnattended}" = 'true' ]; then
		echo "::: Invalid OS detected"
		echo "::: We have not been able to detect a supported OS."
		echo "::: Currently this installer supports Raspbian (Buster), Debian (Buster) and Ubuntu (Bionic)."
		exit 1
	fi

	whiptail --msgbox --backtitle "INVALID OS DETECTED" --title "Invalid OS" "We have not been able to detect a supported OS.
Currently this installer supports Raspbian (Buster), Debian (Buster) and Ubuntu (Bionic).
If you think you received this message in error, you can post an issue on the GitHub at https://github.com/pivpn/pivpn/issues." ${r} ${c}
	exit 1
}

maybeOSSupport(){
	if [ "${runUnattended}" = 'true' ]; then
		echo "::: Not Supported OS"
		echo "::: You are on an OS that we have not tested but MAY work, continuing anyway..."
		return
	fi

	if (whiptail --backtitle "Not Supported OS" --title "Not Supported OS" --yesno "You are on an OS that we have not tested but MAY work.
Currently this installer supports Raspbian (Buster).
Would you like to continue anyway?" ${r} ${c}) then
		echo "::: Did not detect perfectly supported OS but,"
		echo "::: Continuing installation at user's own risk..."
	else
		echo "::: Exiting due to unsupported OS"
		exit 1
	fi
}

# Compatibility
distroCheck(){
	# if lsb_release command is on their system
	if hash lsb_release 2>/dev/null; then

		PLAT=$(lsb_release -si)
		OSCN=$(lsb_release -sc)

	else # else get info from os-release

		source /etc/os-release
		PLAT=$(awk '{print $1}' <<< "$NAME")
		VER="$VERSION_ID"
		declare -A VER_MAP=(["10"]="buster" ["18.04"]="bionic")
		OSCN=${VER_MAP["${VER}"]}
	fi

	case ${PLAT} in
		Debian|Raspbian|Ubuntu)
		case ${OSCN} in
			buster|bionic)
			;;
			*)
			maybeOSSupport
			;;
		esac
		;;
		*)
		noOSSupport
		;;
	esac

	if [ "$PLAT" = "Raspbian" ]; then
		BASE_DEPS+=(dhcpcd5)
	fi

	echo "PLAT=${PLAT}" > /tmp/setupVars.conf
	echo "OSCN=${OSCN}" >> /tmp/setupVars.conf
}

checkHostname(){
###Checks for hostname size
	host_name=$(hostname -s)
	if [[ ! ${#host_name} -le 28 ]]; then
		if [ "${runUnattended}" = 'true' ]; then
			echo "::: Your hostname is too long."
			echo "::: Use 'hostnamectl set-hostname YOURHOSTNAME' to set a new hostname"
			echo "::: It must be less then 28 characters long and it must not use special characters"
			exit 1
		fi
		until [[ ${#host_name} -le 28 && $host_name  =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$ ]]; do
			host_name=$(whiptail --inputbox "Your hostname is too long.\nEnter new hostname with less then 28 characters\nNo special characters allowed." \
		   --title "Hostname too long" ${r} ${c} 3>&1 1>&2 2>&3)
			$SUDO hostnamectl set-hostname "${host_name}"
			if [[ ${#host_name} -le 28 && $host_name  =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$  ]]; then
				echo "::: Hostname valid and length OK, proceeding..."
			fi
		done
	else
		echo "::: Hostname length OK"
	fi
}

####### FUNCTIONS ##########
spinner(){
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

verifyFreeDiskSpace(){
	# If user installs unattended-upgrades we'd need about 60MB so will check for 75MB free
	echo "::: Verifying free disk space..."
	local required_free_kilobytes=76800
	local existing_free_kilobytes=$(df -Pk | grep -m1 '\/$' | awk '{print $4}')

	# - Unknown free disk space , not a integer
	if ! [[ "${existing_free_kilobytes}" =~ ^([0-9])+$ ]]; then
		echo "::: Unknown free disk space!"
		echo "::: We were unable to determine available free disk space on this system."
		if [ "${runUnattended}" = 'true' ]; then
			exit 1
		fi
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

updatePackageCache(){
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
		echo -ne "::: ${PKG_MANAGER} update has not been run today. Running now...\n"
		$SUDO ${UPDATE_PKG_CACHE} &> /dev/null
		echo " done!"
	fi
}

notifyPackageUpdatesAvailable(){
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

preconfigurePackages(){
	# Add support for https repositories if there are any that use it otherwise the installation will silently fail
	if grep -q https /etc/apt/sources.list; then
		BASE_DEPS+=("apt-transport-https")
	fi

	if [[ ${OSCN} == "buster" ]]; then
		$SUDO update-alternatives --set iptables /usr/sbin/iptables-legacy
		$SUDO update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
	fi

	echo iptables-persistent iptables-persistent/autosave_v4 boolean true | $SUDO debconf-set-selections
	echo iptables-persistent iptables-persistent/autosave_v6 boolean false | $SUDO debconf-set-selections
}

installDependentPackages(){
	# Install packages passed in via argument array
	# No spinner - conflicts with set -e
	declare -a argArray1=("${!1}")

	for i in "${argArray1[@]}"; do
		echo -n ":::    Checking for $i..."
			if dpkg-query -W -f='${Status}' "${i}" 2>/dev/null | grep -q "ok installed"; then
				echo " installed!"
			else
				TO_INSTALL+=("${i}")
				echo " not installed!"
			fi
	done

	if command -v debconf-apt-progress &> /dev/null; then
		$SUDO debconf-apt-progress -- ${PKG_INSTALL} "${argArray1[@]}"
	else
		${PKG_INSTALL} "${argArray1[@]}"
	fi
}

welcomeDialogs(){
	if [ "${runUnattended}" = 'true' ]; then
		echo "::: PiVPN Automated Installer"
		echo "::: This installer will transform your Raspberry Pi into an OpenVPN or WireGuard server!"
		echo "::: Initiating network interface"
		return
	fi

	# Display the welcome dialog
	whiptail --msgbox --backtitle "Welcome" --title "PiVPN Automated Installer" "This installer will transform your Raspberry Pi into an OpenVPN or WireGuard server!" ${r} ${c}

	# Explain the need for a static address
	whiptail --msgbox --backtitle "Initiating network interface" --title "Static IP Needed" "The PiVPN is a SERVER so it needs a STATIC IP ADDRESS to function properly.

In the next section, you can choose to use your current network settings (DHCP) or to manually edit them." ${r} ${c}
}

chooseInterface(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$IPv4dev" ]; then
			if [ "$(echo "${availableInterfaces}" | wc -l)" -eq 1 ]; then
				IPv4dev="${availableInterfaces}"
				echo "::: No interface specified, but only ${IPv4dev} is available, using it"
			else
				echo "::: No interface specified"
				exit 1
			fi
		else
			if ip -o link | grep -qw "${IPv4dev}"; then
				echo "::: Using interface: ${IPv4dev}"
			else
				echo "::: Interface ${IPv4dev} does not exist"
				exit 1
			fi
		fi
		echo "IPv4dev=${IPv4dev}" >> /tmp/setupVars.conf
		return
	fi

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
		IPv4dev="${availableInterfaces}"
		echo "IPv4dev=${IPv4dev}" >> /tmp/setupVars.conf
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
			IPv4dev=${desiredInterface}
			echo "::: Using interface: $IPv4dev"
			echo "IPv4dev=${IPv4dev}" >> /tmp/setupVars.conf
		done
	else
		echo "::: Cancel selected, exiting...."
		exit 1
	fi
}

avoidStaticIPv4Ubuntu() {
	if [ "${runUnattended}" = 'true' ]; then
		echo "::: Since we think you are not using Raspbian, we will not configure a static IP for you."
		return
	fi

	# If we are in Ubuntu then they need to have previously set their network, so just use what you have.
	whiptail --msgbox --backtitle "IP Information" --title "IP Information" "Since we think you are not using Raspbian, we will not configure a static IP for you.
If you are in Amazon then you can not configure a static IP anyway. Just ensure before this installer started you had set an elastic IP on your instance." ${r} ${c}

}

validIP(){
	local ip=$1
	local stat=1

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

getStaticIPv4Settings() {
	# Grab their current DNS Server
	IPv4dns=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | xargs)

	if [ "${runUnattended}" = 'true' ]; then

		local INVALID_STATIC_IPV4_SETTINGS=0

		if [ -z "$IPv4addr" ]; then
			echo "::: Missing static IP address"
			INVALID_STATIC_IPV4_SETTINGS=1
		fi

		if [ -z "$IPv4gw" ]; then
			echo "::: Missing static IP gateway"
			INVALID_STATIC_IPV4_SETTINGS=1
		fi

		if [ "$INVALID_STATIC_IPV4_SETTINGS" -eq 1 ]; then
			echo "::: Incomplete static IP settings"
			exit 1
		fi

		if [ -z "$IPv4addr" ] && [ -z "$IPv4gw" ]; then
			echo "::: No static IP settings, using current settings"
			echo "::: Your static IPv4 address:    ${IPv4addr}"
			echo "::: Your static IPv4 gateway:    ${IPv4gw}"
		else
			if validIP "${IPv4addr%/*}"; then
				echo "::: Your static IPv4 address:    ${IPv4addr}"
			else
				echo "::: ${IPv4addr%/*} is not a valid IP address"
				exit 1
			fi

			if validIP "${IPv4gw}"; then
				echo "::: Your static IPv4 gateway:    ${IPv4gw}"
			else
				echo "::: ${IPv4gw} is not a valid IP address"
				exit 1
			fi
		fi

		echo "IPv4addr=${IPv4addr%/*}" >> /tmp/setupVars.conf
		echo "IPv4gw=${IPv4gw}" >> /tmp/setupVars.conf
		return
	fi

	local ipSettingsCorrect
	# Ask if the user wants to use DHCP settings as their static IP
	if (whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Do you want to use your current network settings as a static address?
					IP address:    ${IPv4addr}
					Gateway:       ${IPv4gw}" ${r} ${c}); then

		echo "IPv4addr=${IPv4addr%/*}" >> /tmp/setupVars.conf
		echo "IPv4gw=${IPv4gw}" >> /tmp/setupVars.conf
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
					echo "IPv4addr=${IPv4addr%/*}" >> /tmp/setupVars.conf
					echo "IPv4gw=${IPv4gw}" >> /tmp/setupVars.conf
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

setDHCPCD(){
	# Append these lines to dhcpcd.conf to enable a static IP
	echo "interface ${IPv4dev}
	static ip_address=${IPv4addr}
	static routers=${IPv4gw}
	static domain_name_servers=${IPv4dns}" | $SUDO tee -a ${dhcpcdFile} >/dev/null
}

setStaticIPv4(){
	# Tries to set the IPv4 address
	if [[ -f /etc/dhcpcd.conf ]]; then
		if grep -q "${IPv4addr}" ${dhcpcdFile}; then
			echo "::: Static IP already configured."
		else
			setDHCPCD
			$SUDO ip addr replace dev "${IPv4dev}" "${IPv4addr}"
			echo ":::"
			echo "::: Setting IP to ${IPv4addr}.  You may need to restart after the install is complete."
			echo ":::"
		fi
	else
		echo "::: Critical: Unable to locate configuration file to set static IPv4 address!"
		exit 1
	fi
}

chooseUser(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$install_user" ]; then
			if [ "$(awk -F':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)" -eq 1 ]; then
				install_user="$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)"
				echo "::: No user specified, but only ${install_user} is available, using it"
			else
				echo "::: No user specified"
				exit 1
			fi
		else
			if awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd | grep -qw "${install_user}"; then
				echo "::: ${install_user} will hold your ovpn configurations."
			else
				echo "::: User ${install_user} does not exist"
				exit 1
			fi
		fi
		install_home=$(grep -m1 "^${install_user}:" /etc/passwd | cut -d: -f6)
		install_home=${install_home%/}
		echo "install_user=${install_user}" >> /tmp/setupVars.conf
		echo "install_home=${install_home}" >> /tmp/setupVars.conf
		return
	fi

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
			install_user=${desiredUser}
			echo "::: Using User: $install_user"
			install_home=$(grep -m1 "^${install_user}:" /etc/passwd | cut -d: -f6)
			install_home=${install_home%/} # remove possible trailing slash
			echo "install_user=${install_user}" >> /tmp/setupVars.conf
			echo "install_home=${install_home}" >> /tmp/setupVars.conf
		done
	else
		echo "::: Cancel selected, exiting...."
		exit 1
	fi


}

isRepo(){
	# If the directory does not have a .git folder it is not a repo
	echo -n ":::    Checking $1 is a repo..."
	cd "${1}" &> /dev/null || return 1
	$SUDO git status &> /dev/null && echo " OK!"; return 0 || echo " not found!"; return 1
}

updateRepo(){
	# Pull the latest commits
	echo -n ":::     Updating repo in $1..."
	$SUDO rm -rf "${1}"
	# Go back to /etc otherwhise git will complain when the current working
	# directory has just been deleted (/etc/.pivpn).
	cd /etc
	$SUDO git clone -q --depth 1 --no-single-branch "${2}" "${1}" > /dev/null & spinner $!
	cd "${1}" || exit 1
	if [ -z "${TESTING}" ]; then
		:
	elif [ "${TESTING}" = "test" ]; then
		${SUDOE} git checkout test
	elif [ "${TESTING}" = "test-wireguard" ]; then
		${SUDOE} git checkout test-wireguard
	fi
	echo " done!"
}

makeRepo(){
	# Remove the non-repos interface and clone the interface
	echo -n ":::    Cloning $2 into $1..."
	$SUDO rm -rf "${1}"
	# Go back to /etc otherwhise git will complain when the current working
	# directory has just been deleted (/etc/.pivpn).
	cd /etc
	$SUDO git clone -q --depth 1 --no-single-branch "${2}" "${1}" > /dev/null & spinner $!
	cd "${1}" || exit 1
	if [ -z "${TESTING}" ]; then
		:
	elif [ "${TESTING}" = "test" ]; then
		${SUDOE} git checkout test
	elif [ "${TESTING}" = "test-wireguard" ]; then
		${SUDOE} git checkout test-wireguard
	fi
	echo " done!"
}

getGitFiles(){
	# Setup git repos for base files
	echo ":::"
	echo "::: Checking for existing base files..."
	if isRepo "${1}"; then
		updateRepo "${1}" "${2}"
	else
		makeRepo "${1}" "${2}"
	fi
}

cloneOrUpdateRepos(){
	# Get Git files
	getGitFiles ${pivpnFilesDir} ${pivpnGitUrl} || \
	{ echo "!!! Unable to clone ${pivpnGitUrl} into ${pivpnFilesDir}, unable to continue."; \
	exit 1; \
}
}

askWhichVPN(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$VPN" ]; then
			echo ":: No VPN protocol specified, using WireGuard"
			VPN="wireguard"
		else
			VPN="${VPN,,}"
			if [ "$VPN" = "wireguard" ]; then
				echo "::: WireGuard will be installed"
			elif [ "$VPN" = "openvpn" ]; then
				echo "::: OpenVPN will be installed"
			else
				echo ":: $VPN is not a supported VPN protocol, please specify 'wireguard' or 'openvpn'"
				exit 1
			fi
		fi
	else
		if (whiptail --backtitle "Setup PiVPN" --title "Installation mode" --yesno "WireGuard is a new kind of VPN that provides near-istantaneous connection speed, high performance, modern cryptography.\n\nIt's the recommended choise expecially if you use mobile devices where WireGuard is easier on battery than OpenVPN.\n\nOpenVPN is still available if you need the traditional, flexible, trusted VPN protocol. Or if you need features like TCP and custom search domain.\n\nChoose 'Yes' to use WireGuard or 'No' to use OpenVPN." ${r} ${c});
		then
			VPN="wireguard"
		else
			VPN="openvpn"
		fi
	fi

	if [ "$VPN" = "wireguard" ]; then
		pivpnPROTO="udp"
		pivpnDEV="wg0"
		pivpnNET="10.6.0.0"
	elif [ "$VPN" = "openvpn" ]; then
		pivpnDEV="tun0"
		pivpnNET="10.8.0.0"
	fi

	echo "VPN=${VPN}" >> /tmp/setupVars.conf
}

installOpenVPN(){
	echo "::: Installing OpenVPN from Debian package... "
	# grepcidr is used to redact IPs in the debug log, whereas expect is used
	# to feed easy-rsa with passwords
	PIVPN_DEPS=(openvpn grepcidr expect)
	installDependentPackages PIVPN_DEPS[@]
}

installWireGuard(){
	if [ "$PLAT" = "Raspbian" ]; then

		# If this Raspberry Pi uses armv7l we can use the package from the repo
		# https://lists.zx2c4.com/pipermail/wireguard/2017-November/001885.html
		# Otherwhise compile and build the kernel module via DKMS (so it will
		# be recompiled on kernel upgrades)

		if [ "$(uname -m)" = "armv7l" ]; then

			echo "::: Installing WireGuard from Debian package... "
			# dirmngr is used to download repository keys, whereas qrencode is used to generate qrcodes
			# from config file, for use with mobile clients
			PIVPN_DEPS=(dirmngr qrencode)
			installDependentPackages PIVPN_DEPS[@]
			# Do not upgrade packages from the unstable repository except for wireguard
			echo "::: Adding Debian repository... "
			echo "deb http://deb.debian.org/debian/ unstable main" | $SUDO tee /etc/apt/sources.list.d/unstable.list > /dev/null
			echo "Package: *
		Pin: release a=unstable
		Pin-Priority: 1

		Package: wireguard wireguard-dkms wireguard-tools
		Pin: release a=unstable
		Pin-Priority: 500" | $SUDO tee /etc/apt/preferences.d/limit-unstable > /dev/null

			$SUDO apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC 648ACFD622F3D138
			$SUDO ${UPDATE_PKG_CACHE} &> /dev/null
			PIVPN_DEPS=(raspberrypi-kernel-headers wireguard wireguard-tools wireguard-dkms)
			installDependentPackages PIVPN_DEPS[@]

		elif [ "$(uname -m)" = "armv6l" ]; then

			echo "::: Installing WireGuard from source... "
			PIVPN_DEPS=(checkinstall dkms libmnl-dev libelf-dev raspberrypi-kernel-headers build-essential pkg-config qrencode jq)
			installDependentPackages PIVPN_DEPS[@]

			WG_SNAPSHOT="$(curl -s https://build.wireguard.com/distros.json | jq -r '."upstream-kmodtools"."version"')"
			WG_SOURCE="https://git.zx2c4.com/WireGuard/snapshot/WireGuard-${WG_SNAPSHOT}.tar.xz"

			# Delete any leftover code
			$SUDO rm -rf /usr/src/wireguard-*

			echo "::: Downloading source code... "
			wget -qO- "${WG_SOURCE}" | $SUDO tar Jxf - --directory /usr/src
			echo "done!"

			cd /usr/src
			$SUDO mv WireGuard-"${WG_SNAPSHOT}" wireguard-"${WG_SNAPSHOT}"
			cd wireguard-"${WG_SNAPSHOT}"
			$SUDO mv src/* .
			$SUDO rmdir src

			# We install the userspace tools manually since DKMS only compiles and
			# installs the kernel module
			echo "::: Compiling WireGuard tools... "
			if $SUDO make tools; then
				echo "done!"
			else
				echo "failed!"
				exit 1
			fi

			# Use checkinstall to install userspace tools so if the user wants to uninstall
			# PiVPN we can just do apt remove wireguard-tools, instead of manually removing
			# files from the file system
			echo "::: Installing WireGuard tools... "
			if $SUDO checkinstall --pkgname wireguard-tools --pkgversion "${WG_SNAPSHOT}" -y make tools-install; then
				TO_INSTALL+=("wireguard-tools")
				echo "done!"
			else
				echo "failed!"
				exit 1
			fi

			echo "::: Adding WireGuard modules via DKMS... "
			if $SUDO dkms add wireguard/"${WG_SNAPSHOT}"; then
				echo "done!"
			else
				echo "failed!"
				$SUDO dkms remove wireguard/"${WG_SNAPSHOT}" --all
				exit 1
			fi

			echo "::: Compiling WireGuard modules via DKMS... "
			if $SUDO dkms build wireguard/"${WG_SNAPSHOT}"; then
				echo "done!"
			else
				echo "failed!"
				$SUDO dkms remove wireguard/"${WG_SNAPSHOT}" --all
				exit 1
			fi

			echo "::: Installing WireGuard modules via DKMS... "
			if $SUDO dkms install wireguard/"${WG_SNAPSHOT}"; then
				TO_INSTALL+=("wireguard-dkms")
				echo "done!"
			else
				echo "failed!"
				$SUDO dkms remove wireguard/"${WG_SNAPSHOT}" --all
				exit 1
			fi

			echo "WG_SNAPSHOT=${WG_SNAPSHOT}" >> /tmp/setupVars.conf

		fi

	elif [ "$PLAT" = "Debian" ]; then

		echo "::: Installing WireGuard from Debian package... "
		echo "::: Adding Debian repository... "
		echo "deb http://deb.debian.org/debian/ unstable main" | $SUDO tee /etc/apt/sources.list.d/unstable.list > /dev/null
		echo "Package: *
	Pin: release a=unstable
	Pin-Priority: 90" | $SUDO tee /etc/apt/preferences.d/limit-unstable > /dev/null
		$SUDO ${UPDATE_PKG_CACHE} &> /dev/null
		PIVPN_DEPS=(linux-headers-amd64 qrencode wireguard wireguard-tools wireguard-dkms)
		installDependentPackages PIVPN_DEPS[@]

	elif [ "$PLAT" = "Ubuntu" ]; then

		echo "::: Installing WireGuard from PPA... "
		$SUDO add-apt-repository ppa:wireguard/wireguard -y
		PIVPN_DEPS=(qrencode wireguard wireguard-tools wireguard-dkms)
		installDependentPackages PIVPN_DEPS[@]

	fi
}

askCustomProto(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$pivpnPROTO" ]; then
			echo "::: No TCP/IP protocol specified, using the default protocol udp"
			pivpnPROTO="udp"
		else
			pivpnPROTO="${pivpnPROTO,,}"
			if [ "$pivpnPROTO" = "udp" ] || [ "$pivpnPROTO" = "tcp" ]; then
				echo "::: Using the $pivpnPROTO protocol"
			else
				echo ":: $pivpnPROTO is not a supported TCP/IP protocol, please specify 'udp' or 'tcp'"
				exit 1
			fi
		fi
		echo "pivpnPROTO=${pivpnPROTO}" >> /tmp/setupVars.conf
		return
	fi

	# Set the available protocols into an array so it can be used with a whiptail dialog
	if pivpnPROTO=$(whiptail --title "Protocol" --radiolist \
		"Choose a protocol (press space to select). Please only choose TCP if you know why you need TCP." ${r} ${c} 2 \
		"UDP" "" ON \
		"TCP" "" OFF 3>&1 1>&2 2>&3)
	then
		# Convert option into lowercase (UDP->udp)
		pivpnPROTO="${pivpnPROTO,,}"
		echo "::: Using protocol: $pivpnPROTO"
		echo "pivpnPROTO=${pivpnPROTO}" >> /tmp/setupVars.conf
	else
		echo "::: Cancel selected, exiting...."
		exit 1
	fi
}

askCustomPort(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$pivpnPORT" ]; then
			if [ "$VPN" = "wireguard" ]; then
				echo "::: No port specified, using the default port 51820"
				pivpnPORT=51820
			elif [ "$VPN" = "openvpn" ]; then
				if [ "$pivpnPROTO" = "udp" ]; then
					echo "::: No port specified, using the default port 1194"
					pivpnPORT=1194
				elif [ "$pivpnPROTO" = "tcp" ]; then
					echo "::: No port specified, using the default port 443"
					pivpnPORT=443
				fi
			fi
		else
			if [[ "$pivpnPORT" =~ ^[0-9]+$ ]] && [ "$pivpnPORT" -ge 1 ] && [ "$pivpnPORT" -le 65535 ]; then
				echo "::: Using port $pivpnPORT"
			else
				echo "::: $pivpnPORT is not a valid port, use a port within the range [1,65535] (inclusive)"
				exit 1
			fi
		fi
		echo "pivpnPORT=${pivpnPORT}" >> /tmp/setupVars.conf
		return
	fi

	until [[ $PORTNumCorrect = True ]]
		do
			portInvalid="Invalid"

			if [ "$VPN" = "wireguard" ]; then
				DEFAULT_PORT=51820
			elif [ "$VPN" = "openvpn" ]; then
				if [ "$pivpnPROTO" = "udp" ]; then
					DEFAULT_PORT=1194
				else
					DEFAULT_PORT=443
				fi
			fi

			if pivpnPORT=$(whiptail --title "Default $VPN Port" --inputbox "You can modify the default $VPN port. \nEnter a new value or hit 'Enter' to retain the default" ${r} ${c} $DEFAULT_PORT 3>&1 1>&2 2>&3)
			then
				if [[ "$pivpnPORT" =~ ^[0-9]+$ ]] && [ "$pivpnPORT" -ge 1 ] && [ "$pivpnPORT" -le 65535 ]; then
					:
				else
					pivpnPORT=$portInvalid
				fi
			else
				echo "::: Cancel selected, exiting...."
				exit 1
			fi

			if [[ $pivpnPORT == "$portInvalid" ]]; then
				whiptail --msgbox --backtitle "Invalid Port" --title "Invalid Port" "You entered an invalid Port number.\n    Please enter a number from 1 - 65535.\n    If you are not sure, please just keep the default." ${r} ${c}
				PORTNumCorrect=False
			else
				if (whiptail --backtitle "Specify Custom Port" --title "Confirm Custom Port Number" --yesno "Are these settings correct?\n    PORT:   $pivpnPORT" ${r} ${c}) then
					PORTNumCorrect=True
				else
					# If the settings are wrong, the loop continues
					PORTNumCorrect=False
				fi
			fi
		done
	# write out the port
	echo "pivpnPORT=${pivpnPORT}" >> /tmp/setupVars.conf
}

askClientDNS(){
	if [ "${runUnattended}" = 'true' ]; then

		if [ -z "$pivpnDNS1" ] && [ -n "$pivpnDNS2" ]; then
			pivpnDNS1="$pivpnDNS2"
			unset pivpnDNS2
		elif [ -z "$pivpnDNS1" ] && [ -z "$pivpnDNS2" ]; then
			pivpnDNS1="8.8.8.8"
			pivpnDNS2="8.8.4.4"
			echo "::: No DNS provider specified, using Google DNS ($pivpnDNS1 $pivpnDNS2)"
		fi

		local INVALID_DNS_SETTINGS=0

		if ! validIP "$pivpnDNS1"; then
			INVALID_DNS_SETTINGS=1
			echo "::: Invalid DNS $pivpnDNS1"
		fi

		if [ -n "$pivpnDNS2" ] && ! validIP "$pivpnDNS2"; then
			INVALID_DNS_SETTINGS=1
			echo "::: Invalid DNS $pivpnDNS2"
		fi

		if [ "$INVALID_DNS_SETTINGS" -eq 0 ]; then
			echo "::: Using DNS $pivpnDNS1 $pivpnDNS2"
		else
			exit 1
		fi

		echo "pivpnDNS1=${pivpnDNS1}" >> /tmp/setupVars.conf
		echo "pivpnDNS2=${pivpnDNS2}" >> /tmp/setupVars.conf
		return
	fi

	# Detect and offer to use Pi-hole
	if command -v pihole &>/dev/null; then
		if (whiptail --backtitle "Setup PiVPN" --title "Pi-hole" --yesno "We have detected a Pi-hole installation, do you want to use it as the DNS server for the VPN, so you get ad blocking on the go?" ${r} ${c}); then
			pivpnDNS1="$IPv4addr"
			echo "interface=$pivpnDEV" | $SUDO tee /etc/dnsmasq.d/02-pivpn.conf > /dev/null
			$SUDO pihole restartdns
			echo "pivpnDNS1=${pivpnDNS1}" >> /tmp/setupVars.conf
			echo "pivpnDNS2=${pivpnDNS2}" >> /tmp/setupVars.conf
			return
		fi
	fi

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
			declare -A DNS_MAP=(["Google"]="8.8.8.8 8.8.4.4"
								["OpenDNS"]="208.67.222.222 208.67.220.220"
								["Level3"]="209.244.0.3 209.244.0.4"
								["DNS.WATCH"]="84.200.69.80 84.200.70.40"
								["Norton"]="199.85.126.10 199.85.127.10"
								["FamilyShield"]="208.67.222.123 208.67.220.123"
								["CloudFlare"]="1.1.1.1 1.0.0.1")

			pivpnDNS1=$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")
			pivpnDNS2=$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")

		else

			until [[ $DNSSettingsCorrect = True ]]; do
				strInvalid="Invalid"

				if pivpnDNS=$(whiptail --backtitle "Specify Upstream DNS Provider(s)" --inputbox "Enter your desired upstream DNS provider(s), separated by a comma.\n\nFor example '8.8.8.8, 8.8.4.4'" ${r} ${c} "" 3>&1 1>&2 2>&3)
				then
					pivpnDNS1=$(echo "$pivpnDNS" | sed 's/[, \t]\+/,/g' | awk -F, '{print$1}')
					pivpnDNS2=$(echo "$pivpnDNS" | sed 's/[, \t]\+/,/g' | awk -F, '{print$2}')
					if ! validIP "$pivpnDNS1" || [ ! "$pivpnDNS1" ]; then
						pivpnDNS1=$strInvalid
					fi
					if ! validIP "$pivpnDNS2" && [ "$pivpnDNS2" ]; then
						pivpnDNS2=$strInvalid
					fi
				else
					echo "::: Cancel selected, exiting...."
					exit 1
				fi

				if [[ $pivpnDNS1 == "$strInvalid" ]] || [[ $pivpnDNS2 == "$strInvalid" ]]; then
					whiptail --msgbox --backtitle "Invalid IP" --title "Invalid IP" "One or both entered IP addresses were invalid. Please try again.\n\n    DNS Server 1:   $pivpnDNS1\n    DNS Server 2:   $pivpnDNS2" ${r} ${c}
					if [[ $pivpnDNS1 == "$strInvalid" ]]; then
						pivpnDNS1=""
					fi
					if [[ $pivpnDNS2 == "$strInvalid" ]]; then
						pivpnDNS2=""
					fi
					DNSSettingsCorrect=False
				else
					if (whiptail --backtitle "Specify Upstream DNS Provider(s)" --title "Upstream DNS Provider(s)" --yesno "Are these settings correct?\n    DNS Server 1:   $pivpnDNS1\n    DNS Server 2:   $pivpnDNS2" ${r} ${c}) then
						DNSSettingsCorrect=True
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

	echo "pivpnDNS1=${pivpnDNS1}" >> /tmp/setupVars.conf
	echo "pivpnDNS2=${pivpnDNS2}" >> /tmp/setupVars.conf
}

#Call this function to use a regex to check user input for a valid custom domain
validDomain(){
  local domain=$1
  local stat=1

  if [[ $domain =~ ^(([a-zA-Z0-9]{1,63}|([a-zA-Z0-9]{1,60}[-a-zA-Z0-9()]{0,2}[a-zA-Z0-9]{1,60}))\.){1,6}([a-zA-Z]{2,})$ ]]; then
    stat=$?
  fi
  return $stat
}

#This procedure allows a user to specify a custom search domain if they have one.
askCustomDomain(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -n "$pivpnSEARCHDOMAIN" ]; then
			if validDomain "$pivpnSEARCHDOMAIN"; then
				echo "::: Using custom domain $pivpnSEARCHDOMAIN"
			else
				echo "::: Custom domain $pivpnSEARCHDOMAIN is not valid"
				exit 1
			fi
		else
			echo "::: Skipping custom domain"
		fi
		echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> /tmp/setupVars.conf
		return
	fi

	DomainSettingsCorrect=False

	if (whiptail --backtitle "Custom Search Domain" --title "Custom Search Domain" --yesno --defaultno "Would you like to add a custom search domain? \n (This is only for advanced users who have their own domain)\n" ${r} ${c}); then

		until [[ $DomainSettingsCorrect = True ]]
		do
			if pivpnSEARCHDOMAIN=$(whiptail --inputbox "Enter Custom Domain\nFormat: mydomain.com" ${r} ${c} --title "Custom Domain" 3>&1 1>&2 2>&3); then
				if validDomain "$pivpnSEARCHDOMAIN"; then
					if (whiptail --backtitle "Custom Search Domain" --title "Custom Search Domain" --yesno "Are these settings correct?\n    Custom Search Domain: $pivpnSEARCHDOMAIN" ${r} ${c}); then
						DomainSettingsCorrect=True
					else
						# If the settings are wrong, the loop continues
						DomainSettingsCorrect=False
					fi
				else
					whiptail --msgbox --backtitle "Invalid Domain" --title "Invalid Domain" "Domain is invalid. Please try again.\n\n    DOMAIN:   $pivpnSEARCHDOMAIN\n" ${r} ${c}
					DomainSettingsCorrect=False
				fi
			else
				echo "::: Cancel selected. Exiting..."
				exit 1
			fi
		done
	fi

	echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> /tmp/setupVars.conf
}

askPublicIPOrDNS(){
	if ! IPv4pub=$(dig +short myip.opendns.com @208.67.222.222) || ! validIP "$IPv4pub"; then
		echo "dig failed, now trying to curl checkip.amazonaws.com"
		if ! IPv4pub=$(curl -s https://checkip.amazonaws.com) || ! validIP "$IPv4pub"; then
			echo "checkip.amazonaws.com failed, please check your internet connection/DNS"
			exit 1
		fi
	fi

	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$pivpnHOST" ]; then
			echo "::: No IP or domain name specified, using public IP $IPv4pub"
			pivpnHOST="$IPv4pub"
		else
			if validIP "$pivpnHOST"; then
				echo "::: Using public IP $pivpnHOST"
			elif validDomain "$pivpnHOST"; then
				echo "::: Using domain name $pivpnHOST"
			else
				echo "::: $pivpnHOST is not a valid IP or domain name"
				exit 1
			fi
		fi
		echo "pivpnHOST=${pivpnHOST}" >> /tmp/setupVars.conf
		return
	fi

	METH=$(whiptail --title "Public IP or DNS" --radiolist "Will clients use a Public IP or DNS Name to connect to your server (press space to select)?" ${r} ${c} 2 \
		"$IPv4pub" "Use this public IP" "ON" \
		"DNS Entry" "Use a public DNS" "OFF" 3>&1 1>&2 2>&3)

	exitstatus=$?
	if [ $exitstatus != 0 ]; then
		echo "::: Cancel selected. Exiting..."
		exit 1
	fi

	if [ "$METH" == "$IPv4pub" ]; then
		pivpnHOST="${IPv4pub}"
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
				pivpnHOST="${PUBLICDNS}"
			else
				publicDNSCorrect=False
			fi
		done
	fi

	echo "pivpnHOST=${pivpnHOST}" >> /tmp/setupVars.conf
}

askEncryption(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$pivpnENCRYPT" ]; then
			pivpnENCRYPT=2048
			echo "::: Using a 2048 bit certificate"
		else
			if [ "$pivpnENCRYPT" -eq 2048 ] || [ "$pivpnENCRYPT" -eq 3072 ] || [ "$pivpnENCRYPT" -eq 4096 ]; then
				echo "::: Using a ${pivpnENCRYPT}-bit certificate"
			else
				echo "::: ${pivpnENCRYPT} is not a valid certificate size, use 2048, 3072, or 4096"
				exit 1
			fi
		fi

		if [ -z "$DOWNLOAD_DH_PARAM" ] || [ "$DOWNLOAD_DH_PARAM" -ne 1 ]; then
			DOWNLOAD_DH_PARAM=0
			echo "::: DH parameters will be generated locally"
		else
			echo "::: DH parameters will be downloaded from \"2 Ton Digital\""
		fi

		echo "pivpnENCRYPT=${pivpnENCRYPT}" >> /tmp/setupVars.conf
		echo "DOWNLOAD_DH_PARAM=${DOWNLOAD_DH_PARAM}" >> /tmp/setupVars.conf
		return
	fi

	pivpnENCRYPT=$(whiptail --backtitle "Setup OpenVPN" --title "RSA certificate size" --radiolist \
		"Choose the desired size of your certificate (press space to select):\nThis is a certificate that will be generated on your system. The larger the certificate, the more time this will take. For most applications, it is recommended to use 2048 bits. If you are paranoid about ... things... then grab a cup of joe and pick 4096 bits." ${r} ${c} 3 \
			"2048" "Use a 2048-bit certificate (recommended level)" ON \
			"3072" "Use a 3072-bit certificate " OFF \
			"4096" "Use a 4096-bit certificate (paranoid level)" OFF 3>&1 1>&2 2>&3)

	exitstatus=$?
	if [ $exitstatus != 0 ]; then
		echo "::: Cancel selected. Exiting..."
		exit 1
	fi

	if ([ "$pivpnENCRYPT" -ge "3072" ] && whiptail --backtitle "Setup OpenVPN" --title "Download Diffie-Hellman Parameters" --yesno --defaultno "Download Diffie-Hellman parameters from a public DH parameter generation service?\n\nGenerating DH parameters for a $pivpnENCRYPT-bit key can take many hours on a Raspberry Pi. You can instead download DH parameters from \"2 Ton Digital\" that are generated at regular intervals as part of a public service. Downloaded DH parameters will be randomly selected from their database.\nMore information about this service can be found here: https://2ton.com.au/safeprimes/\n\nIf you're paranoid, choose 'No' and Diffie-Hellman parameters will be generated on your device." ${r} ${c}); then
		DOWNLOAD_DH_PARAM=1
	else
		DOWNLOAD_DH_PARAM=0
	fi

	echo "pivpnENCRYPT=${pivpnENCRYPT}" >> /tmp/setupVars.conf
	echo "DOWNLOAD_DH_PARAM=${DOWNLOAD_DH_PARAM}" >> /tmp/setupVars.conf
}

confOpenVPN(){
	# Grab the existing Hostname
	host_name=$(hostname -s)
	# Generate a random UUID for this server so that we can use verify-x509-name later that is unique for this server installation.
	NEW_UUID=$(</proc/sys/kernel/random/uuid)
	# Create a unique server name using the host name and UUID
	SERVER_NAME="${host_name}_${NEW_UUID}"

	# Backup the openvpn folder
	OPENVPN_BACKUP="openvpn_$(date +%Y-%m-%d-%H%M%S).tar.gz"
	echo "::: Backing up the openvpn folder to /etc/${OPENVPN_BACKUP}"
	$SUDO tar czf "/etc/${OPENVPN_BACKUP}" /etc/openvpn &> /dev/null

	if [ -f /etc/openvpn/server.conf ]; then
		$SUDO rm /etc/openvpn/server.conf
	fi

	# If easy-rsa exists, remove it
	if [[ -d /etc/openvpn/easy-rsa/ ]]; then
		$SUDO rm -rf /etc/openvpn/easy-rsa/
	fi

	# Get easy-rsa
	wget -qO- "${easyrsaRel}" | $SUDO tar xz -C /etc/openvpn
	$SUDO mv /etc/openvpn/EasyRSA-v${easyrsaVer} /etc/openvpn/easy-rsa
	# fix ownership
	$SUDO chown -R root:root /etc/openvpn/easy-rsa
	$SUDO mkdir /etc/openvpn/easy-rsa/pki
	$SUDO chmod 700 /etc/openvpn/easy-rsa/pki

	cd /etc/openvpn/easy-rsa || exit

	# Write out new vars file
	echo "if [ -z \"\$EASYRSA_CALLER\" ]; then
	echo \"Nope.\" >&2
	return 1
fi
set_var EASYRSA            \"/etc/openvpn/easy-rsa\"
set_var EASYRSA_PKI        \"\$EASYRSA/pki\"
set_var EASYRSA_CRL_DAYS   3650
set_var EASYRSA_ALGO       rsa
set_var EASYRSA_KEY_SIZE   ${pivpnENCRYPT}" | $SUDO tee vars >/dev/null

	# Remove any previous keys
	${SUDOE} ./easyrsa --batch init-pki

	# Build the certificate authority
	printf "::: Building CA...\n"
	${SUDOE} ./easyrsa --batch build-ca nopass
	printf "\n::: CA Complete.\n"

	if [ "${runUnattended}" = 'true' ]; then
		echo "::: The server key, Diffie-Hellman parameters, and HMAC key will now be generated."
	else
		whiptail --msgbox --backtitle "Setup OpenVPN" --title "Server Information" "The server key, Diffie-Hellman parameters, and HMAC key will now be generated." ${r} ${c}
	fi

	# Build the server
	EASYRSA_CERT_EXPIRE=3650 ${SUDOE} ./easyrsa build-server-full ${SERVER_NAME} nopass

	if [ ${DOWNLOAD_DH_PARAM} -eq 1 ]; then
		# Downloading parameters
		${SUDOE} curl -s "https://2ton.com.au/getprimes/random/dhparam/${pivpnENCRYPT}" -o "/etc/openvpn/easy-rsa/pki/dh${pivpnENCRYPT}.pem"
	else
		# Generate Diffie-Hellman key exchange
		${SUDOE} ./easyrsa gen-dh
		${SUDOE} mv pki/dh.pem pki/dh${pivpnENCRYPT}.pem
	fi

	# Generate static HMAC key to defend against DDoS
	${SUDOE} openvpn --genkey --secret pki/ta.key

	# Generate an empty Certificate Revocation List
	${SUDOE} ./easyrsa gen-crl
	${SUDOE} cp pki/crl.pem /etc/openvpn/crl.pem
	${SUDOE} chown nobody:nogroup /etc/openvpn/crl.pem

	# Write config file for server using the template.txt file
	$SUDO cp /etc/.pivpn/server_config.txt /etc/openvpn/server.conf

	# Apply client DNS settings
	${SUDOE} sed -i '0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1'${pivpnDNS1}'\"/' /etc/openvpn/server.conf

	if [ -z ${pivpnDNS2} ]; then
		${SUDOE} sed -i '/\(dhcp-option DNS \)/{n;N;d}' /etc/openvpn/server.conf
	else
		${SUDOE} sed -i '0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1'${pivpnDNS2}'\"/' /etc/openvpn/server.conf
	fi

	# Set the user encryption key size
	$SUDO sed -i "s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/\1${pivpnENCRYPT}.pem/" /etc/openvpn/server.conf

	# if they modified port put value in server.conf
	if [ "$pivpnPORT" != 1194 ]; then
		$SUDO sed -i "s/1194/${pivpnPORT}/g" /etc/openvpn/server.conf
	fi

	# if they modified protocol put value in server.conf
	if [ "$pivpnPROTO" != "udp" ]; then
		$SUDO sed -i "s/proto udp/proto tcp/g" /etc/openvpn/server.conf
	fi

	if [ -n "$pivpnSEARCHDOMAIN" ]; then
		$SUDO sed -i "0,/\(.*dhcp-option.*\)/s//\push \"dhcp-option DOMAIN ${pivpnSEARCHDOMAIN}\" \n&/" /etc/openvpn/server.conf
	fi

	# write out server certs to conf file
	$SUDO sed -i "s/\(key \/etc\/openvpn\/easy-rsa\/pki\/private\/\).*/\1${SERVER_NAME}.key/" /etc/openvpn/server.conf
	$SUDO sed -i "s/\(cert \/etc\/openvpn\/easy-rsa\/pki\/issued\/\).*/\1${SERVER_NAME}.crt/" /etc/openvpn/server.conf
}

confOVPN(){
	$SUDO cp /etc/.pivpn/Default.txt /etc/openvpn/easy-rsa/pki/Default.txt

	$SUDO sed -i 's/IPv4pub/'"$pivpnHOST"'/' /etc/openvpn/easy-rsa/pki/Default.txt

	# if they modified port put value in Default.txt for clients to use
	if [ "$pivpnPORT" != 1194 ]; then
		$SUDO sed -i -e "s/1194/${pivpnPORT}/g" /etc/openvpn/easy-rsa/pki/Default.txt
	fi

	# if they modified protocol put value in Default.txt for clients to use
	if [ "$pivpnPROTO" != "udp" ]; then
		$SUDO sed -i -e "s/proto udp/proto tcp/g" /etc/openvpn/easy-rsa/pki/Default.txt
	fi

	# verify server name to strengthen security
	$SUDO sed -i "s/SRVRNAME/${SERVER_NAME}/" /etc/openvpn/easy-rsa/pki/Default.txt
}

confWireGuard(){
	if [ -d /etc/wireguard ]; then
		# Backup the wireguard folder
		WIREGUARD_BACKUP="wireguard_$(date +%Y-%m-%d-%H%M%S).tar.gz"
		echo "::: Backing up the wireguard folder to /etc/${WIREGUARD_BACKUP}"
		$SUDO tar czf "/etc/${WIREGUARD_BACKUP}" /etc/wireguard &> /dev/null

		if [ -f /etc/wireguard/wg0.conf ]; then
			$SUDO rm /etc/wireguard/wg0.conf
		fi
	else
		# If compiled from source, the wireguard folder is not being created
		$SUDO mkdir /etc/wireguard
	fi

	# Ensure that only root is able to enter the wireguard folder
	$SUDO chown root:root /etc/wireguard
	$SUDO chmod 700 /etc/wireguard

	if [ "${runUnattended}" = 'true' ]; then
		echo "::: The Server Keys and Pre-Shared key will now be generated."
	else
		whiptail --title "Server Information" --msgbox "The Server Keys and Pre-Shared key will now be generated." "${r}" "${c}"
	fi
	$SUDO mkdir -p /etc/wireguard/configs
	$SUDO touch /etc/wireguard/configs/clients.txt
	$SUDO mkdir -p /etc/wireguard/keys

	# Generate private key and derive public key from it
	wg genkey | $SUDO tee /etc/wireguard/keys/server_priv &> /dev/null
	wg genpsk | $SUDO tee /etc/wireguard/keys/psk &> /dev/null
	$SUDO cat /etc/wireguard/keys/server_priv | wg pubkey | $SUDO tee /etc/wireguard/keys/server_pub &> /dev/null

	echo "::: Server Keys and Pre-Shared Key have been generated."

	echo "[Interface]
PrivateKey = $($SUDO cat /etc/wireguard/keys/server_priv)
Address = 10.6.0.1/24
ListenPort = ${pivpnPORT}" | $SUDO tee /etc/wireguard/wg0.conf &> /dev/null
	echo "::: Server config generated."
}

confNetwork(){
	# Enable forwarding of internet traffic
	$SUDO sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
	$SUDO sysctl -p > /dev/null

	# if ufw enabled, configure that (running as root because sometimes the executable is not in the user's $PATH, on Debian for example)
	if $SUDO bash -c 'hash ufw' 2>/dev/null; then
		if LANG=en_US.UTF-8 $SUDO ufw status | grep -q inactive
		then
			USING_UFW=0
		else
			USING_UFW=1
			echo "::: Detected UFW is enabled."
			echo "::: Adding UFW rules..."
			$SUDO sed "/delete these required/i *nat\n:POSTROUTING ACCEPT [0:0]\n-I POSTROUTING -s ${pivpnNET}\/24 -o ${IPv4dev} -j MASQUERADE\nCOMMIT\n" -i /etc/ufw/before.rules
			# Insert rules at the beginning of the chain (in case there are other rules that may drop the traffic)
			$SUDO ufw insert 1 allow "${pivpnPORT}"/"${pivpnPROTO}" >/dev/null
			$SUDO ufw route insert 1 allow in on "${pivpnDEV}" from "${pivpnNET}/24" out on "${IPv4dev}" to any >/dev/null

			$SUDO ufw reload >/dev/null
			echo "::: UFW configuration completed."
		fi
	else
		USING_UFW=0
	fi
	# else configure iptables
	if [[ $USING_UFW -eq 0 ]]; then
		# Now some checks to detect which rules we need to add. On a newly installed system all policies
		# should be ACCEPT, so the only required rule would be the MASQUERADE one.

		$SUDO iptables -t nat -I POSTROUTING -s "${pivpnNET}/24" -o "${IPv4dev}" -j MASQUERADE

		# Count how many rules are in the INPUT and FORWARD chain. When parsing input from
		# iptables -S, '^-P' skips the policies and 'ufw-' skips ufw chains (in case ufw was found
		# installed but not enabled).

		# Grep returns non 0 exit code where there are no matches, however that would make the script exit,
		# for this reasons we use '|| true' to force exit code 0
		INPUT_RULES_COUNT="$($SUDO iptables -S INPUT | grep -vcE '(^-P|ufw-)')"
		FORWARD_RULES_COUNT="$($SUDO iptables -S FORWARD | grep -vcE '(^-P|ufw-)')"

		INPUT_POLICY="$($SUDO iptables -S INPUT | grep '^-P' | awk '{print $3}')"
		FORWARD_POLICY="$($SUDO iptables -S FORWARD | grep '^-P' | awk '{print $3}')"

		# If rules count is not zero, we assume we need to explicitly allow traffic. Same conclusion if
		# there are no rules and the policy is not ACCEPT. Note that rules are being added to the top of the
		# chain (using -I).

		if [ "$INPUT_RULES_COUNT" -ne 0 ] || [ "$INPUT_POLICY" != "ACCEPT" ]; then
			$SUDO iptables -I INPUT 1 -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT
			INPUT_CHAIN_EDITED=1
		else
			INPUT_CHAIN_EDITED=0
		fi

		if [ "$FORWARD_RULES_COUNT" -ne 0 ] || [ "$FORWARD_POLICY" != "ACCEPT" ]; then
			$SUDO iptables -I FORWARD 1 -d "${pivpnNET}/24" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
			$SUDO iptables -I FORWARD 2 -s "${pivpnNET}/24" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT
			FORWARD_CHAIN_EDITED=1
		else
			FORWARD_CHAIN_EDITED=0
		fi

		case ${PLAT} in
			Debian|Raspbian|Ubuntu)
				$SUDO iptables-save | $SUDO tee /etc/iptables/rules.v4 > /dev/null
			;;
		esac

		echo "INPUT_CHAIN_EDITED=${INPUT_CHAIN_EDITED}" >> /tmp/setupVars.conf
		echo "FORWARD_CHAIN_EDITED=${FORWARD_CHAIN_EDITED}" >> /tmp/setupVars.conf
	fi

	echo "USING_UFW=${USING_UFW}" >> /tmp/setupVars.conf
}

confLogging() {
	echo "if \$programname == 'ovpn-server' then /var/log/openvpn.log
if \$programname == 'ovpn-server' then stop" | $SUDO tee /etc/rsyslog.d/30-openvpn.conf > /dev/null

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
		Debian|Raspbian|Ubuntu)
			$SUDO systemctl restart rsyslog.service || true
		;;
	esac
}

installPiVPN(){
	$SUDO mkdir -p /etc/pivpn/
	askWhichVPN

	if [ "$VPN" = "openvpn" ]; then
		installOpenVPN
		askCustomProto
		askCustomPort
		askClientDNS
		askCustomDomain
		askPublicIPOrDNS
		askEncryption
		confOpenVPN
		confOVPN
		confNetwork
		confLogging
	elif [ "$VPN" = "wireguard" ]; then
		installWireGuard
		askCustomPort
		askClientDNS
		askPublicIPOrDNS
		confWireGuard
		confNetwork
	fi
}

askUnattendedUpgrades(){
	if [ "${runUnattended}" = 'true' ]; then
		if [ -z "$UNATTUPG" ]; then
			UNATTUPG=1
			echo "::: No preference regarding unattended upgrades, assuming yes"
		else
			if [ "$UNATTUPG" -eq 1 ]; then
				echo "::: Enabling unattended upgrades"
			else
				echo "::: Skipping unattended upgrades"
			fi
		fi
		echo "UNATTUPG=${UNATTUPG}" >> /tmp/setupVars.conf
		return
	fi

	whiptail --msgbox --backtitle "Security Updates" --title "Unattended Upgrades" "Since this server will have at least one port open to the internet, it is recommended you enable unattended-upgrades.\nThis feature will check daily for security package updates only and apply them when necessary.\nIt will NOT automatically reboot the server so to fully apply some updates you should periodically reboot." ${r} ${c}

	if (whiptail --backtitle "Security Updates" --title "Unattended Upgrades" --yesno "Do you want to enable unattended upgrades of security patches to this server?" ${r} ${c}); then
		UNATTUPG=1
	else
		UNATTUPG=0
	fi

	echo "UNATTUPG=${UNATTUPG}" >> /tmp/setupVars.conf
}

confUnattendedUpgrades(){
	PIVPN_DEPS=(unattended-upgrades)
	installDependentPackages PIVPN_DEPS[@]

	cd /etc/apt/apt.conf.d

	if [ "$PLAT" = "Ubuntu" ]; then

		# Ubuntu 50unattended-upgrades should already just have security enabled
		# so we just need to configure the 10periodic file
		echo "APT::Periodic::Update-Package-Lists \"1\";
	APT::Periodic::Download-Upgradeable-Packages \"1\";
	APT::Periodic::AutocleanInterval \"5\";
	APT::Periodic::Unattended-Upgrade \"1\";" | $SUDO tee 10periodic > /dev/null

	else

		# Fix Raspbian config
		if [ "$PLAT" = "Raspbian" ]; then
			wget -qO- "$UNATTUPG_CONFIG" | $SUDO tar xz
			$SUDO cp "unattended-upgrades-$UNATTUPG_RELEASE/data/50unattended-upgrades.Raspbian" 50unattended-upgrades
			$SUDO rm -rf "unattended-upgrades-$UNATTUPG_RELEASE"
		fi

		# Add the remaining settings for all other distributions
		echo "APT::Periodic::Enable \"1\";
	APT::Periodic::Update-Package-Lists \"1\";
	APT::Periodic::Download-Upgradeable-Packages \"1\";
	APT::Periodic::Unattended-Upgrade \"1\";
	APT::Periodic::AutocleanInterval \"7\";
	APT::Periodic::Verbose \"0\";" | $SUDO tee 02periodic > /dev/null

	fi

	# Enable automatic updates via the unstable repository when installing from debian package
	if [ "$VPN" = "wireguard" ] && [ "$PLAT" != "Ubuntu" ] && [ "$(uname -m)" != "armv6l" ]; then
		if ! grep -q '"o=Debian,a=unstable";' 50unattended-upgrades; then
			$SUDO sed -i '/Unattended-Upgrade::Origins-Pattern {/a"o=Debian,a=unstable";' 50unattended-upgrades
		fi
	fi
}

installScripts(){
	# Install the scripts from /etc/.pivpn to their various locations
	echo ":::"
	echo -n "::: Installing scripts to /opt/pivpn..."
	if [ ! -d /opt/pivpn ]; then
		$SUDO mkdir /opt/pivpn
		$SUDO chown root:root /opt/pivpn
		$SUDO chmod 0755 /opt/pivpn
	fi

	$SUDO cp /etc/.pivpn/scripts/uninstall.sh /opt/pivpn/
	$SUDO cp /etc/.pivpn/scripts/$VPN/*.sh /opt/pivpn/
	$SUDO chmod 0755 /opt/pivpn/*.sh
	$SUDO cp /etc/.pivpn/scripts/$VPN/pivpn /usr/local/bin/pivpn
	$SUDO chmod 0755 /usr/local/bin/pivpn
	$SUDO cp /etc/.pivpn/scripts/$VPN/bash-completion /etc/bash_completion.d/pivpn
	. /etc/bash_completion.d/pivpn
	echo " done."
}

displayFinalMessage(){
	if [ "${runUnattended}" = 'true' ]; then
		echo "::: Installation Complete!"
		echo "::: Now run 'pivpn add' to create the ovpn profiles."
		echo "::: Run 'pivpn help' to see what else you can do!"
		echo
		echo "::: If you run into any issue, please read all our documentation carefully."
		echo "::: All incomplete posts or bug reports will be ignored or deleted."
		echo
		echo "::: Thank you for using PiVPN."
		echo "::: It is strongly recommended you reboot after installation."
		return
	fi

	# Final completion message to user
	whiptail --msgbox --backtitle "Make it so." --title "Installation Complete!" "Now run 'pivpn add' to create the ovpn profiles.
Run 'pivpn help' to see what else you can do!\n\nIf you run into any issue, please read all our documentation carefully.
All incomplete posts or bug reports will be ignored or deleted.\n\nThank you for using PiVPN." ${r} ${c}
	if (whiptail --title "Reboot" --yesno --defaultno "It is strongly recommended you reboot after installation.  Would you like to reboot now?" ${r} ${c}); then
		whiptail --title "Rebooting" --msgbox "The system will now reboot." ${r} ${c}
		printf "\nRebooting system...\n"
		$SUDO sleep 3
		$SUDO shutdown -r now
	fi
}

######## SCRIPT ############

main(){

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

	# Check arguments for the undocumented flags
	for var in "$@"; do
		case "$var" in
			"--i_do_not_follow_recommendations"   ) skipSpaceCheck=false;;
			"--unattended"     ) runUnattended=true;;
		esac
	done

	# Check for supported distribution
	distroCheck

	# Checks for hostname Length
	checkHostname

	if [[ "${runUnattended}" == true ]]; then
		echo "::: --unattended passed to install script, no whiptail dialogs will be displayed"
		if [ -z "$2" ]; then
			echo "::: No configuration file passed, using default settings..."
		else
			if [ -r "$2" ]; then
				source "$2"
			else
				echo "::: Can't open $2"
				exit 1
			fi
		fi
	fi

	# Start the installer
	# Verify there is enough disk space for the install
	if [[ "${skipSpaceCheck}" == true ]]; then
		echo "::: --i_do_not_follow_recommendations passed to script, skipping free disk space verification!"
	else
		verifyFreeDiskSpace
	fi

	updatePackageCache

	# Notify user of package availability
	notifyPackageUpdatesAvailable

	# Install packages used by this installation script
	preconfigurePackages
	installDependentPackages BASE_DEPS[@]

	# Display welcome dialogs
	welcomeDialogs

	# Find interfaces and let the user choose one
	chooseInterface

	if [ "$PLAT" != "Raspbian" ]; then
		avoidStaticIPv4Ubuntu
	else
		getStaticIPv4Settings
		setStaticIPv4
	fi

	# Choose the user for the ovpns
	chooseUser

	# Clone/Update the repos
	cloneOrUpdateRepos

	# Install
	if installPiVPN; then
		echo "::: Install Complete..."
	else
		exit 1
	fi

	echo "::: Restarting services..."
	# Start services
	case ${PLAT} in
		Debian|Raspbian|Ubuntu)
			if [ "$VPN" = "openvpn" ]; then
				$SUDO systemctl enable openvpn.service &> /dev/null
				$SUDO systemctl start openvpn.service
			elif [ "$VPN" = "wireguard" ]; then
				$SUDO systemctl enable wg-quick@wg0.service &> /dev/null
				$SUDO systemctl start wg-quick@wg0.service
			fi
		;;
	esac

	# Ask if unattended-upgrades will be enabled
	askUnattendedUpgrades

	if [ "$UNATTUPG" -eq 1 ]; then
		confUnattendedUpgrades
	fi

	# Save installation setting to the final location
	echo "TO_INSTALL=(${TO_INSTALL[*]})" >> /tmp/setupVars.conf
	$SUDO cp /tmp/setupVars.conf "$setupVars"

	installScripts

	# Ensure that cached writes reach persistent storage
	echo "::: Flushing writes to disk..."
	sync
	echo "::: done."

	displayFinalMessage
	echo ":::"
}

main "$@"
