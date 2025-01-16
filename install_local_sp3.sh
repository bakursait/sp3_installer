#!/bin/bash

# Export Variables:
MAIN_DIRECTORY_LOCATION="$(cd "$(dirname "$0")" && pwd)"
SUPPORTING_FILES="${MAIN_DIRECTORY_LOCATION}/sp3_supporting_files"
# Define variables
RANDOM_UUID="$(uuidgen)"
SP_ENTITY_ID="http://devstack.sait.${RANDOM_UUID}/shibboleth"
SP_METADATA_FILE="/etc/shibboleth/devstack.sait.${RANDOM_UUID}-metadata.xml"
SHIBBOLETH_XML="/etc/shibboleth/shibboleth2.xml"

DEVSTACK_BRANCH="stable/2023.2"
STACK_USER="stack"
DEVSTACK_HOME="/opt/stack"
HOST_IP="192.168.4.121"
ADMIN_PASSWORD="secret"


KEYSTONE_MAIN_CONF="/etc/keystone/keystone.conf"
HORIZON_SETTINGS_FILE="~/horizon/openstack_dashboard/local/local_settings.py"



# Ensure non-interactive mode for apt
export DEBIAN_FRONTEND=noninteractive

#ensure the current user has the full 
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER


usage(){
    echo "Usage: $0 {devstack|shibsp|configure_shibsp}"
    echo "You must specify at least one option to run the script."
    exit 1
}


DEBUG=0
if [[ "$1" == "--debug" ]]; then
    DEBUG=1
    shift
fi

log_debug() {
    if [[ $DEBUG -eq 1 ]]; then
        echo "$@"
    fi
}

log_debug "Debugging enabled"

# Setup Devstack:
#source "$MAIN_DIRECTORY_LOCATION/setup_devstack.sh"


add_idps(){
    echo "Adding IdP metadata from CSV file..."
    local idp_csv_file="${SUPPORTING_FILES}/idp_list.csv"
    cat $idp_csv_file
    # Check if the CSV file exists
    if [[ ! -f "$idp_csv_file" ]]; then
        echo "Error: $idp_csv_file not found."
        exit 1
    fi
    # Read the CSV file line by line, skipping the header
    tail -n +2 "$idp_csv_file" | while IFS=";" read -r idp_entity_id idp_backup_file idp_keystone_name idp_horizon_name idp_mapping_rules; do
	echo "Processing IdP: $idp_entity_id"
	if grep -q "<MetadataProvider .* url=\"$idp_entity_id\"" "${SHIBBOLETH_XML}"; then
	    echo "The IdP: \"$idp_entity_id\", is alredy register in: \"${SHIBBOLETH_XML}\"... Skip it"
	    continue
	fi
	# Use sed to add the MetadataProvider entry after <Errors />
	# add validate=\"true\"
	sudo sed -i "/<Errors/s|/>|/>\n\n    <MetadataProvider type=\"XML\" validate=\"true\" url=\"$idp_entity_id\" backingFilePath=\"$idp_backup_file\" maxRefreshDelay=\"720000\" />|" "${SHIBBOLETH_XML}" || { echo "failed adding idps. Check logs."; exit 1; }
    done
}


validate_xml_file(){
    xml_file=$1
    # Validate the XML file
    if xmlstarlet val -e "$xml_file"; then
	echo "XML validation passed for the file: ${xml_file}. Metadata added successfully."
    else
	echo "XML validation failed for the file: ${xml_file}. Check the file for errors."
	exit 1
    fi
}

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
    sudo apt install -y ca-certificates emacs openssl xmlstarlet

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

    # Backup the original Shibboleth XML file
    sudo cp "$SHIBBOLETH_XML" "${SHIBBOLETH_XML}.bak"
    sudo chown _shibd: "${SHIBBOLETH_XML}.bak"


    if [[ ! -d "$SUPPORTING_FILES" ]]; then
	echo "Error: Supporting files directory ${SUPPORTING_FILES} does not exist."
	exit 1
    fi
    

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
    sudo xmlstarlet ed --inplace -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
         -u '//_:ApplicationDefaults/@entityID' -v "${SP_ENTITY_ID}" /etc/shibboleth/shibboleth2.xml
    
    echo "Configuring <Sessions> directive..."
    sudo xmlstarlet ed --inplace -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
        -u '//_:Sessions/@handlerSSL' -v 'false' /etc/shibboleth/shibboleth2.xml
    sudo xmlstarlet ed --inplace -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
         -u '//_:Sessions/@cookieProps' -v 'http' /etc/shibboleth/shibboleth2.xml



    

    # Step 6: Add IdP metadata from CSV file
    add_idps
    

    validate_xml_file "$SHIBBOLETH_XML"

    echo "Shibboleth SP configuration complete!"

    # Step 7: Restart services to apply changes
    echo "Restarting services to apply changes..."
    sudo systemctl restart shibd.service
    sudo systemctl restart apache2.service

    # Step 8: Test shibd configuration
    echo "Testing Shibboleth daemon configuration..."
    sudo shibd -t || { echo "shibd configuration test failed. Check logs."; exit 1; }

    echo "Shibboleth SP configuration complete!"
    sudo wget "http://${HOST_IP}/Shibboleth.sso/Metadata" -O "${SP_METADATA_FILE}"
    sudo chown _shibd: "${SP_METADATA_FILE}"
    echo "SP metadata available at ${SP_METADATA_FILE}"

    # Step 9: copy attribute-map.xml file to the shibboleth working directory:
    sudo cp "${SUPPORTING_FILES}/attribute-map.xml" /etc/shibboleth/


    configure_keystone_debugging
}



