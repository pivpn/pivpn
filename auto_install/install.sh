#!/usr/bin/env bash
# PiVPN: Trivial OpenVPN or WireGuard setup and configuration
# Easiest setup and mangement of OpenVPN or WireGuard on Raspberry Pi
# https://pivpn.io
# Heavily adapted from the pi-hole.net project and...
# https://github.com/StarshipEngineer/OpenVPN-Setup/
#
# Install with this command (from your Pi):
#
# curl -sSfL https://install.pivpn.io | bash
# Make sure you have `curl` installed

######## VARIABLES #########
pivpnGitUrl='https://github.com/pivpn/pivpn.git'
# Uncomment to checkout a custom branch for local pivpn files
#pivpnGitBranch='custombranchtocheckout'
setupVarsFile='setupVars.conf'
setupConfigDir='/etc/pivpn'
tempsetupVarsFile='/tmp/setupVars.conf'
pivpnFilesDir='/usr/local/src/pivpn'
pivpnScriptDir='/opt/pivpn'

piholeSetupVars='/etc/pihole/setupVars.conf'
dnsmasqConfig='/etc/dnsmasq.d/02-pivpn.conf'

dhcpcdFile='/etc/dhcpcd.conf'
debianOvpnUserGroup='openvpn:openvpn'

######## PKG Vars ########
PKG_MANAGER='apt-get'
### FIXME: quoting UPDATE_PKG_CACHE and PKG_INSTALL hangs the script, shellcheck SC2086
UPDATE_PKG_CACHE="${PKG_MANAGER} update -y"
PKG_INSTALL="${PKG_MANAGER} --yes --no-install-recommends install"
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -csEe '^Inst' || true"

# Dependencies that are required by the script, regardless of the VPN protocol chosen
BASE_DEPS=(git tar curl grep dnsutils grepcidr whiptail net-tools bsdmainutils bash-completion)

# Dependencies that where actually installed by the script. For example if the script requires
# grep and dnsutils but dnsutils is already installed, we save grep here. This way when uninstalling
# PiVPN we won't prompt to remove packages that may have been installed by the user for other reasons
INSTALLED_PACKAGES=()

######## URLs ########
easyrsaVer='3.1.0'
easyrsaRel="https://github.com/OpenVPN/easy-rsa/releases/download/v${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"

######## Undocumented Flags. Shhh ########
runUnattended=false
skipSpaceCheck=false
reconfigure=false
showUnsupportedNICs=false

######## Some vars that might be empty
# but need to be defined for checks
pivpnPERSISTENTKEEPALIVE=''
pivpnDNS2=''

######## IPv6 related config
# cli parameter '--noipv6' allows to disable IPv6 which also prevents forced IPv6 route
# cli parameter '--ignoreipv6leak' allows to skip the forced IPv6 route if required (not recommended)

## Force IPv6 through VPN even if IPv6 is not supported by the server
## This will prevent an IPv6 leak on the client site but might cause
## issues on the client site accessing IPv6 addresses.
## This option is useless if routes are set manually.
## It's also irrelevant when IPv6 is (forced) enabled.
pivpnforceipv6route=1

## Enable or disable IPv6.
## Leaving it empty or set to 1 will trigger an IPv6 uplink check
pivpnenableipv6=1

## Enable to skip IPv6 connectivity check and also force client IPv6 traffic through wireguard
## regardless if there is a working IPv6 route on the server.
pivpnforceipv6=0

######## SCRIPT ########

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || \
	echo 24 80)
rows=$(echo "$screen_size" | \
	awk '{print $1}')
columns=$(echo "$screen_size" | \
	awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

# Override localization settings so the output is in English language.
export LC_ALL=C

main() {
	# Pre install checks and configs
	rootCheck
	flagsCheck "$@"
	unattendedCheck
	checkExistingInstall "$@"
	distroCheck
	checkHostname

	# Verify there is enough disk space for the install
	if [ "${skipSpaceCheck}" == true ]
	then
		echo '::: --skip-space-check passed to script, skipping free disk space verification!'
	else
		verifyFreeDiskSpace
	fi

	updatePackageCache
	notifyPackageUpdatesAvailable
	preconfigurePackages
	installDependentPackages "${BASE_DEPS[@]}"
	welcomeDialogs

	if [ $pivpnforceipv6 -eq 1 ]
	then
		echo '::: Forced IPv6 config, skipping IPv6 uplink check!'
		pivpnenableipv6=1
	else
		[ $pivpnenableipv6 -eq 1 ] && \
			checkipv6uplink

		[ $pivpnenableipv6 -eq 0 ] && \
			[ $pivpnforceipv6route -eq 1 ] && \
			askforcedipv6route
	fi
	
	chooseInterface

	if checkStaticIpSupported
	then
		getStaticIPv4Settings

		if [ -z "${dhcpReserv}" ] || \
			[ $dhcpReserv -ne 1 ]
		then
			setStaticIPv4
		fi
	else
		staticIpNotSupported
	fi

	chooseUser
	cloneOrUpdateRepos

	# Install
	installPiVPN && \
		echo '::: Install Complete...' || \
		exit 1

	restartServices

	# Ask if unattended-upgrades will be enabled
	askUnattendedUpgrades

	[ $UNATTUPG -eq 1 ] && \
		confUnattendedUpgrades

	writeConfigFiles
	installScripts
	displayFinalMessage
	echo ':::'
}

####### FUNCTIONS ##########

rootCheck() {
	######## FIRST CHECK ########
	# Must be root to install
	echo ':::'

	if [ $EUID -eq 0 ]
	then
		echo '::: You are root.'
	else
		echo '::: sudo will be used for the install.'
		
		# Check if it is actually installed
		# If it isn't, exit because the install cannot complete
		if dpkg-query -s sudo
		then
			export SUDO='sudo'
			export SUDOE='sudo -E'
		else
			echo '::: Please install sudo or run this as root.'
			exit 1
		fi
	fi
}

flagsCheck() {
	# Check arguments for the undocumented flags
	for ((i=1; i <= "$#"; i++))
	do
		j=$((i+1))

		case "${!i}" in
			--skip-space-check)
				skipSpaceCheck=true
				;;
			--unattended)
				runUnattended=true
				unattendedConfig="${!j}"
				;;
			--reconfigure)
				reconfigure=true
				;;
			--show-unsupported-nics)
				showUnsupportedNICs=true
				;;
			--giturl)
				pivpnGitUrl="${!j}"
				;;
			--gitbranch)
				pivpnGitBranch="${!j}"
				;;
			--noipv6)
				pivpnforceipv6=0
				pivpnenableipv6=0
				pivpnforceipv6route=0
				;;
			--ignoreipv6leak)
				pivpnforceipv6route=0
				;;
		esac
	done
}

unattendedCheck() {
	if [ "${runUnattended}" == true ]
	then
		echo '::: --unattended passed to install script, no whiptail dialogs will be displayed'

		if [ -z "${unattendedConfig}" ]
		then
			echo '::: No configuration file passed'
			exit 1
		else
			if [ -r "${unattendedConfig}" ]
			then
				# shellcheck disable=SC1090
				source "${unattendedConfig}"
			else
				echo "::: Can't open ${unattendedConfig}"
				exit 1
			fi
		fi
	fi
}

checkExistingInstall() {
  # see which setup already exists
	[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ] && \
    	setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"

	[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ] && \
    	setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"

	if [ -r "${setupVars}" ]
	then
		if [ "${reconfigure}" == true ]
		then
			echo '::: --reconfigure passed to install script, will reinstall PiVPN overwriting existing settings'
			UpdateCmd='Reconfigure'
		elif [ "${runUnattended}" == true ]
		then
			### What should the script do when passing --unattended to an existing installation?
			UpdateCmd='Reconfigure'
		else
			askAboutExistingInstall "${setupVars}"
		fi
	fi

	if [ -z "${UpdateCmd}" ] || \
		[ "${UpdateCmd}" == 'Reconfigure' ]
	then
		:
	elif [ "${UpdateCmd}" == 'Update' ]
	then
		"${SUDO}" "${pivpnScriptDir}/update.sh" "$@"
		exit "$?"
	elif [ "${UpdateCmd}" == 'Repair' ]
	then
		# shellcheck disable=SC1090
		source "${setupVars}"
		runUnattended=true
	fi
}

askAboutExistingInstall() {
	opt1a='Update'
	opt1b='Get the latest PiVPN scripts'

	opt2a='Repair'
	opt2b='Reinstall PiVPN using existing settings'

	opt3a='Reconfigure'
	opt3b='Reinstall PiVPN with new settings'

	if ! UpdateCmd=$(whiptail --title 'Existing Install Detected!' --menu "\nWe have detected an existing install.\n$1\n\nPlease choose from the following options (Reconfigure can be used to add a second VPN type):" "${r}" "${c}" 3 \
	"${opt1a}"  "${opt1b}" \
	"${opt2a}"  "${opt2b}" \
	"${opt3a}"  "${opt3b}" 3> /dev/stderr 2> /dev/stdout >&3)
	then
		echo '::: Cancel selected. Exiting'
		exit 1
	fi

	echo "::: ${UpdateCmd} option selected."
}

distroCheck() {
	# Check for supported distribution
	# Compatibility, functions to check for supported OS
	# distroCheck, maybeOSSupport, noOSSupport
	# if lsb_release command is on their system
	if command -v lsb_release > /dev/null
	then
		PLAT=$(lsb_release -si)
		OSCN=$(lsb_release -sc)
	else # else get info from os-release
		declare -A VER_MAP

		VER_MAP=(['9']='stretch')
		VER_MAP+=(['10']='buster')
		VER_MAP+=(['11']='bullseye')
		VER_MAP+=(['16.04']='xenial')
		VER_MAP+=(['18.04']='bionic')
		VER_MAP+=(['20.04']='focal')

		# shellcheck disable=SC1091
		source /etc/os-release

		PLAT=$(awk '{print $1}' <<< "$NAME")
		VER="${VERSION_ID}"
	fi

	case "${PLAT}" in
		Debian | Raspbian | Ubuntu)
			case "${OSCN}" in
				stretch | buster | bullseye | xenial | bionic | focal)
					:
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

	echo "PLAT=${PLAT}" > "${tempsetupVarsFile}"
	echo "OSCN=${OSCN}" >> "${tempsetupVarsFile}"
}

noOSSupport() {
	if [ "${runUnattended}" == true ]
	then
		echo '::: Invalid OS detected'
		echo '::: We have not been able to detect a supported OS.'
		echo '::: Currently this installer supports Raspbian, Debian and Ubuntu.'
		exit 1
	fi

	whiptail --msgbox --backtitle 'INVALID OS DETECTED' --title 'Invalid OS' "We have not been able to detect a supported OS.
Currently this installer supports Raspbian, Debian and Ubuntu.
For more details, check our documentation at https://github.com/pivpn/pivpn/wiki " "${r}" "${c}"
	exit 1
}

