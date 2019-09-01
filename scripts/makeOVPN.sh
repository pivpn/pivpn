#!/bin/bash
# Create OVPN Client
# Default Variable Declarations
DEFAULT="Default.txt"
FILEEXT=".ovpn"
CRT=".crt"
KEY=".key"
CA="ca.crt"
TA="ta.key"
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"
INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)

helpFunc() {
    echo "::: Create a client ovpn profile, optional nopass"
    echo ":::"
    echo "::: Usage: pivpn <-a|add> [-n|--name <arg>] [-p|--password <arg>]|[nopass] [-d|--days <number>] [-i|--iOS] [-h|--help]"
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Interactive mode"
    echo ":::  nopass               Create a client without a password"
    echo ":::  -b,--bitwarden       Create and save a client through Bitwarden"
    echo ":::  -d,--days            Expire the certificate after specified number of days (default: 1080)"
    echo ":::  -n,--name            Name for the Client (default: '"$(hostname)"')"
    echo ":::  -p,--password        Password for the Client (no default)"
	echo ":::  -i,--iOS             Generate a certificate that leverages iOS keychain"
    echo ":::  -h,--help            Show this help dialog"
}

# Parse input arguments
while test $# -gt 0
do
    _key="$1"
    case "$_key" in
        -n|--name|--name=*)
            _val="${_key##--name=}"
            if test "$_val" = "$_key"
            then
                test $# -lt 2 && echo "Missing value for the optional argument '$_key'." && exit 1
                _val="$2"
                shift
            fi
            NAME="$_val"
            ;;
        -p|--password|--password=*)
            _val="${_key##--password=}"
            if test "$_val" = "$_key"
            then
                test $# -lt 2 && echo "Missing value for the optional argument '$_key'." && exit 1
                _val="$2"
                shift
            fi
            PASSWD="$_val"
            ;;
        -d|--days|--days=*)
            _val="${_key##--days=}"
            if test "$_val" = "$_key"
            then
                test $# -lt 2 && echo "Missing value for the optional argument '$_key'." && exit 1
                _val="$2"
                shift
            fi
            DAYS="$_val"
            ;;
        -i|--iOS)
			iOS=1
			;;
		-h|--help)
            helpFunc
            exit 0
            ;;
        nopass)
            NO_PASS="1"
            ;;
        -b|--bitwarden)
            BITWARDEN="2"
            ;;
        *)
            echo "Error: Got an unexpected argument '$1'"
            helpFunc
            exit 1
            ;;
    esac
    shift
done

# Functions def

function keynoPASS() {

    #Build the client key
    expect << EOF
    set timeout -1
    set env(EASYRSA_CERT_EXPIRE) "${DAYS}"
    spawn ./easyrsa build-client-full "${NAME}" nopass
    expect eof
EOF

    cd pki || exit

}

function useBitwarden() {

    # login and unlock vault
    printf "****Bitwarden Login****"
    printf "\n"
    SESSION_KEY=`bw login --raw`
    export BW_SESSION=$SESSION_KEY
    printf "Successfully Logged in!"
    printf "\n"

    # ask user for username
    printf "Enter the username:  "
    read -r NAME

    # check name
    until [[ "$NAME" =~ ^[a-zA-Z0-9.@_-]+$ && ${NAME::1} != "." && ${NAME::1} != "-"  ]]
    do
      	echo "Name can only contain alphanumeric characters and these characters (.-@_). The name also cannot start with a dot (.) or a dash (-). Please try again."
      	# ask user for username again
      	printf "Enter the username: "
      	read -r NAME
    done


    # ask user for length of password
    printf "Please enter the length of characters you want your password to be (minimum 12): "
    read -r LENGTH

    # check length
    until [[ "$LENGTH" -gt 11 && "$LENGTH" -lt 129 ]]
    do
      	echo "Password must be between from 12 to 128 characters, please try again."
      	# ask user for length of password
      	printf "Enter the length of characters you want your password to be (minimum 12): "
      	read -r LENGTH
    done

    printf "Creating a PiVPN item for your vault..."
    printf "\n"
    # create a new item for your PiVPN Password
    PASSWD=`bw generate -usln --length $LENGTH`
    bw get template item | jq '.login.type = "1"'| jq '.name = "PiVPN"' | jq -r --arg NAME "$NAME" '.login.username = $NAME' | jq -r --arg PASSWD "$PASSWD" '.login.password = $PASSWD' |  bw encode | bw create item
    bw logout

}

