#!/bin/bash
# Create OVPN Client
# Default Variable Declarations
DEFAULT="Default.txt"
FILEEXT=".ovpn"
CRT=".crt"
OKEY=".key"
KEY=".3des.key"
CA="ca.crt"
TA="ta.key"
INSTALL_USER=$(cat /etc/pivpn/INSTALL_USER)

# Functions def

function keynoPASS() {

    # Override key def
    KEY=".key"

    #Build the client key
    expect << EOF
    spawn ./build-key "$NAME"
    expect "Country Name" { send "\r" }
    expect "State or Province Name" { send "\r" }
    expect "Locality Name" { send "\r" }
    expect "Organization Name" { send "\r" }
    expect "Organizational Unit" { send "\r" }
    expect "Common Name" { send "\r" }
    expect "Name" { send "\r" }
    expect "Email Address" { send "\r" }
    expect "challenge password" { send "\r" }
    expect "optional company name" { send "\r" }
    expect "Sign the certificate" { send "y\r" }
    expect "commit" { send "y\r" }
    expect eof
EOF

    cd keys || exit

}

function keyPASS() {

    stty -echo
    while true
    do
        printf "Enter the password for the Client:  "
        read -r PASSWD
        printf "\n"
        printf "Enter the password again to verify:  "
        read -r PASSWD2
        printf "\n"
        [ "$PASSWD" = "$PASSWD2" ] && break
        printf "Passwords do not match! Please try again.\n"
    done
    stty echo
    if [[ -z "$PASSWD" ]]; then
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

    #Build the client key and then encrypt the key

    expect << EOF
    spawn ./build-key-pass "$NAME"
    expect "Enter PEM pass phrase" { send "$PASSWD\r" }
    expect "Verifying - Enter PEM pass phrase" { send "$PASSWD\r" }
    expect "Country Name" { send "\r" }
    expect "State or Province Name" { send "\r" }
    expect "Locality Name" { send "\r" }
    expect "Organization Name" { send "\r" }
    expect "Organizational Unit" { send "\r" }
    expect "Common Name" { send "\r" }
    expect "Name" { send "\r" }
    expect "Email Address" { send "\r" }
    expect "challenge password" { send "\r" }
    expect "optional company name" { send "\r" }
    expect "Sign the certificate" { send "y\r" }
    expect "commit" { send "y\r" }
    expect eof
EOF

    cd keys || exit

    expect << EOF
    spawn openssl rsa -in "$NAME$OKEY" -des3 -out "$NAME$KEY"
    expect "Enter pass phrase for" { send "$PASSWD\r" }
    expect "Enter PEM pass phrase" { send "$PASSWD\r" }
    expect "Verifying - Enter PEM pass" { send "$PASSWD\r" }
    expect eof
EOF
}

printf "Enter a Name for the Client:  "
read -r NAME

if [[ "$NAME" =~ [^a-zA-Z0-9] ]]; then
    echo "Name can only contain alphanumeric characters"
    exit 1
fi

if [[ -z "$NAME" ]]; then
    echo "You cannot leave the name blank"
    exit 1
fi

cd /etc/openvpn/easy-rsa || exit
source /etc/openvpn/easy-rsa/vars

if [[ "$@" =~ "nopass" ]]; then
    keynoPASS
else
    keyPASS
fi

#1st Verify that clients Public Key Exists
if [ ! -f "$NAME$CRT" ]; then
    echo "[ERROR]: Client Public Key Certificate not found: $NAME$CRT"
    exit
fi
echo "Client's cert found: $NAME$CRT"

#Then, verify that there is a private key for that client
if [ ! -f "$NAME$KEY" ]; then
    echo "[ERROR]: Client 3des Private Key not found: $NAME$KEY"
    exit
fi
echo "Client's Private Key found: $NAME$KEY"

#Confirm the CA public key exists
if [ ! -f "$CA" ]; then
    echo "[ERROR]: CA Public Key not found: $CA"
    exit
fi
echo "CA public Key found: $CA"

#Confirm the tls-auth ta key file exists
if [ ! -f "$TA" ]; then
    echo "[ERROR]: tls-auth Key not found: $TA"
    exit
fi
echo "tls-auth Private Key found: $TA"

#Ready to make a new .ovpn file
{
    # Start by populating with the default file
    cat "$DEFAULT"

    #Now, append the CA Public Cert
    echo "<ca>"
    cat "$CA"
    echo "</ca>"

    #Next append the client Public Cert
    echo "<cert>"
    sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' < "$NAME$CRT"
    echo "</cert>"

    #Then, append the client Private Key
    echo "<key>"
    cat "$NAME$KEY"
    echo "</key>"

    #Finally, append the TA Private Key
    echo "<tls-auth>"
    cat "$TA"
    echo "</tls-auth>"
} > "$NAME$FILEEXT"

# Copy the .ovpn profile to the home directory for convenient remote access
cp "/etc/openvpn/easy-rsa/keys/$NAME$FILEEXT" "/home/$INSTALL_USER/ovpns/$NAME$FILEEXT"
chown "$INSTALL_USER" "/home/$INSTALL_USER/ovpns/$NAME$FILEEXT"
printf "\n\n"
printf "========================================================\n"
printf "\e[1mDone! %s successfully created!\e[0m \n" "$NAME$FILEEXT"
printf "%s was copied to:\n" "$NAME$FILEEXT"
printf "  /home/%s/ovpns\n" "$INSTALL_USER"
printf "for easy transfer.\n"
printf "========================================================\n\n"
