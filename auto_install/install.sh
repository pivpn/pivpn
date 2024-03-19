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
pivpnGitUrl="https://github.com/pivpn/pivpn.git"
# Uncomment to checkout a custom branch for local pivpn files
#pivpnGitBranch="custombranchtocheckout"
setupVarsFile="setupVars.conf"
setupConfigDir="/etc/pivpn"
tempsetupVarsFile="/tmp/setupVars.conf"
pivpnFilesDir="/usr/local/src/pivpn"
pivpnScriptDir="/opt/pivpn"
GITBIN="/usr/bin/git"

piholeSetupVars="/etc/pihole/setupVars.conf"
dnsmasqConfig="/etc/dnsmasq.d/02-pivpn.conf"

dhcpcdFile="/etc/dhcpcd.conf"
ovpnUserGroup="openvpn:openvpn"

######## PKG Vars ########
PKG_MANAGER="apt-get"
### FIXME: quoting UPDATE_PKG_CACHE and PKG_INSTALL hangs the script,
### shellcheck SC2086
UPDATE_PKG_CACHE="${PKG_MANAGER} update -y"
PKG_INSTALL="${PKG_MANAGER} --yes --no-install-recommends install"
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"
CHECK_PKG_INSTALLED='dpkg-query -s'

# Dependencies that are required by the script,
# regardless of the VPN protocol chosen
BASE_DEPS=(git tar curl grep dnsutils grepcidr whiptail net-tools)
BASE_DEPS+=(bsdmainutils bash-completion)

BASE_DEPS_ALPINE=(git grep bind-tools newt net-tools bash-completion coreutils)
BASE_DEPS_ALPINE+=(openssl util-linux openrc iptables ip6tables coreutils sed)
BASE_DEPS_ALPINE+=(perl libqrencode-tools)

# Dependencies that where actually installed by the script. For example if the
# script requires grep and dnsutils but dnsutils is already installed, we save
# grep here. This way when uninstalling PiVPN we won't prompt to remove packages
# that may have been installed by the user for other reasons
INSTALLED_PACKAGES=()

######## URLs ########
easyrsaVer="3.1.0"
easyrsaRel="https://github.com/OpenVPN/easy-rsa/releases/download/v${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"

######## Undocumented Flags. Shhh ########
runUnattended=false
usePiholeDNS=false
skipSpaceCheck=false
reconfigure=false
showUnsupportedNICs=false

######## Some vars that might be empty
# but need to be defined for checks
pivpnPERSISTENTKEEPALIVE=""
pivpnDNS2=""

######## IPv6 related config
# cli parameter "--noipv6" allows to disable IPv6 which also prevents forced
# IPv6 route
# cli parameter "--ignoreipv6leak" allows to skip the forced IPv6 route if
# required (not recommended)

## Force IPv6 through VPN even if IPv6 is not supported by the server
## This will prevent an IPv6 leak on the client site but might cause
## issues on the client site accessing IPv6 addresses.
## This option is useless if routes are set manually.
## It's also irrelevant when IPv6 is (forced) enabled.
pivpnforceipv6route=1

## Enable or disable IPv6.
## Leaving it empty or set to "1" will trigger an IPv6 uplink check
pivpnenableipv6=""

## Enable to skip IPv6 connectivity check and also force client IPv6 traffic
## through wireguard regardless if there is a working IPv6 route on the server.
pivpnforceipv6=0

######## SCRIPT ########

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size="$(stty size 2> /dev/null || echo 24 80)"
rows="$(echo "${screen_size}" | awk '{print $1}')"
columns="$(echo "${screen_size}" | awk '{print $2}')"

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$((rows / 2))
c=$((columns / 2))
# Unless the screen is tiny
r=$((r < 20 ? 20 : r))
c=$((c < 70 ? 70 : c))

# Override localization settings so the output is in English language.
export LC_ALL=C

main() {
  # Pre install checks and configs
  distroCheck
  rootCheck
  flagsCheck "$@"
  unattendedCheck
  checkExistingInstall "$@"
  checkHostname

  # Verify there is enough disk space for the install
  if [[ "${skipSpaceCheck}" == 'true' ]]; then
    echo -n "::: --skip-space-check passed to script, "
    echo "skipping free disk space verification!"
  else
    verifyFreeDiskSpace
  fi

  updatePackageCache
  notifyPackageUpdatesAvailable
  preconfigurePackages

  if [[ "${PLAT}" == 'Alpine' ]]; then
    installDependentPackages BASE_DEPS_ALPINE[@]
  else
    installDependentPackages BASE_DEPS[@]
  fi

  welcomeDialogs

  if [[ "${pivpnforceipv6}" -eq 1 ]]; then
    echo "::: Forced IPv6 config, skipping IPv6 uplink check!"
    pivpnenableipv6=1
  else
    if [[ -z "${pivpnenableipv6}" ]] \
      || [[ "${pivpnenableipv6}" -eq 1 ]]; then
      checkipv6uplink
    fi

    if [[ "${pivpnenableipv6}" -eq 0 ]] \
      && [[ "${pivpnforceipv6route}" -eq 1 ]]; then
      askforcedipv6route
    fi
  fi

  chooseInterface

  if checkStaticIpSupported; then
    getStaticIPv4Settings

    if [[ -z "${dhcpReserv}" ]] \
      || [[ "${dhcpReserv}" -ne 1 ]]; then
      setStaticIPv4
    fi
  else
    staticIpNotSupported
  fi

  chooseUser
  cloneOrUpdateRepos

  # Install
  if installPiVPN; then
    echo "::: Install Complete..."
  else
    exit 1
  fi

  restartServices
  # Ask if unattended-upgrades will be enabled
  askUnattendedUpgrades

  if [[ "${UNATTUPG}" -eq 1 ]]; then
    confUnattendedUpgrades
  fi

  writeConfigFiles
  installScripts
  displayFinalMessage
  echo ":::"
}

####### FUNCTIONS ##########

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

rootCheck() {
  ######## FIRST CHECK ########
  # Must be root to install
  echo ":::"

  if [[ "${EUID}" -eq 0 ]]; then
    echo "::: You are root."
  else
    echo "::: sudo will be used for the install."

    # Check if it is actually installed
    # If it isn't, exit because the install cannot complete
    if eval "${CHECK_PKG_INSTALLED} sudo" &> /dev/null; then
      export SUDO="sudo"
      export SUDOE="sudo -E"
    else
      err "::: Please install sudo or run this as root."
      exit 1
    fi
  fi
}

flagsCheck() {
  # Check arguments for the undocumented flags
  for ((i = 1; i <= "$#"; i++)); do
    j="$((i + 1))"

    case "${!i}" in
      "--skip-space-check")
        skipSpaceCheck=true
        ;;
      "--unattended")
        runUnattended=true
        unattendedConfig="${!j}"
        ;;
      "--use-pihole")
        usePiholeDNS=true
        ;;
      "--reconfigure")
        reconfigure=true
        ;;
      "--show-unsupported-nics")
        showUnsupportedNICs=true
        ;;
      "--giturl")
        pivpnGitUrl="${!j}"
        ;;
      "--gitbranch")
        pivpnGitBranch="${!j}"
        ;;
      "--noipv6")
        pivpnforceipv6=0
        pivpnenableipv6=0
        pivpnforceipv6route=0
        ;;
      "--ignoreipv6leak")
        pivpnforceipv6route=0
        ;;
    esac
  done
}

unattendedCheck() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo -n "::: --unattended passed to install script, "
    echo "no whiptail dialogs will be displayed"

    if [[ -z "${unattendedConfig}" ]]; then
      err "::: No configuration file passed"
      exit 1
    else
      if [[ -r "${unattendedConfig}" ]]; then
        # shellcheck disable=SC1090
        . "${unattendedConfig}"
      else
        err "::: Can't open ${unattendedConfig}"
        exit 1
      fi
    fi
  fi
}

checkExistingInstall() {
  # see which setup already exists
  if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"
  elif [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
  fi

  if [[ -r "${setupVars}" ]]; then
    if [[ "${reconfigure}" == 'true' ]]; then
      echo -n "::: --reconfigure passed to install script, "
      echo "will reinstall PiVPN overwriting existing settings"
      UpdateCmd="Reconfigure"
    elif [[ "${runUnattended}" == 'true' ]]; then
      ### What should the script do when passing --unattended to
      ### an existing installation?
      UpdateCmd="Reconfigure"
    else
      askAboutExistingInstall "${setupVars}"
    fi
  fi

  if [[ -z "${UpdateCmd}" ]] \
    || [[ "${UpdateCmd}" == "Reconfigure" ]]; then
    :
  elif [[ "${UpdateCmd}" == "Update" ]]; then
    ${SUDO} "${pivpnScriptDir}/update.sh" "$@"
    exit "$?"
  elif [[ "${UpdateCmd}" == "Repair" ]]; then
    # shellcheck disable=SC1090
    . "${setupVars}"
    runUnattended=true
  fi
}

askAboutExistingInstall() {
  opt1a="Update"
  opt1b="Get the latest PiVPN scripts"

  opt2a="Repair"
  opt2b="Reinstall PiVPN using existing settings"

  opt3a="Reconfigure"
  opt3b="Reinstall PiVPN with new settings"

  UpdateCmd="$(whiptail \
    --title "Existing Install Detected!" \
    --menu "
We have detected an existing install.
${1}

Please choose from the following options \
(Reconfigure can be used to add a second VPN type):" "${r}" "${c}" 3 \
    "${opt1a}" "${opt1b}" \
    "${opt2a}" "${opt2b}" \
    "${opt3a}" "${opt3b}" \
    3>&2 2>&1 1>&3)" \
    || {
      err "::: Cancel selected. Exiting"
      exit 1
    }

  echo "::: ${UpdateCmd} option selected."
}

distroCheck() {
  # Check for supported distribution
  # Compatibility, functions to check for supported OS
  # distroCheck, maybeOSSupport, noOSSupport
  # if lsb_release command is on their system
  if command -v lsb_release > /dev/null; then
    PLAT="$(lsb_release -si)"
    OSCN="$(lsb_release -sc)"
  else # else get info from os-release
    . /etc/os-release
    PLAT="$(awk '{print $1}' <<< "${NAME}")"
    VER="${VERSION_ID}"
    declare -A VER_MAP=(["10"]="buster"
      ["11"]="bullseye"
      ["12"]="bookworm"
      ["18.04"]="bionic"
      ["20.04"]="focal"
      ["22.04"]="jammy"
      ["23.04"]="lunar")
    OSCN="${VER_MAP["${VER}"]}"

    # Alpine support
    if [[ -z "${OSCN}" ]]; then
      OSCN="${VER}"
    fi
  fi

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      case "${OSCN}" in
        stretch | buster | bullseye | bookworm | xenial | bionic | focal | jammy | lunar)
          :
          ;;
        *)
          maybeOSSupport
          ;;
      esac
      ;;
    Alpine)
      PKG_MANAGER='apk'
      UPDATE_PKG_CACHE="${PKG_MANAGER} update"
      PKG_INSTALL="${PKG_MANAGER} --no-cache add"
      PKG_COUNT="${PKG_MANAGER} list -u | wc -l || true"
      CHECK_PKG_INSTALLED="${PKG_MANAGER} --no-cache info -e"
      ;;
    *)
      noOSSupport
      ;;
  esac

  {
    echo "PLAT=${PLAT}"
    echo "OSCN=${OSCN}"
  } > "${tempsetupVarsFile}"
}

noOSSupport() {
  if [[ "${runUnattended}" == 'true' ]]; then
    err "::: Invalid OS detected"
    err "::: We have not been able to detect a supported OS."
    err "::: Currently this installer supports Raspbian, Debian and Ubuntu."
    exit 1
  fi

  whiptail \
    --backtitle "INVALID OS DETECTED" \
    --title "Invalid OS" \
    --msgbox "We have not been able to detect a supported OS.
Currently this installer supports Raspbian, Debian and Ubuntu.
For more details, check our documentation at \
https://github.com/pivpn/pivpn/wiki" "${r}" "${c}"
  exit 1
}

maybeOSSupport() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: OS Not Supported"
    echo -n "::: You are on an OS that we have not tested but MAY work, "
    echo "continuing anyway..."
    return
  fi

  if whiptail \
    --backtitle "Untested OS" \
    --title "Untested OS" \
    --yesno "You are on an OS that we have not tested but MAY work.
Currently this installer supports Raspbian, Debian and Ubuntu.
For more details about supported OS please check our documentation \
at https://github.com/pivpn/pivpn/wiki
Would you like to continue anyway?" "${r}" "${c}"; then
    echo "::: Did not detect perfectly supported OS but,"
    echo -n "::: Continuing installation at user's own "
    echo "risk..."
  else
    err "::: Exiting due to untested OS"
    exit 1
  fi
}

