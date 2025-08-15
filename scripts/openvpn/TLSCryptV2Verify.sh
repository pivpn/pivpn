#!/bin/bash
# PiVPN: verify tls-crypt-v2 metadata agains allowlist
# shellcheck disable=SC2154

### Constants
TC_V2_METADATA="/etc/pivpn/openvpn/tc-v2-metadata.txt"

if [ "${script_type}" != "tls-crypt-v2-verify" ]; then
    echo "Unsupported script type, rejecting..."
    exit 1
fi

if [ "${metadata_type}" != "0" ]; then
    # Shouldn't be possible with our configuration
    echo "Metadata is not user-supplied, rejecting..."
    exit 1
fi

if ! metadata="$(head -c 22 "${metadata_file}")"; then
    echo "Unable to read metadata, rejecting..."
    exit 1
fi

if [ "${#metadata}" -lt 22 ]; then
    # Shouldn't be possible with our configuration
    echo "Metadata shorter than 22 characters, rejecting..."
    exit 1
fi

if grep -q ' '"${metadata}"'$' "${TC_V2_METADATA}"; then
    # Allowed to continue authentication
    exit 0
else
    # Rejected
    exit 1
fi