maybeOSSupport() {
	if [ "${runUnattended}" == true ]
	then
		echo '::: OS Not Supported'
		echo '::: You are on an OS that we have not tested but MAY work, continuing anyway...'
		return
	fi

	if (whiptail --backtitle 'Untested OS' --title 'Untested OS' --yesno "You are on an OS that we have not tested but MAY work.
Currently this installer supports Raspbian, Debian and Ubuntu.
For more details about supported OS please check our documentation at https://github.com/pivpn/pivpn/wiki
Would you like to continue anyway?" "${r}" "${c}")
	then
		echo '::: Did not detect perfectly supported OS but,'
		echo "::: Continuing installation at user's own risk..."
	else
		echo '::: Exiting due to untested OS'
		exit 1
	fi
}

checkHostname() {
	# Checks for hostname Length
	host_name=$(hostname -s)

	if [ ! ${#host_name} -le 28 ]
	then
		if [ "${runUnattended}" == true ]
		then
			echo '::: Your hostname is too long.'
			echo "::: Use 'hostnamectl set-hostname YOURHOSTNAME' to set a new hostname"
			echo '::: It must be less then 28 characters long and it must not use special characters'
			exit 1
		fi

		until [[ ${#host_name} -le 28 && "${host_name}"  =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$ ]]
		do
			host_name=$(whiptail --inputbox 'Your hostname is too long.\\nEnter new hostname with less then 28 characters\\nNo special characters allowed.' \
		   --title 'Hostname too long' "${r}" "${c}" 3> /dev/stdout > /dev/stderr 2>&3)

			"${SUDO}" hostnamectl set-hostname "${host_name}"

			[[ ${#host_name} -le 28 && "${host_name}"  =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$ ]] && \
				echo '::: Hostname valid and length OK, proceeding...'
		done
	else
		echo '::: Hostname length OK'
	fi
}

spinner() {
	local pid="$1"
	local delay=0.50
	local spinstr='/-\|'

	while ps a | \
		awk '{print $1}' | \
		grep -qsEe "${pid}"
	do
		local temp=${spinstr#?}
		local spinstr="${temp}${spinstr%$temp}"

		printf ' [%c]  ' "${spinstr}"

		sleep "${delay}"

		printf '\\b\\b\\b\\b\\b\\b'
	done

	printf '    \\b\\b\\b\\b'
}

verifyFreeDiskSpace() {
	local required_free_kilobytes=76800
	local existing_free_kilobytes

	# If user installs unattended-upgrades we'd need about 60MB so will check for 75MB free
	echo '::: Verifying free disk space...'
	
	existing_free_kilobytes=$(df -Pk | \
		grep -m1 -sEe '\/$' | \
		awk '{print $4}')

	# - Unknown free disk space , not a integer
	if ! [[ "${existing_free_kilobytes}" =~ ^([0-9])+$ ]]
	then
		echo '::: Unknown free disk space!'
		echo '::: We were unable to determine available free disk space on this system.'

		[ "${runUnattended}" == true ] && \
			exit 1

		echo '::: You may continue with the installation, however, it is not recommended.'
		read -r -p '::: If you are sure you want to continue, type YES and press enter :: ' response

		case "${response}" in
			[Y][E][S])
				;;
			*)
				echo '::: Confirmation not received, exiting...'
				exit 1
				;;
		esac
	# - Insufficient free disk space
	elif [ $existing_free_kilobytes -lt $required_free_kilobytes ]
	then
		echo '::: Insufficient Disk Space!'
		echo "::: Your system appears to be low on disk space. PiVPN recommends a minimum of ${required_free_kilobytes} KiloBytes."
		echo "::: You only have ${existing_free_kilobytes} KiloBytes free."
		echo '::: If this is a new install on a Raspberry Pi you may need to expand your disk.'
		echo "::: Try running 'sudo raspi-config', and choose the 'expand file system option'"
		echo '::: After rebooting, run this installation again. (curl -sSfL https://install.pivpn.io | bash)'

		echo 'Insufficient free space, exiting...'
		exit 1
	fi
}

updatePackageCache() {
	#update package lists
	echo ':::'
	echo -ne "::: Package Cache update is needed, running ${UPDATE_PKG_CACHE} ...\\n"

	# shellcheck disable=SC2086
	"${SUDO}" "${UPDATE_PKG_CACHE}" &> /dev/null & spinner "$!"

	echo ' done!'
}

notifyPackageUpdatesAvailable() {
	# Let user know if they have outdated packages on their system and
	# advise them to run a package update at soonest possible.
	echo ':::'
	echo -n "::: Checking ${PKG_MANAGER} for upgraded packages...."

	updatesToInstall=$(eval "${PKG_COUNT}")

	echo ' done!'
	echo ':::'

	if [ $updatesToInstall -eq 0 ]
	then
		echo '::: Your system is up to date! Continuing with PiVPN installation...'
	else
		echo "::: There are ${updatesToInstall} updates available for your system!"
		echo '::: We recommend you update your OS after installing PiVPN! '
		echo ':::'
	fi
}

preconfigurePackages() {
	# Install packages used by this installation script
	# If apt is older than 1.5 we need to install an additional package to add
	# support for https repositories that will be used later on
	if [ -f /etc/apt/sources.list ]
	then
		INSTALLED_APT=$(apt-cache policy apt | \
			grep -m1 -sEe 'Installed\: ' | \
			grep -vsEe '\(none\)' | \
			awk '{print $2}')

		dpkg --compare-versions "${INSTALLED_APT}" lt 1.5 && \
			BASE_DEPS+=(apt-transport-https)
	fi

	# We set static IP only on Raspberry Pi OS
	checkStaticIpSupported && \
		BASE_DEPS+=(dhcpcd5)

	DPKG_ARCH=$(dpkg --print-architecture)

	AVAILABLE_OPENVPN=$(apt-cache policy openvpn | \
		grep -m1 -sEe 'Candidate\: ' | \
		grep -vsEe '\(none\)' | \
		awk '{print $2}')
	OPENVPN_SUPPORT=0
	NEED_OPENVPN_REPO=0

	# We require OpenVPN 2.4 or later for ECC support. If not available in the
	# repositories but we are running x86 Debian or Ubuntu, add the official repo
	# which provides the updated package.
	if [ -n "${AVAILABLE_OPENVPN}" ] && \
		dpkg --compare-versions "${AVAILABLE_OPENVPN}" ge 2.4
	then
		OPENVPN_SUPPORT=1
	else
		if [ "${PLAT}" == 'Debian' ] || \
			[ "${PLAT}" == 'Ubuntu' ]
		then
			if [ "${DPKG_ARCH}" == 'amd64' ] || \
				[ "${DPKG_ARCH}" == 'i386' ]
			then
				NEED_OPENVPN_REPO=1
				OPENVPN_SUPPORT=1
			else
				OPENVPN_SUPPORT=0
			fi
		else
			OPENVPN_SUPPORT=0
		fi
	fi

	AVAILABLE_WIREGUARD=$(apt-cache policy wireguard | \
		grep -m1 -sEe 'Candidate\: ' | \
		grep -vsEe '\(none\)' | \
		awk '{print $2}')
	WIREGUARD_SUPPORT=0

	# If a wireguard kernel object is found and is part of any installed package, then
	# it has not been build via DKMS or manually (installing via wireguard-dkms does not
	# make the module part of the package since the module itself is built at install time
	# and not part of the .deb).
	# Source: https://github.com/MichaIng/DietPi/blob/7bf5e1041f3b2972d7827c48215069d1c90eee07/dietpi/dietpi-software#L1807-L1815
	WIREGUARD_BUILTIN=0

	if dpkg-query -S '/lib/modules/*/wireguard.ko*' &> /dev/null ||
		modinfo wireguard 2> /dev/null | \
		grep -qsEe '^filename\:[[:blank:]]*\(builtin\)$'
	then
		WIREGUARD_BUILTIN=1
	fi

	if
		# If the module is builtin and the package available, we only need to install wireguard-tools.
		[[ $WIREGUARD_BUILTIN -eq 1 && -n $AVAILABLE_WIREGUARD ]] || \
		# If the package is not available, on Debian and Raspbian we can add it via Bullseye repository.
			[[ $WIREGUARD_BUILTIN -eq 1 && ( "${PLAT}" == 'Debian' || "${PLAT}" == 'Raspbian' ) ]] || \
		# If the module is not builtin, on Raspbian we know the headers package: raspberrypi-kernel-headers
			[[ "${PLAT}" == 'Raspbian' ]] || \
		# On Debian (and Ubuntu), we can only reliably assume the headers package for amd64: linux-image-amd64
			[[ "${PLAT}" == 'Debian' && "${DPKG_ARCH}" == 'amd64' ]] || \
		# On Ubuntu, additionally the WireGuard package needs to be available, since we didn't test mixing Ubuntu repositories.
			[[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'amd64' && -n "${AVAILABLE_WIREGUARD}" ]] || \
		# Ubuntu focal has wireguard support
			[[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'arm64' && "${OSCN}" == 'focal' && -n "${AVAILABLE_WIREGUARD}" ]]
	then
		WIREGUARD_SUPPORT=1
	fi

	if [ $OPENVPN_SUPPORT -eq 0 ] && [ $WIREGUARD_SUPPORT -eq 0 ]
	then
		echo '::: Neither OpenVPN nor WireGuard are available to install by PiVPN, exiting...'
		exit 1
	fi

	# if ufw is enabled, configure that.
	# running as root because sometimes the executable is not in the user's $PATH
	if "${SUDO}" bash -c 'command -v ufw' > /dev/null
	then
		if "${SUDO}" ufw status | \
			grep -qsEe 'inactive'
		then
			USING_UFW=0
		else
			USING_UFW=1
		fi
	else
		USING_UFW=0
	fi

	if [ $USING_UFW -eq 0 ]
	then
		BASE_DEPS+=(iptables-persistent)

		echo iptables-persistent iptables-persistent/autosave_v4 boolean true | \
			"${SUDO}" debconf-set-selections
		echo iptables-persistent iptables-persistent/autosave_v6 boolean false | \
			"${SUDO}" debconf-set-selections
	fi

	echo "USING_UFW=${USING_UFW}" >> "${tempsetupVarsFile}"
}

installDependentPackages() {
	local APTLOGFILE
	local FAILED=0

	declare -a TO_INSTALL=()
	declare -a argArray1=("${!1}")

	# Install packages passed via argument array
	# No spinner - conflicts with set -e

	for i in "${argArray1[@]}"
	do
		echo -n ":::    Checking for ${i}..."
		if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null | \
			grep -qsEe 'ok installed'
		then
			echo ' already installed!'
		else
			echo ' not installed!'
			# Add this package to the list of packages in the argument array that need to be installed
			TO_INSTALL+=("${i}")
		fi
	done

	APTLOGFILE=$("${SUDO}" mktemp)

	# shellcheck disable=SC2086
	"${SUDO}" "${PKG_INSTALL}" "${TO_INSTALL[@]}"

	for i in "${TO_INSTALL[@]}"
	do
		if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null | \
			grep -qsEe 'ok installed'
		then
			echo ":::    Package ${i} successfully installed!"
			# Add this package to the total list of packages that were actually installed by the script
			INSTALLED_PACKAGES+=("${i}")
		else
			echo ":::    Failed to install ${i}!"
			((FAILED++))
		fi
	done

	if [ $FAILED -gt 0 ]
	then
		"${SUDO}" cat "${APTLOGFILE}"
		exit 1
	fi
}

welcomeDialogs() {
	if [ "${runUnattended}" == true ]
	then
		echo '::: PiVPN Automated Installer'
		echo "::: This installer will transform your ${PLAT} host into an OpenVPN or WireGuard server!"
		echo '::: Initiating network interface'
		return
	fi

	# Display the welcome dialog
	whiptail --msgbox --backtitle 'Welcome' --title 'PiVPN Automated Installer' 'This installer will transform your Raspberry Pi into an OpenVPN or WireGuard server!' "${r}" "${c}"

	# Explain the need for a static address
	whiptail --msgbox --backtitle 'Initiating network interface' --title 'Static IP Needed' "The PiVPN is a SERVER so it needs a STATIC IP ADDRESS to function properly.

In the next section, you can choose to use your current network settings (DHCP) or to manually edit them." "${r}" "${c}"
}

chooseInterface() {
	# Find interfaces and let the user choose one

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

	if [ "${showUnsupportedNICs}" == true ]
		then
		# Show every network interface, could be useful for those who install PiVPN inside virtual machines
		# or on Raspberry Pis with USB adapters (the loopback and docker interfaces are still skipped)
		availableInterfaces=$(ip -o link | \
			awk '{print $2}' | \
			cut -d ':' -f 1 | \
			cut -d '@' -f 1 | \
			grep -vwsEe 'lo' | \
			grep -vsEe '^docker')
	else
		# Find network interfaces whose state is UP, so as to skip virtual, loopback and docker interfaces.
		availableInterfaces=$(ip -o link | \
			awk '/state UP/ {print $2}' | \
			cut -d ':' -f 1 | \
			cut -d '@' -f 1 | \
			grep -vwsEe 'lo' | \
			grep -vsEe '^docker')
	fi

	if [ -z "${availableInterfaces}" ]
	then
		echo "::: Could not find any active network interface, exiting"
		exit 1
	else
		while read -r line
		do
			mode="OFF"

			if [ $firstloop -eq 1 ]
			then
				firstloop=0
				mode="ON"
			fi

			interfacesArray+=("${line}" "available" "${mode}")
			((interfaceCount++))
		done <<< "${availableInterfaces}"
	fi

	if [ "${runUnattended}" == true ]
	then
		if [ -z "${IPv4dev}" ]
		then
			if [ $interfaceCount -eq 1 ]
			then
				IPv4dev="${availableInterfaces}"
				echo "::: No interface specified for IPv4, but only ${IPv4dev} is available, using it"
			else
				echo '::: No interface specified for IPv4 and failed to determine one'
				exit 1
			fi
		else
			if ip -o link | \
				grep -qwsEe "${IPv4dev}"
			then
				echo "::: Using interface: ${IPv4dev} for IPv4"
			else
				echo "::: Interface ${IPv4dev} for IPv4 does not exist"
				exit 1
			fi
		fi

		echo "IPv4dev=${IPv4dev}" >> "${tempsetupVarsFile}"

		if [ $pivpnenableipv6 -eq 1 ]
		then
			if [ -z "${IPv6dev}" ]
			then
				if [ $interfaceCount -eq 1 ]
				then
					IPv6dev="${availableInterfaces}"
					echo "::: No interface specified for IPv6, but only ${IPv6dev} is available, using it"
				else
					echo '::: No interface specified for IPv6 and failed to determine one'
					exit 1
				fi
			else
				if ip -o link | \
					grep -qwsEe "${IPv6dev}"
				then
					echo "::: Using interface: ${IPv6dev} for IPv6"
				else
					echo "::: Interface ${IPv6dev} for IPv6 does not exist"
					exit 1
				fi
			fi
		fi

		if [ $pivpnenableipv6 -eq 1 ] && [ -z "${IPv6dev}" ]
		then
			echo "IPv6dev=${IPv6dev}" >> "${tempsetupVarsFile}"
		fi

		return
	else
		if [ $interfaceCount -eq 1 ]
		then
			IPv4dev="${availableInterfaces}"
			echo "IPv4dev=${IPv4dev}" >> "${tempsetupVarsFile}"

			if [ $pivpnenableipv6 -eq 1 ]
			then
				IPv6dev="${availableInterfaces}"
				echo "IPv6dev=${IPv6dev}" >> "${tempsetupVarsFile}"
			fi

			return
		fi
	fi

	chooseInterfaceCmd=(whiptail --separate-output --radiolist 'Choose An interface for IPv4 (press space to select):' "${r}" "${c}" "${interfaceCount}")
	
	if chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2> /dev/stdout > /dev/tty) 
	then
		for desiredInterface in "${chooseInterfaceOptions}"
		do
			IPv4dev="${desiredInterface}"
			echo "::: Using interface: ${IPv4dev}"
			echo "IPv4dev=${IPv4dev}" >> "${tempsetupVarsFile}"
		done
	else
		echo '::: Cancel selected, exiting....'
		exit 1
	fi

	if [ $pivpnenableipv6 -eq 1 ]
	then
		chooseInterfaceCmd=(whiptail --separate-output --radiolist 'Choose An interface for IPv6, usually the same as used by IPv4 (press space to select):' "${r}" "${c}" "${interfaceCount}")
		
		if chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2> /dev/stdout > /dev/tty) 
		then
			for desiredInterface in "${chooseInterfaceOptions}"
			do
				IPv6dev="${desiredInterface}"
				echo "::: Using interface: ${IPv6dev}"
				echo "IPv6dev=${IPv6dev}" >> "${tempsetupVarsFile}"
			done
		else
			echo '::: Cancel selected, exiting....'
			exit 1
		fi
	fi
}

checkStaticIpSupported() {
	# Not really robust and correct, we should actually check for dhcpcd, not the distro, but works on Raspbian and Debian.
	if [ "${PLAT}" == 'Raspbian' ]
	then
		return 0
	# If we are on 'Debian' but the raspi.list file is present, then we actually are on 64-bit Raspberry Pi OS.
	elif [ "${PLAT}" == 'Debian' ] && [ -s /etc/apt/sources.list.d/raspi.list ]
	then
		return 0
	fi

	return 1
}

staticIpNotSupported() {
	if [ "${runUnattended}" == true ]
	then
		echo '::: Since we think you are not using Raspberry Pi OS, we will not configure a static IP for you.'
		return
	fi

	# If we are in Ubuntu then they need to have previously set their network, so just use what you have.
	whiptail --msgbox --backtitle 'IP Information' --title 'IP Information' "Since we think you are not using Raspberry Pi OS, we will not configure a static IP for you.
If you are in Amazon then you can not configure a static IP anyway. Just ensure before this installer started you had set an elastic IP on your instance." "${r}" "${c}"
}

validIP() {
	local ip="$1"

	[[ "${ip}" =~ '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]?|0)$' ]] && \
		return 0 || \
		return 1
}

validIPAndNetmask() {
	local ip="$1"

	[[ "${ip}" =~ '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]?|0)\/(3[0-2]|[1-2][0-9]|[0-9])$' ]] && \
		return 0 || \
		return 1
}

checkipv6uplink() {
	curl --max-time 3 --connect-timeout 3 -s -f -6 https://google.com > /dev/null
	curlv6testres=$?

	if [ $curlv6testres -ne 0 ]
	then
		echo "::: IPv6 test connections to google.com have failed. Disabling IPv6 support. (The curl test failed with code: ${curlv6testres})"
		pivpnenableipv6=0
	else
		echo '::: IPv6 test connections to google.com successful. Enabling IPv6 support.'
		pivpnenableipv6=1
	fi

	return 
}

askforcedipv6route() {
	if [ "${runUnattended}" == true ]
	then
		echo '::: Enable forced IPv6 route with no IPv6 uplink on server.'
		echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
		return
	fi

	if (whiptail --backtitle 'Privacy setting' --title 'IPv6 leak' --yesno "Although this server doesn't seem to have a working IPv6 connection or IPv6 was disabled on purpose, it is still recommended you force all IPv6 connections through the VPN.\\n\\nThis will prevent the client from bypassing the tunnel and leaking its real IPv6 address to servers, though it might cause the client to have slow response when browsing the web on IPv6 networks.\\n\\nDo you want to force routing IPv6 to block the leakage?" "${r}" "${c}")
	then
		pivpnforceipv6route=1
	else
		pivpnforceipv6route=0
	fi

	echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
}

getStaticIPv4Settings() {
	# Find the gateway IP used to route to outside world
	CurrentIPv4gw=$(ip -o route get 192.0.2.1 | \
		grep -osEe '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
		awk 'NR==2')

	# Find the IP address (and netmask) of the desidered interface
	CurrentIPv4addr=$(ip -o -f inet address show dev "${IPv4dev}" | \
		grep -osEe '([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}')

	# Grab their current DNS servers
	IPv4dns=$(grep -vsEe '^\#' /etc/resolv.conf | \
		grep -wsEe 'nameserver' | \
		grep -osEe '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
		xargs)

	if [ "${runUnattended}" == true ]
	then
		if [ -z "${dhcpReserv}" ] || [ $dhcpReserv -ne 1 ]
		then
			local MISSING_STATIC_IPV4_SETTINGS=0

			if [ -z "${IPv4addr}" ]
			then
				echo '::: Missing static IP address'
				((MISSING_STATIC_IPV4_SETTINGS++))
			fi

			if [ -z "$IPv4gw" ]
			then
				echo '::: Missing static IP gateway'
				((MISSING_STATIC_IPV4_SETTINGS++))
			fi

			if [ $MISSING_STATIC_IPV4_SETTINGS -eq 0 ]
			then
				# If both settings are not empty, check if they are valid and proceed
				if validIPAndNetmask "${IPv4addr}"
				then
					echo "::: Your static IPv4 address:    ${IPv4addr}"
				else
					echo "::: ${IPv4addr} is not a valid IP address"
					exit 1
				fi

				if validIP "${IPv4gw}"
				then
					echo "::: Your static IPv4 gateway:    ${IPv4gw}"
				else
					echo "::: ${IPv4gw} is not a valid IP address"
					exit 1
				fi
			elif [ $MISSING_STATIC_IPV4_SETTINGS -eq 1 ]
			then
				# If either of the settings is missing, consider the input inconsistent
				echo '::: Incomplete static IP settings'
				exit 1
			elif [ $MISSING_STATIC_IPV4_SETTINGS -eq 2 ]
			then
				# If both of the settings are missing, assume the user wants to use current settings
				IPv4addr="${CurrentIPv4addr}"
				IPv4gw="${CurrentIPv4gw}"

				echo '::: No static IP settings, using current settings'
				echo "::: Your static IPv4 address:    ${IPv4addr}"
				echo "::: Your static IPv4 gateway:    ${IPv4gw}"
			fi
		else
			echo '::: Skipping setting static IP address'
		fi

		{
			echo "dhcpReserv=${dhcpReserv}"
			echo "IPv4addr=${IPv4addr}"
			echo "IPv4gw=${IPv4gw}"
		} >> "${tempsetupVarsFile}"
		return
	fi

	local ipSettingsCorrect
	local IPv4AddrValid
	local IPv4gwValid

	# Some users reserve IP addresses on another DHCP Server or on their routers,
	# Lets ask them if they want to make any changes to their interfaces.
	if (whiptail --backtitle 'Calibrating network interface' --title 'DHCP Reservation' --yesno --defaultno \
	"Are you Using DHCP Reservation on your Router/DHCP Server?
These are your current Network Settings:

			IP address:    ${CurrentIPv4addr}
			Gateway:       ${CurrentIPv4gw}

Yes: Keep using DHCP reservation
No: Setup static IP address
Don't know what DHCP Reservation is? Answer No." "${r}" "${c}")
	then
		dhcpReserv=1

        # shellcheck disable=SC2129
		echo "dhcpReserv=${dhcpReserv}" >> "${tempsetupVarsFile}"
		# We don't really need to save them as we won't set a static IP but they might be useful for debugging
		echo "IPv4addr=${CurrentIPv4addr}" >> "${tempsetupVarsFile}"
		echo "IPv4gw=${CurrentIPv4gw}" >> "${tempsetupVarsFile}"
	else
		# Ask if the user wants to use DHCP settings as their static IP
		if (whiptail --backtitle 'Calibrating network interface' --title 'Static IP Address' --yesno "Do you want to use your current network settings as a static address?

				IP address:    ${CurrentIPv4addr}
				Gateway:       ${CurrentIPv4gw}" "${r}" "${c}")
		then
			IPv4addr="${CurrentIPv4addr}"
			IPv4gw="${CurrentIPv4gw}"

			echo "IPv4addr=${IPv4addr}" >> "${tempsetupVarsFile}"
			echo "IPv4gw=${IPv4gw}" >> "${tempsetupVarsFile}"

			# If they choose yes, let the user know that the IP address will not be available via DHCP and may cause a conflict.
			whiptail --msgbox --backtitle 'IP information' --title 'FYI: IP Conflict' "It is possible your router could still try to assign this IP to a device, which would cause a conflict.  But in most cases the router is smart enough to not do that.
If you are worried, either manually set the address, or modify the DHCP reservation pool so it does not include the IP you want.
It is also possible to use a DHCP reservation, but if you are going to do that, you might as well set a static address." "${r}" "${c}"
			# Nothing else to do since the variables are already set above
		else
			# Otherwise, we need to ask the user to input their desired settings.
			# Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
			# Start a loop to let the user enter their information with the chance to go back and edit it if necessary
			until [ "${ipSettingsCorrect}" == true ]
			do
				until [ "${IPv4AddrValid}" == true ]
				do
					# Ask for the IPv4 address
					if IPv4addr=$(whiptail --backtitle 'Calibrating network interface' --title 'IPv4 address' --inputbox 'Enter your desired IPv4 address' "${r}" "${c}" "${CurrentIPv4addr}" 3> /dev/stdout > /dev/stderr 2>&3) 
					then
						if validIPAndNetmask "${IPv4addr}"
						then
							echo "::: Your static IPv4 address:    ${IPv4addr}"
							IPv4AddrValid=true
						else
							whiptail --msgbox --backtitle 'Calibrating network interface' --title 'IPv4 address' "You've entered an invalid IP address: ${IPv4addr}\\n\\nPlease enter an IP address in the CIDR notation, example: 192.168.23.211/24\\n\\nIf you are not sure, please just keep the default." "${r}" "${c}"
							echo "::: Invalid IPv4 address:    ${IPv4addr}"
							IPv4AddrValid=false
						fi
					else
						# Cancelling IPv4 settings window
						echo '::: Cancel selected. Exiting...'
						exit 1
					fi
				done

				until [ "${IPv4gwValid}" == true ]
				do
					# Ask for the gateway
					if IPv4gw=$(whiptail --backtitle 'Calibrating network interface' --title 'IPv4 gateway (router)' --inputbox 'Enter your desired IPv4 default gateway' "${r}" "${c}" "${CurrentIPv4gw}" 3> /dev/stdout > /dev/stderr 2>&3) 
					then
						if validIP "${IPv4gw}"
						then
							echo "::: Your static IPv4 gateway:    ${IPv4gw}"
							IPv4gwValid=true
						else
							whiptail --msgbox --backtitle 'Calibrating network interface' --title 'IPv4 gateway (router)' "You've entered an invalid gateway IP: ${IPv4gw}\\n\\nPlease enter the IP address of your gateway (router), example: 192.168.23.1\\n\\nIf you are not sure, please just keep the default." "${r}" "${c}"
							echo "::: Invalid IPv4 gateway:    ${IPv4gw}"
							IPv4gwValid=false
						fi
					else
						# Cancelling gateway settings window
						echo '::: Cancel selected. Exiting...'
						exit 1
					fi
				done

				# Give the user a chance to review their settings before moving on
				if (whiptail --backtitle 'Calibrating network interface' --title 'Static IP Address' --yesno "Are these settings correct?

						IP address:    ${IPv4addr}
						Gateway:       ${IPv4gw}" "${r}" "${c}")
				then
					# If the settings are correct, then we need to set the pivpnIP
					echo "IPv4addr=${IPv4addr}" >> "${tempsetupVarsFile}"
					echo "IPv4gw=${IPv4gw}" >> "${tempsetupVarsFile}"

					# After that's done, the loop ends and we move on
					ipSettingsCorrect=true
				else
					# If the settings are wrong, the loop continues
					ipSettingsCorrect=false
					IPv4AddrValid=false
					IPv4gwValid=false
				fi
			done
			# End the if statement for DHCP vs. static
		fi
		# End of If Statement for DCHCP Reservation
	fi
}

setDHCPCD() {
	# Append these lines to dhcpcd.conf to enable a static IP
	echo "interface ${IPv4dev}" | \
		"${SUDO}" tee -a "${dhcpcdFile}" > /dev/null
	echo "static ip_address=${IPv4addr}" | \
		"${SUDO}" tee -a "${dhcpcdFile}" > /dev/null
	echo "static routers=${IPv4gw}" | \
		"${SUDO}" tee -a "${dhcpcdFile}" > /dev/null
	echo "static domain_name_servers=${IPv4dns}" | \
		"${SUDO}" tee -a "${dhcpcdFile}" > /dev/null
}

setStaticIPv4() {
	# Tries to set the IPv4 address
	if [ -f /etc/dhcpcd.conf ]
	then
		if grep -qsEe "${IPv4addr}" "${dhcpcdFile}"
		then
			echo '::: Static IP already configured.'
		else
			setDHCPCD

			"${SUDO}" ip addr replace dev "${IPv4dev}" "${IPv4addr}"

			echo ':::'
			echo "::: Setting IP to ${IPv4addr}.  You may need to restart after the install is complete."
			echo ':::'
		fi
	else
		echo '::: Critical: Unable to locate configuration file to set static IPv4 address!'
		exit 1
	fi
}

chooseUser() {
	local userArray=()
	local firstloop=1

	# Choose the user for the ovpns
	if [ "${runUnattended}" == true ]
	then
		if [ -z "${install_user}" ]
		then
			if [ $(awk -F':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd) -eq 1 ]
			then
				install_user=$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)
				echo "::: No user specified, but only ${install_user} is available, using it"
			else
				echo '::: No user specified'
				exit 1
			fi
		else
			if awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd | \
				grep -qwsEe "${install_user}"
			then
				echo "::: ${install_user} will hold your ovpn configurations."
			else
				echo "::: User ${install_user} does not exist, creating..."

				"${SUDO}" useradd -ms /bin/bash "${install_user}"

				echo "::: User created without a password, please do sudo passwd ${install_user} to create one"
			fi
		fi

		install_home=$(grep -m1 -sEe "^${install_user}\:" /etc/passwd | \
			cut -d ':' -f 6)
		install_home="${install_home%/}"

		echo "install_user=${install_user}" >> "${tempsetupVarsFile}"
		echo "install_home=${install_home}" >> "${tempsetupVarsFile}"
		return
	fi

	# Explain the local user
	whiptail --msgbox --backtitle 'Parsing User List' --title 'Local Users' 'Choose a local user that will hold your ovpn configurations.' "${r}" "${c}"
	# First, let's check if there is a user available.
	numUsers=$(awk -F':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)

	if [ $numUsers -eq 0 ]
	then
		# We don't have a user, let's ask to add one.
		if userToAdd=$(whiptail --title 'Choose A User' --inputbox 'No non-root user account was found. Please type a new username.' "${r}" "${c}" 3> /dev/stdout > /dev/stderr 2>&3)
		then
			# See https://askubuntu.com/a/667842/459815
			PASSWORD=$(whiptail  --title 'password dialog' --passwordbox 'Please enter the new user password' "${r}" "${c}" 3> /dev/stdout > /dev/stderr 2>&3)
			CRYPT=$(perl -e 'printf("%s\n", crypt($ARGV[0], "password"))' "${PASSWORD}")
			if "${SUDO}" useradd -mp "${CRYPT}" -s /bin/bash "${userToAdd}"
			then
				echo 'Succeeded'
				((numUsers+=1))
			else
				exit 1
			fi
		else
			exit 1
		fi
	fi

	availableUsers=$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)

	while read -r line
	do
		mode='OFF'

		if [ $firstloop -eq 1 ]
		then
			firstloop=0
			mode='ON'
		fi

		userArray+=("${line}" '' "${mode}")
	done <<< "${availableUsers}"

	chooseUserCmd=(whiptail --title 'Choose A User' --separate-output --radiolist
  'Choose (press space to select):' "${r}" "${c}" "${numUsers}")

	if chooseUserOptions=$("${chooseUserCmd[@]}" "${userArray[@]}" 2> /dev/stdout > /dev/tty) 
	then
		for desiredUser in "${chooseUserOptions}"
		do
			install_user="${desiredUser}"

			echo "::: Using User: ${install_user}"

			install_home=$(grep -m1 "^${install_user}:" /etc/passwd | \
				cut -d ':' -f6)
			install_home="${install_home%/}" # remove possible trailing slash

			echo "install_user=${install_user}" >> "${tempsetupVarsFile}"
			echo "install_home=${install_home}" >> "${tempsetupVarsFile}"
		done
	else
		echo '::: Cancel selected, exiting....'
		exit 1
	fi
}

isRepo() {
	# If the directory does not have a .git folder it is not a repo
	echo -n ":::    Checking $1 is a repo..."

	cd "${1}" &> /dev/null || {
		echo ' not found!'
		return 1
	}

	"${SUDO}" git status &> /dev/null && \
		echo ' OK!'; \
		return 0 || \
		echo ' not found!'; \
		return 1
}

updateRepo() {
	local directory
	local git_URL

	directory="$1"
	git_URL="$2"

	if [ "${UpdateCmd}" == 'Repair' ]
	then
		echo '::: Repairing an existing installation, not downloading/updating local repos'
	else
		# Pull the latest commits
		echo -n ":::     Updating repo in ${directory} from ${git_URL} ..."

		### FIXME: Never call rm -rf with a plain variable. Never again as SU!
		#"${SUDO}" rm -rf "${directory}"
		[ -n "${directory}" ] && \
			"${SUDO}" rm -rf "$(dirname "${directory}")/pivpn"

		# Go back to /usr/local/src otherwise git will complain when the current working
		# directory has just been deleted (/usr/local/src/pivpn).
		cd /usr/local/src && \
			"${SUDO}" git clone -q --depth 1 --no-single-branch "${git_URL}" "${directory}" > /dev/null && \
			spinner $!

		cd "${directory}" || \
			exit 1

		echo ' done!'

		if [ -n "${pivpnGitBranch}" ]
		then
			echo ":::     Checkout branch '${pivpnGitBranch}' from ${git_URL} in ${directory}..."

			"${SUDOE}" git checkout -q "${pivpnGitBranch}"

			echo ':::     Custom branch checkout done!'
		elif [ -z "${TESTING+x}" ]
		then
			:
		else
			echo ":::     Checkout branch 'test' from ${git_URL} in ${directory}..."

			"${SUDOE}" git checkout -q test

			echo ':::     'test' branch checkout done!'
		fi
	fi
}

makeRepo() {
	local directory
	local git_URL

	directory="$1"
	git_URL="$2"

	# Remove the non-repos interface and clone the interface
	echo -n ":::    Cloning ${git_URL} into ${directory} ..."

	### FIXME: Never call rm -rf with a plain variable. Never again as SU!
	#"${SUDO}" rm -rf "${directory}"
	[ -n "${directory}" ] && \
		"${SUDO}" rm -rf "$(dirname "${directory}")/pivpn"

	# Go back to /usr/local/src otherwhise git will complain when the current working
	# directory has just been deleted (/usr/local/src/pivpn).
	cd /usr/local/src && \
		"${SUDO}" git clone -q --depth 1 --no-single-branch "${git_URL}" "${directory}" > /dev/null && \
			spinner $!

	cd "${directory}" || \
		exit 1

	echo ' done!'

	if [ -n "${pivpnGitBranch}" ]
	then
		echo ":::     Checkout branch '${pivpnGitBranch}' from ${git_URL} in ${directory}..."

		"${SUDOE}" git checkout -q "${pivpnGitBranch}"

		echo ':::     Custom branch checkout done!'
	elif [ -z "${TESTING+x}" ]
	then
		:
	else
		echo ":::     Checkout branch 'test' from ${git_URL} in ${directory}..."

		"${SUDOE}" git checkout -q test

		echo ':::     'test' branch checkout done!'
	fi
}

getGitFiles() {
	local directory
	local git_URL

	directory="$1"
	git_URL="$2"

	# Setup git repos for base files
	echo ':::'
	echo '::: Checking for existing base files...'

	if isRepo "${directory}"
	then
		updateRepo "${directory}" "${git_URL}"
	else
		makeRepo "${directory}" "${git_URL}"
	fi
}

cloneOrUpdateRepos() {
	# Clone/Update the repos
	# /usr/local should always exist, not sure about the src subfolder though
	"${SUDO}" mkdir -p /usr/local/src

	# Get Git files
	getGitFiles "${pivpnFilesDir}" "${pivpnGitUrl}" || \
	{
		echo "!!! Unable to clone ${pivpnGitUrl} into ${pivpnFilesDir}, unable to continue."
		exit 1
	}
}

installPiVPN() {
	"${SUDO}" mkdir -p /etc/pivpn/

	askWhichVPN
	setVPNDefaultVars

	if [ "$VPN" == 'openvpn' ]
	then
		setOpenVPNDefaultVars
		askAboutCustomizing
		installOpenVPN
		askCustomProto
	elif [ "$VPN" == 'wireguard' ]
	then
		setWireguardDefaultVars
		installWireGuard
	fi

	askCustomPort
	askClientDNS

	[ "$VPN" == 'openvpn' ] && \
		askCustomDomain

	askPublicIPOrDNS

	if [ "$VPN" == 'openvpn' ]
	then
		askEncryption
		confOpenVPN
		confOVPN
	elif [ "$VPN" == 'wireguard' ]
	then
		confWireGuard
	fi

	confNetwork

	[ "$VPN" == 'openvpn' ] && \
		confLogging
	[ "$VPN" == 'wireguard' ] && \
		writeWireguardTempVarsFile

	writeVPNTempVarsFile
}

setVPNDefaultVars() {
	# Allow custom subnetClass via unattend setupVARs file. Use default if not provided.
	[ -z "${subnetClass}" ] && \
		subnetClass='24'

	[ -z "${subnetClassv6}" ] && \
		subnetClassv6='64'
}

generateRandomSubnet() {
	local MATCHES

	# Source: https://community.openvpn.net/openvpn/wiki/AvoidRoutingConflicts
	declare -a SUBNET_EXCLUDE_LIST
	
	SUBNET_EXCLUDE_LIST=(10.0.0.0/24 10.0.1.0/24 10.1.1.0/24 10.1.10.0/24 10.2.0.0/24 10.8.0.0/24 10.10.1.0/24 10.90.90.0/24 10.100.1.0/24 10.255.255.0/24)
	
	readarray -t CURRENTLY_USED_SUBNETS <<< "$(ip route show | \
		grep -osEe '([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}')"
	
	SUBNET_EXCLUDE_LIST=("${SUBNET_EXCLUDE_LIST[@]}" "${CURRENTLY_USED_SUBNETS[@]}")

	while true
	do
		MATCHES=0
		pivpnNET="10.$((RANDOM % 256)).$((RANDOM % 256)).0"

		for SUB in "${SUBNET_EXCLUDE_LIST[@]}"
		do
			grepcidr "${SUB}" <<< "${pivpnNET}/${subnetClass}" 2> /dev/stdout > /dev/null && \
				((MATCHES++))
		done

		[ $MATCHES -eq 0 ] && \
			break
	done

	echo "${pivpnNET}"
}

setOpenVPNDefaultVars() {
		pivpnDEV='tun0'

		# Allow custom NET via unattend setupVARs file. Use default if not provided.
		[ -z "$pivpnNET" ] && \
			pivpnNET=$(generateRandomSubnet)

		vpnGw="$(cut -d '.' -f 1-3 <<< "${pivpnNET}").1"
}

setWireguardDefaultVars() {
	# Since WireGuard only uses UDP, askCustomProto() is never called so we
	# set the protocol here.
	pivpnPROTO='udp'
	pivpnDEV='wg0'

	# Allow custom NET via unattend setupVARs file. Use default if not provided.
	[ -z "${pivpnNET}" ] && \
		pivpnNET=$(generateRandomSubnet)

	[ $pivpnenableipv6 -eq 1 ] && \
		[ -z "${pivpnNETv6}" ] && \
		pivpnNETv6='fd11:5ee:bad:c0de::'

	vpnGw="$(cut -d '.' -f 1-3 <<< "${pivpnNET}").1"

	[ $pivpnenableipv6 -eq 1 ] && \
		vpnGwv6="${pivpnNETv6}1"

	# Allow custom allowed IPs via unattend setupVARs file. Use default if not provided.
	if [ -z "${ALLOWED_IPS}" ]
	then
		# Forward all traffic through PiVPN (i.e. full-tunnel), may be modified by
		# the user after the installation.
		if [ $pivpnenableipv6 -eq 1 ] || [ $pivpnforceipv6route -eq 1 ]
		then
			ALLOWED_IPS='0.0.0.0/0, ::0/0'
		else
			ALLOWED_IPS='0.0.0.0/0'
		fi
	fi

	# The default MTU should be fine for most users but we allow to set a
	# custom MTU via unattend setupVARs file. Use default if not provided.
	[ -z "${pivpnMTU}" ] && \
		pivpnMTU='1420'

	CUSTOMIZE=0
}

writeVPNTempVarsFile() {
	{
		echo "pivpnDEV=${pivpnDEV}"
		echo "pivpnNET=${pivpnNET}"
		echo "subnetClass=${subnetClass}"
		echo "pivpnenableipv6=${pivpnenableipv6}"
		
		if [ $pivpnenableipv6 -eq 1 ]
		then
			echo "pivpnNETv6=\"${pivpnNETv6}\""
			echo "subnetClassv6=${subnetClassv6}"
		fi

		echo "ALLOWED_IPS=\"${ALLOWED_IPS}\""
	} >> "${tempsetupVarsFile}"
}

writeWireguardTempVarsFile() {
	echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
	echo "pivpnMTU=${pivpnMTU}" >> "${tempsetupVarsFile}"

	# Write PERSISTENTKEEPALIVE if provided via unattended file
	# May also be added manually to /etc/pivpn/wireguard/setupVars.conf
	# post installation to be used for client profile generation
	[ -n "${pivpnPERSISTENTKEEPALIVE}" ] && \
		echo "pivpnPERSISTENTKEEPALIVE=${pivpnPERSISTENTKEEPALIVE}" >> "${tempsetupVarsFile}"
}

askWhichVPN() {
	if [ "${runUnattended}" == true ]
	then
		if [ $WIREGUARD_SUPPORT -eq 1 ]
		then
			if [ -z "${VPN}" ]
			then
				echo ':: No VPN protocol specified, using WireGuard'
				VPN='wireguard'
			else
				VPN="${VPN,,}"

				if [ "${VPN}" == 'wireguard' ]
				then
					echo '::: WireGuard will be installed'
				elif [ "${VPN}" == 'openvpn' ]
				then
					echo '::: OpenVPN will be installed'
				else
					echo ":: ${VPN} is not a supported VPN protocol, please specify 'wireguard' or 'openvpn'"
					exit 1
				fi
			fi
		else
			if [ -z "${VPN}" ]
			then
				echo ':: No VPN protocol specified, using OpenVPN'
				VPN='openvpn'
			else
				VPN="${VPN,,}"
				if [ "${VPN}" == 'openvpn' ]
				then
					echo '::: OpenVPN will be installed'
				else
					echo ":: ${VPN} is not a supported VPN protocol on ${DPKG_ARCH} ${PLAT}, only 'openvpn' is"
					exit 1
				fi
			fi
		fi
	else
		if [ $WIREGUARD_SUPPORT -eq 1 ] && [ $OPENVPN_SUPPORT -eq 1 ]
		then
			chooseVPNCmd=(whiptail --backtitle 'Setup PiVPN' --title 'Installation mode' --separate-output --radiolist "WireGuard is a new kind of VPN that provides near-instantaneous connection speed, high performance, and modern cryptography.\\n\\nIt's the recommended choice especially if you use mobile devices where WireGuard is easier on battery than OpenVPN.\\n\\nOpenVPN is still available if you need the traditional, flexible, trusted VPN protocol or if you need features like TCP and custom search domain.\\n\\nChoose a VPN (press space to select):" "${r}" "${c}" 2)
			VPNChooseOptions=(WireGuard '' on
								OpenVPN '' off)

			if VPN=$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2> /dev/stdout > /dev/tty) 
			then
				echo "::: Using VPN: $VPN"
				VPN="${VPN,,}"
			else
				echo '::: Cancel selected, exiting....'
				exit 1
			fi
		elif [ $OPENVPN_SUPPORT -eq 1 ] && [ $WIREGUARD_SUPPORT -eq 0 ]
		then
			echo '::: Using VPN: OpenVPN'
			VPN='openvpn'
		elif [ $OPENVPN_SUPPORT -eq 0 ] && [ $WIREGUARD_SUPPORT -eq 1 ]
		then
			echo '::: Using VPN: WireGuard'
			VPN='wireguard'
		fi
	fi

	echo "VPN=${VPN}" >> "${tempsetupVarsFile}"
}

askAboutCustomizing() {
	[ "${runUnattended}" == false ] && \
		( whiptail --backtitle 'Setup PiVPN' --title 'Installation mode' --yesno --defaultno 'PiVPN uses the following settings that we believe are good defaults for most users. However, we still want to keep flexibility, so if you need to customize them, choose Yes.\n\n* UDP or TCP protocol: UDP\n* Custom search domain for the DNS field: None\n* Modern features or best compatibility: Modern features (256 bit certificate + additional TLS encryption)' "${r}" "${c}" && \
			CUSTOMIZE=1 || \
			CUSTOMIZE=0 )
}

installOpenVPN() {
	local PIVPN_DEPS

	echo '::: Installing OpenVPN from Debian package... '

	if [ $NEED_OPENVPN_REPO -eq 1 ]
	then
		# gnupg is used by apt-key to import the openvpn GPG key into the
		# APT keyring
		PIVPN_DEPS=(gnupg)
		installDependentPackages PIVPN_DEPS[@]

		# OpenVPN repo's public GPG key (fingerprint 0x30EBF4E73CCE63EEE124DD278E6DA8B4E158C569)
		echo '::: Adding repository key...'

		if ! "${SUDO}" apt-key add "${pivpnFilesDir}/files/etc/apt/repo-public.gpg"
		then
			echo "::: Can't import OpenVPN GPG key"
			exit 1
		fi

		echo '::: Adding OpenVPN repository... '
		echo "deb https://build.openvpn.net/debian/openvpn/stable $OSCN main" | "${SUDO}" tee /etc/apt/sources.list.d/pivpn-openvpn-repo.list > /dev/null
		echo '::: Updating package cache...'

		# shellcheck disable=SC2086
		updatePackageCache
	fi

	# Expect is used to feed easy-rsa with passwords
	PIVPN_DEPS=(openvpn expect)
	installDependentPackages PIVPN_DEPS[@]
}

installWireGuard() {
	local PIVPN_DEPS

	if [ "${PLAT}" == 'Raspbian' ]
	then
		echo '::: Installing WireGuard from Debian package... '

		if [ -z "${AVAILABLE_WIREGUARD}" ]
		then
			echo '::: Adding Raspbian Bullseye repository... '
			echo 'deb http://raspbian.raspberrypi.org/raspbian/ bullseye main' | "${SUDO}" tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null

			# Do not upgrade packages from the bullseye repository except for wireguard
			printf 'Package: *\nPin: release n=bullseye\nPin-Priority: -1\n\nPackage: wireguard wireguard-dkms wireguard-tools\nPin: release n=bullseye\nPin-Priority: 100\n' | "${SUDO}" tee /etc/apt/preferences.d/pivpn-limit-bullseye > /dev/null

			echo '::: Updating package cache...'

			# shellcheck disable=SC2086
			updatePackageCache
		fi

		# qrencode is used to generate qrcodes from config file, for use with mobile clients
		PIVPN_DEPS=(wireguard-tools qrencode)

		installDependentPackages PIVPN_DEPS[@]
	elif [ "$PLAT" == 'Debian' ]
	then
		echo '::: Installing WireGuard from Debian package... '

		if [ -z "${AVAILABLE_WIREGUARD}" ]
		then
			echo '::: Adding Debian Bullseye repository... '
			echo 'deb https://deb.debian.org/debian/ bullseye main' | "${SUDO}" tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null

			printf 'Package: *\nPin: release n=bullseye\nPin-Priority: -1\n\nPackage: wireguard wireguard-dkms wireguard-tools\nPin: release n=bullseye\nPin-Priority: 100\n' | "${SUDO}" tee /etc/apt/preferences.d/pivpn-limit-bullseye > /dev/null

			echo '::: Updating package cache...'

			# shellcheck disable=SC2086
			updatePackageCache
		fi

		PIVPN_DEPS=(wireguard-tools qrencode)

		# Explicitly install the module if not built-in
		[ $WIREGUARD_BUILTIN -eq 0 ] && \
			PIVPN_DEPS+=(linux-headers-amd64 wireguard-dkms)

		installDependentPackages PIVPN_DEPS[@]
	elif [ "${PLAT}" == 'Ubuntu' ]
	then
		echo '::: Installing WireGuard... '

		PIVPN_DEPS=(wireguard-tools qrencode)

		[ $WIREGUARD_BUILTIN -eq 0 ] && \
			PIVPN_DEPS+=(linux-headers-generic wireguard-dkms)

		installDependentPackages PIVPN_DEPS[@]
	fi
}

askCustomProto() {
	if [ "${runUnattended}" == true ]
	then
		if [ -z "${pivpnPROTO}" ]
		then
			echo '::: No TCP/IP protocol specified, using the default protocol udp'
			pivpnPROTO='udp'
		else
			pivpnPROTO="${pivpnPROTO,,}"
			if [ "${pivpnPROTO}" == 'udp' ] || [ "${pivpnPROTO}" == 'tcp' ]
			then
				echo "::: Using the $pivpnPROTO protocol"
			else
				echo ":: $pivpnPROTO is not a supported TCP/IP protocol, please specify 'udp' or 'tcp'"
				exit 1
			fi
		fi

		echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
		return
	fi

	if [ $CUSTOMIZE -eq 0 ]
	then
		if [ "${VPN}" == 'openvpn' ]
		then
			pivpnPROTO='udp'
			echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
			return
		fi
	fi

	# Set the available protocols into an array so it can be used with a whiptail dialog
	if pivpnPROTO=$(whiptail --title 'Protocol' --radiolist \
		'Choose a protocol (press space to select). Please only choose TCP if you know why you need TCP.' "${r}" "${c}" 2 \
		'UDP' '' ON \
		'TCP' '' OFF 3> /dev/stdout > /dev/stderr 2>&3)
	then
		# Convert option into lowercase (UDP->udp)
		pivpnPROTO="${pivpnPROTO,,}"
		echo "::: Using protocol: ${pivpnPROTO}"
		echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
	else
		echo '::: Cancel selected, exiting....'
		exit 1
	fi
}

askCustomPort() {
	if [ "${runUnattended}" == true ]
	then
		if [ -z "${pivpnPORT}" ]
		then
			if [ "$VPN" == 'wireguard' ]
			then
				echo '::: No port specified, using the default port 51820'
				pivpnPORT=51820
			elif [ "${VPN}" == 'openvpn' ]
			then
				if [ "${pivpnPROTO}" == 'udp' ]
				then
					echo '::: No port specified, using the default port 1194'
					pivpnPORT=1194
				elif [ "${pivpnPROTO}" == 'tcp' ]
				then
					echo '::: No port specified, using the default port 443'
					pivpnPORT=443
				fi
			fi
		else
			if [[ "${pivpnPORT}" =~ ^(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3}|0)$ ]]
			then
				echo "::: Using port ${pivpnPORT}"
			else
				echo "::: ${pivpnPORT} is not a valid port, use a port within the range [1,65535] (inclusive)"
				exit 1
			fi
		fi

		echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"
		return
	fi

	until [ "${PORTNumCorrect}" == true ]
	do
		portInvalid='Invalid'

		if [ "${VPN}" == 'wireguard' ]
		then
			DEFAULT_PORT=51820
		elif [ "${VPN}" == 'openvpn' ]
		then
			if [ "${pivpnPROTO}" == 'udp' ]
			then
				DEFAULT_PORT=1194
			else
				DEFAULT_PORT=443
			fi
		fi

		if pivpnPORT=$(whiptail --title "Default ${VPN} Port" --inputbox "You can modify the default ${VPN} port. \\nEnter a new value or hit 'Enter' to retain the default" "${r}" "${c}" "${DEFAULT_PORT}" 3> /dev/stdout > /dev/stderr 2>&3)
		then
			if [[ "${pivpnPORT}" =~ ^(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3}|0)$ ]]
			then
				:
			else
				pivpnPORT="${portInvalid}"
			fi
		else
			echo '::: Cancel selected, exiting....'
			exit 1
		fi

		if [[ "${pivpnPORT}" == "${portInvalid}" ]]
		then
			whiptail --msgbox --backtitle 'Invalid Port' --title 'Invalid Port' 'You entered an invalid Port number.\\n    Please enter a number from 1 - 65535.\\n    If you are not sure, please just keep the default.' "${r}" "${c}"
			PORTNumCorrect=false
		else
			if (whiptail --backtitle 'Specify Custom Port' --title 'Confirm Custom Port Number' --yesno "Are these settings correct?\\n    PORT:   ${pivpnPORT}" "${r}" "${c}") then
				PORTNumCorrect=true
			else
				# If the settings are wrong, the loop continues
				PORTNumCorrect=false
			fi
		fi
	done

	# write out the port
	echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"
}

askClientDNS() {
	local INVALID_DNS_SETTINGS=0

	if [ "${runUnattended}" == true ]
	then
		if [ -z "${pivpnDNS1}" ] && [ -n "${pivpnDNS2}" ]
		then
			pivpnDNS1="${pivpnDNS2}"
			unset pivpnDNS2
		elif [ -z "${pivpnDNS1}" ] && [ -z "${pivpnDNS2}" ]
		then
			pivpnDNS1='9.9.9.9'
			pivpnDNS2='149.112.112.112'
			echo "::: No DNS provider specified, using Quad9 DNS (${pivpnDNS1} ${pivpnDNS2})"
		fi

		if ! validIP "${pivpnDNS1}"
		then
			INVALID_DNS_SETTINGS=1
			echo "::: Invalid DNS ${pivpnDNS1}"
		fi

		if [ -n "${pivpnDNS2}" ] && ! validIP "${pivpnDNS2}"
		then
			INVALID_DNS_SETTINGS=1
			echo "::: Invalid DNS $pivpnDNS2"
		fi

		if [ $INVALID_DNS_SETTINGS -eq 0 ]
		then
			echo "::: Using DNS ${pivpnDNS1} ${pivpnDNS2}"
		else
			exit 1
		fi

		echo "pivpnDNS1=${pivpnDNS1}" >> "${tempsetupVarsFile}"
		echo "pivpnDNS2=${pivpnDNS2}" >> "${tempsetupVarsFile}"
		return
	fi

	# Detect and offer to use Pi-hole
	if command -v pihole > /dev/null
	then
		if (whiptail --backtitle 'Setup PiVPN' --title 'Pi-hole' --yesno 'We have detected a Pi-hole installation, do you want to use it as the DNS server for the VPN, so you get ad blocking on the go?' "${r}" "${c}")
		then
			if [ ! -r "${piholeSetupVars}" ]
			then
				echo "::: Unable to read ${piholeSetupVars}"
				exit 1
			fi

			# Add a custom hosts file for VPN clients so they appear as 'name.pivpn' in the
			# Pi-hole dashboard as well as resolve by their names.
			echo "addn-hosts=/etc/pivpn/hosts.${VPN}" | "${SUDO}" tee "${dnsmasqConfig}" > /dev/null

			# Then create an empty hosts file or clear if it exists.
			"${SUDO}" bash -c "> /etc/pivpn/hosts.${VPN}"

			# Setting Pi-hole to "Listen on all interfaces" allows dnsmasq to listen on the
			# VPN interface while permitting queries only from hosts whose address is on
			# the LAN and VPN subnets.
			"${SUDO}" pihole -a -i local

			# Use the Raspberry Pi VPN IP as DNS server.
			pivpnDNS1="${vpnGw}"

			echo "pivpnDNS1=${pivpnDNS1}" >> "${tempsetupVarsFile}"
			echo "pivpnDNS2=${pivpnDNS2}" >> "${tempsetupVarsFile}"

			# Allow incoming DNS requests through UFW.
			[ $USING_UFW -eq 1 ] && \
				"${SUDO}" ufw insert 1 allow in on "${pivpnDEV}" to any port 53 from "${pivpnNET}/${subnetClass}" >/dev/null

			return
		fi
	fi

	DNSChoseCmd=(whiptail --backtitle 'Setup PiVPN' --title 'DNS Provider' --separate-output --radiolist "Select the DNS Provider for your VPN Clients (press space to select).\nTo use your own, select Custom.\n\nIn case you have a local resolver running, i.e. unbound, select \"PiVPN-is-local-DNS\" and make sure your resolver is listening on \"${vpnGw}\", allowing requests from \"${pivpnNET}/${subnetClass}\"." "${r}" "${c}" 6)
	DNSChooseOptions=(Quad9 '' on
			OpenDNS '' off
			Level3 '' off
			DNS.WATCH '' off
			Norton '' off
			FamilyShield '' off
			CloudFlare '' off
			Google '' off
			PiVPN-is-local-DNS '' off
			Custom '' off)

	if DNSchoices=$("${DNSChoseCmd[@]}" "${DNSChooseOptions[@]}" 2> /dev/stdout > /dev/tty)
	then
		if [ "${DNSchoices}" != 'Custom' ]
		then
			declare -A DNS_MAP

			echo "::: Using ${DNSchoices} servers."
			DNS_MAP=(['Quad9']='9.9.9.9 149.112.112.112'
						['OpenDNS']='208.67.222.222 208.67.220.220'
						['Level3']='209.244.0.3 209.244.0.4'
						['DNS.WATCH']='84.200.69.80 84.200.70.40'
						['Norton']='199.85.126.10 199.85.127.10'
						['FamilyShield']='208.67.222.123 208.67.220.123'
						['CloudFlare']='1.1.1.1 1.0.0.1'
						['Google']='8.8.8.8 8.8.4.4'
						["PiVPN-is-local-DNS"]="${vpnGw}")

			pivpnDNS1=$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")
			pivpnDNS2=$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")
		else
			until [[ "${DNSSettingsCorrect}" == true ]]
			do
				strInvalid='Invalid'

				if pivpnDNS=$(whiptail --backtitle 'Specify Upstream DNS Provider(s)' --inputbox "Enter your desired upstream DNS provider(s), separated by a comma.\\n\\nFor example '1.1.1.1, 9.9.9.9'" "${r}" "${c}" '' 3> /dev/stdout > /dev/stderr 2>&3)
				then
					pivpnDNS1=$(echo "${pivpnDNS}" | \
						sed -Ee 's/[, \t]+/,/g' | \
						awk -F, '{print$1}')
					pivpnDNS2=$(echo "${pivpnDNS}" | \
						sed -Ee 's/[, \t]+/,/g' | \
						awk -F, '{print$2}')

					if ! validIP "$pivpnDNS1" || [ ! "$pivpnDNS1" ]
					then
						pivpnDNS1="${strInvalid}"
					fi

					if ! validIP "$pivpnDNS2" && [ "$pivpnDNS2" ]
					then
						pivpnDNS2="${strInvalid}"
					fi
				else
					echo '::: Cancel selected, exiting....'
					exit 1
				fi

				if [ "${pivpnDNS1}" == "${strInvalid}" ] || [ "${pivpnDNS2}" == "${strInvalid}" ]
				then
					whiptail --msgbox --backtitle 'Invalid IP' --title 'Invalid IP' "One or both entered IP addresses were invalid. Please try again.\\n\\n    DNS Server 1:   ${pivpnDNS1}\\n    DNS Server 2:   ${pivpnDNS2}" "${r}" "${c}"
					
					if [ "${pivpnDNS1}" == "${strInvalid}" ]
					then
						pivpnDNS1=''
					fi

					if [ "${pivpnDNS2}" == "${strInvalid}" ]
					then
						pivpnDNS2=''
					fi

					DNSSettingsCorrect=false
				else
					whiptail --backtitle 'Specify Upstream DNS Provider(s)' --title 'Upstream DNS Provider(s)' --yesno "Are these settings correct?\\n    DNS Server 1:   ${pivpnDNS1}\\n    DNS Server 2:   ${pivpnDNS2}" "${r}" "${c}" && \
						DNSSettingsCorrect=true || \
						DNSSettingsCorrect=false
					fi
				fi
			done
		fi
	else
		echo '::: Cancel selected. Exiting...'
		exit 1
	fi

	echo "pivpnDNS1=${pivpnDNS1}" >> "${tempsetupVarsFile}"
	echo "pivpnDNS2=${pivpnDNS2}" >> "${tempsetupVarsFile}"
}

# Call this function to use a regex to check user input for a valid custom domain
validDomain() {
    local domain
	local top_level_domains top_level_domains_regex

	domain="$1"

	# generic top-level domains
	top_level_domains='com net int edu gov mil org'

	# infrastructure top-level domains
	top_level_domains="${top_level_domains} arpa"

	# country code top-level domains
	top_level_domains="${top_level_domains} a[c-gi-moq-uwxz] b[abd-jm-oq-twyz] c[acdf-ik-oru-z] d[ejkmoz] e[ceghr-u]"
	top_level_domains="${top_level_domains} f[i-kmor] g[ad-il-np-uwy] h[kmnrtu] i[del-oq-t] j[emop] k[eg-imnprwyz]"
	top_level_domains="${top_level_domains} l[a-cikr-vy] m[ac-eghk-z] n[ace-gilopruz] om p[ae-hk-nr-twy] qa r[eosuw]"
	top_level_domains="${top_level_domains} s[a-eg-ik-or-vx-z] t[cdf-hj-ortvwz] u[agksyz] v[aceginu] w[fs] y[et] z[amw]"

	# sponsored top-level domains
	top_level_domains="${top_level_domains} aero asia cat coop jobs museum post tel travel xxx"

	# geographic top-level domains
	top_level_domains="${top_level_domains} africa capetown durban joburg"
	top_level_domains="${top_level_domains} abudhabi arab doha dubai krd kyoto nagoya okinawa osaka ryukyu taipei tatar"
	top_level_domains="${top_level_domains} tokyo yokohama"
	top_level_domains="${top_level_domains} alsace bzh corsica eus paris bcn bar(celona)? gal madrid bayern berlin"
	top_level_domains="${top_level_domains} cologne koeln hamburg nrw ruhr saarland amsterdam brussels budapest cymru"
	top_level_domains="${top_level_domains} wales frl gent helsinki irish ist(anbul)? london moscow scot stockholm"
	top_level_domains="${top_level_domains} swiss tirol vlaanderen wien zuerich"
	top_level_domains="${top_level_domains} boston miami nyc quebec vegas"
	top_level_domains="${top_level_domains} kiwi melbourne sydney"
	top_level_domains="${top_level_domains} lat rio"

	# special top-level domains
	top_level_domains="${top_level_domains} local(host)? onion test"

	top_level_domains_regex=$(echo "${top_level_domains}" | \
		sed -Ee 's/([^ ]+) /\(\1\)\|/g' | \
		sed -Ee 's/\|([^\|]+)$/\|\(\1\)/')

	grep -qsEe "^[^\-]([a-zA-Z0-9\-]+\.)+(${top_level_domains_regex})$" <<< "${domain}"
}

# This procedure allows a user to specify a custom search domain if they have one.
askCustomDomain() {
	if [ "${runUnattended}" == true ]
	then
		if [ -n "${pivpnSEARCHDOMAIN}" ]
		then
			if validDomain "${pivpnSEARCHDOMAIN}"
			then
				echo "::: Using custom domain ${pivpnSEARCHDOMAIN}"
			else
				echo "::: Custom domain ${pivpnSEARCHDOMAIN} is not valid"
				exit 1
			fi
		else
			echo '::: Skipping custom domain'
		fi

		echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
		return
	fi

	if [ $CUSTOMIZE -eq 0 ]
	then
		if [ "${VPN}" == 'openvpn' ]
		then
			echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
			return
		fi
	fi

	DomainSettingsCorrect=false

	if whiptail --backtitle 'Custom Search Domain' --title 'Custom Search Domain' --yesno --defaultno 'Would you like to add a custom search domain? \\n (This is only for advanced users who have their own domain)\\n' "${r}" "${c}"
	then
		until [ "${DomainSettingsCorrect}" == true ]
		do
			if pivpnSEARCHDOMAIN=$(whiptail --inputbox 'Enter Custom Domain\\nFormat: mydomain.com' "${r}" "${c}" --title 'Custom Domain' 3> /dev/stdout > /dev/stderr 2>&3)
			then
				if validDomain "${pivpnSEARCHDOMAIN}"
				then
					whiptail --backtitle 'Custom Search Domain' --title 'Custom Search Domain' --yesno "Are these settings correct?\\n    Custom Search Domain: ${pivpnSEARCHDOMAIN}" "${r}" "${c}" && \
						DomainSettingsCorrect=true || \
						DomainSettingsCorrect=false
				else
					whiptail --msgbox --backtitle 'Invalid Domain' --title 'Invalid Domain' "Domain is invalid. Please try again.\\n\\n    DOMAIN:   ${pivpnSEARCHDOMAIN}\\n" "${r}" "${c}"
					DomainSettingsCorrect=false
				fi
			else
				echo '::: Cancel selected. Exiting...'
				exit 1
			fi
		done
	fi

	echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
}

askPublicIPOrDNS() {
	local publicDNSCorrect
	local publicDNSValid

	if ! IPv4pub=$(dig +short myip.opendns.com @208.67.222.222) || \
		! validIP "$IPv4pub"
	then
		echo 'dig failed, now trying to curl checkip.amazonaws.com'

		if ! IPv4pub=$(curl -sSf https://checkip.amazonaws.com) || \
			! validIP "$IPv4pub"
		then
			echo 'checkip.amazonaws.com failed, please check your internet connection/DNS'
			exit 1
		fi
	fi

	if [ "${runUnattended}" == true ]
	then
		if [ -z "${pivpnHOST}" ]
		then
			echo "::: No IP or domain name specified, using public IP ${IPv4pub}"
			pivpnHOST="${IPv4pub}"
		else
			if validIP "$pivpnHOST"
			then
				echo "::: Using public IP ${pivpnHOST}"
			elif validDomain "${pivpnHOST}"
			then
				echo "::: Using domain name ${pivpnHOST}"
			else
				echo "::: ${pivpnHOST} is not a valid IP or domain name"
				exit 1
			fi
		fi

		echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
		return
	fi

	if METH=$(whiptail --title 'Public IP or DNS' --radiolist 'Will clients use a Public IP or DNS Name to connect to your server (press space to select)?' "${r}" "${c}" 2 \
		"${IPv4pub}" 'Use this public IP' 'ON' \
		'DNS Entry' 'Use a public DNS' 'OFF' 3> /dev/stdout > /dev/stderr 2>&3)
	then
		if [ "${METH}" == "${IPv4pub}" ]
		then
			pivpnHOST="${IPv4pub}"
		else
			until [ "${publicDNSCorrect}" == true ]
			do
				until [ "${publicDNSValid}" == true ]
				do
					if PUBLICDNS=$(whiptail --title 'PiVPN Setup' --inputbox 'What is the public DNS name of this Server?' "${r}" "${c}" 3> /dev/stdout > /dev/stderr 2>&3)
					then
						if validDomain "${PUBLICDNS}"
						then
							publicDNSValid=true
							pivpnHOST="${PUBLICDNS}"
						else
							whiptail --msgbox --backtitle 'PiVPN Setup' --title 'Invalid DNS name' "This DNS name is invalid. Please try again.\\n\\n    DNS name:   ${PUBLICDNS}\\n" "${r}" "${c}"
							publicDNSValid=false
						fi
					else
						echo '::: Cancel selected. Exiting...'
						exit 1
					fi
				done

				if whiptail --backtitle 'PiVPN Setup' --title 'Confirm DNS Name' --yesno "Is this correct?\\n\\n Public DNS Name:  ${PUBLICDNS}" "${r}" "${c}"
				then
					publicDNSCorrect=true
				else
					publicDNSCorrect=false
					publicDNSValid=false
				fi
			done
		fi
	else
		echo '::: Cancel selected. Exiting...'
		exit 1
	fi

	echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
}

askEncryption() {
	if [ "${runUnattended}" == true ]
	then
		if [ -z "${TWO_POINT_FOUR}" ] || \
			[ $TWO_POINT_FOUR -eq 1 ]
		then
			TWO_POINT_FOUR=1

			echo '::: Using OpenVPN 2.4 features'

			[ -z "${pivpnENCRYPT}" ] && \
				pivpnENCRYPT=256

			if [ $pivpnENCRYPT -eq 256 ] || \
				[ $pivpnENCRYPT -eq 384 ] || \
				[ $pivpnENCRYPT -eq 521 ]
			then
				echo "::: Using a ${pivpnENCRYPT}-bit certificate"
			else
				echo "::: ${pivpnENCRYPT} is not a valid certificate size, use 256, 384, or 521"
				exit 1
			fi
		else
			TWO_POINT_FOUR=0

			echo '::: Using traditional OpenVPN configuration'

			[ -z "${pivpnENCRYPT}" ] && \
				pivpnENCRYPT=2048

			if [ $pivpnENCRYPT -eq 2048 ] || \
				[ $pivpnENCRYPT -eq 3072 ] || \
				[ $pivpnENCRYPT -eq 4096 ]
			then
				echo "::: Using a ${pivpnENCRYPT}-bit certificate"
			else
				echo "::: ${pivpnENCRYPT} is not a valid certificate size, use 2048, 3072, or 4096"
				exit 1
			fi

			[ -z "${USE_PREDEFINED_DH_PARAM}" ] && \
				USE_PREDEFINED_DH_PARAM=1

			[ $USE_PREDEFINED_DH_PARAM -eq 1 ] && \
				echo '::: Pre-defined DH parameters will be used' || \
				echo '::: DH parameters will be generated locally'
		fi

		{
			echo "TWO_POINT_FOUR=${TWO_POINT_FOUR}"
			echo "pivpnENCRYPT=${pivpnENCRYPT}"
			echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
		} >> "${tempsetupVarsFile}"
		return
	fi

	if [ $CUSTOMIZE -eq 0 ]
	then
		if [ "${VPN}" == 'openvpn' ]
		then
			TWO_POINT_FOUR=1
			pivpnENCRYPT=256

			{
				echo "TWO_POINT_FOUR=${TWO_POINT_FOUR}"
				echo "pivpnENCRYPT=${pivpnENCRYPT}"
				echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
			} >> "${tempsetupVarsFile}"
			return
		fi
	fi

	if whiptail --backtitle 'Setup OpenVPN' --title 'Installation mode' --yesno "OpenVPN 2.4 can take advantage of Elliptic Curves to provide higher connection speed and improved security over RSA, while keeping smaller certificates.\\n\\nMoreover, the 'tls-crypt' directive encrypts the certificates being used while authenticating, increasing privacy.\\n\\nIf your clients do run OpenVPN 2.4 or later you can enable these features, otherwise choose 'No' for best compatibility." "${r}" "${c}"
	then
		TWO_POINT_FOUR=1
		pivpnENCRYPT=$(whiptail --backtitle 'Setup OpenVPN' --title 'ECDSA certificate size' --radiolist \
			'Choose the desired size of your certificate (press space to select):\\nThis is a certificate that will be generated on your system. The larger the certificate, the more time this will take. For most applications, it is recommended to use 256 bits. You can increase the number of bits if you care about, however, consider that 256 bits are already as secure as 3072 bit RSA.' "${r}" "${c}" 3 \
			'256' 'Use a 256-bit certificate (recommended level)' ON \
			'384' 'Use a 384-bit certificate' OFF \
			'521' 'Use a 521-bit certificate (paranoid level)' OFF 3> /dev/stdout > /dev/stderr 2>&3)
	else
		TWO_POINT_FOUR=0
		pivpnENCRYPT=$(whiptail --backtitle 'Setup OpenVPN' --title 'RSA certificate size' --radiolist \
			'Choose the desired size of your certificate (press space to select):\\nThis is a certificate that will be generated on your system. The larger the certificate, the more time this will take. For most applications, it is recommended to use 2048 bits. If you are paranoid about ... things... then grab a cup of joe and pick 4096 bits.' "${r}" "${c}" 3 \
			'2048' 'Use a 2048-bit certificate (recommended level)' ON \
			'3072' 'Use a 3072-bit certificate ' OFF \
			'4096' 'Use a 4096-bit certificate (paranoid level)' OFF 3> /dev/stdout > /dev/stderr 2>&3)
	fi

	exitstatus=$?

	if [ $exitstatus -ne 0 ]
	then
		echo '::: Cancel selected. Exiting...'
		exit 1
	fi

	[ $pivpnENCRYPT -ge 2048 ] && \
		whiptail --backtitle 'Setup OpenVPN' --title 'Generate Diffie-Hellman Parameters' --yesno "Generating DH parameters can take many hours on a Raspberry Pi. You can instead use Pre-defined DH parameters recommended by the Internet Engineering Task Force.\\n\\nMore information about those can be found here: https://wiki.mozilla.org/Security/Archive/Server_Side_TLS_4.0#Pre-defined_DHE_groups\\n\\nIf you want unique parameters, choose 'No' and new Diffie-Hellman parameters will be generated on your device." "${r}" "${c}" && \
		USE_PREDEFINED_DH_PARAM=1 || \
		USE_PREDEFINED_DH_PARAM=0

	{
		echo "TWO_POINT_FOUR=${TWO_POINT_FOUR}"
		echo "pivpnENCRYPT=${pivpnENCRYPT}"
		echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
	} >> "${tempsetupVarsFile}"
}

cidrToMask() {
	# Source: https://stackoverflow.com/a/20767392
	set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0

	shift "$1"

	echo "${1-0}.${2-0}.${3-0}.${4-0}"
}

confOpenVPN() {
	declare -A ECDSA_MAP
	local NEW_UUID
	local message
	local extended_mask

	# Grab the existing Hostname
	host_name=$(hostname -s)

	# Generate a random UUID for this server so that we can use verify-x509-name later that is unique for this server installation.
	NEW_UUID=$(< /proc/sys/kernel/random/uuid)

	# Create a unique server name using the host name and UUID
	SERVER_NAME="${host_name}_${NEW_UUID}"

	# Backup the openvpn folder
	NOW_TIME=$(date +%Y-%m-%d-%H%M%S)

	echo "::: Backing up the openvpn folder to /etc/openvpn_${NOW_TIME}.tar.gz"

	"${SUDO}" tar -czf "/etc/openvpn_${NOW_TIME}.tar.gz" /etc/openvpn &> /dev/null
	chmod 700 "/etc/openvpn_${NOW_TIME}.tar.gz"

	[ -f /etc/openvpn/server.conf ] && \
		"${SUDO}" rm /etc/openvpn/server.conf

	[ -d /etc/openvpn/ccd ] && \
		"${SUDO}" rm -rf /etc/openvpn/ccd

	# Create folder to store client specific directives used to push static IPs
	"${SUDO}" mkdir /etc/openvpn/ccd

	# If easy-rsa exists, remove it
	[ -d /etc/openvpn/easy-rsa/ ] && \
		"${SUDO}" rm -rf /etc/openvpn/easy-rsa/

	# Get easy-rsa
	curl -sSfL "${easyrsaRel}" | \
		"${SUDO}" tar -xz --one-top-level=/etc/openvpn/easy-rsa --strip-components 1

	if ! test -s /etc/openvpn/easy-rsa/easyrsa
	then
		echo "$0: ERR: Failed to download EasyRSA."
		exit 1
	fi

	# fix ownership
	"${SUDO}" chown -R root:root /etc/openvpn/easy-rsa
	"${SUDO}" mkdir /etc/openvpn/easy-rsa/pki
	"${SUDO}" chmod 700 /etc/openvpn/easy-rsa/pki

	cd /etc/openvpn/easy-rsa || exit 1

	if [ $TWO_POINT_FOUR -eq 1 ]
	then
		pivpnCERT='ec'
		pivpnTLSPROT='tls-crypt'
	else
		pivpnCERT='rsa'
		pivpnTLSPROT='tls-auth'
	fi

	# Remove any previous keys
	"${SUDOE}" ./easyrsa --batch init-pki

	# Copy template vars file
	"${SUDOE}" cp vars.example pki/vars

	# Set elliptic curve certificate or traditional rsa certificates
	"${SUDOE}" sed -iEe "s/\#set_var EASYRSA_ALGO.*/set_var EASYRSA_ALGO ${pivpnCERT}/" pki/vars

	# Set expiration for the CRL to 10 years
	"${SUDOE}" sed -iEe 's/\#set_var EASYRSA_CRL_DAYS.*/set_var EASYRSA_CRL_DAYS 3650/' pki/vars

	if [ $pivpnENCRYPT -ge 2048 ]
	then
		# Set custom key size if different from the default
		"${SUDOE}" sed -iEe "s/\#set_var EASYRSA_KEY_SIZE.*/set_var EASYRSA_KEY_SIZE ${pivpnENCRYPT}/" pki/vars
	else
		# If less than 2048, then it must be 521 or lower, which means elliptic curve certificate was selected.
		# We set the curve in this case.
		ECDSA_MAP=(['256']='prime256v1')
		ECDSA_MAP+=(['384']='secp384r1')
		ECDSA_MAP+=(['521']='secp521r1')

		"${SUDOE}" sed -iEe "s/\#set_var EASYRSA_CURVE.*/set_var EASYRSA_CURVE ${ECDSA_MAP["${pivpnENCRYPT}"]}/" pki/vars
	fi

	# Build the certificate authority
	printf '::: Building CA...\\n'

	"${SUDOE}" ./easyrsa --batch build-ca nopass

	printf '\\n::: CA Complete.\\n'

	[ "${pivpnCERT}" == 'rsa' ] && \
		[ $USE_PREDEFINED_DH_PARAM -ne 1 ] && \
		message=', Diffie-Hellman parameters,'
	
	[ "${pivpnCERT}" == 'ec' ] || \
		{ [ "${pivpnCERT}" == 'rsa' ] && [ $USE_PREDEFINED_DH_PARAM -eq 1 ] } && \
		message=''

	[ "${runUnattended}" == true ] && \
		echo "::: The server key${message} and HMAC key will now be generated." || \
		whiptail --msgbox --backtitle 'Setup OpenVPN' --title 'Server Information' "::: The server key${message} and HMAC key will now be generated." "${r}" "${c}"

	# Build the server
	EASYRSA_CERT_EXPIRE=3650 "${SUDOE}" ./easyrsa build-server-full "${SERVER_NAME}" nopass

	if [ "${pivpnCERT}" == 'rsa' ]
	then
		if [ $USE_PREDEFINED_DH_PARAM -eq 1 ]
		then
			# Use Diffie-Hellman parameters from RFC 7919 (FFDHE)
			"${SUDOE}" install -m 644 "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/ffdhe${pivpnENCRYPT}.pem" "pki/dh${pivpnENCRYPT}.pem"
		else
			# Generate Diffie-Hellman key exchange
			"${SUDOE}" ./easyrsa gen-dh
			"${SUDOE}" mv pki/dh.pem "pki/dh${pivpnENCRYPT}".pem
		fi
	fi

	# Generate static HMAC key to defend against DDoS
	"${SUDOE}" openvpn --genkey --secret pki/ta.key

	# Generate an empty Certificate Revocation List
	"${SUDOE}" ./easyrsa gen-crl
	"${SUDOE}" cp pki/crl.pem /etc/openvpn/crl.pem

	getent passwd openvpn || \
		"${SUDOE}" adduser --system --home /var/lib/openvpn/ --group --disabled-login "${debianOvpnUserGroup%:*}"

	"${SUDOE}" chown "${debianOvpnUserGroup}" /etc/openvpn/crl.pem

	# Write config file for server using the template.txt file
	"${SUDO}" install -m 644 "${pivpnFilesDir}/files/etc/openvpn/server_config.txt" /etc/openvpn/server.conf

	# Apply client DNS settings
	"${SUDOE}" sed -iEe "0,/(dhcp-option DNS )/ s/(dhcp-option DNS ).*/\1${pivpnDNS1}\"/" /etc/openvpn/server.conf

	[ -z "${pivpnDNS2}" ] && \
		"${SUDOE}" sed -iEe '/(dhcp-option DNS )/{n;N;d}' /etc/openvpn/server.conf || \
		"${SUDOE}" sed -iEe "0,/(dhcp-option DNS )/! s/(dhcp-option DNS ).*/\1${pivpnDNS2}\"/" /etc/openvpn/server.conf

	# Set the user encryption key size
	"${SUDO}" sed -iEe "s/(dh \/etc\/openvpn\/easy\-rsa\/pki\/dh).*/\1${pivpnENCRYPT}.pem/" /etc/openvpn/server.conf

	# If they enabled 2.4 use tls-crypt instead of tls-auth to encrypt control channel
	[ "${pivpnTLSPROT}" == 'tls-crypt' ] && \
		"${SUDO}" sed -iEe 's/tls-auth \/etc\/openvpn\/easy\-rsa\/pki\/ta.key 0/tls\-crypt \/etc\/openvpn\/easy\-rsa\/pki\/ta.key/' /etc/openvpn/server.conf

	# If they enabled 2.4 disable dh parameters and specify the matching curve from the ECDSA certificate
	[ "${pivpnCERT}" == 'ec' ] && \
		"${SUDO}" sed -iEe "s/(dh \/etc\/openvpn\/easy\-rsa\/pki\/dh).*/dh none\necdh\-curve ${ECDSA_MAP["${pivpnENCRYPT}"]}/" /etc/openvpn/server.conf
	
	# Otherwise set the user encryption key size
	[ "${pivpnCERT}" == 'rsa' ] && \
		"${SUDO}" sed -iEe "s/(dh \/etc\/openvpn\/easy\-rsa\/pki\/dh).*/\1${pivpnENCRYPT}.pem/" /etc/openvpn/server.conf

	# if they modified VPN network put value in server.conf
	[ "${pivpnNET}" != '10.8.0.0' ] && \
		"${SUDO}" sed -iEe "s/10\.8\.0\.0/${pivpnNET}/g" /etc/openvpn/server.conf

	extended_mask=$(cidrToMask "${subnetClass}")

	# if they modified VPN subnet class put value in server.conf
	[ "${extended_mask}" != '255.255.255.0' ] && \
		"${SUDO}" sed -iEe "s/255\.255\.255\.0/${extended_mask}/g" /etc/openvpn/server.conf

	# if they modified port put value in server.conf
	[ $pivpnPORT -ne 1194 ] && \
		"${SUDO}" sed -iEe "s/1194/${pivpnPORT}/g" /etc/openvpn/server.conf

	# if they modified protocol put value in server.conf
	[ "${pivpnPROTO}" != 'udp' ] && \
		"${SUDO}" sed -iEe 's/proto udp/proto tcp/g' /etc/openvpn/server.conf

	[ -n "${pivpnSEARCHDOMAIN}" ] && \
		"${SUDO}" sed -iEe "0,/(.*dhcp-option.*)/s//push \"dhcp-option DOMAIN ${pivpnSEARCHDOMAIN}\" \\n&/" /etc/openvpn/server.conf

	# write out server certs to conf file
	"${SUDO}" sed -iEe "s/key \/etc\/openvpn\/easy\-rsa\/pki\/private\/).*/\1${SERVER_NAME}.key/" /etc/openvpn/server.conf
	"${SUDO}" sed -iEe "s/(cert \/etc\/openvpn\/easy\-rsa\/pki\/issued\/).*/\1${SERVER_NAME}.crt/" /etc/openvpn/server.conf
}

confOVPN() {
	"${SUDO}" install -m 644 "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt" /etc/openvpn/easy-rsa/pki/Default.txt

	"${SUDO}" sed -iEe "s/IPv4pub/${pivpnHOST}/" /etc/openvpn/easy-rsa/pki/Default.txt

	# if they modified port put value in Default.txt for clients to use
	[ $pivpnPORT -ne 1194 ] && \
		"${SUDO}" sed -iEe "s/1194/${pivpnPORT}/g" /etc/openvpn/easy-rsa/pki/Default.txt

	# if they modified protocol put value in Default.txt for clients to use
	[ "${pivpnPROTO}" != 'udp' ] && \
		"${SUDO}" sed -iEe 's/proto udp/proto tcp/g' /etc/openvpn/easy-rsa/pki/Default.txt

	# verify server name to strengthen security
	"${SUDO}" sed -iEe "s/SRVRNAME/${SERVER_NAME}/" /etc/openvpn/easy-rsa/pki/Default.txt

	# If they enabled 2.4 remove key-direction options since it's not required
	[ "${pivpnTLSPROT}" == 'tls-crypt' ] && \
		"${SUDO}" sed -iEe '/key-direction 1/d' /etc/openvpn/easy-rsa/pki/Default.txt
}

confWireGuard() {
	local NOW_TIME
	local private_key

	# Reload job type is not yet available in wireguard-tools shipped with Ubuntu 20.04
	if ! grep -qsEe 'ExecReload' /lib/systemd/system/wg-quick@.service
	then
		echo '::: Adding additional reload job type for wg-quick unit'

		"${SUDO}" install -D -m 644 "${pivpnFilesDir}/files/etc/systemd/system/wg-quick@.service.d/override.conf" /etc/systemd/system/wg-quick@.service.d/override.conf
		"${SUDO}" systemctl daemon-reload
	fi

	if [ -d /etc/wireguard ]
	then
		# Backup the wireguard folder
		NOW_TIME=$(date +%Y-%m-%d-%H%M%S)

		echo "::: Backing up the wireguard folder to /etc/wireguard_${NOW_TIME}.tar.gz"

		"${SUDO}" tar -czf "/etc/wireguard_${NOW_TIME}.tar.gz" /etc/wireguard &> /dev/null
		chmod 700 "/etc/wireguard_${NOW_TIME}.tar.gz"

		[ -f /etc/wireguard/wg0.conf ] && \
			"${SUDO}" rm /etc/wireguard/wg0.conf
	else
		# If compiled from source, the wireguard folder is not being created
		"${SUDO}" mkdir /etc/wireguard
	fi

	# Ensure that only root is able to enter the wireguard folder
	"${SUDO}" chown root:root /etc/wireguard
	"${SUDO}" chmod 700 /etc/wireguard

	[ "${runUnattended}" == true ] && \
		echo '::: The Server Keys will now be generated.' || \
		whiptail --title 'Server Information' --msgbox 'The Server Keys will now be generated.' "${r}" "${c}"

	# Remove configs and keys folders to make space for a new server when using 'Repair' or 'Reconfigure'
	# over an existing installation
	"${SUDO}" rm -rf /etc/wireguard/configs
	"${SUDO}" rm -rf /etc/wireguard/keys

	"${SUDO}" mkdir -p /etc/wireguard/configs
	"${SUDO}" touch /etc/wireguard/configs/clients.txt
	"${SUDO}" mkdir -p /etc/wireguard/keys

	# Generate private key and derive public key from it
	private_key=$(wg genkey | \
		"${SUDO}" tee /etc/wireguard/keys/server_priv)
	echo "${private_key}" | \
		wg pubkey | \
		"${SUDO}" tee /etc/wireguard/keys/server_pub &> /dev/null

	echo '::: Server Keys have been generated.'

	echo '[Interface]' | "${SUDO}" tee /etc/wireguard/wg0.conf &> /dev/null
	echo "PrivateKey == ${private_key}" | "${SUDO}" tee /etc/wireguard/wg0.conf &> /dev/null
	echo -n "Address == ${vpnGw}/${subnetClass}" | "${SUDO}" tee /etc/wireguard/wg0.conf &> /dev/null
	[ $pivpnenableipv6 -eq 1 ] && \
		echo ",${vpnGwv6}/${subnetClassv6}" | "${SUDO}" tee /etc/wireguard/wg0.conf &> /dev/null || \
		echo | "${SUDO}" tee /etc/wireguard/wg0.conf &> /dev/null
	echo "MTU == ${pivpnMTU}" | "${SUDO}" tee /etc/wireguard/wg0.conf &> /dev/null
	echo "ListenPort == ${pivpnPORT}" | "${SUDO}" tee /etc/wireguard/wg0.conf &> /dev/null

	echo '::: Server config generated.'
}

confNetwork() {
	# Enable forwarding of internet traffic
	"${SUDO}" sed -iEe '/net\.ipv4\.ip_forward\=1/s/^#//g' /etc/sysctl.conf

	if [ $pivpnenableipv6 -eq 1 ]
	then
		"${SUDO}" sed -iEe '/net\.ipv6\.conf\.all\.forwarding\=1/s/^#//g' /etc/sysctl.conf

		echo "net.ipv6.conf.${IPv6dev}.accept_ra=2" | \
			"${SUDO}" tee /etc/sysctl.d/99-pivpn.conf > /dev/null
	fi

	"${SUDO}" sysctl -p > /dev/null

	if [ $USING_UFW -eq 1 ]
	then
		echo '::: Detected UFW is enabled.'
		echo '::: Adding UFW rules...'

		### Basic safeguard: if file is empty, there's been something weird going on.
		### Note: no safeguard against imcomplete content as a result of previous failures.
		if test -s /etc/ufw/before.rules
		then
			"${SUDO}" cp -f /etc/ufw/before.rules /etc/ufw/before.rules.pre-pivpn
		else
			echo "$0: ERR: Sorry, won't touch empty file \"/etc/ufw/before.rules\"."
			exit 1
		fi

		if test -s /etc/ufw/before6.rules
		then
			"${SUDO}" cp -f /etc/ufw/before6.rules /etc/ufw/before6.rules.pre-pivpn
		else
			echo "$0: ERR: Sorry, won't touch empty file \"/etc/ufw/before6.rules\"."
			exit 1
		fi

		### If there is already a "*nat" section just add our POSTROUTING MASQUERADE
		if "${SUDO}" grep -qsEe '.*nat' /etc/ufw/before.rules
		then
			### Onyl add the IPv4 NAT rule if it isn't already there
			"${SUDO}" grep -qsEe "${VPN}\-nat\-rule" /etc/ufw/before.rules || \
				"${SUDO}" sed -iEe "/^.*nat/\n;s/(:POSTROUTING ACCEPT .*)/\1\n\-I POSTROUTING \-s ${pivpnNET}\/${subnetClass} \-o ${IPv4dev} \-j MASQUERADE \-m comment \-\-comment ${VPN}\-nat\-rule/}" /etc/ufw/before.rules
		else
			"${SUDO}" sed -iEe "/delete these required/i .*nat\n\:POSTROUTING ACCEPT \[0\:0\]\n\-I POSTROUTING \-s ${pivpnNET}\/${subnetClass} \-o ${IPv4dev} \-j MASQUERADE \-m comment \-\-comment ${VPN}\-nat\-rule\nCOMMIT\n" /etc/ufw/before.rules
		fi

		if [ $pivpnenableipv6 -eq 1 ]
		then
			if "${SUDO}" grep -qsEe '.*nat' /etc/ufw/before6.rules
			then
				### Onyl add the IPv6 NAT rule if it isn't already there
				"${SUDO}" grep -qsEe "${VPN}\-nat\-rule" /etc/ufw/before6.rules || \
					"${SUDO}" sed -iEe "/^.*nat/{n;s/(:POSTROUTING ACCEPT .*)/\1\n\-I POSTROUTING \-s ${pivpnNETv6}\/${subnetClassv6} \-o ${IPv6dev} \-j MASQUERADE \-m comment \-\-comment ${VPN}\-nat\-rule/}" /etc/ufw/before6.rules
			else
				"${SUDO}" sed -iEe "/delete these required/i .*nat\n\:POSTROUTING ACCEPT \[0\:0\]\n\-I POSTROUTING \-s ${pivpnNETv6}\/${subnetClassv6} \-o ${IPv6dev} \-j MASQUERADE \-m comment \-\-comment ${VPN}\-nat\-rule\nCOMMIT\n" /etc/ufw/before6.rules
			fi
		fi

		# Insert rules at the beginning of the chain (in case there are other rules that may drop the traffic)
		"${SUDO}" ufw insert 1 allow "${pivpnPORT}"/"${pivpnPROTO}" comment "allow-${VPN}" >/dev/null
		"${SUDO}" ufw route insert 1 allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any >/dev/null
		
		if [ $pivpnenableipv6 -eq 1 ]
		then
			"${SUDO}" ufw route insert 1 allow in on "${pivpnDEV}" from "${pivpnNETv6}/${subnetClassv6}" out on "${IPv6dev}" to any >/dev/null
		fi

		"${SUDO}" ufw reload >/dev/null

		echo '::: UFW configuration completed.'
	else
		# Now some checks to detect which rules we need to add. On a newly installed system all policies
		# should be ACCEPT, so the only required rule would be the MASQUERADE one.

		"${SUDO}" iptables -t nat -S | \
			grep -qsEe "${VPN}\-nat\-rule" || \
			"${SUDO}" iptables -t nat -I POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"

		if [ $pivpnenableipv6 -eq 1 ]
		then
			"${SUDO}" ip6tables -t nat -S | \
				grep -qsEe "${VPN}\-nat\-rule" || \
				"${SUDO}" ip6tables -t nat -I POSTROUTING -s "${pivpnNETv6}/${subnetClassv6}" -o "${IPv6dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
		fi
		# Count how many rules are in the INPUT and FORWARD chain. When parsing input from
		# iptables -S, '^-P' skips the policies and 'ufw-' skips ufw chains (in case ufw was found
		# installed but not enabled).

		# Grep returns non 0 exit code where there are no matches, however that would make the script exit,
		# for this reasons we use '|| true' to force exit code 0
		INPUT_RULES_COUNT=$("${SUDO}" iptables -S INPUT | \
			grep -vcsEe '(^\-P|ufw\-)')
		FORWARD_RULES_COUNT=$("${SUDO}" iptables -S FORWARD | \
			grep -vcsEe '(^\-P|ufw\-)')
		INPUT_POLICY=$("${SUDO}" iptables -S INPUT | \
			grep -sEe '^\-P' | \
			awk '{print $3}')
		FORWARD_POLICY=$("${SUDO}" iptables -S FORWARD | \
			grep -sEe '^\-P' | \
			awk '{print $3}')

		if [ $pivpnenableipv6 -eq 1 ]
		then
			INPUT_RULES_COUNTv6=$("${SUDO}" ip6tables -S INPUT | \
				grep -vcsEe '(^\-P|ufw\-)')
			FORWARD_RULES_COUNTv6=$("${SUDO}" ip6tables -S FORWARD | \
				grep -vcsEe '(^\-P|ufw\-)')
			INPUT_POLICYv6=$("${SUDO}" ip6tables -S INPUT | \
				grep -sEe '^\-P' | \
				awk '{print $3}')
			FORWARD_POLICYv6=$("${SUDO}" ip6tables -S FORWARD | \
				grep -sEe '^\-P' | \
				awk '{print $3}')
		fi

		# If rules count is not zero, we assume we need to explicitly allow traffic. Same conclusion if
		# there are no rules and the policy is not ACCEPT. Note that rules are being added to the top of the
		# chain (using -I).

		if [ $INPUT_RULES_COUNT -ne 0 ] || \\
			[ "${INPUT_POLICY}" != 'ACCEPT' ]
		then
			"${SUDO}" iptables -S | \
				grep -qsEe "${VPN}\-input\-rule" || \
				"${SUDO}" iptables -I INPUT 1 -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule"

			INPUT_CHAIN_EDITED=1
		else
			INPUT_CHAIN_EDITED=0
		fi

		if [ $pivpnenableipv6 -eq 1 ]
		then
			if [ $INPUT_RULES_COUNTv6 -ne 0 ] || \
				[ "${INPUT_POLICYv6}" != 'ACCEPT' ]
			then
				"${SUDO}" ip6tables -S | \
					grep -qsEe "${VPN}\-input\-rule" || \
					"${SUDO}" ip6tables -I INPUT 1 -i "${IPv6dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule"

				INPUT_CHAIN_EDITEDv6=1
			else
				INPUT_CHAIN_EDITEDv6=0
			fi
		fi

		if [ $FORWARD_RULES_COUNT -ne 0 ] || \
			[ "${FORWARD_POLICY}" != 'ACCEPT' ]
		then
			if ! "${SUDO}" iptables -S | \
				grep -qsEe "${VPN}\-forward\-rule"
			then
				"${SUDO}" iptables -I FORWARD 1 -d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
				"${SUDO}" iptables -I FORWARD 2 -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
			fi

			FORWARD_CHAIN_EDITED=1
		else
			FORWARD_CHAIN_EDITED=0
		fi

		if [ $pivpnenableipv6 -eq 1 ]
		then
			if [ $FORWARD_RULES_COUNTv6 -ne 0 ] || \
				[ "${FORWARD_POLICYv6}" != 'ACCEPT' ]
			then
				if ! "${SUDO}" ip6tables -S | \
					grep -qsEe "${VPN}\-forward\-rule"
				then
					"${SUDO}" ip6tables -I FORWARD 1 -d "${pivpnNETv6}/${subnetClassv6}" -i "${IPv6dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
					"${SUDO}" ip6tables -I FORWARD 2 -s "${pivpnNETv6}/${subnetClassv6}" -i "${pivpnDEV}" -o "${IPv6dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
				fi

				FORWARD_CHAIN_EDITEDv6=1
			else
				FORWARD_CHAIN_EDITEDv6=0
			fi
		fi

		case "${PLAT}" in
			Debian | Raspbian | Ubuntu)
				"${SUDO}" iptables-save | \
					"${SUDO}" tee /etc/iptables/rules.v4 > /dev/null

				"${SUDO}" ip6tables-save | \
					"${SUDO}" tee /etc/iptables/rules.v6 > /dev/null
				;;
			*)
				;;
		esac

		{
			echo "INPUT_CHAIN_EDITED=${INPUT_CHAIN_EDITED}"
			echo "FORWARD_CHAIN_EDITED=${FORWARD_CHAIN_EDITED}"
			echo "INPUT_CHAIN_EDITEDv6=${INPUT_CHAIN_EDITEDv6}"
			echo "FORWARD_CHAIN_EDITEDv6=${FORWARD_CHAIN_EDITEDv6}"
		} >> "${tempsetupVarsFile}"
	fi
}

confLogging() {
	# Pre-create rsyslog/logrotate config directories if missing, to assure logs are handled as expected when those are installed at a later time
	"${SUDO}" mkdir -p /etc/rsyslog.d /etc/logrotate.d

	echo "if \$programname == 'ovpn-server' then /var/log/openvpn.log" | "${SUDO}" tee /etc/rsyslog.d/30-openvpn.conf > /dev/null
	echo "if \$programname == 'ovpn-server' then stop" | "${SUDO}" tee /etc/rsyslog.d/30-openvpn.conf > /dev/null

	echo '/var/log/openvpn.log' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo '{' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'rotate 4' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'weekly' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'missingok' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'notifempty' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'compress' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'delaycompress' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'sharedscripts' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'postrotate' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' $'\t' 'invoke-rc.d rsyslog rotate >/dev/null 2> /dev/stdout || true' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo $'\t' 'endscript' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null
	echo '}' | "${SUDO}" tee /etc/logrotate.d/openvpn > /dev/null

	# Restart the logging service
	case "${PLAT}" in
		Debian | Raspbian | Ubuntu)
			"${SUDO}" systemctl -q is-active rsyslog.service && \
				"${SUDO}" systemctl restart rsyslog.service
			;;
		*)
			;;
	esac
}

restartServices() {
	# Start services
	echo '::: Restarting services...'

	case "${PLAT}" in
		Debian | Raspbian | Ubuntu)
			if [ "${VPN}" == 'openvpn' ]
			then
				"${SUDO}" systemctl enable openvpn.service &> /dev/null
				"${SUDO}" systemctl restart openvpn.service
			elif [ "${VPN}" == 'wireguard' ]
			then
				"${SUDO}" systemctl enable wg-quick@wg0.service &> /dev/null
				"${SUDO}" systemctl restart wg-quick@wg0.service
			fi
			;;
		*)
			;;
	esac
}

askUnattendedUpgrades() {
	if [ "${runUnattended}" == true ]
	then
		if [ -z "${UNATTUPG}" ]
		then
			UNATTUPG=1
			echo '::: No preference regarding unattended upgrades, assuming yes'
		else
			[ $UNATTUPG -eq 1 ] && \
				echo '::: Enabling unattended upgrades' || \
				echo '::: Skipping unattended upgrades'
		fi

		echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
		return
	fi

	whiptail --msgbox --backtitle 'Security Updates' --title 'Unattended Upgrades' 'Since this server will have at least one port open to the internet, it is recommended you enable unattended-upgrades.\\nThis feature will check daily for security package updates only and apply them when necessary.\\nIt will NOT automatically reboot the server so to fully apply some updates you should periodically reboot.' "${r}" "${c}"

	whiptail --backtitle 'Security Updates' --title 'Unattended Upgrades' --yesno 'Do you want to enable unattended upgrades of security patches to this server?' "${r}" "${c}" && \
		UNATTUPG=1 || \
		UNATTUPG=0

	echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
}

confUnattendedUpgrades() {
	local PIVPN_DEPS

	PIVPN_DEPS=(unattended-upgrades)

	installDependentPackages PIVPN_DEPS[@]

	if [ "$PLAT" == 'Ubuntu' ]
	then
		# Ubuntu 50unattended-upgrades should already just have security enabled
		# so we just need to configure the 10periodic file
		echo 'APT::Periodic::Update-Package-Lists "1";' | "${SUDO}" tee /etc/apt/apt.conf.d/10periodic > /dev/null
		echo 'APT::Periodic::Download-Upgradeable-Packages "1";' | "${SUDO}" tee /etc/apt/apt.conf.d/10periodic > /dev/null
		echo 'APT::Periodic::AutocleanInterval "5";' | "${SUDO}" tee /etc/apt/apt.conf.d/10periodic > /dev/null
		echo 'APT::Periodic::Unattended-Upgrade "1";' | "${SUDO}" tee /etc/apt/apt.conf.d/10periodic > /dev/null
	else
		# Raspbian's unattended-upgrades package downloads Debian's config, so we copy over the proper config
		# Source: https://github.com/mvo5/unattended-upgrades/blob/master/data/50unattended-upgrades.Raspbian
		[ "$PLAT" == 'Raspbian' ] && \
			"${SUDO}" install -m 644 "${pivpnFilesDir}/files/etc/apt/apt.conf.d/50unattended-upgrades.Raspbian" /etc/apt/apt.conf.d/50unattended-upgrades

		# Add the remaining settings for all other distributions
		echo 'APT::Periodic::Enable "1";' | "${SUDO}" tee /etc/apt/apt.conf.d/02periodic > /dev/null
		echo 'APT::Periodic::Update-Package-Lists "1";' | "${SUDO}" tee /etc/apt/apt.conf.d/02periodic > /dev/null
		echo 'APT::Periodic::Download-Upgradeable-Packages "1";' | "${SUDO}" tee /etc/apt/apt.conf.d/02periodic > /dev/null
		echo 'APT::Periodic::Unattended-Upgrade "1";' | "${SUDO}" tee /etc/apt/apt.conf.d/02periodic > /dev/null
		echo 'APT::Periodic::AutocleanInterval "7";' | "${SUDO}" tee /etc/apt/apt.conf.d/02periodic > /dev/null
		echo 'APT::Periodic::Verbose "0";' | "${SUDO}" tee /etc/apt/apt.conf.d/02periodic > /dev/null
	fi

	# Enable automatic updates via the bullseye repository when installing from debian package
	[ "${VPN}" == 'wireguard' ] && \
		[ -f /etc/apt/sources.list.d/pivpn-bullseye-repo.list ] && \
		grep -qsEe "\"o\=${PLAT},n\=bullseye\";" /etc/apt/apt.conf.d/50unattended-upgrades || \
		"${SUDO}" sed -iEe "/Unattended\-Upgrade\:\:Origins-Pattern {/a\"o\=${PLAT},n\=bullseye\";" /etc/apt/apt.conf.d/50unattended-upgrades
}

writeConfigFiles() {
	# Save installation setting to the final location
	echo "INSTALLED_PACKAGES=(${INSTALLED_PACKAGES[@]})" >> "${tempsetupVarsFile}"
	echo "::: Setupfiles copied to ${setupConfigDir}/${VPN}/${setupVarsFile}"

	"${SUDO}" mkdir -p "${setupConfigDir}/${VPN}/"
	"${SUDO}" cp "${tempsetupVarsFile}" "${setupConfigDir}/${VPN}/${setupVarsFile}"
}

installScripts() {
	# Ensure /opt exists (issue #607)
	"${SUDO}" mkdir -p /opt

	[ "${VPN}" == 'wireguard' ] && \
		othervpn='openvpn' || \
		othervpn='wireguard'

	# Symlink scripts from /usr/local/src/pivpn to their various locations
	echo -n -e "::: Installing scripts to ${pivpnScriptDir}...\n"

	# if the other protocol file exists it has been installed
	if [ -r "${setupConfigDir}/${othervpn}/${setupVarsFile}" ]
	then
		# Both are installed, no bash completion, unlink if already there
		"${SUDO}" unlink /etc/bash_completion.d/pivpn

		# Unlink the protocol specific pivpn script and symlink the common
		# script to the location instead
		"${SUDO}" unlink /usr/local/bin/pivpn
		"${SUDO}" ln -sf -T "${pivpnFilesDir}/scripts/pivpn" /usr/local/bin/pivpn
	else
		# Check if bash_completion scripts dir exists and creates it if not
		[ ! -d /etc/bash_completion.d ] && \
			mkdir -p /etc/bash_copletion.d

		# Only one protocol is installed, symlink bash completion, the pivpn script
		# and the script directory
		"${SUDO}" ln -sfT "${pivpnFilesDir}/scripts/${VPN}/bash-completion" /etc/bash_completion.d/pivpn
		"${SUDO}" ln -sfT "${pivpnFilesDir}/scripts/${VPN}/pivpn.sh" /usr/local/bin/pivpn
		"${SUDO}" ln -sf "${pivpnFilesDir}/scripts/" "${pivpnScriptDir}"

		# shellcheck disable=SC1091
		. /etc/bash_completion.d/pivpn
	fi

	echo ' done.'
}

displayFinalMessage() {
	# Ensure that cached writes reach persistent storage
	echo '::: Flushing writes to disk...'

	sync

	echo '::: done.'

	if [ "${runUnattended}" == true ]
	then
		echo '::: Installation Complete!'
		echo "::: Now run 'pivpn add' to create the client profiles."
		echo "::: Run 'pivpn help' to see what else you can do!"
		echo
		echo '::: If you run into any issue, please read all our documentation carefully.'
		echo '::: All incomplete posts or bug reports will be ignored or deleted.'
		echo
		echo '::: Thank you for using PiVPN.'
		echo '::: It is strongly recommended you reboot after installation.'
		return
	fi

	# Final completion message to user
	whiptail --msgbox --backtitle 'Make it so.' --title 'Installation Complete!' "Now run 'pivpn add' to create the client profiles.
Run 'pivpn help' to see what else you can do!\\n\\nIf you run into any issue, please read all our documentation carefully.
All incomplete posts or bug reports will be ignored or deleted.\\n\\nThank you for using PiVPN." "${r}" "${c}"
	
	if whiptail --title 'Reboot' --yesno --defaultno 'It is strongly recommended you reboot after installation.  Would you like to reboot now?' "${r}" "${c}"
	then
		whiptail --title 'Rebooting' --msgbox 'The system will now reboot.' "${r}" "${c}"
		printf '\\nRebooting system...\\n'

		"${SUDO}" sleep 3
		"${SUDO}" shutdown -r now
	fi
}

main "$@"
