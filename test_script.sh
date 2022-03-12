#!/usr/bin/env bash

# Allow custom IP network for setupVARS file. Use default if not provided.
while [ -z "$pivpnNET" ]; do
		if (whiptail --yesno --backtitle "Setup PiVPN" --title "Installation Mode" "Would you like to select your own IP network for your VPN? If you are not sure, please select no! Selecting yes may cause disruptions with your current network and is for advanced users only." 12 78 ); then 
			answer=$(whiptail --backtitle "Setup PiVPN" --title "Installation Mode" --inputbox "Please Choose your IP Gateway Address" 8 78 3>&1 1>&2 2>&3) 
						if [[ $answer =~ ^([0-9]{1,3}\.){2}[0]{1,3}\.[0]{1,3}$ ]]; then
								whiptail --msgbox --backtitle "Setup PiVPN" --title "Installation Mode" "$answer is a valid IP!" 8 78
								pivpnNET=$answer
						else
								if (whiptail --yesno --backtitle "Setup PiVPN" --title "Installation Mode" "$answer is not a valid IP! Select yes to Try again, no to use the default of 10.6.0.0" 8 78); then
									continue	
								else	
										whiptail --msgbox --title "DEFAULT" "Great! Using the default IP of 10.6.0.0" 8 78
										pivpnNET="10.6.0.0"
								fi
						fi
		else 
			continue
		fi
done
echo "Completed!"