checkHostname() {
  # Checks for hostname Length
  host_name="$(hostname -s)"

  if [[ "${#host_name}" -gt 28 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      err "::: Your hostname is too long."
      err "::: Use 'hostnamectl set-hostname YOURHOSTNAME' to set a new hostname"
      err "::: It must be less then 28 characters long and it must not use special characters"
      exit 1
    fi

    until [[ "${#host_name}" -le 28 ]] \
      && [[ "${host_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$ ]]; do
      host_name="$(whiptail \
        --title "Hostname too long" \
        --inputbox "Your hostname is too long.
Enter new hostname with less then 28 characters
No special characters allowed." "${r}" "${c}" \
        3>&1 1>&2 2>&3)"
      ${SUDO} hostnamectl set-hostname "${host_name}"

      if [[ "${#host_name}" -le 28 ]] \
        && [[ "${host_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$ ]]; then
        echo "::: Hostname valid and length OK, proceeding..."
      fi
    done
  else
    echo "::: Hostname length OK"
  fi
}

spinner() {
  local pid="${1}"
  local delay=0.50
  local spinstr='/-\|'

  while ps a | awk '{print $1}' | grep -q "${pid}"; do
    local temp="${spinstr#?}"
    printf " [%c]  " "${spinstr}"
    local spinstr="${temp}${spinstr%"$temp"}"
    sleep "${delay}"
    printf "\\b\\b\\b\\b\\b\\b"
  done

  printf "    \\b\\b\\b\\b"
}

verifyFreeDiskSpace() {
  # If user installs unattended-upgrades we'd need about 60MB so
  # will check for 75MB free
  echo "::: Verifying free disk space..."
  local required_free_kilobytes=76800
  local existing_free_kilobytes
  existing_free_kilobytes="$(df -Pk \
    | grep -m1 '\/$' \
    | awk '{print $4}')"

  # - Unknown free disk space , not a integer
  if [[ ! "${existing_free_kilobytes}" =~ ^([0-9])+$ ]]; then
    echo "::: Unknown free disk space!"
    echo -n "::: We were unable to determine available free disk space "
    echo "on this system."

    if [[ "${runUnattended}" == 'true' ]]; then
      exit 1
    fi

    echo -n "::: You may continue with the installation, however, "
    echo "it is not recommended."
    echo -n "::: If you are sure you want to continue, "
    echo -n "type YES and press enter :: "
    read -r response

    case "${response}" in
      [Yy][Ee][Ss])
        :
        ;;
      *)
        err "::: Confirmation not received, exiting..."
        exit 1
        ;;
    esac
  # - Insufficient free disk space
  elif [[ "${existing_free_kilobytes}" -lt "${required_free_kilobytes}" ]]; then
    err "::: Insufficient Disk Space!"
    err "::: Your system appears to be low on disk space. PiVPN recommends a minimum of ${required_free_kilobytes} KiloBytes."
    err "::: You only have ${existing_free_kilobytes} KiloBytes free."
    err "::: If this is a new install on a Raspberry Pi you may need to expand your disk."
    err "::: Try running 'sudo raspi-config', and choose the 'expand file system option'"
    err "::: After rebooting, run this installation again. (curl -sSfL https://install.pivpn.io | bash)"
    err "Insufficient free space, exiting..."
    exit 1
  fi
}

updatePackageCache() {
  # update package lists
  echo ":::"
  echo -e "::: Package Cache update is needed, running ${UPDATE_PKG_CACHE} ..."
  # shellcheck disable=SC2086
  ${SUDO} ${UPDATE_PKG_CACHE} &> /dev/null &
  spinner "$!"
  echo " done!"
}

notifyPackageUpdatesAvailable() {
  # Let user know if they have outdated packages on their system and
  # advise them to run a package update at soonest possible.
  echo ":::"
  echo -n "::: Checking ${PKG_MANAGER} for upgraded packages...."
  updatesToInstall="$(eval "${PKG_COUNT}")"
  echo " done!"
  echo ":::"

  if [[ "${updatesToInstall}" -eq 0 ]]; then
    echo "::: Your system is up to date! Continuing with PiVPN installation..."
  else
    echo "::: There are ${updatesToInstall} updates available for your system!"
    echo "::: We recommend you update your OS after installing PiVPN! "
    echo ":::"
  fi
}

preconfigurePackages() {
  # Install packages used by this installation script
  # If apt is older than 1.5 we need to install an additional package to add
  # support for https repositories that will be used later on
  if [[ "${PKG_MANAGER}" == 'apt-get' ]] \
    && [[ -f /etc/apt/sources.list ]]; then
    INSTALLED_APT="$(apt-cache policy apt \
      | grep -m1 'Installed: ' \
      | grep -v '(none)' \
      | awk '{print $2}')"

    if dpkg --compare-versions "${INSTALLED_APT}" lt 1.5; then
      BASE_DEPS+=("apt-transport-https")
    fi
  fi

  # We set static IP only on Raspberry Pi OS
  if checkStaticIpSupported; then
    if [[ "${OSCN}" != "bookworm" ]]; then
      BASE_DEPS+=(dhcpcd5)
    else
      useNetworkManager=true
    fi
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    DPKG_ARCH="$(dpkg --print-architecture)"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    DPKG_ARCH="$(apk --print-arch)"
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_OPENVPN="$(apt-cache policy openvpn \
      | grep -m1 'Candidate: ' \
      | grep -v '(none)' \
      | awk '{print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_OPENVPN="$(apk search -e openvpn \
      | sed -E -e 's/openvpn\-(.*)/\1/')"
  fi

  OPENVPN_SUPPORT=0
  NEED_OPENVPN_REPO=0

  # We require OpenVPN 2.4 or later for ECC support. If not available in the
  # repositories but we are running x86 Debian or Ubuntu, add the official repo
  # which provides the updated package.
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] \
      && dpkg --compare-versions "${AVAILABLE_OPENVPN}" ge 2.4; then
      OPENVPN_SUPPORT=1
    else
      if [[ "${PLAT}" == "Debian" ]] \
        || [[ "${PLAT}" == "Ubuntu" ]]; then
        if [[ "${DPKG_ARCH}" == "amd64" ]] \
          || [[ "${DPKG_ARCH}" == "i386" ]]; then
          NEED_OPENVPN_REPO=1
          OPENVPN_SUPPORT=1
        else
          OPENVPN_SUPPORT=0
        fi
      else
        OPENVPN_SUPPORT=0
      fi
    fi
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] \
      && [[ "$(apk version -t "${AVAILABLE_OPENVPN}" 2.4)" == '>' ]]; then
      OPENVPN_SUPPORT=1
    else
      OPENVPN_SUPPORT=0
    fi
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_WIREGUARD="$(apt-cache policy wireguard \
      | grep -m1 'Candidate: ' \
      | grep -v '(none)' \
      | awk '{print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_WIREGUARD="$(apk search -e wireguard-tools \
      | sed -E -e 's/wireguard\-tools\-(.*)/\1/')"
  fi

  WIREGUARD_SUPPORT=0

  # If a wireguard kernel object is found and is part of any installed package,
  # then it has not been build via DKMS or manually (installing via
  # wireguard-dkms does not make the module part of the package since the
  # module itself is built at install time and not part of the .deb).
  # Source: https://github.com/MichaIng/DietPi/blob/7bf5e1041f3b2972d7827c48215069d1c90eee07/dietpi/dietpi-software#L1807-L1815
  WIREGUARD_BUILTIN=0

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if dpkg-query -S '/lib/modules/*/wireguard.ko*' &> /dev/null \
      || modinfo wireguard 2> /dev/null \
      | grep -q '^filename:[[:blank:]]*(builtin)$'; then
      WIREGUARD_BUILTIN=1
    fi
  fi

  # case 1: If the module is builtin and the package available,
  #         we only need to install wireguard-tools.
  # case 2: If the package is not available, on Debian and
  #         Raspbian we can add it via Bullseye repository.
  # case 3: If the module is not builtin, on Raspbian we know
  #         the headers package: raspberrypi-kernel-headers
  # case 4: On Alpine, the kernel must be linux-lts or linux-virt
  #         if we want to load the kernel module
  # case 5: On Alpine Docker Container, the responsibility to have
  #         a WireGuard module on the host system is at user side
  # case 6: On Alpine container, wireguard-tools is available
  # case 7: On Debian (and Ubuntu), we can only reliably assume the
  #         headers package for amd64: linux-image-amd64
  # case 8: On Ubuntu, additionally the WireGuard package needs to
  #         be available, since we didn't test mixing Ubuntu repositories.
  # case 9: Ubuntu focal has wireguard support

  if [[ "${WIREGUARD_BUILTIN}" -eq 1 && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${WIREGUARD_BUILTIN}" -eq 1 && ("${PLAT}" == 'Debian' || "${PLAT}" == 'Raspbian') ]] \
    || [[ "${PLAT}" == 'Raspbian' ]] \
    || [[ "${PLAT}" == 'Alpine' && ! -f /.dockerenv && "$(uname -mrs)" =~ ^Linux\ +[0-9\.\-]+\-((lts)|(virt))\ +.*$ ]] \
    || [[ "${PLAT}" == 'Alpine' && -f /.dockerenv ]] \
    || [[ "${PLAT}" == 'Alpine' && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${PLAT}" == 'Debian' && "${DPKG_ARCH}" == 'amd64' ]] \
    || [[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'amd64' && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'arm64' && "${OSCN}" == 'focal' && -n "${AVAILABLE_WIREGUARD}" ]]; then
    WIREGUARD_SUPPORT=1
  fi

  if [[ "${OPENVPN_SUPPORT}" -eq 0 ]] \
    && [[ "${WIREGUARD_SUPPORT}" -eq 0 ]]; then
    err "::: Neither OpenVPN nor WireGuard are available to install by PiVPN, exiting..."
    exit 1
  fi

  # if ufw is enabled, configure that.
  # running as root because sometimes the executable is not in the user's $PATH
  if ${SUDO} bash -c 'command -v ufw' > /dev/null; then
    if ! ${SUDO} ufw status || ${SUDO} ufw status | grep -q inactive; then
      USING_UFW=0
    else
      USING_UFW=1
    fi
  else
    USING_UFW=0
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]] && [[ "${USING_UFW}" -eq 0 ]]; then
    BASE_DEPS+=(iptables-persistent)
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true \
      | ${SUDO} debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false \
      | ${SUDO} debconf-set-selections
  fi

  if [[ "${PLAT}" == 'Alpine' ]] \
    && ! command -v grepcidr &> /dev/null; then
    local down_dir
    ## install dependencies
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} build-base make curl tar

    if ! down_dir="$(mktemp -d)"; then
      err "::: Failed to create download directory for grepcidr!"
      exit 1
    fi

    ## download binaries
    curl -fLo "${down_dir}/master.tar.gz" \
      https://github.com/pivpn/grepcidr/archive/master.tar.gz
    tar -xzC "${down_dir}" -f "${down_dir}/master.tar.gz"

    (
      cd "${down_dir}/grepcidr-master" || exit

      ## personalize binaries
      sed -i -E -e 's/^PREFIX\=.*/PREFIX\=\/usr\nCC\=gcc/' Makefile

      ## install
      make
      ${SUDO} make install

      if ! command -v grepcidr &> /dev/null; then
        err "::: Failed to compile and install grepcidr!"
        exit
      fi
    ) || exit 1
  fi

  echo "USING_UFW=${USING_UFW}" >> "${tempsetupVarsFile}"
}

installDependentPackages() {
  # Install packages passed via argument array
  # No spinner - conflicts with set -e
  local FAILED=0
  local APTLOGFILE
  declare -a TO_INSTALL=()
  declare -a argArray1=("${!1}")

  for i in "${argArray1[@]}"; do
    echo -n ":::    Checking for ${i}..."

    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null \
        | grep -q "ok installed"; then
        echo " already installed!"
      else
        echo " not installed!"
        # Add this package to the list of packages in the argument array that
        # need to be installed
        TO_INSTALL+=("${i}")
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        echo " already installed!"
      else
        echo " not installed!"
        # Add this package to the list of packages in the argument array that
        # need to be installed
        TO_INSTALL+=("${i}")
      fi
    fi
  done

  APTLOGFILE="$(${SUDO} mktemp)"

  # shellcheck disable=SC2086
  ${SUDO} ${PKG_INSTALL} "${TO_INSTALL[@]}"

  for i in "${TO_INSTALL[@]}"; do
    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null \
        | grep -q "ok installed"; then
        echo ":::    Package ${i} successfully installed!"
        # Add this package to the total list of packages that were actually
        # installed by the script
        INSTALLED_PACKAGES+=("${i}")
      else
        echo ":::    Failed to install ${i}!"
        ((FAILED++))
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        echo ":::    Package ${i} successfully installed!"
        # Add this package to the total list of packages that were actually
        # installed by the script
        INSTALLED_PACKAGES+=("${i}")
      else
        echo ":::    Failed to install ${i}!"
        ((FAILED++))
      fi
    fi
  done

  if [[ "${FAILED}" -gt 0 ]]; then
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]:" >&2
    ${SUDO} cat "${APTLOGFILE}" >&2
    exit 1
  fi
}

welcomeDialogs() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: PiVPN Automated Installer"
    echo -n "::: This installer will transform your ${PLAT} host into an "
    echo "OpenVPN or WireGuard server!"
    echo "::: Initiating network interface"
    return
  fi

  # Display the welcome dialog
  whiptail \
    --backtitle "Welcome" \
    --title "PiVPN Automated Installer" \
    --msgbox "This installer will transform your Raspberry Pi into an \
OpenVPN or WireGuard server!" "${r}" "${c}"

  # Explain the need for a static address
  whiptail \
    --backtitle "Initiating network interface" \
    --title "Static IP Needed" \
    --msgbox "The PiVPN is a SERVER so it needs a STATIC IP ADDRESS to \
function properly.

In the next section, you can choose to use your current network settings \
(DHCP) or to manually edit them." "${r}" "${c}"
}

chooseInterface() {
  # Find interfaces and let the user choose one

  # Turn the available interfaces into an array so it can be used with
  # a whiptail dialog
  local interfacesArray=()
  # Number of available interfaces
  local interfaceCount
  # Whiptail variable storage
  local chooseInterfaceCmd
  # Temporary Whiptail options storage
  local chooseInterfaceOptions
  # Loop sentinel variable
  local firstloop=1

  availableInterfaces="$(ip -o link)"

  if [[ "${showUnsupportedNICs}" == 'true' ]]; then
    # Show every network interface, could be useful for those who
    # install PiVPN inside virtual machines or on Raspberry Pis
    # with USB adapters
    availableInterfaces="$(echo "${availableInterfaces}" \
      | awk '{print $2}')"
  else
    # Find network interfaces whose state is UP
    availableInterfaces="$(echo "${availableInterfaces}" \
      | awk '/state UP/ {print $2}')"
  fi

  # Skip virtual, loopback and docker interfaces
  availableInterfaces="$(echo "${availableInterfaces}" \
    | cut -d ':' -f 1 \
    | cut -d '@' -f 1 \
    | grep -v -w 'lo' \
    | grep -v '^docker')"

  if [[ -z "${availableInterfaces}" ]]; then
    err "::: Could not find any active network interface, exiting"
    exit 1
  else
    while read -r line; do
      mode="OFF"

      if [[ "${firstloop}" -eq 1 ]]; then
        firstloop=0
        mode="ON"
      fi

      interfacesArray+=("${line}" "available" "${mode}")
      ((interfaceCount++))
    done <<< "${availableInterfaces}"
  fi

  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${IPv4dev}" ]]; then
      if [[ "${interfaceCount}" -eq 1 ]]; then
        IPv4dev="${availableInterfaces}"
        echo -n "::: No interface specified for IPv4, but only ${IPv4dev} "
        echo "is available, using it"
      else
        err "::: No interface specified for IPv4 and failed to determine one"
        exit 1
      fi
    else
      if ip -o link | grep -qw "${IPv4dev}"; then
        echo "::: Using interface: ${IPv4dev} for IPv4"
      else
        err "::: Interface ${IPv4dev} for IPv4 does not exist"
        exit 1
      fi
    fi

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      if [[ -z "${IPv6dev}" ]]; then
        if [[ "${interfaceCount}" -eq 1 ]]; then
          IPv6dev="${availableInterfaces}"
          echo -n "::: No interface specified for IPv6, but only ${IPv6dev} "
          echo "is available, using it"
        else
          err "::: No interface specified for IPv6 and failed to determine one"
          exit 1
        fi
      else
        if ip -o link | grep -qw "${IPv6dev}"; then
          echo "::: Using interface: ${IPv6dev} for IPv6"
        else
          err "::: Interface ${IPv6dev} for IPv6 does not exist"
          exit 1
        fi
      fi
    fi

    {
      echo "IPv4dev=${IPv4dev}"

      if [[ "${pivpnenableipv6}" -eq 1 ]] \
        && [[ -z "${IPv6dev}" ]]; then
        echo "IPv6dev=${IPv6dev}"
      fi
    } >> "${tempsetupVarsFile}"

    return
  else
    if [[ "${interfaceCount}" -eq 1 ]]; then
      IPv4dev="${availableInterfaces}"

      {
        echo "IPv4dev=${IPv4dev}"

        if [[ "${pivpnenableipv6}" -eq 1 ]]; then
          IPv6dev="${availableInterfaces}"
          echo "IPv6dev=${IPv6dev}"
        fi
      } >> "${tempsetupVarsFile}"

      return
    fi
  fi

  chooseInterfaceCmd=(whiptail
    --separate-output
    --radiolist "Choose An interface for IPv4 \
(press space to select):" "${r}" "${c}" "${interfaceCount}")

  if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" \
    "${interfacesArray[@]}" \
    2>&1 > /dev/tty)"; then
    for desiredInterface in ${chooseInterfaceOptions}; do
      IPv4dev="${desiredInterface}"
      echo "::: Using interface: ${IPv4dev}"
      echo "IPv4dev=${IPv4dev}" >> "${tempsetupVarsFile}"
    done
  else
    err "::: Cancel selected, exiting...."
    exit 1
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    chooseInterfaceCmd=(whiptail
      --separate-output
      --radiolist "Choose An interface for IPv6, usually the same as used by \
IPv4 (press space to select):" "${r}" "${c}" "${interfaceCount}")

    if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" \
      "${interfacesArray[@]}" \
      2>&1 > /dev/tty)"; then
      for desiredInterface in ${chooseInterfaceOptions}; do
        IPv6dev="${desiredInterface}"
        echo "::: Using interface: ${IPv6dev}"
        echo "IPv6dev=${IPv6dev}" >> "${tempsetupVarsFile}"
      done
    else
      err "::: Cancel selected, exiting...."
      exit 1
    fi
  fi
}

checkStaticIpSupported() {
  # Not really robust and correct, we should actually check for dhcpcd,
  # not the distro, but works on Raspbian and Debian.
  if [[ "${PLAT}" == "Raspbian" ]]; then
    return 0
  # If we are on 'Debian' but the raspi.list file is present,
  # then we actually are on 64-bit Raspberry Pi OS.
  elif [[ "${PLAT}" == "Debian" ]] \
    && [[ -s /etc/apt/sources.list.d/raspi.list ]]; then
    return 0
  else
    return 1
  fi
}

staticIpNotSupported() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo -n "::: Since we think you are not using Raspberry Pi OS, "
    echo "we will not configure a static IP for you."
    return
  fi

  # If we are in Ubuntu then they need to have previously set their network,
  # so just use what you have.
  whiptail \
    --backtitle "IP Information" \
    --title "IP Information" \
    --msgbox "Since we think you are not using Raspberry Pi OS, we will not \
configure a static IP for you.
If you are in Amazon then you can not configure a static IP anyway. Just \
ensure before this installer started you had set an elastic IP on your \
instance." "${r}" "${c}"
}

