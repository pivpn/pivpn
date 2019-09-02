# Information of Latest updates

This file has the objective of describing the major changes for each merge from test to master in a similar way as a
patch release notes. 

Everytime Test branch is merged into master, a new entry should be created with the date and changes being merged. 

## Sept 1st 2019

Latest changes merged from test branch

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
