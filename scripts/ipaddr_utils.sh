#!/usr/bin/env bash

decIPv4ToDot() {
  local a b c d
  a=$((($1 & 4278190080) >> 24))
  b=$((($1 & 16711680) >> 16))
  c=$((($1 & 65280) >> 8))
  d=$(($1 & 255))
  printf "%s.%s.%s.%s\n" $a $b $c $d
}

dotIPv4ToDec() {
  local original_ifs=$IFS
  IFS='.'
  read -r -a array_ip <<< "$1"
  IFS=$original_ifs
  printf "%s\n" $((array_ip[0] * 16777216 + array_ip[1] * 65536 + array_ip[2] * 256 + array_ip[3]))
}

dotIPv4FirstDec() {
  local decimal_ip decimal_mask
  decimal_ip=$(dotIPv4ToDec "$1")
  decimal_mask=$((2 ** 32 - 1 ^ (2 ** (32 - $2) - 1)))
  printf "%s\n" "$((decimal_ip & decimal_mask))"
}

dotIPv4LastDec() {
  local decimal_ip decimal_mask_inv
  decimal_ip=$(dotIPv4ToDec "$1")
  decimal_mask_inv=$((2 ** (32 - $2) - 1))
  printf "%s\n" "$((decimal_ip | decimal_mask_inv))"
}

decIPv4ToHex() {
  local hex
  hex="$(printf "%08x\n" "$1")"
  quartet_hi=${hex:0:4}
  quartet_lo=${hex:4:4}
  # Removes leading zeros from quartets, purely for aesthetic reasons
  # Source: https://stackoverflow.com/a/19861690
  leading_zeros_hi="${quartet_hi%%[!0]*}"
  leading_zeros_lo="${quartet_lo%%[!0]*}"
  printf "%s:%s\n" "${quartet_hi#"${leading_zeros_hi}"}" "${quartet_lo#"${leading_zeros_lo}"}"
}

cidrToMask() {
  # Source: https://stackoverflow.com/a/20767392
  set -- $((5 - (${1} / 8))) \
    255 255 255 255 \
    $(((255 << (8 - (${1} % 8))) & 255)) \
    0 0 0
  shift "${1}"
  echo "${1-0}.${2-0}.${3-0}.${4-0}"
}
