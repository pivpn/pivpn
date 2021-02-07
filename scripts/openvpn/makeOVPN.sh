#!/bin/bash
# Create OVPN Client
# Default Variable Declarations
setupVars="/etc/pivpn/openvpn/setupVars.conf"
DEFAULT="Default.txt"
FILEEXT=".ovpn"
CRT=".crt"
KEY=".key"
CA="ca.crt"
TA="ta.key"
INDEX="/etc/openvpn/easy-rsa/pki/index.txt"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

helpFunc() {
    echo "::: Create a client ovpn profile, optional nopass"
    echo ":::"
    echo "::: Usage: pivpn <-a|add> [-n|--name <arg>] [-p|--password <arg>]|[nopass] [-d|--days <number>] [-b|--bitwarden] [-i|--iOS] [-o|--ovpn] [-h|--help]"
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Interactive mode"
    echo ":::  nopass               Create a client without a password"
    echo ":::  -n,--name            Name for the Client (default: '"$(hostname)"')"
    echo ":::  -p,--password        Password for the Client (no default)"
    echo ":::  -d,--days            Expire the certificate after specified number of days (default: 1080)"
    echo ":::  -b,--bitwarden       Create and save a client through Bitwarden"
    echo ":::  -i,--iOS             Generate a certificate that leverages iOS keychain"
    echo ":::  -o,--ovpn            Regenerate a .ovpn config file for an existing client"
    echo ":::  -h,--help            Show this help dialog"
}

if [ -z "$HELP_SHOWN" ]; then
    helpFunc
    echo
    echo "HELP_SHOWN=1" >> "$setupVars"
fi

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
            if [ "$TWO_POINT_FOUR" -ne 1 ]; then
                iOS=1
            else
               echo "Sorry, can't generate iOS-specific configs for ECDSA certificates"
               echo "Generate traditional certificates using 'pivpn -a' or reinstall PiVPN without opting in for OpenVPN 2.4 features"
               exit 1
            fi
            ;;
        -h|--help)
            helpFunc
            exit 0
            ;;
        nopass)
            NO_PASS="1"
            ;;
        -b|--bitwarden)
            if command -v bw > /dev/null; then
                BITWARDEN="2"
            else
               echo "Bitwarden not found, please install bitwarden"
               exit 1
            fi

            ;;
        -o|--ovpn)
            GENOVPNONLY=1
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
    SESSION_KEY=$(bw login --raw)
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
    PASSWD=$(bw generate -usln --length $LENGTH)
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
    PASSWD_UNESCAPED="${PASSWD}"
    PASSWD=$(echo -n ${PASSWD} | sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e 's/\$/\\\$/g' -e 's/!/\\!/g' -e 's/\./\\\./g' -e "s/'/\\\'/g" -e 's/"/\\"/g' -e 's/\*/\\\*/g' -e 's/\@/\\\@/g' -e 's/\#/\\\#/g' -e 's/£/\\£/g' -e 's/%/\\%/g' -e 's/\^/\\\^/g' -e 's/\&/\\\&/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/-/\\-/g' -e 's/_/\\_/g' -e 's/\+/\\\+/g' -e 's/=/\\=/g' -e 's/\[/\\\[/g' -e 's/\]/\\\]/g' -e 's/;/\\;/g' -e 's/:/\\:/g' -e 's/|/\\|/g' -e 's/</\\</g' -e 's/>/\\>/g' -e 's/,/\\,/g' -e 's/?/\\?/g' -e 's/~/\\~/g' -e 's/{/\\{/g' -e 's/}/\\}/g')

    #Build the client key and then encrypt the key

    expect << EOF
    set timeout -1
    set env(EASYRSA_CERT_EXPIRE) "${DAYS}"
    spawn ./easyrsa build-client-full "${NAME}"
    expect "Enter PEM pass phrase" { sleep 0.1; send -- "${PASSWD}\r" }
    expect "Verifying - Enter PEM pass phrase" { sleep 0.1; send -- "${PASSWD}\r" }
    expect eof
