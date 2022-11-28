#!/bin/bash
# Create OVPN Client

### Constants
setupVars="/etc/pivpn/openvpn/setupVars.conf"
DEFAULT="Default.txt"
FILEEXT=".ovpn"
CRT=".crt"
KEY=".key"
CA="ca.crt"
TA="ta.key"
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"

# shellcheck disable=SC1090
source "${setupVars}"


# shellcheck disable=SC2154
userGroup="${install_user}:${install_user}"

## Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Create a client ovpn profile, optional nopass"
  echo ":::"
  echo -n "::: Usage: pivpn <-a|add> [-n|--name <arg>] "
  echo -n "[-p|--password <arg>]|[nopass] [-d|--days <number>] "
  echo "[-b|--bitwarden] [-i|--iOS] [-o|--ovpn] [-h|--help]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]               Interactive mode"
  echo ":::  nopass               Create a client without a password"
  echo -n ":::  -n,--name            Name for the Client "
  echo "(default: \"$(hostname)\")"
  echo ":::  -p,--password        Password for the Client (no default)"
  echo -n ":::  -d,--days            Expire the certificate after specified "
  echo "number of days (default: 1080)"
  echo ":::  -b,--bitwarden       Create and save a client through Bitwarden"
  echo -n ":::  -i,--iOS             Generate a certificate that leverages iOS "
  echo "keychain"
  echo -n ":::  -o,--ovpn            Regenerate a .ovpn config file for an "
  echo "existing client"
  echo ":::  -h,--help            Show this help dialog"
}

