#!/bin/bash

command -v systemctl > /dev/null && \
	systemctl status openvpn
command -v rc-service > /dev/null && \
	rc-service openvpn status

pivpn add -n foo
pivpn -qr foo
pivpn -bk
pivpn -l
pivpn -c
pivpn -r foo -y
