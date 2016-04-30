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

printf "Enter a Name for the Client:  "
read NAME

stty -echo
while true
do
    printf "Enter the password for the Client:  "
    read PASSWD
    printf "\n"
    printf "Enter the password again to verify:  "
    read PASSWD2
    printf "\n"
    [ "$PASSWD" = "$PASSWD2" ] && break
    printf "Passwords do not match! Please try again.\n"
done
stty echo

#Build the client key and then encrypt the key
cd /etc/openvpn/easy-rsa
source /etc/openvpn/easy-rsa/vars

expect << EOF
spawn ./build-key-pass $NAME
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

cd keys

expect << EOF
spawn openssl rsa -in $NAME$OKEY -des3 -out $NAME$KEY
expect "Enter pass phrase for" { send "$PASSWD\r" }
expect "Enter PEM pass phrase" { send "$PASSWD\r" }
expect "Verifying - Enter PEM pass" { send "$PASSWD\r" }
expect eof
EOF
 
#1st Verify that clients Public Key Exists 
if [ ! -f $NAME$CRT ]; then 
 echo "[ERROR]: Client Public Key Certificate not found: $NAME$CRT" 
 exit 
fi 
echo "Client's cert found: $NAME$CRT" 
 
#Then, verify that there is a private key for that client 
if [ ! -f $NAME$KEY ]; then 
 echo "[ERROR]: Client 3des Private Key not found: $NAME$KEY" 
 exit 
fi 
echo "Client's Private Key found: $NAME$KEY"
 
#Confirm the CA public key exists 
if [ ! -f $CA ]; then 
 echo "[ERROR]: CA Public Key not found: $CA" 
 exit 
fi 
echo "CA public Key found: $CA" 
 
#Confirm the tls-auth ta key file exists 
if [ ! -f $TA ]; then 
 echo "[ERROR]: tls-auth Key not found: $TA" 
 exit 
fi 
echo "tls-auth Private Key found: $TA" 
 
#Ready to make a new .ovpn file - Start by populating with the 
#default file 
cat $DEFAULT > $NAME$FILEEXT 
 
#Now, append the CA Public Cert 
echo "<ca>" >> $NAME$FILEEXT 
cat $CA >> $NAME$FILEEXT 
echo "</ca>" >> $NAME$FILEEXT
 
#Next append the client Public Cert 
echo "<cert>" >> $NAME$FILEEXT 
cat $NAME$CRT | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' >> $NAME$FILEEXT 
echo "</cert>" >> $NAME$FILEEXT 
 
#Then, append the client Private Key 
echo "<key>" >> $NAME$FILEEXT 
cat $NAME$KEY >> $NAME$FILEEXT 
echo "</key>" >> $NAME$FILEEXT 
 
#Finally, append the TA Private Key 
echo "<tls-auth>" >> $NAME$FILEEXT 
cat $TA >> $NAME$FILEEXT 
echo "</tls-auth>" >> $NAME$FILEEXT 

# Copy the .ovpn profile to the home directory for convenient remote access
cp /etc/openvpn/easy-rsa/keys/$NAME$FILEEXT /home/$INSTALL_USER/ovpns/$NAME$FILEEXT
chown $INSTALL_USER /home/$INSTALL_USER/ovpns/$NAME$FILEEXT
printf "\n\n"
printf "========================================================\n"
printf "\e[1mDone! $NAME$FILEEXT successfully created!\e[0m \n"
printf "$NAME$FILEEXT was copied to:\n"
printf "  /home/$INSTALL_USER/ovpns\n"
printf "for easy transfer.\n"
printf "========================================================\n\n"