validIP() {
  local ip="${1}"
  local stat=1

  if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    OIFS="${IFS}"
    IFS='.'
    read -r -a ip <<< "${ip}"
    IFS="${OIFS}"

    [[ "${ip[0]}" -le 255 && "${ip[1]}" -le 255 && "${ip[2]}" -le 255 && "${ip[3]}" -le 255 ]]

    stat="$?"
  fi

  return "${stat}"
}

validIPAndNetmask() {
  # shellcheck disable=SC2178
  local ip="${1}"
  local stat=1

  # shellcheck disable=SC2178
  ip="${ip/\//.}"

  # shellcheck disable=SC2128
  if [[ "${ip}" =~ ^([0-9]{1,3}\.){4}[0-9]{1,2}$ ]]; then
    OIFS="${IFS}"
    IFS='.'
    # shellcheck disable=SC2128
    read -r -a ip <<< "${ip}"
    IFS="${OIFS}"

    [[ "${ip[0]}" -le 255 && "${ip[1]}" -le 255 && "${ip[2]}" -le 255 && "${ip[3]}" -le 255 && "${ip[4]}" -le 32 ]]

    stat="$?"
  fi

  return "${stat}"
}

checkipv6uplink() {
  curl \
    --max-time 3 \
    --connect-timeout 3 \
    --silent \
    --fail \
    -6 \
    https://google.com \
    > /dev/null
  curlv6testres="$?"

  if [[ "${curlv6testres}" -ne 0 ]]; then
    echo -n "::: IPv6 test connections to google.com have failed. "
    echo -n "Disabling IPv6 support. "
    echo "(The curl test failed with code: ${curlv6testres})"
    pivpnenableipv6=0
  else
    echo -n "::: IPv6 test connections to google.com successful. "
    echo "Enabling IPv6 support."
    pivpnenableipv6=1
  fi
}

askforcedipv6route() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: Enable forced IPv6 route with no IPv6 uplink on server."
    echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
    return
  fi

  if whiptail \
    --backtitle "Privacy setting" \
    --title "IPv6 leak" \
    --yesno "Although this server doesn't seem to have a working IPv6 \
connection or IPv6 was disabled on purpose, it is still recommended you \
force all IPv6 connections through the VPN.\\n\\nThis will prevent the \
client from bypassing the tunnel and leaking its real IPv6 address to servers, \
though it might cause the client to have slow response when browsing the web \
on IPv6 networks.

Do you want to force routing IPv6 to block the leakage?" "${r}" "${c}"; then
    pivpnforceipv6route=1
  else
    pivpnforceipv6route=0
  fi

  echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
}

getStaticIPv4Settings() {
  # Find the gateway IP used to route to outside world
  CurrentIPv4gw="$(ip -o route get 192.0.2.1 \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
    | awk 'NR==2')"

  # Find the IP address (and netmask) of the desidered interface
  CurrentIPv4addr="$(ip -o -f inet address show dev "${IPv4dev}" \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}')"

  # Grab their current DNS servers
  IPv4dns="$(grep -v "^#" /etc/resolv.conf \
    | grep -w nameserver \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
    | xargs)"

  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${dhcpReserv}" ]] \
      || [[ "${dhcpReserv}" -ne 1 ]]; then
      local MISSING_STATIC_IPV4_SETTINGS=0

      if [[ -z "${IPv4addr}" ]]; then
        echo "::: Missing static IP address"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ -z "${IPv4gw}" ]]; then
        echo "::: Missing static IP gateway"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 0 ]]; then
        # If both settings are not empty, check if they are valid and proceed
        if validIPAndNetmask "${IPv4addr}"; then
          echo "::: Your static IPv4 address:    ${IPv4addr}"
        else
          err "::: ${IPv4addr} is not a valid IP address"
          exit 1
        fi

        if validIP "${IPv4gw}"; then
          echo "::: Your static IPv4 gateway:    ${IPv4gw}"
        else
          err "::: ${IPv4gw} is not a valid IP address"
          exit 1
        fi
      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 1 ]]; then
        # If either of the settings is missing, consider the input inconsistent
        err "::: Incomplete static IP settings"
        exit 1
      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 2 ]]; then
        # If both of the settings are missing,
        # assume the user wants to use current settings
        IPv4addr="${CurrentIPv4addr}"
        IPv4gw="${CurrentIPv4gw}"
        echo "::: No static IP settings, using current settings"
        echo "::: Your static IPv4 address:    ${IPv4addr}"
        echo "::: Your static IPv4 gateway:    ${IPv4gw}"
      fi
    else
      echo "::: Skipping setting static IP address"
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

  if whiptail \
    --backtitle "Calibrating network interface" \
    --title "DHCP Reservation" \
    --defaultno \
    --yesno "Are you Using DHCP Reservation on your Router/DHCP Server?
These are your current Network Settings:

			IP address:    ${CurrentIPv4addr}
			Gateway:       ${CurrentIPv4gw}

Yes: Keep using DHCP reservation
No: Setup static IP address
Don't know what DHCP Reservation is? Answer No." "${r}" "${c}"; then
    dhcpReserv=1

    {
      echo "dhcpReserv=${dhcpReserv}"
      # We don't really need to save them as we won't set a static IP
      # but they might be useful for debugging
      echo "IPv4addr=${CurrentIPv4addr}"
      echo "IPv4gw=${CurrentIPv4gw}"
    } >> "${tempsetupVarsFile}"
  else
    # Ask if the user wants to use DHCP settings as their static IP
    if whiptail \
      --backtitle "Calibrating network interface" \
      --title "Static IP Address" \
      --yesno "Do you want to use your current network settings as a static \
address?

				IP address:    ${CurrentIPv4addr}
				Gateway:       ${CurrentIPv4gw}" "${r}" "${c}"; then
      IPv4addr="${CurrentIPv4addr}"
      IPv4gw="${CurrentIPv4gw}"

      {
        echo "IPv4addr=${IPv4addr}"
        echo "IPv4gw=${IPv4gw}"
      } >> "${tempsetupVarsFile}"

      # If they choose yes, let the user know that the IP address will not
      # be available via DHCP and may cause a conflict.
      whiptail \
        --backtitle "IP information" \
        --title "FYI: IP Conflict" \
        --msgbox "It is possible your router could still try to assign this \
IP to a device, which would cause a conflict.  But in most cases the router is \
smart enough to not do that.
If you are worried, either manually set the address, or modify the DHCP \
reservation pool so it does not include the IP you want.
It is also possible to use a DHCP reservation, but if you are going to do \
that, you mightas well set a static address." "${r}" "${c}"
      # Nothing else to do since the variables are already set above
    else
      # Otherwise, we need to ask the user to input their desired settings.
      # Start by getting the IPv4 address
      # (pre-filling it with info gathered from DHCP)
      # Start a loop to let the user enter their information with the chance
      # to go back and edit it if necessary
      until [[ "${ipSettingsCorrect}" == 'true' ]]; do
        until [[ "${IPv4AddrValid}" == 'true' ]]; do
          # Ask for the IPv4 address
          if IPv4addr="$(whiptail \
            --backtitle "Calibrating network interface" \
            --title "IPv4 address" \
            --inputbox "Enter your desired \
IPv4 address" "${r}" "${c}" "${CurrentIPv4addr}" \
            3>&1 1>&2 2>&3)"; then
            if validIPAndNetmask "${IPv4addr}"; then
              echo "::: Your static IPv4 address:    ${IPv4addr}"
              IPv4AddrValid=true
            else
              whiptail \
                --backtitle "Calibrating network interface" \
                --title "IPv4 address" \
                --msgbox "You've entered an invalid IP address: ${IPv4addr}

Please enter an IP address in the CIDR notation, example: 192.168.23.211/24

If you are not sure, please just keep the default." "${r}" "${c}"
              echo "::: Invalid IPv4 address:    ${IPv4addr}"
              IPv4AddrValid=false
            fi
          else
            # Cancelling IPv4 settings window
            err "::: Cancel selected. Exiting..."
            exit 1
          fi
        done

        until [[ "${IPv4gwValid}" == 'true' ]]; do
          # Ask for the gateway
          if IPv4gw="$(whiptail \
            --backtitle "Calibrating network interface" \
            --title "IPv4 gateway (router)" \
            --inputbox "Enter your desired IPv4 \
default gateway" "${r}" "${c}" "${CurrentIPv4gw}" \
            3>&1 1>&2 2>&3)"; then
            if validIP "${IPv4gw}"; then
              echo "::: Your static IPv4 gateway:    ${IPv4gw}"
              IPv4gwValid=true
            else
              whiptail \
                --backtitle "Calibrating network interface" \
                --title "IPv4 gateway (router)" \
                --msgbox "You've entered an invalid gateway IP: ${IPv4gw}

Please enter the IP address of your gateway (router), example: 192.168.23.1

If you are not sure, please just keep the default." "${r}" "${c}"
              echo "::: Invalid IPv4 gateway:    ${IPv4gw}"
              IPv4gwValid=false
            fi
          else
            # Cancelling gateway settings window
            err "::: Cancel selected. Exiting..."
            exit 1
          fi
        done

        # Give the user a chance to review their settings before moving on
        if whiptail \
          --backtitle "Calibrating network interface" \
          --title "Static IP Address" \
          --yesno "Are these settings correct?

						IP address:    ${IPv4addr}
						Gateway:       ${IPv4gw}" "${r}" "${c}"; then
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
  if [[ -f /etc/dhcpcd.conf ]]; then
    if grep -q "${IPv4addr}" "${dhcpcdFile}"; then
      echo "::: Static IP already configured."
    else
      writeDHCPCDConf
      ${SUDO} ip addr replace dev "${IPv4dev}" "${IPv4addr}"
      echo ":::"
      echo -n "::: Setting IP to ${IPv4addr}.  "
      echo "You may need to restart after the install is complete."
      echo ":::"
    fi
  else
    err "::: Critical: Unable to locate configuration file to set static IPv4 address!"
    exit 1
  fi
}

writeDHCPCDConf() {
  # Append these lines to dhcpcd.conf to enable a static IP
  {
    echo "interface ${IPv4dev}"
    echo "static ip_address=${IPv4addr}"
    echo "static routers=${IPv4gw}"
    echo "static domain_name_servers=${IPv4dns}"
  } | ${SUDO} tee -a "${dhcpcdFile}" > /dev/null

}

setNetworkManager() {
  connectionUUID=$(nmcli -t con show --active \
    | awk -v ref="${IPv4dev}" -F: 'match($0, ref){print $2}')

  ${SUDO} nmcli con mod "${connectionUUID}" \
    ipv4.addresses "${IPv4addr}" \
    ipv4.gateway "${IPv4gw}" \
    ipv4.dns "${IPv4dns}" \
    ipv4.method "manual"
}

setStaticIPv4() {
  # Tries to set the IPv4 address
  if [[ -v useNetworkManager ]]; then
    echo "::: Using Network manager"
    setNetworkManager
    echo "useNetworkManager=${useNetworkManager}" >> "${tempsetupVarsFile}"
  else
    echo "::: Using DHCPCD"
    setDHCPCD
  fi
}

