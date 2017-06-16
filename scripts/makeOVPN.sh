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
INSTALL_HOME=$(eval echo ~${INSTALL_USER})

# Functions def

function keynoPASS() {

    #Build the client key
    expect << EOF
    set timeout -1
    spawn ./easyrsa build-client-full "${NAME}" nopass
    expect eof
EOF

    cd pki || exit

}

function keyPASS() {

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
    spawn ./easyrsa build-client-full "${NAME}"
    expect "Enter PEM pass phrase" { send "${PASSWD}\r" }
    expect "Verifying - Enter PEM pass phrase" { send "${PASSWD}\r" }
    expect eof
EOF

    cd pki || exit

}

printf "Enter a Name for the Client:  "
read -r NAME

if [[ "${NAME}" =~ [^a-zA-Z0-9] ]]; then
    echo "Name can only contain alphanumeric characters."
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

cd /etc/openvpn/easy-rsa || exit

if [[ "$@" =~ "nopass" ]]; then
    keynoPASS
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

#Confirm the tls-auth ta key file exists
if [ ! -f "${TA}" ]; then
    echo "[ERROR]: tls-auth Key not found: $TA"
    exit
fi
echo "tls-auth Private Key found: $TA"

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

    #Finally, append the TA Private Key
    echo "<tls-auth>"
    cat "${TA}"
    echo "</tls-auth>"
} > "${NAME}${FILEEXT}"

# Copy the .ovpn profile to the home directory for convenient remote access
cp "/etc/openvpn/easy-rsa/pki/$NAME$FILEEXT" "$INSTALL_HOME/ovpns/$NAME$FILEEXT"
chown "$INSTALL_USER" "$INSTALL_HOME/ovpns/$NAME$FILEEXT"
printf "\n\n"
printf "========================================================\n"
printf "\e[1mDone! %s successfully created!\e[0m \n" "$NAME$FILEEXT"
printf "%s was copied to:\n" "$NAME$FILEEXT"
printf "  %s/ovpns\n" "$INSTALL_HOME"
printf "for easy transfer.\n"
printf "========================================================\n\n"