EOF
    cd pki || exit

}

#make sure ovpns dir exists
if [ ! -d "$install_home/ovpns" ]; then
    mkdir "$install_home/ovpns"
    chown "$install_user":"$install_user" "$install_home/ovpns"
    chmod 0750 "$install_home/ovpns"
fi

#bitWarden
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

if [[ "${NAME}" =~ ^[0-9]+$ ]]; then
    echo "Names cannot be integers."
    exit 1
fi

if [[ -z "${NAME}" ]]; then
    echo "You cannot leave the name blank."
    exit 1
fi

if [ "${GENOVPNONLY}" == "1" ]; then
    # Generate .ovpn configuration file
    cd /etc/openvpn/easy-rsa/pki || exit
else
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

    #Finally, append the tls Private Key
    echo "<tls-auth>"
    cat "${TA}"
    echo "</tls-auth>"

	} > "${NAME}${FILEEXT}"

	# Copy the .ovpn profile to the home directory for convenient remote access

	printf "========================================================\n"
	printf "Generating an .ovpn12 file for use with iOS devices\n"
	printf "Please remember the export password\n"
	printf "as you will need this import the certificate on your iOS device\n"
	printf "========================================================\n"
	openssl pkcs12 -passin pass:"$PASSWD_UNESCAPED" -export -in "issued/${NAME}${CRT}" -inkey "private/${NAME}${KEY}" -certfile ${CA} -name "${NAME}" -out "$install_home/ovpns/$NAME.ovpn12"
	chown "$install_user":"$install_user" "$install_home/ovpns/$NAME.ovpn12"
    chmod 640 "$install_home/ovpns/$NAME.ovpn12"
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
    if [ "$TWO_POINT_FOUR" -eq 1 ]; then
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

cidrToMask(){
	# Source: https://stackoverflow.com/a/20767392
	set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
	[ $1 -gt 1 ] && shift $1 || shift
	echo ${1-0}.${2-0}.${3-0}.${4-0}
}

NET_REDUCED="${pivpnNET::-2}"

# Find an unused number for the last octet of the client IP
for i in {2..254}; do
    # find returns 0 if the folder is empty, so we create the 'ls -A [...]'
    # exception to stop at the first static IP (10.8.0.2). Otherwise it would
    # cycle to the end without finding and available octet.
    if [ -z "$(ls -A /etc/openvpn/ccd)" ] || ! find /etc/openvpn/ccd -type f -exec grep -q "${NET_REDUCED}.${i}" {} +; then
        COUNT="${i}"
        echo "ifconfig-push ${NET_REDUCED}.${i} $(cidrToMask "$subnetClass")" >> /etc/openvpn/ccd/"${NAME}"
        break
    fi
done

if [ -f /etc/pivpn/hosts.openvpn ]; then
    echo "${NET_REDUCED}.${COUNT} ${NAME}.pivpn" >> /etc/pivpn/hosts.openvpn
    if killall -SIGHUP pihole-FTL; then
        echo "::: Updated hosts file for Pi-hole"
    else
        echo "::: Failed to reload pihole-FTL configuration"
    fi
fi

# Copy the .ovpn profile to the home directory for convenient remote access
cp "/etc/openvpn/easy-rsa/pki/$NAME$FILEEXT" "$install_home/ovpns/$NAME$FILEEXT"
chown "$install_user":"$install_user" "$install_home/ovpns/$NAME$FILEEXT"
chmod 640 "/etc/openvpn/easy-rsa/pki/$NAME$FILEEXT"
chmod 640 "$install_home/ovpns/$NAME$FILEEXT"
printf "\n\n"
printf "========================================================\n"
printf "\e[1mDone! %s successfully created!\e[0m \n" "$NAME$FILEEXT"
printf "%s was copied to:\n" "$NAME$FILEEXT"
printf "  %s/ovpns\n" "$install_home"
printf "for easy transfer. Please use this profile only on one\n"
printf "device and create additional profiles for other devices.\n"
printf "========================================================\n\n"