chooseUser() {
  # Choose the user for the ovpns
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${install_user}" ]]; then
      if [[ "$(awk -F ':' \
        'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' \
        /etc/passwd)" -eq 1 ]]; then
        install_user="$(awk -F ':' \
          '$3>=1000 && $3<=60000 {print $1}' \
          /etc/passwd)"
        echo -n "::: No user specified, but only ${install_user} is available, "
        echo "using it"
      else
        err "::: No user specified"
        exit 1
      fi
    else
      if awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd \
        | grep -qw "${install_user}"; then
        echo "::: ${install_user} will hold your VPN client configuration files."
      else
        echo "::: User ${install_user} does not exist, creating..."

        if [[ "${PLAT}" == 'Alpine' ]]; then
          ${SUDO} adduser -s /bin/bash "${install_user}"
          ${SUDO} addgroup "${install_user}" wheel
        else
          ${SUDO} useradd -ms /bin/bash "${install_user}"
        fi

        echo -n "::: User created without a password, "
        echo "please do sudo passwd ${install_user} to create one"
      fi
    fi

    install_home="$(grep -m1 "^${install_user}:" /etc/passwd \
      | cut -d ':' -f 6)"
    install_home="${install_home%/}"

    {
      echo "install_user=${install_user}"
      echo "install_home=${install_home}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # Explain the local user
  whiptail \
    --msgbox \
    --backtitle "Parsing User List" \
    --title "Local Users" \
    "Choose a local user that will hold your ovpn configurations." \
    "${r}" \
    "${c}"
  # First, let's check if there is a user available.
  numUsers="$(awk -F ':' \
    'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' \
    /etc/passwd)"

  if [[ "${numUsers}" -eq 0 ]]; then
    # We don't have a user, let's ask to add one.
    if userToAdd="$(whiptail \
      --title "Choose A User" \
      --inputbox \
      "No non-root user account was found. Please type a new username." \
      "${r}" \
      "${c}" \
      3>&1 1>&2 2>&3)"; then
      # See https://askubuntu.com/a/667842/459815
      PASSWORD="$(whiptail \
        --title "password dialog" \
        --passwordbox \
        "Please enter the new user password" \
        "${r}" \
        "${c}" \
        3>&1 1>&2 2>&3)"
      CRYPT="$(perl \
        -e 'printf("%s\n", crypt($ARGV[0], "password"))' "${PASSWORD}")"

      if [[ "${PLAT}" == 'Alpine' ]]; then
        if ${SUDO} adduser -Ds /bin/bash "${userToAdd}"; then
          ${SUDO} addgroup "${userToAdd}" wheel

          ${SUDO} chpasswd <<< "${userToAdd}:${PASSWORD}"
          ${SUDO} passwd -u "${userToAdd}"

          echo "Succeeded"
          ((numUsers += 1))
        else
          exit 1
        fi
      else
        if ${SUDO} useradd -mp "${CRYPT}" -s /bin/bash "${userToAdd}"; then
          echo "Succeeded"
          ((numUsers += 1))
        else
          exit 1
        fi
      fi
    else
      exit 1
    fi
  fi

  availableUsers="$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)"
  local userArray=()
  local firstloop=1

  while read -r line; do
    mode="OFF"

    if [[ "${firstloop}" -eq 1 ]]; then
      firstloop=0
      mode="ON"
    fi

    userArray+=("${line}" "" "${mode}")
  done <<< "${availableUsers}"

  chooseUserCmd=(whiptail
    --title "Choose A User"
    --separate-output
    --radiolist
    "Choose (press space to select):"
    "${r}"
    "${c}"
    "${numUsers}")

  if chooseUserOptions=$("${chooseUserCmd[@]}" \
    "${userArray[@]}" \
    2>&1 > /dev/tty); then
    for desiredUser in ${chooseUserOptions}; do
      install_user=${desiredUser}
      echo "::: Using User: ${install_user}"
      install_home=$(grep -m1 "^${install_user}:" /etc/passwd \
        | cut -d ':' -f 6)
      install_home=${install_home%/} # remove possible trailing slash

      {
        echo "install_user=${install_user}"
        echo "install_home=${install_home}"
      } >> "${tempsetupVarsFile}"
    done
  else
    err "::: Cancel selected, exiting...."
    exit 1
  fi
}

isRepo() {
  # If the directory does not have a .git folder it is not a repo
  echo -n ":::    Checking ${1} is a repo..."
  cd "${1}" &> /dev/null || {
    echo " not found!"
    return 1
  }
  ${SUDO} ${GITBIN} status &> /dev/null && echo " OK!"
  #shellcheck disable=SC2317
  return 0 || echo " not found!"
  #shellcheck disable=SC2317
  return 1
}

updateRepo() {
  if [[ "${UpdateCmd}" == "Repair" ]]; then
    echo -n "::: Repairing an existing installation, "
    echo "not downloading/updating local repos"
  else
    # Pull the latest commits
    echo -n ":::     Updating repo in ${1} from ${2} ..."

    ### FIXME: Never call rm -rf with a plain variable. Never again as SU!
    #${SUDO} rm -rf "${1}"
    if [[ -n "${1}" ]]; then
      ${SUDO} rm -rf "$(dirname "${1}")/pivpn"
    fi

    # Go back to /usr/local/src otherwise git will complain when the current
    # working directory has just been deleted (/usr/local/src/pivpn).
    cd /usr/local/src \
      && ${SUDO} ${GITBIN} clone -q \
        --depth 1 \
        --no-single-branch \
        "${2}" \
        "${1}" \
        > /dev/null &
    spinner $!
    cd "${1}" || exit 1
    echo " done!"

    if [[ -n "${pivpnGitBranch}" ]]; then
      echo ":::     Checkout branch '${pivpnGitBranch}' from ${2} in ${1}..."
      ${SUDOE} ${GITBIN} checkout -q "${pivpnGitBranch}"
      echo ":::     Custom branch checkout done!"
    elif [[ -z "${TESTING+x}" ]]; then
      :
    else
      echo ":::     Checkout branch 'test' from ${2} in ${1}..."
      ${SUDOE} ${GITBIN} checkout -q test
      echo ":::     'test' branch checkout done!"
    fi
  fi
}

makeRepo() {
  # Remove the non-repos interface and clone the interface
  echo -n ":::    Cloning ${2} into ${1} ..."

  ### FIXME: Never call rm -rf with a plain variable. Never again as SU!
  #${SUDO} rm -rf "${1}"
  if [[ -n "${1}" ]]; then
    ${SUDO} rm -rf "$(dirname "${1}")/pivpn"
  fi

  # Go back to /usr/local/src otherwhise git will complain when the current
  # working directory has just been deleted (/usr/local/src/pivpn).
  cd /usr/local/src \
    && ${SUDO} ${GITBIN} clone -q \
      --depth 1 \
      --no-single-branch \
      "${2}" \
      "${1}" \
      > /dev/null &
  spinner $!
  cd "${1}" || exit 1
  echo " done!"

  if [[ -n "${pivpnGitBranch}" ]]; then
    echo ":::     Checkout branch '${pivpnGitBranch}' from ${2} in ${1}..."
    ${SUDOE} ${GITBIN} checkout -q "${pivpnGitBranch}"
    echo ":::     Custom branch checkout done!"
  elif [[ -z "${TESTING+x}" ]]; then
    :
  else
    echo ":::     Checkout branch 'test' from ${2} in ${1}..."
    ${SUDOE} ${GITBIN} checkout -q test
    echo ":::     'test' branch checkout done!"
  fi
}

getGitFiles() {
  # Setup git repos for base files
  echo ":::"
  echo "::: Checking for existing base files..."

  if isRepo "${1}"; then
    updateRepo "${1}" "${2}"
  else
    makeRepo "${1}" "${2}"
  fi
}

cloneOrUpdateRepos() {
  # Clone/Update the repos
  # /usr/local should always exist, not sure about the src subfolder though
  ${SUDO} mkdir -p /usr/local/src

  # Get Git files
  getGitFiles "${pivpnFilesDir}" "${pivpnGitUrl}" \
    || {
      err "!!! Unable to clone ${pivpnGitUrl} into ${pivpnFilesDir}, unable to continue."
      exit 1
    }
}

installPiVPN() {
  ${SUDO} mkdir -p /etc/pivpn/
  askWhichVPN
  setVPNDefaultVars

  if [[ "${VPN}" == 'openvpn' ]]; then
    setOpenVPNDefaultVars
    askAboutCustomizing
    installOpenVPN
    askCustomProto
  elif [[ "${VPN}" == 'wireguard' ]]; then
    setWireguardDefaultVars
    installWireGuard
  fi

  askCustomPort
  askClientDNS

  if [[ "${VPN}" == 'openvpn' ]]; then
    askCustomDomain
  fi

  askPublicIPOrDNS

  if [[ "${VPN}" == 'openvpn' ]]; then
    askEncryption
    confOpenVPN
    confOVPN
  elif [[ "${VPN}" == 'wireguard' ]]; then
    confWireGuard
  fi

  confNetwork

  if [[ "${VPN}" == 'openvpn' ]]; then
    confLogging
  elif [[ "${VPN}" == 'wireguard' ]]; then
    writeWireguardTempVarsFile
  fi

  writeVPNTempVarsFile
}

decIPv4ToDot() {
  local a b c d
  a=$((($1 & 4278190080) >> 24))
  b=$((($1 & 16711680) >> 16))
  c=$((($1 & 65280) >> 8))
  d=$(($1 & 255))
  printf "%s.%s.%s.%s\n" $a $b $c $d
}

dotIPv4ToDec() {
  local original_ifs=$IFS
  IFS='.'
  read -r -a array_ip <<< "$1"
  IFS=$original_ifs
  printf "%s\n" $((array_ip[0] * 16777216 + array_ip[1] * 65536 + array_ip[2] * 256 + array_ip[3]))
}

dotIPv4FirstDec() {
  local decimal_ip decimal_mask
  decimal_ip=$(dotIPv4ToDec "$1")
  decimal_mask=$((2 ** 32 - 1 ^ (2 ** (32 - $2) - 1)))
  printf "%s\n" "$((decimal_ip & decimal_mask))"
}

dotIPv4LastDec() {
  local decimal_ip decimal_mask_inv
  decimal_ip=$(dotIPv4ToDec "$1")
  decimal_mask_inv=$((2 ** (32 - $2) - 1))
  printf "%s\n" "$((decimal_ip | decimal_mask_inv))"
}

decIPv4ToHex() {
  local hex
  hex="$(printf "%08x\n" "$1")"
  quartet_hi=${hex:0:4}
  quartet_lo=${hex:4:4}
  # Removes leading zeros from quartets, purely for aesthetic reasons
  # Source: https://stackoverflow.com/a/19861690
  leading_zeros_hi="${quartet_hi%%[!0]*}"
  leading_zeros_lo="${quartet_lo%%[!0]*}"
  printf "%s:%s\n" "${quartet_hi#"${leading_zeros_hi}"}" "${quartet_lo#"${leading_zeros_lo}"}"
}

cidrToMask() {
  # Source: https://stackoverflow.com/a/20767392
  set -- $((5 - (${1} / 8))) \
    255 255 255 255 \
    $(((255 << (8 - (${1} % 8))) & 255)) \
    0 0 0
  shift "${1}"
  echo "${1-0}.${2-0}.${3-0}.${4-0}"
}

setVPNDefaultVars() {
  # Allow custom subnetClass via unattend setupVARs file.
  # Use default if not provided.
  if [[ -z "${subnetClass}" ]]; then
    subnetClass="24"
  fi

  if [[ -z "${subnetClassv6}" ]]; then
    subnetClassv6="64"
  fi
}

generateRandomSubnet() {
  # Source: https://community.openvpn.net/openvpn/wiki/AvoidRoutingConflicts
  declare -a excluded_subnets_dec=(
    167772160 167772415   # 10.0.0.0/24
    167772416 167772671   # 10.0.1.0/24
    167837952 167838207   # 10.1.1.0/24
    167840256 167840511   # 10.1.10.0/24
    167903232 167903487   # 10.2.0.0/24
    168296448 168296703   # 10.8.0.0/24
    168427776 168428031   # 10.10.1.0/24
    173693440 173693695   # 10.90.90.0/24
    174326016 174326271   # 10.100.1.0/24
    184549120 184549375   # 10.255.255.0/24
    3232235520 3232235775 # 192.168.0.0/24
    3232235776 3232236031 # 192.168.1.0/24
  )

  # Add numeric ranges to the previous array
  readarray -t currently_used_subnets <<< "$(ip route show \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}')"

  local used used_ip used_mask
  for used in "${currently_used_subnets[@]}"; do
    used_ip="${used%/*}"
    used_mask="${used##*/}"

    excluded_subnets_dec+=("$(dotIPv4FirstDec "$used_ip" "$used_mask")")
    excluded_subnets_dec+=("$(dotIPv4LastDec "$used_ip" "$used_mask")")
  done

  # Note: excluded_subnets_count array length is twice the number of subnets
  local excluded_subnets_count="${#excluded_subnets_dec[@]}"

  local source_subnet="$1"
  local source_ip="${source_subnet%/*}"
  # shellcheck disable=SC2155
  local source_ip_dec="$(dotIPv4ToDec "$source_ip")"
  local source_netmask="${source_subnet##*/}"
  local source_netmask_dec="$((2 ** 32 - 1 ^ (2 ** (32 - source_netmask) - 1)))"

  local target_netmask="$2"

  local first_ip_target_subnet_dec="$((source_ip_dec & source_netmask_dec))"
  local total_ips_target_subnet="$((2 ** (32 - target_netmask)))"

  # Picking a random subnet would cause the same subnets to be checked multiple
  # times shall the number of subnets were small, so instead a random permutation
  # is scanned to check a subnet only once.
  local subnets_count="$((2 ** (target_netmask - source_netmask)))"
  readarray -t random_perm <<< "$(shuf -i 0-"$((subnets_count - 1))")"
  # random_perm=( 3221 9 8 431 7 [...] )

  # Due to bash performance limitations, it's not pratical to check all subnets.
  # Taking into account that the install script should not hang for too long even
  # on a Pi Zero, we avoid doing more than about 5000 iteration.
  local max_tries="$subnets_count"
  if [ $((subnets_count * excluded_subnets_count)) -ge 5000 ]; then
    max_tries="$((5000 / (excluded_subnets_count / 2)))"
  fi

  local first_ip_subnet_dec last_ip_subnet_dec
  local first_ip_excluded_subnet_dec last_ip_excluded_subnet_dec
  local overlap
  for ((i = 0; i < max_tries; i++)); do

    first_ip_subnet_dec="$((first_ip_target_subnet_dec + total_ips_target_subnet * random_perm[i]))"
    last_ip_subnet_dec="$((first_ip_subnet_dec + total_ips_target_subnet - 1))"

    overlap=false

    for ((j = 0; j < excluded_subnets_count; j += 2)); do

      first_ip_excluded_subnet_dec="${excluded_subnets_dec[$j]}"
      last_ip_excluded_subnet_dec="${excluded_subnets_dec[$j + 1]}"

      #                              |-------------subnet2------------|
      #           |----------subnet1-----------|                      |
      #           |                  |         |                      |
      # first_ip_excluded_subnet_dec | last_ip_excluded_subnet_dec    |
      #                              |                                |
      #                   first_ip_subnet_dec                last_ip_subnet_dec
      if ((last_ip_excluded_subnet_dec >= first_ip_subnet_dec)) \
        && ((first_ip_excluded_subnet_dec <= last_ip_subnet_dec)); then
        overlap=true
        break
      fi

    done

    if ! "$overlap"; then
      decIPv4ToDot "$first_ip_subnet_dec"
      break
    fi
  done
}

setOpenVPNDefaultVars() {
  pivpnDEV="tun0"

  # Allow custom NET via unattend setupVARs file.
  # Use default if not provided.
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Generating random subnet in network 10.0.0.0/8..."
    pivpnNET="$(generateRandomSubnet "10.0.0.0/8" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Network 10.0.0.0/8 is unavailable, trying 172.16.0.0/12 next..."
    pivpnNET="$(generateRandomSubnet "172.16.0.0/12" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Network 172.16.0.0/12 is unavailable, trying 192.168.0.0/16 next..."
    pivpnNET="$(generateRandomSubnet "192.168.0.0/16" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    # This should not happen in practice
    echo "::: Unable to generate a random subnet for PiVPN. Looks like all private networks are in use."
    exit 1
  fi

  pivpnNETdec="$(dotIPv4ToDec "${pivpnNET}")"

  vpnGwdec="$((pivpnNETdec + 1))"
  vpnGw="$(decIPv4ToDot "${vpnGwdec}")"
  vpnGwhex="$(decIPv4ToHex "${vpnGwdec}")"

  if [[ "${pivpnenableipv6}" -eq 1 ]] \
    && [[ -z "${pivpnNETv6}" ]]; then
    pivpnNETv6="fd11:5ee:bad:c0de::"
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    vpnGwv6="${pivpnNETv6}${vpnGwhex}"
  fi
}

setWireguardDefaultVars() {
  # Since WireGuard only uses UDP, askCustomProto() is never
  # called so we set the protocol here.
  pivpnPROTO="udp"
  pivpnDEV="wg0"

  # Allow custom NET via unattend setupVARs file.
  # Use default if not provided.
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Generating random subnet in network 10.0.0.0/8..."
    pivpnNET="$(generateRandomSubnet "10.0.0.0/8" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Network 10.0.0.0/8 is unavailable, trying 172.16.0.0/12 next..."
    pivpnNET="$(generateRandomSubnet "172.16.0.0/12" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Network 172.16.0.0/12 is unavailable, trying 192.168.0.0/16 next..."
    pivpnNET="$(generateRandomSubnet "192.168.0.0/16" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    # This should not happen in practice
    echo "::: Unable to generate a random subnet for PiVPN. Looks like all private networks are in use."
    exit 1
  fi

  pivpnNETdec="$(dotIPv4ToDec "${pivpnNET}")"

  vpnGwdec="$((pivpnNETdec + 1))"
  vpnGw="$(decIPv4ToDot "${vpnGwdec}")"
  vpnGwhex="$(decIPv4ToHex "${vpnGwdec}")"

  if [[ "${pivpnenableipv6}" -eq 1 ]] \
    && [[ -z "${pivpnNETv6}" ]]; then
    pivpnNETv6="fd11:5ee:bad:c0de::"
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    vpnGwv6="${pivpnNETv6}${vpnGwhex}"
  fi

  # Allow custom allowed IPs via unattend setupVARs file.
  # Use default if not provided.
  if [[ -z "${ALLOWED_IPS}" ]]; then
    ALLOWED_IPS="0.0.0.0/0"

    # Forward all traffic through PiVPN (i.e. full-tunnel), may be modified by
    # the user after the installation.
    if [[ "${pivpnenableipv6}" -eq 1 ]] \
      || [[ "${pivpnforceipv6route}" -eq 1 ]]; then
      ALLOWED_IPS="${ALLOWED_IPS}, ::0/0"
    fi
  fi

  # The default MTU should be fine for most users but we allow to set a
  # custom MTU via unattend setupVARs file. Use default if not provided.
  if [[ -z "${pivpnMTU}" ]]; then
    # Using default Wireguard MTU
    pivpnMTU="1420"
  fi

  CUSTOMIZE=0
}

writeVPNTempVarsFile() {
  {
    echo "pivpnDEV=${pivpnDEV}"
    echo "pivpnNET=${pivpnNET}"
    echo "subnetClass=${subnetClass}"
    echo "pivpnenableipv6=${pivpnenableipv6}"

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      echo "pivpnNETv6=\"${pivpnNETv6}\""
      echo "subnetClassv6=${subnetClassv6}"
    fi

    echo "ALLOWED_IPS=\"${ALLOWED_IPS}\""
  } >> "${tempsetupVarsFile}"
}

writeWireguardTempVarsFile() {
  {
    echo "pivpnPROTO=${pivpnPROTO}"
    echo "pivpnMTU=${pivpnMTU}"

    # Write PERSISTENTKEEPALIVE if provided via unattended file
    # May also be added manually to /etc/pivpn/wireguard/setupVars.conf
    # post installation to be used for client profile generation
    if [[ -n "${pivpnPERSISTENTKEEPALIVE}" ]]; then
      echo "pivpnPERSISTENTKEEPALIVE=${pivpnPERSISTENTKEEPALIVE}"
    fi
  } >> "${tempsetupVarsFile}"
}

askWhichVPN() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ "${WIREGUARD_SUPPORT}" -eq 1 ]]; then
      if [[ -z "${VPN}" ]]; then
        echo ":: No VPN protocol specified, using WireGuard"
        VPN="wireguard"
      else
        VPN="${VPN,,}"

        if [[ "${VPN}" == "wireguard" ]]; then
          echo "::: WireGuard will be installed"
        elif [[ "${VPN}" == "openvpn" ]]; then
          echo "::: OpenVPN will be installed"
        else
          err ":: ${VPN} is not a supported VPN protocol, please specify 'wireguard' or 'openvpn'"
          exit 1
        fi
      fi
    else
      if [[ -z "${VPN}" ]]; then
        echo ":: No VPN protocol specified, using OpenVPN"
        VPN="openvpn"
      else
        VPN="${VPN,,}"

        if [[ "${VPN}" == "openvpn" ]]; then
          echo "::: OpenVPN will be installed"
        else
          err ":: ${VPN} is not a supported VPN protocol on ${DPKG_ARCH} ${PLAT}, only 'openvpn' is"
          exit 1
        fi
      fi
    fi
  else
    if [[ "${WIREGUARD_SUPPORT}" -eq 1 ]] \
      && [[ "${OPENVPN_SUPPORT}" -eq 1 ]]; then
      chooseVPNCmd=(whiptail
        --backtitle "Setup PiVPN"
        --title "Installation mode"
        --separate-output
        --radiolist "WireGuard is a new kind of VPN that provides \
near-instantaneous connection speed, high performance, and modern cryptography.

It's the recommended choice especially if you use mobile devices where \
WireGuard is easier on battery than OpenVPN.

OpenVPN is still available if you need the traditional, flexible, trusted \
VPN protocol or if you need features like TCP and custom search domain.

Choose a VPN (press space to select):" "${r}" "${c}" 2)
      VPNChooseOptions=(WireGuard "" on
        OpenVPN "" off)

      if VPN="$("${chooseVPNCmd[@]}" \
        "${VPNChooseOptions[@]}" \
        2>&1 > /dev/tty)"; then
        echo "::: Using VPN: ${VPN}"
        VPN="${VPN,,}"
      else
        err "::: Cancel selected, exiting...."
        exit 1
      fi
    elif [[ "${OPENVPN_SUPPORT}" -eq 1 ]] \
      && [[ "${WIREGUARD_SUPPORT}" -eq 0 ]]; then
      echo "::: Using VPN: OpenVPN"
      VPN="openvpn"
    elif [[ "${OPENVPN_SUPPORT}" -eq 0 ]] \
      && [[ "${WIREGUARD_SUPPORT}" -eq 1 ]]; then
      echo "::: Using VPN: WireGuard"
      VPN="wireguard"
    fi
  fi

  echo "VPN=${VPN}" >> "${tempsetupVarsFile}"
}

