#!/usr/bin/env zsh

# Allow custom IP network for setupVARS file. Use default if not provided.
while [ -z "$pivpnNET" ]; do
        answer=$(whiptail --backtitle "Setup PiVPN" --title "Installation Mode" --inputbox "Please Choose your IP Gateway Address" 8 78 3>&1 1>&2 2>&3) 
                if [[ $answer =~ ^([0-9]{1,3}\.){2}[0]{1,3}\.[0]{1,3}$ ]]; then
                        whiptail --msgbox --title "ACCEPTED" "$answer is a valid IP." 8 78
                        pivpnNET=$answer
                else
                        whiptail --msgbox --title "ERROR" "$answer is not a valid IP." 8 78
                        if (whiptail --yesno --title "Use Default?" "Would you like to use the default network of 10.6.0.0?" 8 78); then
                                #Send message, okay using 10.6
                                whiptail --msgbox --title "DEFAULT" "Great! Using the default IP of 10.6.0.0" 8 78
                                pivpnNET="10.6.0.0"
                        else
                                # Great, go back to the top of the if statement! 
                                continue
                        fi
                fi
done
echo "Complete!"