checkName() {
  # check name
  if [[ "${NAME}" =~ [^a-zA-Z0-9.@_-] ]]; then
    err "Name can only contain alphanumeric characters and these symbols (.-@_)."
    exit 1
  elif [[ "${NAME}" =~ ^[0-9]+$ ]]; then
    err "Names cannot be integers."
    exit 1
  elif [[ "${NAME}" =~ \ |\' ]]; then
    err "Names cannot contain spaces."
    exit 1
  elif [[ "${NAME:0:1}" == "-" ]]; then
    err "Name cannot start with - (dash)"
    exit 1
  elif [[ "${NAME::1}" == "." ]]; then
    err "Names cannot start with a . (dot)."
    exit 1
  elif [[ -z "${NAME}" ]]; then
    err "::: You cannot leave the name blank."
    exit 1
  fi
}

keynoPASS() {
  # Build the client key
  export EASYRSA_CERT_EXPIRE="${DAYS}"
  ./easyrsa build-client-full "${NAME}" nopass
  cd pki || exit
}

useBitwarden() {
  # login and unlock vault
  printf "****Bitwarden Login****"
  printf "\n"

  SESSION_KEY="$(bw login --raw)"
  export BW_SESSION="${SESSION_KEY}"

  printf "Successfully Logged in!"
  printf "\n"

  # ask user for username
  printf "Enter the username:  "
  read -r NAME

  #check name
  checkName

  # ask user for length of password
  printf "Please enter the length of characters you want your password to be "
  printf "(minimum 12): "
  read -r LENGTH

  # check length
  until [[ "${LENGTH}" -gt 11 ]] && [[ "${LENGTH}" -lt 129 ]]; do
    echo "Password must be between from 12 to 128 characters, please try again."
    # ask user for length of password
    printf "Please enter the length of characters you want your password to be "
    printf "(minimum 12): "
    read -r LENGTH
  done

  printf "Creating a PiVPN item for your vault..."
  printf "\n"

  # create a new item for your PiVPN Password
  PASSWD="$(bw generate -usln --length "${LENGTH}")"
  bw get template item \
    | jq '.login.type = "1"' \
    | jq '.name = "PiVPN"' \
    | jq -r --arg NAME "${NAME}" '.login.username = $NAME' \
    | jq -r --arg PASSWD "${PASSWD}" '.login.password = $PASSWD' \
    | bw encode \
    | bw create item
  bw logout
}

keyPASS() {
  if [[ -z "${PASSWD}" ]]; then
    stty -echo

    while true; do
      printf "Enter the password for the client:  "
      read -r PASSWD
      printf "\n"
      printf "Enter the password again to verify:  "
      read -r PASSWD2
      printf "\n"

      [[ "${PASSWD}" == "${PASSWD2}" ]] && break

      printf "Passwords do not match! Please try again.\n"
    done

    stty echo

    if [[ -z "${PASSWD}" ]]; then
      err "You left the password blank"
      err "If you don't want a password, please run:"
      err "pivpn add nopass"
      exit 1
    fi
  fi

  if [[ "${#PASSWD}" -lt 4 ]] || [[ "${#PASSWD}" -gt 1024 ]]; then
    err "Password must be between from 4 to 1024 characters"
    exit 1
  fi

  export EASYRSA_CERT_EXPIRE="${DAYS}"
  ./easyrsa --passin=pass:"${PASSWD}" \
    --passout=pass:"${PASSWD}" \
    build-client-full "${NAME}"

  cd pki || exit
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

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

if [[ -z "${HELP_SHOWN}" ]]; then
  helpFunc
  echo
  echo "HELP_SHOWN=1" >> "${setupVars}"
fi

# Parse input arguments
while [[ "$#" -gt 0 ]]; do
  _key="${1}"

  case "${_key}" in
    -n | --name | --name=*)
      _val="${_key##--name=}"

      if [[ "${_val}" == "${_key}" ]]; then
        [[ "$#" -lt 2 ]] \
          && err "Missing value for the optional argument '${_key}'." \
          && exit 1

        _val="${2}"
        shift
      fi

      NAME="${_val}"
      checkName
      ;;
    -p | --password | --password=*)
      _val="${_key##--password=}"

      if [[ "${_val}" == "${_key}" ]]; then
        [[ "$#" -lt 2 ]] \
          && err "Missing value for the optional argument '${_key}'." \
          && exit 1

        _val="${2}"
        shift
      fi

      PASSWD="${_val}"
      ;;
    -d | --days | --days=*)
      _val="${_key##--days=}"

      if [[ "${_val}" == "${_key}" ]]; then
        [[ "$#" -lt 2 ]] \
          && err "Missing value for the optional argument '${_key}'." \
          && exit 1

        _val="${2}"
        shift
      fi

      DAYS="${_val}"
      ;;
    -i | --iOS)
      if [[ "${TWO_POINT_FOUR}" -ne 1 ]]; then
        iOS=1
      else
        err "Sorry, can't generate iOS-specific configs for ECDSA certificates"
        err "Generate traditional certificates using 'pivpn -a' or reinstall PiVPN without opting in for OpenVPN 2.4 features"
        exit 1
      fi
      ;;
    -h | --help)
      helpFunc
      exit 0
      ;;
    nopass)
      NO_PASS="1"
      ;;
    -b | --bitwarden)
      if command -v bw > /dev/null; then
        BITWARDEN="2"
      else
        echo 'Bitwarden not found, please install bitwarden'

        if [[ "${PLAT}" == 'Alpine' ]]; then
          echo 'You can download it through the following commands:'
          echo -n $'\t''curl -fLo bitwarden.zip --no-cache https://github.com/'
          echo -n 'bitwarden/clients/releases/download/cli-v2022.6.2/'
          echo 'bw-linux-2022.6.2.zip'
          echo $'\t''apk --no-cache unzip'
          echo $'\t''unzip bitwarden.zip'
          echo $'\t''mv bw /opt/bw'
          echo $'\t''chmod 755 /opt/bw'
          echo $'\t''rm bitwarden.zip'
          echo $'\t''apk --no-cache --purge del -r unzip'
        fi

        exit 1
      fi

      ;;
    -o | --ovpn)
      GENOVPNONLY=1
      ;;
    *)
      err "Error: Got an unexpected argument '${1}'"
      helpFunc
      exit 1
      ;;
  esac

  shift
done

#make sure ovpns dir exists
# Disabling warning for SC2154, var sourced externaly
# shellcheck disable=SC2154
if [[ ! -d "${install_home}/ovpns" ]]; then
  mkdir "${install_home}/ovpns"
  chown "${userGroup}" "${install_home}/ovpns"
  chmod 0750 "${install_home}/ovpns"
fi

#bitWarden
if [[ "${BITWARDEN}" =~ "2" ]]; then
  useBitwarden
fi

