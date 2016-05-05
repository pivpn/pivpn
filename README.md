PiVPN
============

About
-----

Visit the [PiVPN](http://pivpn.io) site for more information.
This is a set of shell scripts that serve to easily turn your Raspberry Pi (TM)
into a VPN server using the free, open-source [OpenVPN](https://openvpn.net) software. 

The master branch of this script installs and configures OpenVPN on Raspbian
Jessie, and should be used if you are running Jessie or Jessie Lite. Jessie Lite
is recommended if this will just be a server.  

> This will also work on a free-tier Amazon AWS server using Ubuntu 14.04.  I don't want to support every scenario there but getting it to run and install successfully on a free server in the cloud was also important.  Many people have untrustworthy ISP's so running on a server elsewhere means you can connect to the VPN from home and your ISP will just see encrypted traffic as your traffic will now be leaving out the amazon infrastructure.

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
curl -L https://install.pivpn.io | bash
```

The script will first update your APT repositories, upgrade packages, and install OpenVPN,
which will take some time.
It will ask which encryption method you wish the guts of your server to use, 1024-bit, 2048-bit, or 4096-bit.
If you're unsure or don't have a convincing reason one way or the other I'd use 2048 today.  From the OpenVPN site:
> For asymmetric keys, general wisdom is that 1024-bit keys are no longer sufficient to protect against well-equipped adversaries. Use of 2048-bit is a good minimum. It is wise to ensure all keys across your active PKI (including the CA root keypair) are using at least 2048-bit keys.

> Up to 4096-bit is accepted by nearly all RSA systems (including OpenVPN,) but use of keys this large will dramatically increase generation time, TLS handshake delays, and CPU usage for TLS operations; the benefit beyond 2048-bit keys is small enough not to be of great use at the current time. It is often a larger benefit to consider lower validity times than more bits past 2048, but that is for you to decide.

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
The script will assemble the client .ovpn file and place it in the directory 'ovpns' within your
home directory.

If you need to create a client certificate that is not password protected (IE for use on a router),
then you can use the 'pivpn add nopass' option to generate that.

"pivpn revoke"
Asks you for the name of the client to revoke.  Once you revoke a client, it will no longer to use 
the certificate (ovpn config) you sent it to connect.  This is useful for many reasons but some ex:
You have a profile on a mobile phone and it was lost or stolen.  Revoke its cert and generate a new 
one for your new phone.  Or even if you suspect that a cert may have been comprmised in any way, 
just revoke it and generate a new one.

"pivpn list"
If you add more than a few clients, this gives you a nice list of thier names and whether their certificate
is still valid or has been revoked.  Great way to keep track of what you did with 'pivpn add' and 'pivpn revoke'.

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

