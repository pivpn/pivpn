# Information of Latest updates

This file has the objective of describing the major changes for each merge from test to master in a similar way as a
patch release notes. 

Everytime Test branch is merged into master, a new entry should be created with the date and changes being merged. 

## Sept 1st 2019

changes Merged into master branch with last merge from master.

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

----
