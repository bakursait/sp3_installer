#!/bin/bash

# Export Variables:
MAIN_DIRECTORY_LOCATION="$(cd "$(dirname "$0")" && pwd)"
source "$MAIN_DIRECTORY_LOCATION/script_variables.sh"


# Ensure non-interactive mode for apt
export DEBIAN_FRONTEND=noninteractive

#ensure the current user has the full 
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER


usage(){
    echo "Usage: $0 {devstack|shibsp}"
    echo "You must specify at least one option to run the script."
    exit 1
}


# Setup Devstack:
#source "$MAIN_DIRECTORY_LOCATION/setup_devstack.sh"


setup_devstack() {
    # Step 1: Add stack user
    if ! id -u $STACK_USER >/dev/null 2>&1; then
	echo "Adding stack user..."
	sudo useradd -s /bin/bash -d $DEVSTACK_HOME -m $STACK_USER
    else
	echo "User ${STACK_USER} already exists."
    fi
    
    
    # Step 2: Set the stack user's home directory executable by ALL
    echo "Setting home directory permissions for $STACK_USER..."
    sudo  chmod a+x $DEVSTACK_HOME
    
    # Step 3: Give stack user sudo privileges
    if [ ! -f /etc/sudoers.d/$STACK_USER ]; then
	echo "Granting sudo privileges to $STACK_USER..."
	echo "$STACK_USER ALL=(ALL) NOPASSWD: ALL" | sudo  tee /etc/sudoers.d/$STACK_USER
	#    sudo chmod 0440 /etc/sudoers.d/$STACK_USER
    else
	echo "Sudo privileges for $STACK_USER already set."
    fi
    
    # Step 4: Switch to stack user and execute the following as stack
    echo "Switching to $STACK_USER and setting up DevStack..."
    sudo -u $STACK_USER bash <<EOF
cd $DEVSTACK_HOME

# Step 5: Clone DevStack repository
if [ ! -d devstack ]; then
    echo "Cloning DevStack repository..."
    git clone https://opendev.org/openstack/devstack -b $DEVSTACK_BRANCH
else
    echo "DevStack repository already cloned."
fi

# Step 6: Access the DevStack directory
cd devstack

# Step 7: Copy sample local.conf
echo "Setting up local.conf..."
cp samples/local.conf .


# Step 8: Configure local.conf
sed -i 's/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$ADMIN_PASSWORD/' local.conf
sed -i 's/^DATABASE_PASSWORD=.*/DATABASE_PASSWORD=\$ADMIN_PASSWORD/' local.conf
sed -i 's/^RABBIT_PASSWORD=.*/RABBIT_PASSWORD=\$ADMIN_PASSWORD/' local.conf
sed -i 's/^SERVICE_PASSWORD=.*/SERVICE_PASSWORD=\$ADMIN_PASSWORD/' local.conf
sed -i 's/^#HOST_IP=.*/HOST_IP=$HOST_IP/' local.conf
sed -i 's/^HOST_IP=.*/HOST_IP=$HOST_IP/g' local.conf


# Step 9: Install DevStack
echo "Starting DevStack installation. This might take some time..."
./stack.sh || { echo "DevStack installation failed"; exit 1; }
EOF

    # Step 10: Test Accessing Horizon
    echo "DevStack installation complete!"
    echo "You can access the Horizon dashboard at: http://$HOST_IP/dashboard"
}




# Function to set up Shibboleth SP
#source "$MAIN_DIRECTORY_LOCATION/setup_shib_sp.sh"
# Include the Shibboleth SP setup function
install_shib_sp() {
    echo "Starting installation of Shibboleth SP..."

    # Step 1: Update and upgrade the system
    echo "Updating and upgrading system packages..."
    sudo apt update && sudo apt-get upgrade -y --no-install-recommends

    # Step 2: Install required packages
    echo "Installing required packages..."
    sudo apt install -y ca-certificates emacs openssl

    # Step 3: Install Shibboleth SP
    echo "Installing Shibboleth SP and related packages..."
    sudo apt install -y apache2 libapache2-mod-shib ntp --no-install-recommends

    # Step 4: Enable Shibboleth module in Apache
    echo "Enabling Shibboleth module in Apache..."
    sudo a2enmod shib
    sudo systemctl restart apache2.service

    echo "Shibboleth SP installation complete!"
}

