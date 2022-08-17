#!/bin/bash -e

# Tests multiple pivpn commands

testopenvpn() {
  if command -v systemctl > /dev/null; then
    systemctl status openvpn
  elif command -v rc-service > /dev/null; then
    rc-service openvpn status
  fi

  pivpn add -n foo nopass -d 180
  pivpn add -p "$RANDOM$RANDOM" -n bar -d 180
  pivpn add -o -n foo
  pivpn -bk
  sudo ls ~pi/pivpnbackup/ | grep backup
  pivpn -l
  pivpn -c
  pivpn -r foo -y
  exit 0
}

testwireguard() {
  if command -v systemctl > /dev/null; then
    systemctl status wg-quick@wg0
  elif command -v rc-service > /dev/null; then
    rc-service wg-quick status
  fi

  pivpn add -n foo
  pivpn -qr foo
  pivpn -bk
  sudo ls ~pi/pivpnbackup/ | grep backup
  pivpn -l
  pivpn -c
  pivpn -r foo -y
  exit 0
}

while true; do
  case "${1}" in
    -o | --openvpn)
      testopenvpn
      ;;
    -w | --wireguard)
      testwireguard
      ;;
    *)
      err "unknown VPN protocol"
      exit 1
      ;;
  esac
done
