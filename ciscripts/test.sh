#!/bin/bash

systemctl status openvpn-server@pivpn.service
pivpn add -n foo
pivpn -qr foo
pivpn -bk
pivpn -l
pivpn -c
pivpn -r foo -y