askAboutCustomizing() {
  if [[ "${runUnattended}" == 'false' ]]; then
    if whiptail \
      --backtitle "Setup PiVPN" \
      --title "Installation mode" \
      --defaultno \
      --yesno "PiVPN uses the following settings that we believe are good \
defaults for most users. However, we still want to keep flexibility, so if \
you need to customize them, choose Yes.

* UDP or TCP protocol: UDP
* Custom search domain for the DNS field: None
* Modern features or best compatibility: Modern features \
(256 bit certificate + additional TLS encryption)" "${r}" "${c}"; then
      CUSTOMIZE=1
    else
      CUSTOMIZE=0
    fi
  fi
}

installOpenVPN() {
  local PIVPN_DEPS gpg_path
  gpg_path="${pivpnFilesDir}/files/etc/apt/repo-public.gpg"
  echo "::: Installing OpenVPN from Debian package... "

  if [[ "${NEED_OPENVPN_REPO}" -eq 1 ]]; then
    # gnupg is used by apt-key to import the openvpn GPG key into the
    # APT keyring
    PIVPN_DEPS=(gnupg)
    installDependentPackages PIVPN_DEPS[@]

    # OpenVPN repo's public GPG key
    # (fingerprint 0x30EBF4E73CCE63EEE124DD278E6DA8B4E158C569)
    echo "::: Adding repository key..."

    if ! ${SUDO} apt-key add "${gpg_path}"; then
      err "::: Can't import OpenVPN GPG key"
      exit 1
    fi

    echo "::: Adding OpenVPN repository... "
    echo "deb https://build.openvpn.net/debian/openvpn/stable ${OSCN} main" \
      | ${SUDO} tee /etc/apt/sources.list.d/pivpn-openvpn-repo.list > /dev/null

    echo "::: Updating package cache..."
    updatePackageCache
  fi

  PIVPN_DEPS=(openvpn)

  installDependentPackages PIVPN_DEPS[@]
}

installWireGuard() {
  local PIVPN_DEPS

  echo -n "::: Installing WireGuard"
  PIVPN_DEPS=(wireguard-tools)

  if [[ "${PLAT}" == "Raspbian" ]]; then
    echo " from Raspbian package..."

    # qrencode is used to generate qrcodes from config file,
    # for use with mobile clients
    PIVPN_DEPS+=(qrencode)
  elif [[ "${PLAT}" == "Debian" ]]; then
    echo " from Debian package..."

    PIVPN_DEPS+=(qrencode)

    if [[ "${WIREGUARD_BUILTIN}" -eq 0 ]]; then
      # Explicitly install the module if not built-in
      PIVPN_DEPS+=(linux-headers-amd64 wireguard-dkms)
    fi
  elif [[ "${PLAT}" == "Ubuntu" ]]; then
    echo "..."

    PIVPN_DEPS+=(qrencode)

    if [[ "${WIREGUARD_BUILTIN}" -eq 0 ]]; then
      PIVPN_DEPS+=(linux-headers-generic wireguard-dkms)
    fi
  elif [[ "${PLAT}" == 'Alpine' ]]; then
    echo "..."

    PIVPN_DEPS+=(libqrencode)
  fi

  if [[ "${PLAT}" == "Raspbian" || "${PLAT}" == "Debian" ]] \
    && [[ -z "${AVAILABLE_WIREGUARD}" ]]; then
    if [[ "${PLAT}" == "Debian" ]]; then
      echo "::: Adding Debian Bullseye repository... "
      echo "deb https://deb.debian.org/debian/ bullseye main" \
        | ${SUDO} tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null
    else
      echo "::: Adding Raspbian Bullseye repository... "
      echo "deb http://raspbian.raspberrypi.org/raspbian/ bullseye main" \
        | ${SUDO} tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null
    fi

    {
      printf 'Package: *\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: -1\n\n'
      printf 'Package: wireguard wireguard-dkms wireguard-tools\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: 100\n'
    } | ${SUDO} tee /etc/apt/preferences.d/pivpn-limit-bullseye > /dev/null

    echo "::: Updating package cache..."
    updatePackageCache
  fi

  installDependentPackages PIVPN_DEPS[@]
}

askCustomProto() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPROTO}" ]]; then
      echo "::: No TCP/IP protocol specified, using the default protocol udp"
      pivpnPROTO="udp"
    else
      pivpnPROTO="${pivpnPROTO,,}"

      if [[ "${pivpnPROTO}" == "udp" ]] \
        || [[ "${pivpnPROTO}" == "tcp" ]]; then
        echo "::: Using the ${pivpnPROTO} protocol"
      else
        err ":: ${pivpnPROTO} is not a supported TCP/IP protocol, please specify 'udp' or 'tcp'"
        exit 1
      fi
    fi

    echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      pivpnPROTO="udp"
      echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
      return
    fi
  fi

  # Set the available protocols into an array so it can be used
  # with a whiptail dialog
  if pivpnPROTO="$(whiptail \
    --title "Protocol" \
    --radiolist "Choose a protocol (press space to select). \
Please only choose TCP if you know why you need TCP." "${r}" "${c}" 2 \
    "UDP" "" ON \
    "TCP" "" OFF \
    3>&1 1>&2 2>&3)"; then
    # Convert option into lowercase (UDP->udp)
    pivpnPROTO="${pivpnPROTO,,}"
    echo "::: Using protocol: ${pivpnPROTO}"
    echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
  else
    err "::: Cancel selected, exiting...."
    exit 1
  fi
}

askCustomPort() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPORT}" ]]; then
      if [[ "${VPN}" == "wireguard" ]]; then
        echo "::: No port specified, using the default port 51820"
        pivpnPORT=51820
      elif [[ "${VPN}" == "openvpn" ]]; then
        if [[ "${pivpnPROTO}" == "udp" ]]; then
          echo "::: No port specified, using the default port 1194"
          pivpnPORT=1194
        elif [[ "${pivpnPROTO}" == "tcp" ]]; then
          echo "::: No port specified, using the default port 443"
          pivpnPORT=443
        fi
      fi
    else
      if [[ "${pivpnPORT}" =~ ^[0-9]+$ ]] \
        && [[ "${pivpnPORT}" -ge 1 ]] \
        && [[ "${pivpnPORT}" -le 65535 ]]; then
        echo "::: Using port ${pivpnPORT}"
      else
        err "::: ${pivpnPORT} is not a valid port, use a port within the range [1,65535] (inclusive)"
        exit 1
      fi
    fi

    echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"
    return
  fi

  until [[ "${PORTNumCorrect}" == 'true' ]]; do
    portInvalid="Invalid"

    if [[ "${VPN}" == "wireguard" ]]; then
      DEFAULT_PORT=51820
    elif [[ "${VPN}" == "openvpn" ]]; then
      if [[ "${pivpnPROTO}" == "udp" ]]; then
        DEFAULT_PORT=1194
      else
        DEFAULT_PORT=443
      fi
    fi

    if pivpnPORT="$(whiptail \
      --title "Default ${VPN} Port" \
      --inputbox "You can modify the default ${VPN} port.
Enter a new value or hit 'Enter' to retain \
the default" "${r}" "${c}" "${DEFAULT_PORT}" \
      3>&1 1>&2 2>&3)"; then
      if [[ "${pivpnPORT}" =~ ^[0-9]+$ ]] \
        && [[ "${pivpnPORT}" -ge 1 ]] \
        && [[ "${pivpnPORT}" -le 65535 ]]; then
        :
      else
        pivpnPORT="${portInvalid}"
      fi
    else
      err "::: Cancel selected, exiting...."
      exit 1
    fi

    if [[ "${pivpnPORT}" == "${portInvalid}" ]]; then
      whiptail \
        --backtitle "Invalid Port" \
        --title "Invalid Port" \
        --msgbox "You entered an invalid Port number.
    Please enter a number from 1 - 65535.
    If you are not sure, please just keep the default." "${r}" "${c}"
      PORTNumCorrect=false
    else
      if whiptail \
        --backtitle "Specify Custom Port" \
        --title "Confirm Custom Port Number" \
        --yesno "Are these settings correct?
    PORT:   ${pivpnPORT}" "${r}" "${c}"; then
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

setupPiholeDNS() {
  # Add a custom hosts file for VPN clients so they appear
  # as 'name.pivpn' in the Pi-hole dashboard as well as resolve
  # by their names.
  echo "addn-hosts=/etc/pivpn/hosts.${VPN}" \
    | ${SUDO} tee "${dnsmasqConfig}" > /dev/null

  # Then create an empty hosts file or clear if it exists.
  ${SUDO} bash -c "> /etc/pivpn/hosts.${VPN}"

  # Setting Pi-hole to "Listen on all interfaces" allows
  # dnsmasq to listen on the VPN interface while permitting
  # queries only from hosts whose address is on the LAN and
  # VPN subnets.
  ${SUDO} pihole -a -i local

  # Use the Raspberry Pi VPN IP as DNS server.
  pivpnDNS1="${vpnGw}"

  {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"

  # Allow incoming DNS requests through UFW.
  if [[ "${USING_UFW}" -eq 1 ]]; then
    ${SUDO} ufw insert 1 allow in \
      on "${pivpnDEV}" to any port 53 \
      from "${pivpnNET}/${subnetClass}" > /dev/null
  else
    ${SUDO} iptables -I INPUT -i "${pivpnDEV}" \
      -p udp --dport 53 -j ACCEPT -m comment --comment "pihole-DNS-rule"
  fi
}

askClientDNS() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ "${usePiholeDNS}" == 'true' ]] \
      && command -v pihole > /dev/null \
      && [[ -r "${piholeSetupVars}" ]]; then
      setupPiholeDNS
      return
    elif [[ -z "${pivpnDNS1}" ]] \
      && [[ -n "${pivpnDNS2}" ]]; then
      pivpnDNS1="${pivpnDNS2}"
      unset pivpnDNS2
    elif [[ -z "${pivpnDNS1}" ]] \
      && [[ -z "${pivpnDNS2}" ]]; then
      pivpnDNS1="9.9.9.9"
      pivpnDNS2="149.112.112.112"
      echo -n "::: No DNS provider specified, "
      echo "using Quad9 DNS (${pivpnDNS1} ${pivpnDNS2})"
    fi

    local INVALID_DNS_SETTINGS=0

    if ! validIP "${pivpnDNS1}"; then
      INVALID_DNS_SETTINGS=1
      echo "::: Invalid DNS ${pivpnDNS1}"
    fi

    if [[ -n "${pivpnDNS2}" ]] \
      && ! validIP "${pivpnDNS2}"; then
      INVALID_DNS_SETTINGS=1
      echo "::: Invalid DNS ${pivpnDNS2}"
    fi

    if [[ "${INVALID_DNS_SETTINGS}" -eq 0 ]]; then
      echo "::: Using DNS ${pivpnDNS1} ${pivpnDNS2}"
    else
      exit 1
    fi

    {
      echo "pivpnDNS1=${pivpnDNS1}"
      echo "pivpnDNS2=${pivpnDNS2}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # Detect and offer to use Pi-hole
  if command -v pihole > /dev/null; then
    if [[ "${usePiholeDNS}" == 'true' ]] \
      || whiptail \
        --backtitle "Setup PiVPN" \
        --title "Pi-hole" \
        --yesno "We have detected a Pi-hole installation, \
do you want to use it as the DNS server for the VPN, so you \
get ad blocking on the go?" "${r}" "${c}"; then
      if [[ ! -r "${piholeSetupVars}" ]]; then
        err "::: Unable to read ${piholeSetupVars}"
        exit 1
      fi

      setupPiholeDNS
      return
    fi
  fi

  DNSChoseCmd=(whiptail
    --backtitle "Setup PiVPN"
    --title "DNS Provider"
    --separate-output
    --radiolist "Select the DNS Provider for your VPN Clients \
(press space to select).
To use your own, select Custom.

In case you have a local resolver running, i.e. unbound, select \
\"PiVPN-is-local-DNS\" and make sure your resolver is listening on \
\"${vpnGw}\", allowing requests from \
\"${pivpnNET}/${subnetClass}\"." "${r}" "${c}" 6)
  DNSChooseOptions=(Quad9 "" on
    OpenDNS "" off
    Level3 "" off
    DNS.WATCH "" off
    Norton "" off
    FamilyShield "" off
    CloudFlare "" off
    Google "" off
    PiVPN-is-local-DNS "" off
    Custom "" off)

  if DNSchoices="$("${DNSChoseCmd[@]}" \
    "${DNSChooseOptions[@]}" \
    2>&1 > /dev/tty)"; then
    if [[ "${DNSchoices}" != "Custom" ]]; then
      echo "::: Using ${DNSchoices} servers."
      declare -A DNS_MAP=(["Quad9"]="9.9.9.9 149.112.112.112"
        ["OpenDNS"]="208.67.222.222 208.67.220.220"
        ["Level3"]="209.244.0.3 209.244.0.4"
        ["DNS.WATCH"]="84.200.69.80 84.200.70.40"
        ["Norton"]="199.85.126.10 199.85.127.10"
        ["FamilyShield"]="208.67.222.123 208.67.220.123"
        ["CloudFlare"]="1.1.1.1 1.0.0.1"
        ["Google"]="8.8.8.8 8.8.4.4"
        ["PiVPN-is-local-DNS"]="${vpnGw}")
      pivpnDNS1=$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")
      pivpnDNS2=$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")
    else
      until [[ "${DNSSettingsCorrect}" == 'true' ]]; do
        strInvalid="Invalid"

        if pivpnDNS="$(whiptail \
          --backtitle "Specify Upstream DNS Provider(s)" \
          --inputbox "Enter your desired upstream DNS provider(s), \
separated by a comma.

For example '1.1.1.1, 9.9.9.9'" "${r}" "${c}" "" \
          3>&1 1>&2 2>&3)"; then
          pivpnDNS1="$(echo "${pivpnDNS}" \
            | sed 's/[, \t]\+/,/g' \
            | awk -F, '{print$1}')"
          pivpnDNS2="$(echo "${pivpnDNS}" \
            | sed 's/[, \t]\+/,/g' \
            | awk -F, '{print$2}')"

          if ! validIP "${pivpnDNS1}" \
            || [[ ! "${pivpnDNS1}" ]]; then
            pivpnDNS1="${strInvalid}"
          fi

          if ! validIP "${pivpnDNS2}" \
            && [[ "${pivpnDNS2}" ]]; then
            pivpnDNS2="${strInvalid}"
          fi
        else
          err "::: Cancel selected, exiting...."
          exit 1
        fi

        if [[ "${pivpnDNS1}" == "${strInvalid}" ]] \
          || [[ "${pivpnDNS2}" == "${strInvalid}" ]]; then
          whiptail \
            --backtitle "Invalid IP" \
            --title "Invalid IP" \
            --msgbox "One or both entered IP addresses were invalid. \
Please try again.
    DNS Server 1:   ${pivpnDNS1}
    DNS Server 2:   ${pivpnDNS2}" "${r}" "${c}"

          if [[ "${pivpnDNS1}" == "${strInvalid}" ]]; then
            pivpnDNS1=""
          fi

          if [[ "${pivpnDNS2}" == "${strInvalid}" ]]; then
            pivpnDNS2=""
          fi

          DNSSettingsCorrect=false
        else
          if whiptail \
            --backtitle "Specify Upstream DNS Provider(s)" \
            --title "Upstream DNS Provider(s)" \
            --yesno "Are these settings correct?
    DNS Server 1:   ${pivpnDNS1}
    DNS Server 2:   ${pivpnDNS2}" "${r}" "${c}"; then
            DNSSettingsCorrect=true
          else
            # If the settings are wrong, the loop continues
            DNSSettingsCorrect=false
          fi
        fi
      done
    fi

  else
    err "::: Cancel selected. Exiting..."
    exit 1
  fi

  {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"
}

# Call this function to use a regex to check user
# input for a valid custom domain
validDomain() {
  local domain="${1}"
  local perl_regexp='(?=^.{4,253}$)'
  perl_regexp="${perl_regexp}(^(?:[a-zA-Z0-9](?:(?:[a-zA-Z0-9\-]){0,61}"
  perl_regexp="${perl_regexp}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)"
  grep -qP "${perl_regexp}" <<< "${domain}"
}

# This procedure allows a user to specify a custom
# search domain if they have one.
askCustomDomain() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
      if validDomain "${pivpnSEARCHDOMAIN}"; then
        echo "::: Using custom domain ${pivpnSEARCHDOMAIN}"
      else
        err "::: Custom domain ${pivpnSEARCHDOMAIN} is not valid"
        exit 1
      fi
    else
      echo "::: Skipping custom domain"
    fi

    echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
      return
    fi
  fi

  DomainSettingsCorrect=false

  if whiptail \
    --backtitle "Custom Search Domain" \
    --title "Custom Search Domain" \
    --defaultno \
    --yesno "Would you like to add a custom search domain?
(This is only for advanced users who have their own domain)
" "${r}" "${c}"; then
    until [[ "${DomainSettingsCorrect}" == 'true' ]]; do
      if pivpnSEARCHDOMAIN="$(whiptail \
        --inputbox "Enter Custom Domain
Format: mydomain.com" "${r}" "${c}" \
        --title "Custom Domain" \
        3>&1 1>&2 2>&3)"; then
        if validDomain "${pivpnSEARCHDOMAIN}"; then
          if whiptail \
            --backtitle "Custom Search Domain" \
            --title "Custom Search Domain" \
            --yesno "Are these settings correct?
    Custom Search Domain: ${pivpnSEARCHDOMAIN}" "${r}" "${c}"; then
            DomainSettingsCorrect=true
          else
            # If the settings are wrong, the loop continues
            DomainSettingsCorrect=false
          fi
        else
          whiptail \
            --backtitle "Invalid Domain" \
            --title "Invalid Domain" \
            --msgbox "Domain is invalid. Please try again.
    DOMAIN:   ${pivpnSEARCHDOMAIN}
" "${r}" "${c}"
          DomainSettingsCorrect=false
        fi
      else
        err "::: Cancel selected. Exiting..."
        exit 1
      fi
    done
  fi

  echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
}

