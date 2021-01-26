#!/bin/bash

systemctl status openvpn
pivpn add -n foo
pivpn -qr foo
pivpn -bk
pivpn -l
pivpn -c
pivpn -r foo -y