if [[ -z "${NAME}" ]]; then
  printf "Enter a Name for the Client:  "
  read -r NAME
  checkName
else
  checkName
fi

if [[ "${GENOVPNONLY}" == 1 ]]; then
  # Generate .ovpn configuration file
  cd /etc/openvpn/easy-rsa/pki || exit
else
  # Check if name is already in use
  while read -r line || [[ -n "${line}" ]]; do
    STATUS=$(echo "${line}" | awk '{print $1}')

    if [[ "${STATUS}" == "V" ]]; then
      # Disabling SC2001 as ${variable//search/replace}
      # doesn't go well with regexp
      # shellcheck disable=SC2001
      CERT="$(echo "${line}" | sed -e 's:.*/CN=::')"

      if [[ "${CERT}" == "${NAME}" ]]; then
        INUSE="1"
        break
      fi
    fi
  done < "${INDEX}"

  if [[ "${INUSE}" == 1 ]]; then
    err "!! This name is already in use by a Valid Certificate."
    err "Please choose another name or revoke this certificate first."
    exit 1
  # Check if name is reserved
  elif [[ "${NAME}" == "ta" ]] \
    || [[ "${NAME}" == "server" ]] \
    || [[ "${NAME}" == "ca" ]]; then
    err "Sorry, this is in use by the server and cannot be used by clients."
    exit 1
  fi

  # As of EasyRSA 3.0.6, by default certificates last 1080 days,
  # see https://github.com/OpenVPN/easy-rsa/blob/6b7b6bf1f0d3c9362b5618ad18c66677351cacd1/easyrsa3/vars.example
  if [[ -z "${DAYS}" ]]; then
    read -r -e -p "How many days should the certificate last?  " -i 1080 DAYS
  fi

  if [[ ! "${DAYS}" =~ ^[0-9]+$ ]] \
    || [[ "${DAYS}" -lt 1 ]] \
    || [[ "${DAYS}" -gt 3650 ]]; then
    # The CRL lasts 3650 days so it doesn't make much sense
    # that certificates would last longer
    err "Please input a valid number of days, between 1 and 3650 inclusive."
    exit 1
  fi

  cd /etc/openvpn/easy-rsa || exit

  if [[ "${NO_PASS}" =~ "1" ]]; then
    if [[ -n "${PASSWD}" ]]; then
      err "Both nopass and password arguments passed to the script. Please use either one."
      exit 1
    else
      keynoPASS
    fi
  else
    keyPASS
  fi
fi

#1st Verify that clients Public Key Exists
if [[ ! -f "issued/${NAME}${CRT}" ]]; then
  err "[ERROR]: Client Public Key Certificate not found: ${NAME}${CRT}"
  exit
fi

echo "Client's cert found: ${NAME}${CRT}"

#Then, verify that there is a private key for that client
if [[ ! -f "private/${NAME}${KEY}" ]]; then
  err "[ERROR]: Client Private Key not found: ${NAME}${KEY}"
  exit
fi

echo "Client's Private Key found: ${NAME}${KEY}"

#Confirm the CA public key exists
if [[ ! -f "${CA}" ]]; then
  err "[ERROR]: CA Public Key not found: ${CA}"
  exit
fi

echo "CA public Key found: ${CA}"

#Confirm the tls key file exists
if [[ ! -f "${TA}" ]]; then
  err "[ERROR]: tls Private Key not found: ${TA}"
  exit
fi

echo "tls Private Key found: ${TA}"

## Added new step to create an .ovpn12 file that can be stored on iOS keychain
## This step is more secure method and does not require the end-user to keep
## entering passwords, or storing the client private cert where it can be easily
## tampered
## https://openvpn.net/faq/how-do-i-use-a-client-certificate-and-private-key-from-the-ios-keychain/

