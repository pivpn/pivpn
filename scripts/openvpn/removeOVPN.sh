#!/bin/bash
# PiVPN: revoke client script

### Constants
setupVars="/etc/pivpn/openvpn/setupVars.conf"
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"

# shellcheck disable=SC1090
source "${setupVars}"

if [ ! -r /opt/pivpn/ipaddr_utils.sh ]; then
  exit 1
fi
# shellcheck disable=SC1091
source /opt/pivpn/ipaddr_utils.sh

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Revoke a client ovpn profile"
  echo ":::"
  echo -n "::: Usage: pivpn <-r|revoke> [-y|--yes] [-h|--help] "
  echo "[<client-1> ... [<client-2>] ...]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]               Interactive mode"
  echo ":::  <client>             Client(s) to to revoke"
  echo ":::  -y,--yes             Remove Client(s) without confirmation"
  echo ":::  -h,--help            Show this help dialog"
}

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

# Parse input arguments
while [[ "$#" -gt 0 ]]; do
  _key="${1}"

  case "${_key}" in
    -h | --help)
      helpFunc
      exit 0
      ;;
    -y | --yes)
      CONFIRM=true
      ;;
    *)
      CERTS_TO_REVOKE+=("${1}")
      ;;
  esac

  shift
done

if [[ ! -f "${INDEX}" ]]; then
  err "The file: ${INDEX} was not found"
  exit 1
fi

# Disabling SC2128, just checking if variable is empty or not
# shellcheck disable=SC2128
if [[ -z "${CERTS_TO_REVOKE}" ]]; then
  printf "\n"
  printf " ::\e[4m  Certificate List  \e[0m:: \n"

  i=0
  while read -r line || [[ -n "${line}" ]]; do
    STATUS=$(echo "${line}" | awk '{print $1}')

    if [[ "${STATUS}" == "V" ]]; then
      # Disabling SC2001 warning, suggested method doesn't work with regexp
      # shellcheck disable=SC2001
      NAME=$(echo "${line}" | sed -e 's:.*/CN=::')

      if [[ "${i}" != 0 ]]; then
        # Prevent printing "server" certificate
        CERTS["${i}"]=$(echo -e "${NAME}")
      fi

      ((i++))
    fi
  done < "${INDEX}"

  i=1
  len="${#CERTS[@]}"
  while [[ "${i}" -le "${len}" ]]; do
    printf "%0${#len}s) %s\r\n" "${i}" "${CERTS[(($i))]}"
    ((i++))
  done

  printf "\n"
  echo -n "::: Please enter the Index/Name of the client to be revoked "
  echo -n "from the list above: "
  read -r NAME

  if [[ -z "${NAME}" ]]; then
    err "You can not leave this blank!"
    exit 1
  fi

  re='^[0-9]+$'
  if [[ "${NAME}" =~ $re ]]; then
    NAME="${CERTS[$((NAME))]}"
  fi

  for ((x = 1; x <= i; ++x)); do
    if [[ "${CERTS[$x]}" == "${NAME}" ]]; then
      VALID=1
    fi
  done

  if [[ -z "${VALID}" ]]; then
    err "You didn't enter a valid cert name!"
    exit 1
  fi

  CERTS_TO_REVOKE=("${NAME}")
else
  i=0
  while read -r line || [[ -n "${line}" ]]; do
    STATUS=$(echo "${line}" | awk '{print $1}')

    if [[ "${STATUS}" == "V" ]]; then
      NAME=$(echo -e "${line}" | sed -e 's:.*/CN=::')
      CERTS["${i}"]="${NAME}"
      ((i++))
    fi
  done < "${INDEX}"

  for ((ii = 0; ii < ${#CERTS_TO_REVOKE[@]}; ii++)); do
    VALID=0

    for ((x = 1; x <= i; ++x)); do
      if [[ "${CERTS[$x]}" == "${CERTS_TO_REVOKE[ii]}" ]]; then
        VALID=1
      fi
    done

    if [[ "${VALID}" != 1 ]]; then
      err "You passed an invalid cert name: '${CERTS_TO_REVOKE[ii]}'!"
      exit 1
    fi
  done
fi

cd /etc/openvpn/easy-rsa || exit

for ((ii = 0; ii < ${#CERTS_TO_REVOKE[@]}; ii++)); do
  if [[ -n "${CONFIRM}" ]]; then
    REPLY="y"
  else
    read -r -p "Do you really want to revoke '${CERTS_TO_REVOKE[ii]}'? [y/N] "
  fi

  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    printf "\n::: Revoking certificate '%s'. \n" "${CERTS_TO_REVOKE[ii]}"

    ./easyrsa --batch revoke "${CERTS_TO_REVOKE[ii]}"
    ./easyrsa gen-crl

    printf "\n::: Certificate revoked, and CRL file updated.\n"
    printf "::: Removing certs and client configuration for this profile.\n"

    rm -rf "pki/reqs/${CERTS_TO_REVOKE[ii]}.req"
    rm -rf "pki/private/${CERTS_TO_REVOKE[ii]}.key"
    rm -rf "pki/issued/${CERTS_TO_REVOKE[ii]}.crt"

    # Disabling SC2154 $pivpnNET sourced externally
    # shellcheck disable=SC2154
    # Grab the client IP address
    STATIC_IP="$(grep -v "^#" /etc/openvpn/ccd/"${CERTS_TO_REVOKE[ii]}" \
      | grep -w ifconfig-push | awk '{print $2}')"
    rm -rf /etc/openvpn/ccd/"${CERTS_TO_REVOKE[ii]}"

    # disablung warning SC2154, $install_home sourced externally
    # shellcheck disable=SC2154
    rm -rf "${install_home}/ovpns/${CERTS_TO_REVOKE[ii]}.ovpn"
    rm -rf "/etc/openvpn/easy-rsa/pki/${CERTS_TO_REVOKE[ii]}.ovpn"
    cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem

    # If using Pi-hole, remove the client from the hosts file
    if [[ -f /etc/pivpn/hosts.openvpn ]]; then
      sed \
        -e "\#${STATIC_IP} ${CERTS_TO_REVOKE[ii]}.pivpn#d" \
        -i /etc/pivpn/hosts.openvpn

      if killall -SIGHUP pihole-FTL; then
        echo "::: Updated hosts file for Pi-hole"
      else
        err "::: Failed to reload pihole-FTL configuration"
      fi
    fi
  fi
done

printf "::: Completed!\n"
