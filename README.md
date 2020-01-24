![WireGuard + OpenVPN logo](logos.jpg)

[Is pivpn.dev down?](https://p.datadoghq.com/sb/od1t7p4rmqi6x1fm-cd513e61b0eb77a5d5f6a52fe0662205?theme=dark)
-----

About
-----

Visit the [PiVPN](https://pivpn.dev) site for more information.
This is a set of shell scripts initially developed by **@0-kaladin** that serve to easily turn your Raspberry Pi (TM)
into a VPN server using two free, open-source protocols:
  * [WireGuard](https://www.wireguard.com/)
  * [OpenVPN](https://openvpn.net)

Have you been looking for a good guide or tutorial for setting up a VPN server on a Raspberry Pi or Ubuntu based server?  
Run this script and you don't need a guide or tutorial, this will do it all for you, in a fraction of the time and with hardened security settings in place by default.  

The master branch of this script installs and configures either WireGuard or OpenVPN on Raspbian, Debian or Ubuntu and it as been tested to run not only on Raspberry Pi but also in any Cloud Provider VPS.  
We recommend using the latest Raspbian Lite image on a Raspberry Pi in your home so you can VPN into your home from a unsecure remote locations and safely use the internet.  
However, the scripts do try to detect different distributions and make adjustments accordingly.  
They should work on the majority of Ubuntu and Debian based distributions including those using UFW by default instead of raw iptables.  

This scripts primary mission in life is to allow a user to have a home VPN for as cost effective as possible and without being a technical wizard.  
Hence the design of pivpn to work on a Raspberry Pi ($35) and then one command installer.  
Followed by easy management of the VPN thereafter with the 'pivpn' command.  
That being said...

> This will also work on a free-tier Amazon AWS server using Ubuntu or Debian.  I don't want to support every scenario there but getting it to run and install successfully on a free server in the cloud was also important.  
Many people have untrustworthy ISP's so running on a server elsewhere means you can connect to the VPN from home and your ISP will just see encrypted traffic as your traffic will now be leaving out the Amazon infrastructure.

Prerequisites
-------------

To follow this guide and use the script to setup a VPN, you will need to have
a Raspberry Pi Model B or later with, an SD or microSD card with Raspbian installed,
a power adapter appropriate to the power needs of your model, and an ethernet cable or wifi
adapter to connect your Pi to your router or gateway.  
It is recommended that you use a fresh image of the latest Raspbian Lite from
https://raspberrypi.org/downloads, but if you don't, be sure to make a backup
image of your existing installation before proceeding.  
You should also setup your Pi with a static IP address
(see either source 1 or 2 at the bottom of this Readme)
but it is not required as the script can do this for you.  
You will need to have your router forwarding UDP port 1194 or whatever custom
port you may have chose in the installer
(varies by model & manufacturer; consult your router manufacturer's documentation to do this).
Enabling SSH on your Pi is also highly recommended, so that you can run a very
compact headless server without a monitor or keyboard and be able to access it
even more conveniently (This is also covered by source 2).


Installation
-----------------

**Method 1**
```Shell
curl -L https://install.pivpn.dev | bash
```

**Method 2**
```Shell
curl -L https://install.pivpn.dev > pivpn.sh
sudo sh pivpn.sh
```

**Method 3**
```Shell
git clone https://github.com/pivpn/pivpn.git
sudo sh pivpn/auto_install/install.sh
```

**OBS:**  
In alternative to install.pivpn.dev you can use the raw github link:   
https://raw.githubusercontent.com/pivpn/pivpn/master/auto_install/install.sh

**To install from Test/Development branch**

Check our [Wiki Page](https://github.com/pivpn/pivpn/wiki#testing)

**How it works**

The script will first update your APT repositories, upgrade packages, and install WireGuard (default) or OpenVPN, which will take some time.

It will ask which authentication method you wish the guts of your server to use. If you go for WireGuard, you don't get to choose: you will use a Curve25519 public key, which provides 128-bit security. On the other end, if you prefer OpenVPN, you can choose between a 2048-bit, 3072-bit, or 4096-bit RSA certificate. If you're unsure or don't have a convincing reason one way or the other I'd use 2048 today (provides 112-bit security).

From the OpenVPN site:

> For asymmetric keys, general wisdom is that 1024-bit keys are no longer sufficient to protect against well-equipped adversaries. Use of 2048-bit is a good minimum. It is wise to ensure all keys across your active PKI (including the CA root keypair) are using at least 2048-bit keys.

> Up to 4096-bit is accepted by nearly all RSA systems (including OpenVPN), but use of keys this large will dramatically increase generation time, TLS handshake delays, and CPU usage for TLS operations; the benefit beyond 2048-bit keys is small enough not to be of great use at the current time. It is often a larger benefit to consider lower validity times than more bits past 2048, but that is for you to decide.

After this, the script will go back to the command line as it builds the server's own certificate authority (OpenVPN only). The script will ask you if you'd like to change the default port, protocol, client's DNS server, etc. If you know you want to change these things, feel free, and the script will put all the information where it needs to go in the various config files.

If you aren't sure, it has been designed that you can simply hit 'Enter' through all the questions and have a working configuration at the end.

Finally, the script will take some time to build the server's Diffie-Hellman key exchange (OpenVPN only). If you chose 2048-bit encryption, it will take about 40 minutes on a Model B+, and several hours if you choose a larger size.

The script will also make some changes to your system to allow it to forward internet traffic and allow VPN connections through the Pi's firewall. When the script informs you that it has finished configuring PiVPN, it will ask if you want to reboot. I have it where you do not need to reboot when done but it also can't hurt.

After the installation is complete you can use the command `pivpn` to manage the server. The commands below are just to get started, run `pivpn -h` to see the full list of options.

Managing the PiVPN (WireGuard)
----------------------

`pivpn add`
You will be prompted to enter a name for your client. Pick anything you like and hit 'enter'.
The script will assemble the client .conf file and place it in the directory 'configs' within your
home directory.

`pivpn remove`
Asks you for the name of the client to remove.  Once you remove a client, it will no longer allow you to use
the given client config (specifically its public key) to connect.  This is useful for many reasons but some ex:
You have a profile on a mobile phone and it was lost or stolen.  Remove its key and generate a new
one for your new phone.  Or even if you suspect that a key may have been compromised in any way,
just remove it and generate a new one.

`pivpn list`
If you add more than a few clients, this gives you a nice list of their names and associated keys.

Managing the PiVPN (OpenVPN)
----------------------

`pivpn add`
You will be prompted to enter a name for your client. Pick anything you like and hit 'enter'.
You will be asked to enter a pass phrase for the client key; make sure it's one you'll remember.
The script will assemble the client .ovpn file and place it in the directory 'ovpns' within your
home directory.

If you need to create a client certificate that is not password protected (IE for use on a router),
then you can use the 'pivpn add nopass' option to generate that.

`pivpn revoke`
Asks you for the name of the client to revoke.  Once you revoke a client, it will no longer allow you to use
the given client certificate (ovpn config) to connect.  This is useful for many reasons but some ex:
You have a profile on a mobile phone and it was lost or stolen.  Revoke its cert and generate a new
one for your new phone.  Or even if you suspect that a cert may have been compromised in any way,
just revoke it and generate a new one.

`pivpn list`
If you add more than a few clients, this gives you a nice list of their names and whether their certificate
is still valid or has been revoked.  Great way to keep track of what you did with 'pivpn add' and 'pivpn revoke'.

Importing Profiles on Client Machines
--------------------------------------------

**Windows**: Use a program like WinSCP or Cyberduck. Note that you may need administrator permission to move files to some folders on your Windows machine, so if you have trouble transferring the profile to a particular folder with your chosen file transfer program, try moving it to your desktop.

**Mac/Linux**: Open the Terminal app and copy the config from the Raspberry Pi using `scp pi-user@ip-of-your-raspberry:configs/whatever.conf .` (if using WireGuard) or `scp pi-user@ip-of-your-raspberry:ovpns/whatever.ovpn .` (if using OpenVPN). The file will be downloaded in the current working directory, which usually is the home folder of your PC.

**Android/iOS** (WireGuard only): Just skip to _Connecting to the PiVPN server (WireGuard)_

**Android**: You can either retrieve it on PC and then move it to your device via USB, or you can use an app like Turbo FTP & SFTP client to retrieve it directly from your Android device.

**iOS**: You can use an app that supports SFTP like Documents by Readdle to retrieve it directly from your iOS device.

Connecting to the PiVPN server (WireGuard)
--------------------------------------------

**Windows/Mac**: Download the [WireGuard GUI app](https://www.wireguard.com/install/), import the configuration and activate the tunnel.

**Linux**: Install [WireGuard](https://www.wireguard.com/install/) following the instructions for your distribution. Now, as root user, create the /etc/wireguard folder and prevent anyone but root to enter it (you only need to do this the first time):
```
mkdir -p /etc/wireguard
chown root:root /etc/wireguard
chmod 700 /etc/wireguard
```
Move the config and activate the tunnel:
```
mv whatever.conf /etc/wireguard/
wg-quick up whatever
```
Run `wg-quick down whatever` to deactivate the tunnel.

**Android/iOS:** Run `pivpn -qr` on the PiVPN server to generate a QR code of your config, download the Wireguard app [Android link](https://play.google.com/store/apps/details?id=com.wireguard.android) / [iOS link](https://apps.apple.com/it/app/wireguard/id1441195209), click the '+' sign and scan the QR code with your phone's camera. Flip the switch to activate the tunnel.

Connecting to the PiVPN server (OpenVPN)
--------------------------------------------

**Windows**: Download the [OpenVPN GUI](https://openvpn.net/community-downloads/), install it, and place the profile in the 'config' folder of your OpenVPN directory, i.e., in 'C:\Program Files\OpenVPN\config'. After importing, connect to the VPN server on Windows by running the OpenVPN GUI with administrator permissions, right-clicking on the icon in the system tray, and clicking 'Connect'.

**Linux**: Install OpenVPN using your package manager (APT in this example). Now, as root user, create the /etc/openvpn/client folder and prevent anyone but root to enter it (you only need to do this the first time):
```
apt install openvpn
mkdir -p /etc/openvpn/client
chown root:root /etc/openvpn/client
chmod 700 /etc/openvpn/client
```
Move the config and connect (input the pass phrase if you set one):
```
mv whatever.ovpn /etc/openvpn/client/
openvpn /etc/openvpn/client/whatever.ovpn
```
Press CTRL-C to disconnect.

**Mac**: You can use an OpenVPN client like [Tunnelblick](https://tunnelblick.net/downloads.html). Here's a [guide](https://tunnelblick.net/czUsing.html) to import the configuration.

**Android**: Install the [OpenVPN Connect app](https://play.google.com/store/apps/details?id=net.openvpn.openvpn), select 'Import' from the drop-down menu in the upper right corner of the main screen, choose the directory on your device where you stored the .ovpn file, and select the file. Connect by selecting the profile under 'OpenVPN Profile' and pressing 'Connect'.

**iOS**: Install the [OpenVPN Connect app](https://apps.apple.com/it/app/openvpn-connect/id590379981). Then go to the app where you copied the .ovpn file to, select the file, find an icon or button to 'Share' or 'Open with', and choose to open with the OpenVPN app.

Removing PiVPN
----------------

If at any point you wish to remove PiVPN from your Pi and revert it to a pre-installation state, such as if you want to undo a failed installation to try again or you want to remove PiVPN without installing a fresh Raspbian image, just run `pivpn uninstall`.

Feedback & Support
--------

#### Please read carefully the [issue template](https://github.com/pivpn/pivpn/blob/master/ISSUE_TEMPLATE.md) and the [contributors' guide](https://github.com/pivpn/pivpn/blob/master/CONTRIBUTING.md), we will close all incomplete issue templates.

PiVPN is purely community driven, and we are interested in making this script work for as many people as possible, we welcome any feedback on your experience.
Please be respectful and be aware that this is maintained with our free time!

for community support or general questions.
Feel free to post on our subreddit <https://www.reddit.com/r/pivpn/>
You can also join #pivpn <ircs://freenode/pivpn> on freenode in IRC

For code related issues, code contributions, feature requests, feel free to open an issue here at github.
We will classify the issues the best we can to keep things sorted.


Related Projects
--------
[StarshipEngineer/OpenVPN-Setup](https://github.com/StarshipEngineer/OpenVPN-Setup)
Shell script to set up a OpenVPN server.

[InnovativeInventor/docker-pivpn](https://github.com/InnovativeInventor/docker-pivpn)
A secure docker container that sets up PiVPN and SSH.

[OpenVPN](https://openvpn.net)
The foundation for all open-source VPN projects.

[WireGuard](https://www.wireguard.com/)
*An extremely simple yet fast and modern VPN that utilizes state-of-the-art cryptography.*

Contributions
-------------

Please check the current issues to see where you can help. If you have any
feature ideas or requests, or are interested in adding your ideas to it,
testing it on other platforms, please comment or leave a pull request.
If you contribute often I can add you as a member of the PiVPN project.
I will be happy to work with you!

If you have found this tool to be useful and want to Donate then consider the following
sources.

1. I began this as a rough merger of the code at [OpenVPNSetup](https://github.com/StarshipEngineer/OpenVPN-Setup) who you can donate to at [this PayPal link](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K99QGVL7KA6ZL)

2. And the code at [pi-hole.net](https://github.com/pi-hole/pi-hole)

3. Of course there is [OpenVPN](https://openvpn.net)

4. Also [WireGuard](https://www.wireguard.com/)

5. And as always the ever vigilant [EFF](https://www.eff.org/)

PiVPN is not taking donations at this time but if you want to show your appreciation, then contribute or leave feedback on suggestions or improvements.