function keyPASS() {

    if [[ -z "${PASSWD}" ]]; then
        stty -echo
        while true
        do
            printf "Enter the password for the client:  "
            read -r PASSWD
            printf "\n"
            printf "Enter the password again to verify:  "
            read -r PASSWD2
            printf "\n"
            [ "${PASSWD}" = "${PASSWD2}" ] && break
            printf "Passwords do not match! Please try again.\n"
        done
        stty echo
        if [[ -z "${PASSWD}" ]]; then
            echo "You left the password blank"
            echo "If you don't want a password, please run:"
            echo "pivpn add nopass"
            exit 1
        fi
    fi
    if [ ${#PASSWD} -lt 4 ] || [ ${#PASSWD} -gt 1024 ]
    then
        echo "Password must be between from 4 to 1024 characters"
        exit 1
    fi

    #Escape chars in PASSWD
    PASSWD=$(echo -n ${PASSWD} | sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e 's/\$/\\\$/g' -e 's/!/\\!/g' -e 's/\./\\\./g' -e "s/'/\\\'/g" -e 's/"/\\"/g' -e 's/\*/\\\*/g' -e 's/\@/\\\@/g' -e 's/\#/\\\#/g' -e 's/£/\\£/g' -e 's/%/\\%/g' -e 's/\^/\\\^/g' -e 's/\&/\\\&/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/-/\\-/g' -e 's/_/\\_/g' -e 's/\+/\\\+/g' -e 's/=/\\=/g' -e 's/\[/\\\[/g' -e 's/\]/\\\]/g' -e 's/;/\\;/g' -e 's/:/\\:/g' -e 's/|/\\|/g' -e 's/</\\</g' -e 's/>/\\>/g' -e 's/,/\\,/g' -e 's/?/\\?/g' -e 's/~/\\~/g' -e 's/{/\\{/g' -e 's/}/\\}/g')

    #Build the client key and then encrypt the key

    expect << EOF
    set timeout -1
    set env(EASYRSA_CERT_EXPIRE) "${DAYS}"
    spawn ./easyrsa build-client-full "${NAME}"
    expect "Enter PEM pass phrase" { send -- "${PASSWD}\r" }
    expect "Verifying - Enter PEM pass phrase" { send -- "${PASSWD}\r" }
    expect eof
EOF
    cd pki || exit

}

# bitWarden first
if [[ "${BITWARDEN}" =~ "2" ]]; then
    useBitwarden
fi

if [ -z "${NAME}" ]; then
    printf "Enter a Name for the Client:  "
    read -r NAME
fi

if [[ ${NAME::1} == "." ]] || [[ ${NAME::1} == "-" ]]; then
    echo "Names cannot start with a dot (.) or a dash (-)."
    exit 1
fi

if [[ "${NAME}" =~ [^a-zA-Z0-9.@_-] ]]; then
    echo "Name can only contain alphanumeric characters and these characters (.-@_)."
    exit 1
fi

if [[ -z "${NAME}" ]]; then
    echo "You cannot leave the name blank."
    exit 1
fi

# Check if name is already in use
while read -r line || [ -n "${line}" ]; do
    STATUS=$(echo "$line" | awk '{print $1}')

    if [ "${STATUS}" == "V" ]; then
        CERT=$(echo "$line" | sed -e 's:.*/CN=::')
        if [ "${CERT}" == "${NAME}" ]; then
            INUSE="1"
            break
        fi
    fi
done <${INDEX}

if [ "${INUSE}" == "1" ]; then
    printf "\n!! This name is already in use by a Valid Certificate."
    printf "\nPlease choose another name or revoke this certificate first.\n"
    exit 1
fi

# Check if name is reserved
if [ "${NAME}" == "ta" ] || [ "${NAME}" == "server" ] || [ "${NAME}" == "ca" ]; then
    echo "Sorry, this is in use by the server and cannot be used by clients."
    exit 1
fi

#As of EasyRSA 3.0.6, by default certificates last 1080 days, see https://github.com/OpenVPN/easy-rsa/blob/6b7b6bf1f0d3c9362b5618ad18c66677351cacd1/easyrsa3/vars.example
if [ -z "${DAYS}" ]; then
    read -r -e -p "How many days should the certificate last?  " -i 1080 DAYS
fi

if [[ ! "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ] || [ "$DAYS" -gt 3650 ]; then
    #The CRL lasts 3650 days so it doesn't make much sense that certificates would last longer
    echo "Please input a valid number of days, between 1 and 3650 inclusive."
    exit 1

fi

cd /etc/openvpn/easy-rsa || exit

if [[ "${NO_PASS}" =~ "1" ]]; then
    if [[ -n "${PASSWD}" ]]; then
        echo "Both nopass and password arguments passed to the script. Please use either one."
        exit 1
    else
        keynoPASS
    fi
else
    keyPASS
fi

#1st Verify that clients Public Key Exists
if [ ! -f "issued/${NAME}${CRT}" ]; then
    echo "[ERROR]: Client Public Key Certificate not found: $NAME$CRT"
    exit
fi
echo "Client's cert found: $NAME$CRT"

#Then, verify that there is a private key for that client
if [ ! -f "private/${NAME}${KEY}" ]; then
    echo "[ERROR]: Client Private Key not found: $NAME$KEY"
    exit
fi
echo "Client's Private Key found: $NAME$KEY"

#Confirm the CA public key exists
if [ ! -f "${CA}" ]; then
    echo "[ERROR]: CA Public Key not found: $CA"
    exit
fi
echo "CA public Key found: $CA"

#Confirm the tls key file exists
if [ ! -f "${TA}" ]; then
    echo "[ERROR]: tls Private Key not found: $TA"
    exit
fi
echo "tls Private Key found: $TA"


## Added new step to create an .ovpn12 file that can be stored on iOS keychain
## This step is more secure method and does not require the end-user to keep entering passwords, or storing the client private cert where it can be easily tampered
## https://openvpn.net/faq/how-do-i-use-a-client-certificate-and-private-key-from-the-ios-keychain/
if [ "$iOS" = "1" ]; then
	#Generates the .ovpn file WITHOUT the client private key
	{
    # Start by populating with the default file
    cat "${DEFAULT}"

    #Now, append the CA Public Cert
    echo "<ca>"
    cat "${CA}"
    echo "</ca>"

    #Next append the client Public Cert
    echo "<cert>"
    sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' < "issued/${NAME}${CRT}"
    echo "</cert>"

    #Finally, append the TA Private Key
    if [ -f /etc/pivpn/TWO_POINT_FOUR ]; then
      echo "<tls-crypt>"
      cat "${TA}"
      echo "</tls-crypt>"
    else
      echo "<tls-auth>"
      cat "${TA}"
      echo "</tls-auth>"
    fi

	} > "${NAME}${FILEEXT}"
	
	# Copy the .ovpn profile to the home directory for convenient remote access
		
	printf "========================================================\n"
	printf "Generating an .ovpn12 file for use with iOS devices\n"
	printf "Please remember the export password\n"
	printf "as you will need this import the certificate on your iOS device\n"
	printf "========================================================\n"
	openssl pkcs12 -passin env:$PASSWD -export -in issued/${NAME}${CRT} -inkey private/${NAME}${KEY} -certfile ${CA} -name ${NAME} -out /home/$INSTALL_USER/ovpns/$NAME.ovpn12
	chown "$INSTALL_USER" "/home/$INSTALL_USER/ovpns/$NAME.ovpn12"
	chmod 600 "/home/$INSTALL_USER/ovpns/$NAME.ovpn12"
	printf "========================================================\n"
	printf "\e[1mDone! %s successfully created!\e[0m \n" "$NAME.ovpn12"
	printf "You will need to transfer both the .ovpn and .ovpn12 files\n"
	printf "to your iOS device.\n"
	printf "========================================================\n\n"
else
	#This is the standard non-iOS configuration
#Ready to make a new .ovpn file
	{
    # Start by populating with the default file
    cat "${DEFAULT}"

    #Now, append the CA Public Cert
    echo "<ca>"
    cat "${CA}"
    echo "</ca>"

    #Next append the client Public Cert
    echo "<cert>"
    sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' < "issued/${NAME}${CRT}"
    echo "</cert>"

    #Then, append the client Private Key
    echo "<key>"
    cat "private/${NAME}${KEY}"
    echo "</key>"

    #Finally, append the tls Private Key
    if [ -f /etc/pivpn/TWO_POINT_FOUR ]; then
      echo "<tls-crypt>"
      cat "${TA}"
      echo "</tls-crypt>"
    else
      echo "<tls-auth>"
      cat "${TA}"
      echo "</tls-auth>"
    fi

	} > "${NAME}${FILEEXT}"

fi

if [ ! -d "/home/$INSTALL_USER/ovpns" ]; then
    mkdir "/home/$INSTALL_USER/ovpns"
    chmod 0750 "/home/$INSTALL_USER/ovpns"
fi

# If user is using Bitwarden, have them login again to submit their .ovpn file to their vault
printf "Would you like to export your .ovpn file to your Bitwarden vault? (y or n)"
read -r RESPONSE
if [ $RESPONSE == "y" ] || [ $RESPONSE == "Y" ]; then
    $OVPN_FILE="$(< "/etc/openvpn/easy-rsa/pki/$NAME$FILEEXT")"
    # Login to Bitwarden
    printf "****Bitwarden Login****"
    printf "\n"
    SESSION_KEY=`bw login --raw`
    export BW_SESSION=$SESSION_KEY
    printf "Successfully Logged in!"
    printf "\n"
    # Create a Bitwarden secure note to export the .ovpn file 
    bw get template item | jq '.name = "PiVPN OVPN File"' | jq '.type = 2' | jq -r --arg VAL "$OVPN_FILE" '.notes = $VAL' | jq ".secureNote = $(bw get template item.secureNote)" | bw encode | bw create item
    bw logout
    exit
  fi

# Copy the .ovpn profile to the home directory for convenient remote access
INSTALL_HOME=$(cat /etc/passwd | grep "$INSTALL_USER" | cut -d: -f6)
cp "/etc/openvpn/easy-rsa/pki/$NAME$FILEEXT" "$INSTALL_HOME/ovpns/$NAME$FILEEXT"
chown "$INSTALL_USER" "$INSTALL_HOME/ovpns/$NAME$FILEEXT"
chmod 640 "/etc/openvpn/easy-rsa/pki/$NAME$FILEEXT"
chmod 640 "$INSTALL_HOME/ovpns/$NAME$FILEEXT"
printf "\n\n"
printf "========================================================\n"
printf "\e[1mDone! %s successfully created!\e[0m \n" "$NAME$FILEEXT"
printf "%s was copied to:\n" "$NAME$FILEEXT"
printf "  %s/ovpns\n" "$INSTALL_HOME"
printf "for easy transfer. Please use this profile only on one\n"
printf "device and create additional profiles for other devices.\n"
printf "========================================================\n\n"
