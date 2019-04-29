#!/usr/bin/env bash
# PiVPN: update crl script

helpFunc() {
    echo "::: Update the Certificate Revocation List"
    echo ":::"
    echo "::: Usage: pivpn <crl> [-h|--help]"
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Updates the certificate revocation list"
    echo ":::  -h,--help            Show this help dialog"
}

# Parse input arguments
while test $# -gt 0
do
    _key="$1"
    case "$_key" in
        -h|--help)
            helpFunc
            exit 0
            ;;
    esac
    shift
done

cd /etc/openvpn/easy-rsa || exit
./easyrsa gen-crl
cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
printf "::: Updated crl!\n"
