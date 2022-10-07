#!/bin/bash
### Updates pivpn scripts (Not PiVPN)
# TODO: Delete this section when the updating functionality will be re-enabled
###
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

err "::: The updating functionality for PiVPN scripts is temporarily disabled"
err "::: To keep the VPN (and the system) up to date, use:"
err "        apt update; apt upgrade"
exit 0
### END SECTION ###

### Constants
pivpnrepo="https://github.com/pivpn/pivpn.git"
pivpnlocalpath="/etc/.pivpn"
pivpnscripts="/opt/pivpn/"
bashcompletiondir="/etc/bash_completion.d/"

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

chooseVPNCmd=(whiptail
  --backtitle "Setup PiVPN"
  --title "Installation mode"
  --separate-output
  --radiolist "Choose a VPN to update (press space to select):"
  "${r}" "${c}" 2)
VPNChooseOptions=(WireGuard "" on
  OpenVPN "" off)

if VPN="$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 > /dev/tty)"; then
  echo "::: Using VPN: ${VPN}"
  VPN="${VPN,,}"
else
  err "::: Cancel selected, exiting...."
  exit 1
fi

setupVars="/etc/pivpn/${VPN}/setupVars.conf"

# shellcheck disable=SC1090
source "${setupVars}"

### Functions
# TODO: Uncomment this function when the updating functionality
# will be re-enabled
#err() {
#  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
#}

scriptusage() {
  echo "::: Updates PiVPN scripts"
  echo ":::"
  echo "::: Usage: pivpn <-up|update> [-t|--test]"
  echo ":::"
  echo "::: Commands:"
  echo ":::  [none]              Updates from master branch"
  echo ":::  -t, test            Updates from test branch"
  echo ":::  -h, help            Show this usage dialog"
}

updatepivpnscripts() {
  local branch
  branch="${1}"
  ## We don't know what sort of changes users have made.
  ## Lets remove first /etc/.pivpn dir then clone it back again
  echo -n "Going do update PiVPN Scripts"

  if [[ -z "${branch}" ]]; then
    echo "from ${branch} branch"
  else
    echo
  fi

  if [[ -d "${pivpnlocalpath}" ]] \
    && [[ -n "${pivpnlocalpath}" ]]; then
    rm -rf "${pivpnlocalpath}/../.pivpn"
  fi

  cloneandupdate "${branch}"
  echo -n "PiVPN Scripts have been updated"

  if [[ -z "${branch}" ]]; then
    echo "from ${branch} branch"
  else
    echo
  fi
}

## Clone and copy pivpn scripts to /opt/pivpn
cloneandupdate() {
  local branch
  branch="${1}"
  git clone "${pivpnrepo}" "${pivpnlocalpath}"

  if [[ -z "${branch}" ]]; then
    git -C "${pivpnlocalpath}" checkout "${branch}"
    git -C "${pivpnlocalpath}" pull origin "${branch}"
  fi

  cp "${pivpnlocalpath}"/scripts/*.sh "${pivpnscripts}"
  cp "${pivpnlocalpath}"/scripts/"${VPN}"/*.sh "${pivpnscripts}"
  cp "${pivpnlocalpath}"/scripts/"${VPN}"/bash-completion "${bashcompletiondir}"

  if [[ -z "${branch}" ]]; then
    git -C "${pivpnlocalpath}" checkout master
  fi
}

## SCRIPT
if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

if [[ "$#" -eq 0 ]]; then
  updatepivpnscripts
else
  while true; do
    case "${1}" in
      -t | test)
        updatepivpnscripts 'test'
        exit 0
        ;;
      -h | help)
        scriptusage
        exit 0
        ;;
      *)
        updatepivpnscripts
        exit 0
        ;;
    esac
  done
fi
