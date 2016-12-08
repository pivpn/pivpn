#!/usr/bin/env bash

# This scripts runs as root
echo ":: PiVPN Debug ::"
echo ":: Latest commit ::"
git --git-dir /etc/.pivpn/.git log -n 1
echo ":: Recursive list of files in /etc/openvpn/easy-rsa/pki ::"
ls -LR /etc/openvpn/easy-rsa/pki/ -Ireqs -Icerts_by_serial
echo ":: /etc/pivpn/* ::"
for filename in /etc/pivpn/*; do
    echo ":: START $filename ::"
    cat "$filename"
    echo ":: END $filename ::"
done
echo ":: /etc/openvpn/easy-rsa/pki/Default.txt ::"
cat /etc/openvpn/easy-rsa/pki/Default.txt
echo ":: done ::"