askPublicIPOrDNS() {
  if ! IPv4pub="$(dig +short myip.opendns.com @208.67.222.222)" \
    || ! validIP "${IPv4pub}"; then
    err "dig failed, now trying to curl checkip.amazonaws.com"

    if ! IPv4pub="$(curl -sSf https://checkip.amazonaws.com)" \
      || ! validIP "${IPv4pub}"; then
      err "checkip.amazonaws.com failed, please check your internet connection/DNS"
      exit 1
    fi
  fi

  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnHOST}" ]]; then
      echo "::: No IP or domain name specified, using public IP ${IPv4pub}"
      pivpnHOST="${IPv4pub}"
    else
      if validIP "${pivpnHOST}"; then
        echo "::: Using public IP ${pivpnHOST}"
      elif validDomain "${pivpnHOST}"; then
        echo "::: Using domain name ${pivpnHOST}"
      else
        err "::: ${pivpnHOST} is not a valid IP or domain name"
        exit 1
      fi
    fi

    echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
    return
  fi

  local publicDNSCorrect
  local publicDNSValid

  if METH="$(whiptail \
    --title "Public IP or DNS" \
    --radiolist \
    "Will clients use a Public IP or DNS Name to connect to your server \
(press space to select)?" "${r}" "${c}" 2 \
    "${IPv4pub}" "Use this public IP" "ON" \
    "DNS Entry" "Use a public DNS" "OFF" \
    3>&1 1>&2 2>&3)"; then
    if [[ "${METH}" == "${IPv4pub}" ]]; then
      pivpnHOST="${IPv4pub}"
    else
      until [[ "${publicDNSCorrect}" == 'true' ]]; do
        until [[ "${publicDNSValid}" == 'true' ]]; do
          if PUBLICDNS="$(whiptail \
            --title "PiVPN Setup" \
            --inputbox "What is the public DNS \
name of this Server?" "${r}" "${c}" \
            3>&1 1>&2 2>&3)"; then
            if validDomain "${PUBLICDNS}"; then
              publicDNSValid=true
              pivpnHOST="${PUBLICDNS}"
            else
              whiptail \
                --backtitle "PiVPN Setup" \
                --title "Invalid DNS name" \
                --msgbox "This DNS name is invalid. Please try again.
    DNS name:   ${PUBLICDNS}
" "${r}" "${c}"
              publicDNSValid=false
            fi
          else
            err "::: Cancel selected. Exiting..."
            exit 1
          fi
        done

        if whiptail \
          --backtitle "PiVPN Setup" \
          --title "Confirm DNS Name" \
          --yesno "Is this correct?
Public DNS Name:  ${PUBLICDNS}" "${r}" "${c}"; then
          publicDNSCorrect=true
        else
          publicDNSCorrect=false
          publicDNSValid=false
        fi
      done
    fi
  else
    err "::: Cancel selected. Exiting..."
    exit 1
  fi

  echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
}

askEncryption() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${TWO_POINT_FOUR}" ]] \
      || [[ "${TWO_POINT_FOUR}" -eq 1 ]]; then
      TWO_POINT_FOUR=1
      echo "::: Using OpenVPN 2.4 features"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=256
      fi

      if [[ "${pivpnENCRYPT}" -eq 256 ]] \
        || [[ "${pivpnENCRYPT}" -eq 384 ]] \
        || [[ "${pivpnENCRYPT}" -eq 521 ]]; then
        echo "::: Using a ${pivpnENCRYPT}-bit certificate"
      else
        err "::: ${pivpnENCRYPT} is not a valid certificate size, use 256, 384, or 521"
        exit 1
      fi
    else
      TWO_POINT_FOUR=0
      echo "::: Using traditional OpenVPN configuration"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=2048
      fi

      if [[ "${pivpnENCRYPT}" -eq 2048 ]] \
        || [[ "${pivpnENCRYPT}" -eq 3072 ]] \
        || [[ "${pivpnENCRYPT}" -eq 4096 ]]; then
        echo "::: Using a ${pivpnENCRYPT}-bit certificate"
      else
        err "::: ${pivpnENCRYPT} is not a valid certificate size, use 2048, 3072, or 4096"
        exit 1
      fi

      if [[ -z "${USE_PREDEFINED_DH_PARAM}" ]]; then
        USE_PREDEFINED_DH_PARAM=1
      fi

      if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
        echo "::: Pre-defined DH parameters will be used"
      else
        echo "::: DH parameters will be generated locally"
      fi
    fi

    {
      echo "TWO_POINT_FOUR=${TWO_POINT_FOUR}"
      echo "pivpnENCRYPT=${pivpnENCRYPT}"
      echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
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

  if whiptail \
    --backtitle "Setup OpenVPN" \
    --title "Installation mode" \
    --yesno "OpenVPN 2.4 can take advantage of Elliptic Curves \
to provide higher connection speed and improved security over \
RSA, while keeping smaller certificates.

Moreover, the 'tls-crypt' directive encrypts the certificates \
being used while authenticating, increasing privacy.

If your clients do run OpenVPN 2.4 or later you can enable \
these features, otherwise choose 'No' for best \
compatibility." \
    "${r}" \
    "${c}"; then
    TWO_POINT_FOUR=1
    pivpnENCRYPT="$(whiptail \
      --backtitle "Setup OpenVPN" \
      --title "ECDSA certificate size" \
      --radiolist "Choose the desired size of your certificate \
(press space to select):
This is a certificate that will be generated on your system. \
The larger the certificate, the more time this will take. \
For most applications, it is recommended to use 256 bits. \
You can increase the number of bits if you care about, however, consider \
that 256 bits are already as secure as 3072 bit RSA." "${r}" "${c}" 3 \
      "256" "Use a 256-bit certificate (recommended level)" ON \
      "384" "Use a 384-bit certificate" OFF \
      "521" "Use a 521-bit certificate (paranoid level)" OFF \
      3>&1 1>&2 2>&3)"
  else
    TWO_POINT_FOUR=0
    pivpnENCRYPT="$(whiptail \
      --backtitle "Setup OpenVPN" \
      --title "RSA certificate size" \
      --radiolist "Choose the desired size of your certificate \
(press space to select):
This is a certificate that will be generated on your system. \
The larger the certificate, the more time this will take. \
For most applications, it is recommended to use 2048 bits. \
If you are paranoid about ... things... \
then grab a cup of joe and pick 4096 bits." "${r}" "${c}" 3 \
      "2048" "Use a 2048-bit certificate (recommended level)" ON \
      "3072" "Use a 3072-bit certificate " OFF \
      "4096" "Use a 4096-bit certificate (paranoid level)" OFF \
      3>&1 1>&2 2>&3)"
  fi

  exitstatus="$?"

  if [[ "${exitstatus}" != 0 ]]; then
    err "::: Cancel selected. Exiting..."
    exit 1
  fi

  if [[ "${pivpnENCRYPT}" -ge 2048 ]] \
    && whiptail \
      --backtitle "Setup OpenVPN" \
      --title "Generate Diffie-Hellman Parameters" \
      --yesno "Generating DH parameters can take many hours on a Raspberry Pi. \
You can instead use Pre-defined DH parameters recommended by the \
Internet Engineering Task Force.
More information about those can be found here: \
https://wiki.mozilla.org/Security/Archive/Server_Side_TLS_4.0#\
Pre-defined_DHE_groups
If you want unique parameters, choose 'No' and new Diffie-Hellman \
parameters will be generated on your device." "${r}" "${c}"; then
    USE_PREDEFINED_DH_PARAM=1
  else
    USE_PREDEFINED_DH_PARAM=0
  fi

  {
    echo "TWO_POINT_FOUR=${TWO_POINT_FOUR}"
    echo "pivpnENCRYPT=${pivpnENCRYPT}"
    echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
  } >> "${tempsetupVarsFile}"
}

