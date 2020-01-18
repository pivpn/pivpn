# Information of Latest updates

This file has the objective of describing the major changes for each merge from test to master in a similar way as a
patch release notes.

Everytime Test branch is merged into master, a new entry should be created with the date and changes being merged.

## Jan 18th 2020

Distro Support, Bug Fixes, Unattended install

Tested and added Support on Debian 9
tested and added support on Ubuntu 16.04 & 18.08
  * Fixed wireguard not installing, added pkg cache update after adding ppa
  * added kernel headers to dependencies as its requred for wireguard-dkms
unattended install
  * When user is provided and doest exist, it will create one without password set


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
* Use radiolist to select a VPN

## Jan 3rd 2020

- Revise route query for IP & GW selection from Quad9 to TEST-NET-1
- Replace mention of 'Google' with 'Quad9'

## Jan 2nd 2020

- Fix mv command when copying the DH parameters to final destination

## Dec 30th 2019

- Fix paths inside the update script
- Use the wireguard script for WireGuard as well
- Updated the README in accordance to changes in the test branch

## Dec 29th 2019

* Handle running the install script over an existing installation (as the script already did before branching to test-wireguard), providing:
    - Update, downloads latest scripts from git repo
    - Repair, reinstall PiVPN while keeping existing settings
    - Reconfigure, start over overwriting the existing settings
* Tag iptables rules as an attempt to make sure that the uninstall script only removes PiVPN rules
* Change the armv6l installation to reflect the split of WireGuard snapshots into wireguard-linux-compat and wireguard-tools

## Dec 27th 2019

 - When suggesting to use Pi-hole, use the VPN server IP instead of the LAN IP to allow DNS resolution even if the user does not route the local network through the tunnel.
- Format listCONF in a similar way as listOVPN
- Specifically look for a free octet in the last word of clients.txt and not just any word.
  Necessary otherwhise public keys starting with a number will match against an octet.
  Example: if line is 'name 5abcdefgh 4', then looking for ' 5' will match but '5$' will
  not (correctly).
- 'pivpn -c' will show the Connected Clients List for WireGuard too

## Dec 10th 2019

- Use dedicated openvpn user and group for increased security
- Added basic safeguards to avoid wrecking /etc/ufw/before.rules
- Applied some Shellcheck suggested changes.
- Added safeguards to rm -rf when downloading the git repo.
- Use more variables instead of hardcoding data
- Add local resolver as DNS option

## Dec 3rd 2019

- Better client stats formatting

## Dec 2nd 2019

* Properly avoid pulling unwanted packages from unstable repo:
  - Currently apt pulls all packages from the unstable repo because the script intendation created the file 'limit-unstable' with tabs in it. Fixed using printf to create a multiline file.
- Accept debug fixes using just the enter key

## Nov 19th 2019

- Added Ubuntu Bionic support

## Nov 16th 2019

- Added back unattended installation: as expected, the user can call the install script with --unattended followed by a config file and PiVPN will be installed non-interactively.
- Removed persist-key and persist-tun from the client config.
- Reverted keepalive setting on the server to smaller values.
- See @TinCanTech's posts for the reasons of the above two: #864 (comment)
- Copied validDomain() function from the test branch.
- Removed 1024 bit certificate options, since on Buster OpenVPN does not start with such small certificates (It's related to OpenSSL 1.1.1).
- Backup /etc/openvpn and /etc/wireguard before installing.
- Always remove VPN configuration when uninstalling, but do not wipe the folder, just remove what PiVPN added.
- Fetch latest WireGuard snapshot instead of hardcoding it into the script.

## Nov 7th 2019

- Add back the uninstall script
- Only uninstall packages that were not already installed when running the PiVPN install script.
- Detect and offer to use Pi-hole
- Use checkinstall to install wireguard-tools for easy uninstallation
- Added missing dkms dependency

## Oct 19th 2019

- MakeOVPN has been updated to include the -i iOS function to allow users to create an OVPN12 format file that can be used with the iOS keychain.
- Check if -i iOS can be used (can't be used with ECDSA certificates).
- Fixed the issues with special characters in OVPN12 files.

## Oct 17th 2019

- Allow subdomain in custom DNS search list.
- Unified PiVPN configuration into the single /etc/pivpn/setupVars.conf file.
- Functions that ask the user for the port, protocol, dns, domain don't apply the setting anymore, they only save the variable on disk. Settings are applied in confOpenVPN, confOVPN, confWireGuard.
- Support and use WireGuard by default with an initial set of scripts matching current PiVPN scripts (list, create, remove clients).
- Removed OpenVPN ECDSA option.
- Renamed some variables (see pull request 849).
- Refactored several functions.

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