configure_shib_sp() {
    echo "Starting Shibboleth SP configuration..."

    # Define variables
    SP_ENTITY_ID="http://devstack.sait.$(uuidgen)/shibboleth"
    IDP_ENTITY_ID="https://idp.bakursait.cloud/idp/shibboleth"
    IDP_METADATA_URL="https://idp.bakursait.cloud/idp/shibboleth"
    SP_METADATA_FILE="/etc/shibboleth/devstack.sait.$(uuidgen)-metadata.xml"

    # Step 1: Verify shibd service status (expect errors initially)
    echo "Testing Shibboleth daemon (expected errors)..."
    sudo shibd -t || echo "Errors expected at this stage."

    # Step 2: Generate keys for SP communication
    echo "Generating SP signing keys..."
    sudo shib-keygen -u _shibd -g _shibd -y 30 -e "$SP_ENTITY_ID" -n sp-signing -f

    echo "Generating SP encryption keys..."
    sudo shib-keygen -u _shibd -g _shibd -y 30 -e "$SP_ENTITY_ID" -n sp-encrypt -f

    # Step 3: Test shibd configuration
    echo "Testing Shibboleth daemon after key generation..."
    sudo shibd -t || { echo "shibd configuration failed. Check logs."; exit 1; }

    # Step 4: Restart services
    echo "Restarting Shibboleth daemon and Apache2..."
    sudo systemctl restart shibd.service
    sudo systemctl restart apache2.service

    # Step 5: Update /etc/shibboleth/shibboleth2.xml
    echo "Updating /etc/shibboleth/shibboleth2.xml with SP EntityID..."
    sudo sed -i "s|entityID=\".*\"|entityID=\"$SP_ENTITY_ID\"|g" /etc/shibboleth/shibboleth2.xml

    echo "Configuring <Sessions> directive..."
    sudo sed -i '/<Sessions/s|handlerSSL=".*"|handlerSSL="false"|g' /etc/shibboleth/shibboleth2.xml
    sudo sed -i '/<Sessions/s|cookieProps=".*"|cookieProps="http"|g' /etc/shibboleth/shibboleth2.xml

    echo "Adding IdP entityID to <SSO> directive..."
    sudo sed -i "s|<SSO entityID=\".*\">|<SSO entityID=\"$IDP_ENTITY_ID\">|g" /etc/shibboleth/shibboleth2.xml

    echo "Adding IdP metadata URL to <MetadataProvider>..."
    sudo sed -i "/<MetadataProvider/s|url=\".*\"|url=\"$IDP_METADATA_URL\"|g" /etc/shibboleth/shibboleth2.xml
    sudo sed -i "/<MetadataProvider/s|backingFilePath=\".*\"|backingFilePath=\"${SP_METADATA_FILE}\"|g" /etc/shibboleth/shibboleth2.xml

    # Step 6: Restart services to apply changes
    echo "Restarting services to apply changes..."
    sudo systemctl restart shibd.service
    sudo systemctl restart apache2.service
    sudo shibd -t || { echo "shibd configuration test failed. Check logs."; exit 1; }

    # Step 7: Generate SP metadata
    echo "Generating SP metadata..."
    sudo wget "http://192.168.4.100/Shibboleth.sso/Metadata" -O "$SP_METADATA_FILE"

    # Step 8: Update attribute-map.xml (example: map attributes as needed)
    echo "Allowing mapped attributes in /etc/shibboleth/attribute-map.xml..."
    sudo sed -i '/attribute-map.xml/s|<!--<Attribute name=".*"/>-->|<Attribute name="eppn"/>|g' /etc/shibboleth/attribute-map.xml

    echo "Shibboleth SP configuration complete!"
    echo "SP metadata available at $SP_METADATA_FILE"
}





if [[ $# -eq 0 ]]; then
    usage
fi

# Execute the requested functions:
for option in "$@"; do
    case $option in
	devstack)
	#setup_devstack
	#usage
	    ;;
	shibsp)
	    setup_shib_sp
	    ;;
	*)
	    echo "Invalid option: $option"
	    usage
	    ;;
    esac
done