# Function to enable debugging for Keystone
configure_keystone_debugging() {
    # we  Must Run it as user: stack
    echo "Configuring Keystone debugging..."

    if [ -z "$STACK_USER" ] || [ -z "$KEYSTONE_MAIN_CONF" ]; then
	echo "Error: STACK_USER or KEYSTONE_MAIN_CONF is not defined."
	exit 1
    fi
    
    
    # switch to the stack usre and perform the operations:
    sudo -i -u $STACK_USER bash <<EOF
cd $DEVSTACK_HOME || { echo "Error: Cannot access $DEVSTACK_HOME"; exit 1; }

#    # Check if the configuration file exists
#    if [ ! -f "$KEYSTONE_MAIN_CONF" ]; then
#        echo "Error: Configuration file $KEYSTONE_MAIN_CONF does not exist."
#        exit 1
#    fi


    for setting in "debug = True" "insecure_debug = True" "log_dir = /var/log/keystone" "log_file = keystone.log"; do
	key=\$(echo "\$setting" | awk -F'=' '{print \$1}' | xargs)
	value=\$(echo "\$setting" | awk -F'=' '{print \$2}' | xargs)
	if ! grep -q "^\s*\${key}\s*=\s*\${value}" "$KEYSTONE_MAIN_CONF"; then
	    echo "Adding '\${setting}' to [DEFAULT] section."
            sudo sed -i "/^\[DEFAULT\]/a \${setting}" "$KEYSTONE_MAIN_CONF"
	else
	    echo "'\${setting}' is already configured."
	fi
    done  
    
    
    # add [log] section and its contents:
    grep -q '^\[log\]' "$KEYSTONE_MAIN_CONF" || echo -e "\n\n[log]" | sudo tee -a "$KEYSTONE_MAIN_CONF"
    
    # Add or update the level setting in the [log] section
    if ! grep -q '^\s*level\s*=\s*DEBUG' "$KEYSTONE_MAIN_CONF"; then
        echo "Adding 'level = DEBUG' to [log] section."
        sudo sed -i '/^\[log\]/a level = DEBUG' "$KEYSTONE_MAIN_CONF"
    else
        echo "'level = DEBUG' is already configured in [log] section."
    fi

    sudo chown stack:stack "$KEYSTONE_MAIN_CONF"
    
    # Create log directory if not exists
    sudo mkdir -p /var/log/keystone
    sudo chown -R stack:stack /var/log/keystone

    # Restart Keystone service
    echo "Restarting Keystone service..."
    sudo systemctl restart devstack@keystone.service

    # Validate service status
    if systemctl is-active --quiet devstack@keystone.service; then
        echo "Keystone service restarted successfully."
    else
        echo "Error: Keystone service failed to restart. Check the logs for details."
    fi

EOF


    
    
    echo "Keystone debugging configured."
}





if [[ $# -eq 0 ]]; then
    usage
fi

# Execute the requested functions:
for option in "$@"; do
    case $option in
        devstack)
            setup_devstack
            ;;
        shibsp)
            install_shib_sp
            ;;
        configure_shibsp)
            configure_shib_sp
            ;;
        *)
            echo "Invalid option: $option"
            usage
            ;;
    esac
done

