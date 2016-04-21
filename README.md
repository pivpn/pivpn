PiVPN
============

About
-----

Visit the [PiVPN](http://pivpn.io) site for more information.
This is a set of shell scripts that server to easily turn your Raspberry Pi (TM)
into a VPN server using the free, open-source [OpenVPN](https://openvpn.net) software. 

The master branch of this script installs and configures OpenVPN on Raspbian
Jessie, and should be used if you are running Jessie or Jessie Lite. Jessie Lite
is recommended if this will just be a server.  The goal is for this to also work
on Debian Jessie built on a free-tier Amazon AWS server for those that want thier
tunneled traffic to be encrypted out of their home ISP. 

Prerequisites
-------------

To follow this guide and use the script to setup OpenVPN, you will need to have
a Raspberry Pi Model B or later with an ethernet port, an SD or microSD card
(depending on the model) with Raspbian installed, a power adapter appropriate to
 the power needs of your model, and an ethernet cable or wifi adapter to connect your Pi to your
router or gateway. It is recommended that you use a fresh image of Raspbian
Jessie Lite from https://raspberrypi.org/downloads, but if you don't,
be sure to make a backup image of your existing installation before proceeding.
You should also setup your Pi with a static IP address (see either source
  1 or 2 at the bottom of this Readme) but it is not required as the script can do this for you.
  You will need to have your router forward UPD port 1194
  (varies by model & manufacturer; consult your router manufacturer's
  documentation to do this). 
  Enabling SSH on your Pi is also highly recommended, so that
  you can run a very compact headless server without a monitor or keyboard and
  be able to access it even more conveniently (This is also covered by source 2).


Installation
-----------------


```shell
curl -L http://install.pivpn.io | bash
```

The script will first update your APT repositories, upgrade packages, and install OpenVPN,
which will take some time.
It will ask which encryption method you wish the guts of your server to use, 1024-bit or 2048-bit.
2048-bit is more secure, but will take much longer to set up. If you're unsure or don't
have a convincing reason one way or the other I'd use 2048 today.

After this, the script will go back to the command line as it builds the server's own
certificate authority. The script will ask you if you'd like to change the certificate fields, 
the default port, client's DNS server, etc.  If you know you want to change these things, feel free,
and the script will put all the information where it needs to go in the various config files.
If you aren't sure, it has been designed that you can simply hit 'Enter' through all the questions
and have a working configuration at the end.

Finally, the script will take some time to build the server's Diffie-Hellman key
exchange. If you chose 1024-bit encryption, this will just take a few minutes, but if you
chose 2048-bit, it will take much longer (anywhere from 40 minutes to several hours on a
Model B+). The script will also make some changes to your system to allow it to forward
internet traffic and allow VPN connections through the Pi's firewall. When the script
informs you that it has finished configuring OpenVPN, it will ask if you want to reboot.  
I have it where you do not need to reboot when done but it also can't hurt.

Managing the PiVPN
----------------------

After the installation is complete you can use the command 'pivpn' to manage the server.

"pivpn add"
You will be prompted to enter a name for your client. Pick anything you like and hit 'enter'.
You will be asked to enter a pass phrase for the client key; make sure it's one you'll remember.
You'll then be prompted for input in more identification fields, which you can again ignore if
you like; make sure you again leave the challenge field blank. The script will then ask if you
want to sign the client certificate and commit; press 'y' for both. You'll then be asked to enter
the pass phrase you just chose in order to encrypt the client key, and immediately after to choose
another pass phrase for the encrypted key - if you're normal, just use the same one. After this,
the script will assemble the client .ovpn file and place it in the directory 'ovpns' within your
home directory.

You can run just 'pivpn' to see all the options.

Importing .ovpn Profiles on Client Machines
--------------------------------------------

To move a client .ovpn profile to Windows, use a program like WinSCP or Cyberduck. Note that
you may need administrator permission to move files to some folders on your Windows machine,
so if you have trouble transferring the profile to a particular folder with your chosen file
transfer program, try moving it to your desktop. To move a profile to Android, you can either
retrieve it on PC and then move it to your device via USB, or you can use an app like Turbo
FTP & SFTP client to retrieve it directly from your Android device.

To import the profile to OpenVPN on Windows, download the OpenVPN GUI from the community downloads
section of openvpn.net, install it, and place the profile in the 'config' folder of your OpenVPN
directory, i.e., in 'C:\Program Files\OpenVPN\config'. To import the profile on Android, install
the OpenVPN Connect app, select 'Import' from the drop-down menu in the upper right corner of the
main screen, choose the directory on your device where you stored the .ovpn file, and select the
file.

After importing, connect to the VPN server on Windows by running the OpenVPN GUI with
administrator permissions, right-clicking on the icon in the system tray, and clicking 'Connect',
or on Android by selecting the profile under 'OpenVPN Profile' and pressing 'Connect'. You'll be
asked to enter the pass phrase you chose. Do so, and you're in! Enjoy your ~$50 USD private VPN.

Removing PiVPN
----------------

If at any point you wish to remove OpenVPN from your Pi and revert it to a
pre-installation state, such as if you want to undo a failed installation to try again or
you want to remove OpenVPN without installing a fresh Raspbian image, just run
'pivpn uninstall' 

Feedback & Support
--------

I am interested in making this script work for as many people as possible, so I
welcome any feedback on your experience. If you have problems using it, feel
free to post an issue here on github.  I'll classify the issues the best I can
to keep things sorted.

Contributions
-------------

I'm also interested in improving this script, and will be adding features to it
over time to make it easier, more intuitive, and more versatile. If you have any 
feature ideas or requests, or are interested in adding your ideas to it,
testing it on other platforms, please comment or leave a pull request. 
If you contribute often I can add you as a member of the PiVPN project.
I will be happy to work with you!

If you have found this tool to be useful and want to Donate then consider the following
sources.
1. I began this as a rough merger of the code at [OpenVPNSetup](https://github.com/StarshipEngineer/OpenVPN-Setup) who you can donate to at [this PayPal link](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=K99QGVL7KA6ZL)
2. And the code at [pi-hole.net](https://github.com/pi-hole/pi-hole)
3. Of course there is [OpenVPN] (https://openvpn.net)
4. And as always the ever vigilant [EFF] (https://www.eff.org/)

I don't take donations at this time but if you want to show your appreciation to me, then contribute or leave feedback on suggestions or improvements.

