#!/bin/bash

###Updates pivpn scripts (Not PiVPN)
###Main Vars
pivpnrepo="https://github.com/pivpn/pivpn.git"
pivpnlocalpath="/etc/.pivpn"
pivpnscripts="/opt/pivpn/"
bashcompletiondir="/etc/bash_completion.d/"

# Find the rows and columns. Will default to 80x24 if it can not be detected.
screen_size=$(stty size 2>/dev/null || echo 24 80)
rows=$(echo "$screen_size" | awk '{print $1}')
columns=$(echo "$screen_size" | awk '{print $2}')

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

                       chooseVPNCmd=(whiptail --backtitle "Setup PiVPN" --title "Installation mode" --separate-output --radiolist "Choose a VPN to update (press space to select):" "${r}" "${c}" 2)
                        VPNChooseOptions=(WireGuard "" on
                                                                OpenVPN "" off)

                        if VPN=$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 >/dev/tty) ; then
                                echo "::: Using VPN: $VPN"
                                VPN="${VPN,,}"
                        else
                                echo "::: Cancel selected, exiting...."
                                exit 1
                        fi

setupVars="/etc/pivpn/${VPN}/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

scriptusage(){
    echo "::: Updates PiVPN scripts"
    echo ":::"
    echo "::: Usage: pivpn <-up|update> [-t|--test]"
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]              Updates from master branch"
    echo ":::  -t, test            Updates from test branch"
    echo ":::  -h, help            Show this usage dialog"
}

###Functions
##Updates scripts
updatepivpnscripts(){
    ##We don't know what sort of changes users have made.
    ##Lets remove first /etc/.pivpn dir then clone it back again
    echo "going do update PiVPN Scripts"
    if [[ -d "$pivpnlocalpath" ]]; then
      if [[ -n "$pivpnlocalpath" ]]; then
        rm -rf "${pivpnlocalpath}/../.pivpn"
        cloneandupdate
			fi
    else
      cloneandupdate
    fi
    echo "PiVPN Scripts have been updated"
}

##Updates scripts using test branch
updatefromtest(){
    ##We don't know what sort of changes users have made.
    ##Lets remove first /etc/.pivpn dir then clone it back again
    echo "PiVPN Scripts updating from test branch"
    if [[ -d "$pivpnlocalpath" ]]; then
      if [[ -n "$pivpnlocalpath" ]]; then
        rm -rf "${pivpnlocalpath}/../.pivpn"
        cloneupdttest
      fi
    else
      cloneupdttest
    fi
    echo "PiVPN Scripts updated have been updated from test branch"
  }

##Clone and copy pivpn scripts to /opt/pivpn
cloneandupdate(){
  git clone "$pivpnrepo" "$pivpnlocalpath"
  cp "${pivpnlocalpath}"/scripts/*.sh "$pivpnscripts"
  cp "${pivpnlocalpath}"/scripts/$VPN/*.sh "$pivpnscripts"
  cp "${pivpnlocalpath}"/scripts/$VPN/bash-completion "$bashcompletiondir"
}

##same as cloneandupdate() but from test branch
##and falls back to master branch again after updating
cloneupdttest(){
  git clone "$pivpnrepo" "$pivpnlocalpath"
  git -C "$pivpnlocalpath" checkout test
  git -C "$pivpnlocalpath" pull origin test
  cp "${pivpnlocalpath}"/scripts/*.sh "$pivpnscripts"
  cp "${pivpnlocalpath}"/scripts/$VPN/*.sh "$pivpnscripts"
  cp "${pivpnlocalpath}"/scripts/$VPN/bash-completion "$bashcompletiondir"
  git -C "$pivpnlocalpath" checkout master
}

## SCRIPT

if [[ $# -eq 0 ]]; then
    updatepivpnscripts
else
  while true; do
    case "$1" in
      -t|test)
          updatefromtest
          exit 0
          ;;
      -h|help)
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
