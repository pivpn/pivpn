#!/bin/bash

if command -v systemctl > /dev/null; then
	systemctl status openvpn
elif command -v rc-service > /dev/null; then
	rc-service openvpn status
fi
pivpn add -n foo
pivpn -qr foo
pivpn -bk
pivpn -l
pivpn -c
pivpn -r foo -y
