# Information of Latest updates

This file has the objective of describing the major changes for each merge from test to master in a similar way as a
patch release notes.

Everytime Test branch is merged into master, a new entry should be created with the date and changes being merged.

## Jan 8th 2020

Updates and improvements
Issue #871: fix backup script

install.sh
  installScripts function:
    update script not being copied over to /opt therefore update funcion was probably broken.
    changed script to copy all .sh scripts from .pivpn/scripts directory.

Issue #871: fix backup script
  I was probably very drunk when i first wrote this backup script.
  fixed it, now works with new code refactoring,
  loads vars from setupVars
  Added backup for wireguard
  Moved script to global pivpnscripts.
  Added backup script to bash-completion
  Added backup script to pivpn script

update.sh
  Commented the update from master branch to avoid users trying to update test from master.


Updated LatestChages.md

## Jan 7th 2020

Changes for FR #897
Support For DHCP IP Reservation

Main:
  - added If statement to skipp SetStaticIPv4 if dhcpRserv=1

getStaticIPv4Settings:
  - Added Whiptail asking if user wants to use DHCP reservation Settings, this will add dhcpReserv and
    skip setStaticIPv4 while still logging everything.
ConfigExample files:
  - Added staticReserv=0 to config examples. so it can be used with Unattended install
    * 0 means static ip will be setup.
    * 1 means DHCP Reservation will be used and no chage will be made to the interfaces


Updated LatestChanges

## Jan 6th 2020

* Removed Unecessary pipe on availableInterfaces
* Changed OS Support messages accross the script
  - Removed OS Version names from the script, this avoids having to change the code everytime a new OS Version is Released, instead we update the wiki with propper information.
* Changed MaybeOSSupport whiptail tiltes and messages to make it more clear.
  - Messages and titles could cause confusion to users and specially developers
* Moved Funcions Comment to correct place.
* DistroCheck Function:
  - Moved up before other functions so it better refflects the order they are called.
  - changed Case identation to make it easier to read.
  - Added info to # compatibility Comment, Removed unecessary comments
  - added break to exit out of case, easier to understand that the script should move on.
* Added Shellcheck ignores,
* chooseinterface Function:
  - Changed function Logic and cleaned it up
  - Fixed Issue #906
  - Added exit code if no interfaces are found
* Updated LatestUpdate.md


## Oct 12th 2019

* Changed pivpn command exit codes from 1 to 0
  - exit code 1 means general error hence should not be used for exiting successfully
* added backup script to backup openvpn and pivpn generated certificates
* added update script to update /opt/pivpn scripts, -t | --test | test update from test branch
* Fixed hostname length issue #831
    - the script now checks for hostname length right at the beginning and prompts for a new one.
    - HOST_NAME to host_name, as best practice variables with capitals, should be used by system variables only.
* fixed ubuntu 18.04 being detected as not supported OS, now fully supported and tested.
* changed how scripts are copied to /opt/pivpn, it hat a lot of long repetitive lines, now it copies all `*.sh` files making it easier to manage when adding new scripts/features
* Changed how supported OS are presented when maybeOS_Support() is called.

## Sept 1st 2019

* Added support for Buster
* .ovpn12 files making use of iOS keychain
* Leverage the Hostname of the Server to generate server uuid
* integrated support to bitwarden password manager into pivpn
* Recreate ovpn folder if deleted
* Handle older UFW version from Jessie
* Only use iptables-legacy if platform is Buster
* improved Buester and Jessie IPtables / ufw handling
* bugfixes and typos
* permissions hardening and writing uniformization
* improved pivpn user and ovpns dirs handling
* Changes variable and file naming in `install.sh`
    -  $pivPNUser renamed to $INSTALL_USER
    -  /tmp/pivpnUSR renamed to INSTALL_USER

### Merge Patch, Sept 2nd 2019

* Bitwarden integration:
    - Bitwarden Installation removed from script, users that whish to use it should install it manually.
    - bugfixes with pivpn add
    - pivpn add -b will fail if bitwarden is not found

* File and dirs permissions:
    - fixed bug where ovpns being owned by root

* IOS integration
    - fixed bug where ovpn12 files not being properly generated

* General improvments:
    - when runing updates, sudo password prompt now shows up in a new line

----