confOpenVPN() {
  local sed_pattern file_pattern

  # Grab the existing Hostname
  host_name="$(hostname -s)"
  # Generate a random UUID for this server so that we can use
  # verify-x509-name later that is unique for this server
  # installation.
  NEW_UUID="$(< /proc/sys/kernel/random/uuid)"
  # Create a unique server name using the host name and UUID
  SERVER_NAME="${host_name}_${NEW_UUID}"

  # Backup the openvpn folder
  OPENVPN_BACKUP="openvpn_$(date +%Y-%m-%d-%H%M%S).tar.gz"
  echo "::: Backing up the openvpn folder to /etc/${OPENVPN_BACKUP}"
  CURRENT_UMASK="$(umask)"
  umask 0077
  ${SUDO} tar -czf "/etc/${OPENVPN_BACKUP}" /etc/openvpn &> /dev/null
  umask "${CURRENT_UMASK}"

  if [[ -f /etc/openvpn/server.conf ]]; then
    ${SUDO} rm /etc/openvpn/server.conf
  fi

  if [[ -d /etc/openvpn/ccd ]]; then
    ${SUDO} rm -rf /etc/openvpn/ccd
  fi

  # Create folder to store client specific directives used to push static IPs
  ${SUDO} mkdir /etc/openvpn/ccd

  # If easy-rsa exists, remove it
  if [[ -d /etc/openvpn/easy-rsa/ ]]; then
    ${SUDO} rm -rf /etc/openvpn/easy-rsa/
  fi

  # Get easy-rsa
  curl -sSfL "${easyrsaRel}" \
    | ${SUDO} tar -xz --one-top-level=/etc/openvpn/easy-rsa --strip-components 1

  if [[ ! -s /etc/openvpn/easy-rsa/easyrsa ]]; then
    err "${0}: ERR: Failed to download EasyRSA."
    exit 1
  fi

  # fix ownership
  ${SUDO} chown -R root:root /etc/openvpn/easy-rsa
  ${SUDO} mkdir /etc/openvpn/easy-rsa/pki
  ${SUDO} chmod 700 /etc/openvpn/easy-rsa/pki

  cd /etc/openvpn/easy-rsa || exit 1

  if [[ "${TWO_POINT_FOUR}" -eq 1 ]]; then
    pivpnCERT="ec"
    pivpnTLSPROT="tls-crypt"
  else
    pivpnCERT="rsa"
    pivpnTLSPROT="tls-auth"
  fi

  # Remove any previous keys
  ${SUDOE} ./easyrsa --batch init-pki

  # Copy template vars file
  ${SUDOE} cp vars.example pki/vars

  # Set elliptic curve certificate or traditional rsa certificates
  ${SUDOE} sed -i \
    "s/#set_var EASYRSA_ALGO.*/set_var EASYRSA_ALGO ${pivpnCERT}/" \
    pki/vars

  # Set expiration for the CRL to 10 years
  ${SUDOE} sed -i \
    's/#set_var EASYRSA_CRL_DAYS.*/set_var EASYRSA_CRL_DAYS 3650/' \
    pki/vars

  if [[ "${pivpnENCRYPT}" -ge 2048 ]]; then
    # Set custom key size if different from the default
    sed_pattern="s/#set_var EASYRSA_KEY_SIZE.*/"
    sed_pattern="${sed_pattern} set_var EASYRSA_KEY_SIZE ${pivpnENCRYPT}/"
    ${SUDOE} sed -i "${sed_pattern}" pki/vars
  else
    # If less than 2048, then it must be 521 or lower,
    # which means elliptic curve certificate was selected.
    # We set the curve in this case.
    declare -A ECDSA_MAP=(["256"]="prime256v1"
      ["384"]="secp384r1"
      ["521"]="secp521r1")

    sed_pattern="s/#set_var EASYRSA_CURVE.*/"
    sed_pattern="${sed_pattern} set_var EASYRSA_CURVE"
    sed_pattern="${sed_pattern} ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
    ${SUDOE} sed -i "${sed_pattern}" pki/vars
  fi

  # Build the certificate authority
  printf "::: Building CA...\\n"
  ${SUDOE} ./easyrsa --batch build-ca nopass
  printf "\\n::: CA Complete.\\n"

  if [[ "${pivpnCERT}" == "rsa" ]] \
    && [[ "${USE_PREDEFINED_DH_PARAM}" -ne 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: The server key, Diffie-Hellman parameters, \
and HMAC key will now be generated."
    else
      whiptail \
        --msgbox \
        --backtitle "Setup OpenVPN" \
        --title "Server Information" \
        "The server key, Diffie-Hellman parameters, \
and HMAC key will now be generated." \
        "${r}" \
        "${c}"
    fi
  elif [[ "${pivpnCERT}" == "ec" ]] \
    || [[ "${pivpnCERT}" == "rsa" && "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: The server key and HMAC key will now be generated."
    else
      whiptail \
        --msgbox \
        --backtitle "Setup OpenVPN" \
        --title "Server Information" \
        "The server key and HMAC key will now be generated." \
        "${r}" \
        "${c}"
    fi
  fi

  # Build the server
  EASYRSA_CERT_EXPIRE=3650 ${SUDOE} ./easyrsa \
    build-server-full \
    "${SERVER_NAME}" \
    nopass

  if [[ "${pivpnCERT}" == "rsa" ]]; then
    if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
      file_pattern="${pivpnFilesDir}/files/etc/openvpn"
      file_pattern="${file_pattern}/easy-rsa/pki/ffdhe${pivpnENCRYPT}.pem"
      # Use Diffie-Hellman parameters from RFC 7919 (FFDHE)
      ${SUDOE} install -m 644 "${file_pattern}" \
        "pki/dh${pivpnENCRYPT}.pem"
    else
      # Generate Diffie-Hellman key exchange
      ${SUDOE} ./easyrsa gen-dh
      ${SUDOE} mv pki/dh.pem "pki/dh${pivpnENCRYPT}".pem
    fi
  fi

  # Generate static HMAC key to defend against DDoS
  ${SUDOE} openvpn --genkey --secret pki/ta.key

  # Generate an empty Certificate Revocation List
  ${SUDOE} ./easyrsa gen-crl
  ${SUDOE} cp pki/crl.pem /etc/openvpn/crl.pem

  if ! getent passwd "${ovpnUserGroup%:*}"; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      ${SUDOE} adduser -SD \
        -h /var/lib/openvpn/ \
        -s /sbin/nologin \
        "${ovpnUserGroup%:*}"
    else
      ${SUDOE} useradd \
        --system \
        --home /var/lib/openvpn/ \
        --shell /usr/sbin/nologin \
        "${ovpnUserGroup%:*}"
    fi
  fi

  ${SUDOE} chown "${ovpnUserGroup}" /etc/openvpn/crl.pem

  # Write config file for server using the template.txt file
  ${SUDO} install -m 644 \
    "${pivpnFilesDir}/files/etc/openvpn/server_config.txt" \
    /etc/openvpn/server.conf

  # Apply client DNS settings
  ${SUDOE} sed -i \
    "0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1${pivpnDNS1}\"/" \
    /etc/openvpn/server.conf

  if [[ -z "${pivpnDNS2}" ]]; then
    ${SUDOE} sed -i '/\(dhcp-option DNS \)/{n;N;d}' /etc/openvpn/server.conf
  else
    ${SUDOE} sed -i \
      "0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1${pivpnDNS2}\"/" \
      /etc/openvpn/server.conf
  fi

  # Set the user encryption key size
  ${SUDO} sed -i \
    "s#\\(dh /etc/openvpn/easy-rsa/pki/dh\\).*#\\1${pivpnENCRYPT}.pem#" \
    /etc/openvpn/server.conf

  if [[ "${pivpnTLSPROT}" == "tls-crypt" ]]; then
    # If they enabled 2.4 use tls-crypt instead of
    # tls-auth to encrypt control channel
    sed_pattern="s/tls-auth"
    sed_pattern="${sed_pattern} \/etc\/openvpn\/easy-rsa\/pki\/ta.key 0/"
    sed_pattern="${sed_pattern} tls-crypt"
    sed_pattern="${sed_pattern} \/etc\/openvpn\/easy-rsa\/pki\/ta.key/"
    ${SUDO} sed -i "${sed_pattern}" /etc/openvpn/server.conf
  fi

  if [[ "${pivpnCERT}" == "ec" ]]; then
    # If they enabled 2.4 disable dh parameters and specify the
    # matching curve from the ECDSA certificate
    sed_pattern="s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/dh"
    sed_pattern="${sed_pattern} none\necdh-curve"
    sed_pattern="${sed_pattern} ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
    ${SUDO} sed -i \
      "${sed_pattern}" \
      /etc/openvpn/server.conf
  elif [[ "${pivpnCERT}" == "rsa" ]]; then
    # Otherwise set the user encryption key size
    ${SUDO} sed -i \
      "s#\\(dh /etc/openvpn/easy-rsa/pki/dh\\).*#\\1${pivpnENCRYPT}.pem#" \
      /etc/openvpn/server.conf
  fi

  # if they modified VPN network put value in server.conf
  if [[ "${pivpnNET}" != "10.8.0.0" ]]; then
    ${SUDO} sed -i "s/10.8.0.0/${pivpnNET}/g" /etc/openvpn/server.conf
  fi

  # if they modified VPN subnet class put value in server.conf
  if [[ "$(cidrToMask "${subnetClass}")" != "255.255.255.0" ]]; then
    ${SUDO} sed -i \
      "s/255.255.255.0/$(cidrToMask "${subnetClass}")/g" \
      /etc/openvpn/server.conf
  fi

  # if they modified port put value in server.conf
  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    ${SUDO} sed -i "s/1194/${pivpnPORT}/g" /etc/openvpn/server.conf
  fi

  # if they modified protocol put value in server.conf
  if [[ "${pivpnPROTO}" != "udp" ]]; then
    ${SUDO} sed -i "s/proto udp/proto tcp/g" /etc/openvpn/server.conf
  fi

  if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
    sed_pattern="0,/\\(.*dhcp-option.*\\)/"
    sed_pattern="${sed_pattern}s//push \"dhcp-option "
    sed_pattern="${sed_pattern}DOMAIN ${pivpnSEARCHDOMAIN}\" \\n&/"
    ${SUDO} sed -i \
      "${sed_pattern}" \
      /etc/openvpn/server.conf
  fi

  # write out server certs to conf file
  ${SUDO} sed -i \
    "s#\\(key /etc/openvpn/easy-rsa/pki/private/\\).*#\\1${SERVER_NAME}.key#" \
    /etc/openvpn/server.conf
  ${SUDO} sed -i \
    "s#\\(cert /etc/openvpn/easy-rsa/pki/issued/\\).*#\\1${SERVER_NAME}.crt#" \
    /etc/openvpn/server.conf

  # On Alpine Linux, the default config file for OpenVPN is
  # "/etc/openvpn/openvpn.conf".
  # To avoid crash thorugh OpenRC, we symlink this file.
  if [[ "${PLAT}" == 'Alpine' ]]; then
    ${SUDO} ln -sfT \
      /etc/openvpn/server.conf \
      /etc/openvpn/openvpn.conf \
      > /dev/null
  fi
}

confOVPN() {
  ${SUDO} install -m 644 \
    "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  ${SUDO} sed -i \
    "s/IPv4pub/${pivpnHOST}/" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  # if they modified port put value in Default.txt for clients to use
  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    ${SUDO} sed -i \
      "s/1194/${pivpnPORT}/g" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi

  # if they modified protocol put value in Default.txt for clients to use
  if [[ "${pivpnPROTO}" != "udp" ]]; then
    ${SUDO} sed -i \
      "s/proto udp/proto tcp/g" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi

  # verify server name to strengthen security
  ${SUDO} sed -i \
    "s/SRVRNAME/${SERVER_NAME}/" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  if [[ "${pivpnTLSPROT}" == "tls-crypt" ]]; then
    # If they enabled 2.4 remove key-direction options since it's not required
    ${SUDO} sed -i \
      "/key-direction 1/d" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi
}

confWireGuard() {
  # Reload job type is not yet available in wireguard-tools shipped with
  # Ubuntu 20.04
  if [[ "${PLAT}" == 'Alpine' ]]; then
    echo '::: Adding wg-quick unit'
    ${SUDO} install -m 0755 \
      "${pivpnFilesDir}/files/etc/init.d/wg-quick" \
      /etc/init.d/wg-quick
  else
    if ! grep -q 'ExecReload' /lib/systemd/system/wg-quick@.service; then
      local wireguard_service_path
      wireguard_service_path="${pivpnFilesDir}/files/etc/systemd/system"
      wireguard_service_path="${wireguard_service_path}/wg-quick@.service.d"
      wireguard_service_path="${wireguard_service_path}/override.conf"
      echo "::: Adding additional reload job type for wg-quick unit"
      ${SUDO} install -Dm 644 \
        "${wireguard_service_path}" \
        /etc/systemd/system/wg-quick@.service.d/override.conf
      ${SUDO} systemctl daemon-reload
    fi
  fi

  if [[ -d /etc/wireguard ]]; then
    # Backup the wireguard folder
    WIREGUARD_BACKUP="wireguard_$(date +%Y-%m-%d-%H%M%S).tar.gz"
    echo "::: Backing up the wireguard folder to /etc/${WIREGUARD_BACKUP}"
    CURRENT_UMASK="$(umask)"
    umask 0077
    ${SUDO} tar -czf "/etc/${WIREGUARD_BACKUP}" /etc/wireguard &> /dev/null
    umask "${CURRENT_UMASK}"

    if [[ -f /etc/wireguard/wg0.conf ]]; then
      ${SUDO} rm /etc/wireguard/wg0.conf
    fi
  else
    # If compiled from source, the wireguard folder is not being created
    ${SUDO} mkdir /etc/wireguard
  fi

  # Ensure that only root is able to enter the wireguard folder
  ${SUDO} chown root:root /etc/wireguard
  ${SUDO} chmod 700 /etc/wireguard

  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: The Server Keys will now be generated."
  else
    whiptail \
      --title "Server Information" \
      --msgbox "The Server Keys will now be generated." \
      "${r}" \
      "${c}"
  fi

  # Remove configs and keys folders to make space for a new server when
  # using 'Repair' or 'Reconfigure' over an existing installation
  ${SUDO} rm -rf /etc/wireguard/configs
  ${SUDO} rm -rf /etc/wireguard/keys

  ${SUDO} mkdir -p /etc/wireguard/configs
  ${SUDO} touch /etc/wireguard/configs/clients.txt
  ${SUDO} mkdir -p /etc/wireguard/keys

  # Generate private key and derive public key from it
  wg genkey \
    | ${SUDO} tee /etc/wireguard/keys/server_priv &> /dev/null
  ${SUDO} cat /etc/wireguard/keys/server_priv \
    | wg pubkey \
    | ${SUDO} tee /etc/wireguard/keys/server_pub &> /dev/null

  echo "::: Server Keys have been generated."

  {
    echo '[Interface]'
    echo "PrivateKey = $(${SUDO} cat /etc/wireguard/keys/server_priv)"
    echo -n "Address = ${vpnGw}/${subnetClass}"

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      echo ",${vpnGwv6}/${subnetClassv6}"
    else
      echo
    fi

    echo "MTU = ${pivpnMTU}"
    echo "ListenPort = ${pivpnPORT}"
  } | ${SUDO} tee /etc/wireguard/wg0.conf &> /dev/null

  echo "::: Server config generated."
}

confNetwork() {
  # Enable forwarding of internet traffic
  echo 'net.ipv4.ip_forward=1' \
    | ${SUDO} tee /etc/sysctl.d/99-pivpn.conf > /dev/null

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    {
      echo "net.ipv6.conf.all.forwarding=1"
      echo "net.ipv6.conf.${IPv6dev}.accept_ra=2"
    } | ${SUDO} tee -a /etc/sysctl.d/99-pivpn.conf > /dev/null
  fi

  ${SUDO} sysctl -p /etc/sysctl.d/99-pivpn.conf > /dev/null

  if [[ "${USING_UFW}" -eq 1 ]]; then
    echo "::: Detected UFW is enabled."
    echo "::: Adding UFW rules..."

    ### Basic safeguard: if file is empty, there's been something weird going
    ### on.
    ### Note: no safeguard against imcomplete content as a result of previous
    ### failures.
    if [[ -s /etc/ufw/before.rules ]]; then
      ${SUDO} cp -f /etc/ufw/before.rules /etc/ufw/before.rules.pre-pivpn
    else
      err "${0}: ERR: Sorry, won't touch empty file \"/etc/ufw/before.rules\"."
      exit 1
    fi

    if [[ -s /etc/ufw/before6.rules ]]; then
      ${SUDO} cp -f /etc/ufw/before6.rules /etc/ufw/before6.rules.pre-pivpn
    else
      err "${0}: ERR: Sorry, won't touch empty file \"/etc/ufw/before6.rules\"."
      exit 1
    fi

    ### If there is already a "*nat" section just add our POSTROUTING MASQUERADE
    if ${SUDO} grep -q "*nat" /etc/ufw/before.rules; then
      local sed_pattern

      ### Onyl add the IPv4 NAT rule if it isn't already there
      if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before.rules; then
        sed_pattern="/^*nat/{n;"
        sed_pattern="${sed_pattern}s/\(:POSTROUTING ACCEPT .*\)/"
        sed_pattern="${sed_pattern}\1\n-I POSTROUTING"
        sed_pattern="${sed_pattern} -s ${pivpnNET}\/${subnetClass}"
        sed_pattern="${sed_pattern} -o ${IPv4dev}"
        sed_pattern="${sed_pattern} -j MASQUERADE"
        sed_pattern="${sed_pattern} -m comment"
        sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/"
        sed_pattern="${sed_pattern}}"
        ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before.rules
      fi
    else
      sed_pattern="/delete these required/i"
      sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
      sed_pattern="${sed_pattern}-I POSTROUTING"
      sed_pattern="${sed_pattern} -s ${pivpnNET}\/${subnetClass}"
      sed_pattern="${sed_pattern} -o ${IPv4dev}"
      sed_pattern="${sed_pattern} -j MASQUERADE"
      sed_pattern="${sed_pattern} -m comment"
      sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule\n"
      sed_pattern="${sed_pattern}COMMIT\n"
      ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before.rules
    fi

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      local sed_pattern

      if ${SUDO} grep -q "*nat" /etc/ufw/before6.rules; then
        ### Onyl add the IPv6 NAT rule if it isn't already there
        if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before6.rules; then
          sed_pattern="/^*nat/{n;"
          sed_pattern="${sed_pattern}s/\(:POSTROUTING ACCEPT .*\)/"
          sed_pattern="${sed_pattern}\1\n-I POSTROUTING"
          sed_pattern="${sed_pattern} -s ${pivpnNETv6}\/${subnetClassv6}"
          sed_pattern="${sed_pattern} -o ${IPv6dev}"
          sed_pattern="${sed_pattern} -j MASQUERADE"
          sed_pattern="${sed_pattern} -m comment"
          sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/"
          sed_pattern="${sed_pattern}}"
          ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before6.rules
        fi
      else
        sed_pattern="/delete these required/i"
        sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
        sed_pattern="${sed_pattern}-I POSTROUTING"
        sed_pattern="${sed_pattern} -s ${pivpnNETv6}\/${subnetClassv6}"
        sed_pattern="${sed_pattern} -o ${IPv6dev}"
        sed_pattern="${sed_pattern} -j MASQUERADE"
        sed_pattern="${sed_pattern} -m comment"
        sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule\n"
        sed_pattern="${sed_pattern}COMMIT\n"
        ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before6.rules
      fi
    fi

    # Checks for any existing UFW rules and
    # insert rules at the beginning of the chain
    # (in case there are other rules that may drop the traffic)
    if ${SUDO} ufw status numbered | grep -E "\[.[0-9]{1}\]" > /dev/null; then
      ${SUDO} ufw insert 1 \
        allow "${pivpnPORT}/${pivpnPROTO}" \
        comment "allow-${VPN}" > /dev/null

      ${SUDO} ufw route insert 1 \
        allow in on "${pivpnDEV}" \
        from "${pivpnNET}/${subnetClass}" \
        out on "${IPv4dev}" to any > /dev/null

      if [[ "${pivpnenableipv6}" -eq 1 ]]; then
        ${SUDO} ufw route insert 1 \
          allow in on "${pivpnDEV}" \
          from "${pivpnNETv6}/${subnetClassv6}" \
          out on "${IPv6dev}" to any > /dev/null
      fi
    fi

    ${SUDO} ufw reload > /dev/null
    echo "::: UFW configuration completed."
    return
  fi

  # Now some checks to detect which rules we need to add.
  # On a newly installed system all policies should be ACCEPT,
  # so the only required rule would be the MASQUERADE one.

  if ! ${SUDO} iptables -t nat -S \
    | grep -q "${VPN}-nat-rule"; then
    ${SUDO} iptables \
      -t nat \
      -I POSTROUTING \
      -s "${pivpnNET}/${subnetClass}" \
      -o "${IPv4dev}" \
      -j MASQUERADE \
      -m comment \
      --comment "${VPN}-nat-rule"
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if ! ${SUDO} ip6tables -t nat -S \
      | grep -q "${VPN}-nat-rule"; then
      ${SUDO} ip6tables \
        -t nat \
        -I POSTROUTING \
        -s "${pivpnNETv6}/${subnetClassv6}" \
        -o "${IPv6dev}" \
        -j MASQUERADE \
        -m comment \
        --comment "${VPN}-nat-rule"
    fi
  fi

  # Count how many rules are in the INPUT and FORWARD chain.
  # When parsing input from iptables -S, '^-P' skips the policies
  # and 'ufw-' skips ufw chains (in case ufw was found
  # installed but not enabled).

  # Grep returns non 0 exit code where there are no matches,
  # however that would make the script exit,
  # for this reasons we use '|| true' to force exit code 0
  INPUT_RULES_COUNT="$(${SUDO} iptables -S INPUT \
    | grep -vcE '(^-P|ufw-)')"
  FORWARD_RULES_COUNT="$(${SUDO} iptables -S FORWARD \
    | grep -vcE '(^-P|ufw-)')"
  INPUT_POLICY="$(${SUDO} iptables -S INPUT \
    | grep '^-P' \
    | awk '{print $3}')"
  FORWARD_POLICY="$(${SUDO} iptables -S FORWARD \
    | grep '^-P' \
    | awk '{print $3}')"

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    INPUT_RULES_COUNTv6="$(${SUDO} ip6tables -S INPUT \
      | grep -vcE '(^-P|ufw-)')"
    FORWARD_RULES_COUNTv6="$(${SUDO} ip6tables -S FORWARD \
      | grep -vcE '(^-P|ufw-)')"
    INPUT_POLICYv6="$(${SUDO} ip6tables -S INPUT \
      | grep '^-P' \
      | awk '{print $3}')"
    FORWARD_POLICYv6="$(${SUDO} ip6tables -S FORWARD \
      | grep '^-P' \
      | awk '{print $3}')"
  fi

  # If rules count is not zero, we assume we need to explicitly allow traffic.
  # Same conclusion if there are no rules and the policy is not ACCEPT.
  # Note that rules are being added to the top of the chain (using -I).

  if [[ "${INPUT_RULES_COUNT}" -ne 0 ]] \
    || [[ "${INPUT_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S \
      | grep -q "${VPN}-input-rule"; then
      ${SUDO} iptables \
        -I INPUT 1 \
        -i "${IPv4dev}" \
        -p "${pivpnPROTO}" \
        --dport "${pivpnPORT}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-input-rule"
    fi

    INPUT_CHAIN_EDITED=1
  else
    INPUT_CHAIN_EDITED=0
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${INPUT_RULES_COUNTv6}" -ne 0 ]] \
      || [[ "${INPUT_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S \
        | grep -q "${VPN}-input-rule"; then
        ${SUDO} ip6tables \
          -I INPUT 1 \
          -i "${IPv6dev}" \
          -p "${pivpnPROTO}" \
          --dport "${pivpnPORT}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-input-rule"
      fi

      INPUT_CHAIN_EDITEDv6=1
    else
      INPUT_CHAIN_EDITEDv6=0
    fi
  fi

  if [[ "${FORWARD_RULES_COUNT}" -ne 0 ]] \
    || [[ "${FORWARD_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S \
      | grep -q "${VPN}-forward-rule"; then
      ${SUDO} iptables \
        -I FORWARD 1 \
        -d "${pivpnNET}/${subnetClass}" \
        -i "${IPv4dev}" \
        -o "${pivpnDEV}" \
        -m conntrack \
        --ctstate RELATED,ESTABLISHED \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
      ${SUDO} iptables \
        -I FORWARD 2 \
        -s "${pivpnNET}/${subnetClass}" \
        -i "${pivpnDEV}" \
        -o "${IPv4dev}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
    fi

    FORWARD_CHAIN_EDITED=1
  else
    FORWARD_CHAIN_EDITED=0
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${FORWARD_RULES_COUNTv6}" -ne 0 ]] \
      || [[ "${FORWARD_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S \
        | grep -q "${VPN}-forward-rule"; then
        ${SUDO} ip6tables \
          -I FORWARD 1 \
          -d "${pivpnNETv6}/${subnetClassv6}" \
          -i "${IPv6dev}" \
          -o "${pivpnDEV}" \
          -m conntrack \
          --ctstate RELATED,ESTABLISHED \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"
        ${SUDO} ip6tables \
          -I FORWARD 2 \
          -s "${pivpnNETv6}/${subnetClassv6}" \
          -i "${pivpnDEV}" \
          -o "${IPv6dev}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"
      fi

      FORWARD_CHAIN_EDITEDv6=1
    else
      FORWARD_CHAIN_EDITEDv6=0
    fi
  fi

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      ${SUDO} iptables-save \
        | ${SUDO} tee /etc/iptables/rules.v4 > /dev/null
      ${SUDO} ip6tables-save \
        | ${SUDO} tee /etc/iptables/rules.v6 > /dev/null
      ;;
  esac

  {
    echo "INPUT_CHAIN_EDITED=${INPUT_CHAIN_EDITED}"
    echo "FORWARD_CHAIN_EDITED=${FORWARD_CHAIN_EDITED}"
    echo "INPUT_CHAIN_EDITEDv6=${INPUT_CHAIN_EDITEDv6}"
    echo "FORWARD_CHAIN_EDITEDv6=${FORWARD_CHAIN_EDITEDv6}"
  } >> "${tempsetupVarsFile}"
}

confLogging() {
  # Pre-create rsyslog/logrotate config directories if missing,
  # to assure logs are handled as expected when those are
  # installed at a later time
  ${SUDO} mkdir -p /etc/{rsyslog,logrotate}.d

  if [[ "${PLAT}" == 'Alpine' ]]; then
    program_name='openvpn'
  else
    program_name='ovpn-server'
  fi

  echo "if \$programname == '${program_name}' then /var/log/openvpn.log
if \$programname == '${program_name}' then stop" | ${SUDO} tee /etc/rsyslog.d/30-openvpn.conf > /dev/null

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
}" | ${SUDO} tee /etc/logrotate.d/openvpn > /dev/null

  # Restart the logging service
  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      ${SUDO} systemctl -q is-active rsyslog.service \
        && ${SUDO} systemctl restart rsyslog.service
      ;;
    Alpine)
      ${SUDO} rc-service -is rsyslog restart
      ${SUDO} rc-service -iN rsyslog start
      ;;
  esac
}

restartServices() {
  # Start services
  echo "::: Restarting services..."

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      if [[ "${VPN}" == "openvpn" ]]; then
        ${SUDO} systemctl enable openvpn.service &> /dev/null
        ${SUDO} systemctl restart openvpn.service
      elif [[ "${VPN}" == "wireguard" ]]; then
        ${SUDO} systemctl enable wg-quick@wg0.service &> /dev/null
        ${SUDO} systemctl restart wg-quick@wg0.service
      fi

      ;;
    Alpine)
      if [[ "${VPN}" == 'openvpn' ]]; then
        ${SUDO} rc-update add openvpn default &> /dev/null
        ${SUDO} rc-service -s openvpn restart
        ${SUDO} rc-service -N openvpn start
      elif [[ "${VPN}" == 'wireguard' ]]; then
        ${SUDO} rc-update add wg-quick default &> /dev/null
        ${SUDO} rc-service -s wg-quick restart
        ${SUDO} rc-service -N wg-quick start
      fi

      ;;
  esac
}

askUnattendedUpgrades() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${UNATTUPG}" ]]; then
      UNATTUPG=1
      echo "::: No preference regarding unattended upgrades, assuming yes"
    else
      if [[ "${UNATTUPG}" -eq 1 ]]; then
        echo "::: Enabling unattended upgrades"
      else
        echo "::: Skipping unattended upgrades"
      fi
    fi

    echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
    return
  fi

  whiptail \
    --msgbox \
    --backtitle "Security Updates" \
    --title "Unattended Upgrades" \
    "Since this server will have at least one port open to the internet, \
it is recommended you enable unattended-upgrades.
This feature will check daily for security package updates only and apply \
them when necessary.
It will NOT automatically reboot the server so to fully apply some updates \
you should periodically reboot." \
    "${r}" \
    "${c}"

  if whiptail \
    --backtitle "Security Updates" \
    --title "Unattended Upgrades" \
    --yesno \
    "Do you want to enable unattended upgrades \
of security patches to this server?" \
    "${r}" \
    "${c}"; then
    UNATTUPG=1
  else
    UNATTUPG=0
  fi

  echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
}

confUnattendedUpgrades() {
  local PIVPN_DEPS periodic_file

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    PIVPN_DEPS=(unattended-upgrades)
    installDependentPackages PIVPN_DEPS[@]
    aptConfDir="/etc/apt/apt.conf.d"

    # Raspbian's unattended-upgrades package downloads Debian's config,
    # so we copy over the proper config
    # https://github.com/mvo5/unattended-upgrades/blob/master/data/50unattended-upgrades.Raspbian
    # Add the remaining settings for all other distributions
    if [[ "${PLAT}" == "Raspbian" ]]; then
      ${SUDO} install -m 644 \
        "${pivpnFilesDir}/files${aptConfDir}/50unattended-upgrades.Raspbian" \
        "${aptConfDir}/50unattended-upgrades"
    fi

    if [[ "${PLAT}" == "Ubuntu" ]]; then
      periodic_file="${aptConfDir}/10periodic"
    else
      periodic_file="${aptConfDir}/02periodic"
    fi

    # Ubuntu 50unattended-upgrades should already just have security enabled
    # so we just need to configure the 10periodic file
    {
      echo "APT::Periodic::Update-Package-Lists \"1\";"
      echo "APT::Periodic::Download-Upgradeable-Packages \"1\";"
      echo "APT::Periodic::Unattended-Upgrade \"1\";"

      if [[ "${PLAT}" == "Ubuntu" ]]; then
        echo "APT::Periodic::AutocleanInterval \"5\";"
      else
        echo "APT::Periodic::Enable \"1\";"
        echo "APT::Periodic::AutocleanInterval \"7\";"
        echo "APT::Periodic::Verbose \"0\";"
      fi
    } | ${SUDO} tee "${periodic_file}" > /dev/null

    # Enable automatic updates via the bullseye repository
    # when installing from debian package
    if [[ "${VPN}" == "wireguard" ]]; then
      if [[ -f /etc/apt/sources.list.d/pivpn-bullseye-repo.list ]]; then
        if ! grep -q "\"o=${PLAT},n=bullseye\";" \
          "${aptConfDir}/50unattended-upgrades"; then
          local sed_pattern
          sed_pattern=" {/a\"o=${PLAT},n=bullseye\";"
          sed_pattern="${sed_pattern} {/a\"o=${PLAT},n=bullseye\";"
          ${SUDO} sed -i "${sed_pattern}" "${aptConfDir}/50unattended-upgrades"
        fi
      fi
    fi
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    local down_dir
    ## install dependencies
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} unzip asciidoctor

    if ! down_dir="$(mktemp -d)"; then
      err "::: Failed to create download directory for apk-autoupdate!"
      exit 1
    fi

    ## download binaries
    curl -fLo "${down_dir}/master.zip" \
      https://github.com/jirutka/apk-autoupdate/archive/refs/heads/master.zip
    unzip -qd "${down_dir}" "${down_dir}/master.zip"

    (
      cd "${down_dir}/apk-autoupdate-master" || exi

      ## personalize binaries
      sed -i -E -e 's/^(prefix\s*:=).*/\1 \/usr/' Makefile

      ## install
      ${SUDO} make install

      if ! command -v apk-autoupdate &> /dev/null; then
        err "::: Failed to compile and install apk-autoupdate!"
        exit
      fi
    ) || exit 1

    ${SUDO} install -m 0755 \
      "${pivpnFilesDir}/files/etc/apk/personal_autoupdate.conf" \
      /etc/apk/personal_autoupdate.conf
    ${SUDO} apk-autoupdate /etc/apk/personal_autoupdate.conf
  fi
}

writeConfigFiles() {
  # Save installation setting to the final location
  echo "INSTALLED_PACKAGES=(${INSTALLED_PACKAGES[*]})" >> "${tempsetupVarsFile}"
  echo "::: Setupfiles copied to ${setupConfigDir}/${VPN}/${setupVarsFile}"
  ${SUDO} mkdir -p "${setupConfigDir}/${VPN}/"
  ${SUDO} cp "${tempsetupVarsFile}" "${setupConfigDir}/${VPN}/${setupVarsFile}"
}

installScripts() {
  # Ensure /opt exists (issue #607)
  ${SUDO} mkdir -p /opt

  if [[ "${VPN}" == 'wireguard' ]]; then
    othervpn='openvpn'
  else
    othervpn='wireguard'
  fi

  # Symlink scripts from /usr/local/src/pivpn to their various locations
  echo -e "::: Installing scripts to ${pivpnScriptDir}..."

  # if the other protocol file exists it has been installed
  if [[ -r "${setupConfigDir}/${othervpn}/${setupVarsFile}" ]]; then
    # Both are installed, no bash completion, unlink if already there
    ${SUDO} unlink /etc/bash_completion.d/pivpn

    # Unlink the protocol specific pivpn script and symlink the common
    # script to the location instead
    ${SUDO} unlink /usr/local/bin/pivpn
    ${SUDO} ln -sfT "${pivpnFilesDir}/scripts/pivpn" /usr/local/bin/pivpn
  else
    # Check if bash_completion scripts dir exists and creates it if not
    ${SUDO} mkdir -p /etc/bash_completion.d

    # Only one protocol is installed, symlink bash completion, the pivpn script
    # and the script directory
    ${SUDO} ln -sfT \
      "${pivpnFilesDir}/scripts/${VPN}/bash-completion" \
      /etc/bash_completion.d/pivpn
    ${SUDO} ln -sfT \
      "${pivpnFilesDir}/scripts/${VPN}/pivpn.sh" \
      /usr/local/bin/pivpn
    ${SUDO} ln -sf "${pivpnFilesDir}/scripts/" "${pivpnScriptDir}"
    # shellcheck disable=SC1091
    . /etc/bash_completion.d/pivpn
  fi

  echo " done."
}

displayFinalMessage() {
  # Ensure that cached writes reach persistent storage
  echo "::: Flushing writes to disk..."

  sync

  echo "::: done."

  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: Installation Complete!"
    echo "::: Now run 'pivpn add' to create the client profiles."
    echo "::: Run 'pivpn help' to see what else you can do!"
    echo
    echo -n "::: If you run into any issue, please read all our documentation "
    echo "carefully."
    echo "::: All incomplete posts or bug reports will be ignored or deleted."
    echo
    echo "::: Thank you for using PiVPN."
    echo "::: It is strongly recommended you reboot after installation."
    return
  fi

  # Final completion message to user
  whiptail \
    --backtitle "Make it so." \
    --title "Installation Complete!" \
    --msgbox "Now run 'pivpn add' to create the client profiles.
Run 'pivpn help' to see what else you can do!

If you run into any issue, please read all our documentation carefully.
All incomplete posts or bug reports will be ignored or deleted.

Thank you for using PiVPN." "${r}" "${c}"

  if whiptail \
    --title "Reboot" \
    --defaultno \
    --yesno "It is strongly recommended you reboot after installation. \
Would you like to reboot now?" "${r}" "${c}"; then
    whiptail \
      --title "Rebooting" \
      --msgbox "The system will now reboot." "${r}" "${c}"
    printf "\\nRebooting system...\\n"
    ${SUDO} sleep 3

    ${SUDO} reboot
  fi
}

main "$@"
