#!/bin/bash

setupVars="/etc/pivpn/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
	echo "::: Missing setup vars file!"
	exit 1
fi

source "${setupVars}"

if [ "$(uname -m)" != "armv6l" ]; then
	echo "On your system, WireGuard updates via the package manager"
	exit 0
fi

CURRENT_WG_TOOLS_SNAPSHOT="${WG_TOOLS_SNAPSHOT}"
WG_TOOLS_SNAPSHOT="$(curl -s https://build.wireguard.com/distros.json | jq -r '."upstream-tools"."version"')"

if dpkg --compare-versions "${WG_TOOLS_SNAPSHOT}" gt "${CURRENT_WG_TOOLS_SNAPSHOT}"; then

	read -r -p "A new wireguard-tools update is available (${WG_TOOLS_SNAPSHOT}), install? [Y/n]: "

	if [[ ${REPLY} =~ ^[Yy]$ ]]; then
		echo "::: Upgrading wireguard-tools from ${CURRENT_WG_TOOLS_SNAPSHOT} to ${WG_TOOLS_SNAPSHOT}..."

		WG_TOOLS_SOURCE="https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-${WG_TOOLS_SNAPSHOT}.tar.xz"
		echo "::: Downloading wireguard-tools source code... "
		wget -qO- "${WG_TOOLS_SOURCE}" | tar xJ --directory /usr/src
		echo "done!"

		## || exits if cd fails.
		cd /usr/src/wireguard-tools-"${WG_TOOLS_SNAPSHOT}/src" || exit 1

		# We install the userspace tools manually since DKMS only compiles and
		# installs the kernel module
		echo "::: Compiling WireGuard tools... "
		if make; then
			echo "done!"
		else
			echo "failed!"
			exit 1
		fi

		# Use checkinstall to install userspace tools so if the user wants to uninstall
		# PiVPN we can just do apt remove wireguard-tools, instead of manually removing
		# files from the file system
		echo "::: Installing WireGuard tools... "
		if checkinstall --pkgname wireguard-tools --pkgversion "${WG_TOOLS_SNAPSHOT}" -y; then
			echo "done!"
		else
			echo "failed!"
			exit 1
		fi

		echo "::: Removing old source code ..."
		rm -rf /usr/src/wireguard-tools-"${CURRENT_WG_TOOLS_SNAPSHOT}"

		sed "s/WG_TOOLS_SNAPSHOT=${CURRENT_WG_TOOLS_SNAPSHOT}/WG_TOOLS_SNAPSHOT=${WG_TOOLS_SNAPSHOT}/" -i "${setupVars}"

		echo "::: Upgrade completed!"
	fi
else
	echo "::: You are running the lastest version of wireguard-tools (${CURRENT_WG_TOOLS_SNAPSHOT})"
fi

CURRENT_WG_MODULE_SNAPSHOT="${WG_MODULE_SNAPSHOT}"
WG_MODULE_SNAPSHOT="$(curl -s https://build.wireguard.com/distros.json | jq -r '."upstream-linuxcompat"."version"')"

if dpkg --compare-versions "${WG_MODULE_SNAPSHOT}" gt "${CURRENT_WG_MODULE_SNAPSHOT}"; then

	read -r -p "A new wireguard-dkms update is available (${WG_MODULE_SNAPSHOT}), install? [Y/n]: "

	if [[ ${REPLY} =~ ^[Yy]$ ]]; then
		echo "::: Upgrading wireguard-dkms from ${CURRENT_WG_MODULE_SNAPSHOT} to ${WG_MODULE_SNAPSHOT}..."

		WG_MODULE_SOURCE="https://git.zx2c4.com/wireguard-linux-compat/snapshot/wireguard-linux-compat-${WG_MODULE_SNAPSHOT}.tar.xz"
		echo "::: Downloading wireguard-linux-compat source code... "
		wget -qO- "${WG_MODULE_SOURCE}" | tar xJ --directory /usr/src
		echo "done!"

		# Rename wireguard-linux-compat folder and move the source code to the parent folder
		# such that dkms picks up the module when referencing wireguard/"${WG_MODULE_SNAPSHOT}"
		cd /usr/src && \
		mv wireguard-linux-compat-"${WG_MODULE_SNAPSHOT}" wireguard-"${WG_MODULE_SNAPSHOT}" && \
		cd wireguard-"${WG_MODULE_SNAPSHOT}" && \
		mv src/* . && \
		rmdir src || exit 1

		echo "::: Adding WireGuard module via DKMS... "
		if dkms add wireguard/"${WG_MODULE_SNAPSHOT}"; then
			echo "done!"
		else
			echo "failed!"
			dkms remove wireguard/"${WG_MODULE_SNAPSHOT}" --all
			exit 1
		fi

		echo "::: Compiling WireGuard module via DKMS... "
		if dkms build wireguard/"${WG_MODULE_SNAPSHOT}"; then
			echo "done!"
		else
			echo "failed!"
			dkms remove wireguard/"${WG_MODULE_SNAPSHOT}" --all
			exit 1
		fi

		echo "::: Installing WireGuard module via DKMS... "
		if dkms install wireguard/"${WG_MODULE_SNAPSHOT}"; then
			echo "done!"
		else
			echo "failed!"
			dkms remove wireguard/"${WG_MODULE_SNAPSHOT}" --all
			exit 1
		fi

		echo "::: Removing old kernel module and source code..."
		if dkms remove wireguard/"${CURRENT_WG_MODULE_SNAPSHOT}" --all; then
			rm -rf /usr/src/wireguard-"${CURRENT_WG_MODULE_SNAPSHOT}"
			echo "done!"
		else
			echo "failed!"
			exit 1
		fi

		sed "s/WG_TOOLS_SNAPSHOT=${CURRENT_WG_MODULE_SNAPSHOT}/WG_TOOLS_SNAPSHOT=${WG_MODULE_SNAPSHOT}/" -i "${setupVars}"

		echo "::: Upgrade completed!"
	fi
else
	echo "::: You are running the lastest version of wireguard-dkms (${CURRENT_WG_MODULE_SNAPSHOT})"
fi