# Generates the .ovpn file WITHOUT the client private key
{
  # Start by populating with the default file
  cat "${DEFAULT}"

  # Now, append the CA Public Cert
  echo "<ca>"
  cat "${CA}"
  echo "</ca>"

  # Next append the client Public Cert
  echo "<cert>"
  sed -n \
    -e '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' \
    < "issued/${NAME}${CRT}"
  echo "</cert>"

  if [[ "${iOS}" != 1 ]]; then
    # Then, append the client Private Key
    echo "<key>"
    cat "private/${NAME}${KEY}"
    echo "</key>"
  fi

  # Finally, append the tls Private Key
  if [[ "${iOS}" != 1 ]] && [[ "${TWO_POINT_FOUR}" -eq 1 ]]; then
    echo "<tls-crypt>"
    cat "${TA}"
    echo "</tls-crypt>"
  else
    echo "<tls-auth>"
    cat "${TA}"
    echo "</tls-auth>"
  fi
} > "${NAME}${FILEEXT}"

if [[ "${iOS}" == 1 ]]; then
  # Copy the .ovpn profile to the home directory for convenient remote access
  printf "========================================================\n"
  printf "Generating an .ovpn12 file for use with iOS devices\n"
  printf "Please remember the export password\n"
  printf "as you will need this import the certificate on your iOS device\n"
  printf "========================================================\n"

  openssl pkcs12 \
    -passin pass:"${PASSWD_UNESCAPED}" \
    -export \
    -in "issued/${NAME}${CRT}" \
    -inkey "private/${NAME}${KEY}" \
    -certfile "${CA}" \
    -name "${NAME}" \
    -out "${install_home}/ovpns/${NAME}.ovpn12"

  chown "${userGroup}" "${install_home}/ovpns/${NAME}.ovpn12"
  chmod 640 "${install_home}/ovpns/${NAME}.ovpn12"

  printf "========================================================\n"
  printf "\e[1mDone! %s successfully created!\e[0m \n" "${NAME}.ovpn12"
  printf "You will need to transfer both the .ovpn and .ovpn12 files\n"
  printf "to your iOS device.\n"
  printf "========================================================\n\n"
fi

#disabling SC2514, variable sourced externaly
# shellcheck disable=SC2154
NET_REDUCED="${pivpnNET::-2}"

# Find an unused number for the last octet of the client IP
for i in {2..254}; do
  # find returns 0 if the folder is empty, so we create the 'ls -A [...]'
  # exception to stop at the first static IP (10.8.0.2). Otherwise it would
  # cycle to the end without finding and available octet.
  # disabling SC2514, variable sourced externaly
  # shellcheck disable=SC2154
  if [[ -z "$(ls -A /etc/openvpn/ccd)" ]] \
    || ! find /etc/openvpn/ccd -type f \
      -exec grep -q "${NET_REDUCED}.${i}" {} +; then
    COUNT="${i}"
    echo -n "ifconfig-push ${NET_REDUCED}.${i} " >> /etc/openvpn/ccd/"${NAME}"
    # The space after ${i} is important ------^!
    cidrToMask "${subnetClass}" >> /etc/openvpn/ccd/"${NAME}"
    # the end resuld should be a line like:
    # ifconfig-push ${NET_REDUCED}.${i} ${subnetClass}
    # ifconfig-push 10.205.45.8 255.255.255.0
    break
  fi
done

if [[ -f /etc/pivpn/hosts.openvpn ]]; then
  echo "${NET_REDUCED}.${COUNT} ${NAME}.pivpn" >> /etc/pivpn/hosts.openvpn

  if killall -SIGHUP pihole-FTL; then
    echo "::: Updated hosts file for Pi-hole"
  else
    err "::: Failed to reload pihole-FTL configuration"
  fi
fi

# Copy the .ovpn profile to the home directory for convenient remote access
dest_path="${install_home}/ovpns/${NAME}${FILEEXT}"
cp "/etc/openvpn/easy-rsa/pki/${NAME}${FILEEXT}" "${dest_path}"
chown "${install_user}:${install_user}" "${dest_path}"
chmod 640 "/etc/openvpn/easy-rsa/pki/${NAME}${FILEEXT}"
chmod 640 "${dest_path}"
unset dest_path

printf "\n\n"
printf "========================================================\n"
printf "\e[1mDone! %s successfully created!\e[0m \n" "${NAME}${FILEEXT}"
printf "%s was copied to:\n" "${NAME}${FILEEXT}"
printf "  %s/ovpns\n" "${install_home}"
printf "for easy transfer. Please use this profile only on one\n"
printf "device and create additional profiles for other devices.\n"
printf "========================================================\n\n"
