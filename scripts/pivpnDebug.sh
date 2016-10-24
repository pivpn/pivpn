#!/usr/bin/env bash

# This scripts runs as root
echo ":: PiVPN Debug ::"
echo ":: Latest commit ::"
git --git-dir /etc/.pivpn/.git log -n 1
echo ":: list of files in /etc/openvpn/easy-rsa/keys ::"
ls /etc/openvpn/easy-rsa/keys/
echo ":: /etc/pivpn/* ::"
for filename in /etc/pivpn/*; do
    echo ":: START $filename ::"
    cat "$filename"
    echo ":: END $filename ::"
done
echo ":: /etc/openvpn/easy-rsa/keys/Default.txt ::"
cat /etc/openvpn/easy-rsa/keys/Default.txt
echo ":: done ::"
