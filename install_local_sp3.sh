#!/bin/bash

# Export Variables:
MAIN_DIRECTORY_LOCATION="$(cd "$(dirname "$0")" && pwd)"
SUPPORTING_FILES="${MAIN_DIRECTORY_LOCATION}/sp3_supporting_files"
# Define variables
SHIBBOLETH_XML="/etc/shibboleth/shibboleth2.xml"

DEVSTACK_BRANCH="stable/2023.2"
STACK_USER="stack"
STACK_USER_HOME="/opt/${STACK_USER}"
DEVSTACK_HOME="${STACK_USER_HOME}/devstack"
HOST_IP="192.168.4.121"
ADMIN_PASSWORD="secret"


KEYSTONE_MAIN_CONF="/etc/keystone/keystone.conf"
HORIZON_SETTINGS_FILE="~/horizon/openstack_dashboard/local/local_settings.py"



# Ensure non-interactive mode for apt
export DEBIAN_FRONTEND=noninteractive

#ensure the current user has the full 
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER


usage() {
    echo -e "\n\033[1;33mUsage:\033[0m $0 {option}"
    echo -e "\n\033[1;32mAvailable Options:\033[0m"
    echo -e "  \033[1;34mdevstack\033[0m                  Install and configure DevStack."
    echo -e "  \033[1;34mshibsp\033[0m                    Install and configure Shibboleth-SP."
    echo -e "  \033[1;34mconfigure_shibsp\033[0m          Configure Shibboleth-SP settings."
    echo -e "  \033[1;34mregister_idps\033[0m             Register IdPs from idp_list.csv file into shibboleth2.xml as MetadataProvider elements."
    echo -e "  \033[1;34mconfigure_keystone_debugging\033[0m Enable debugging for Keystone."
    echo -e "  \033[1;34mhorizon_websso\033[0m          Configure Horizon for WebSSO."
    echo -e "  \033[1;34mconfigure_keystone_cli\033[0m   Configure Keystone CLI settings."
    echo -e "  \033[1;34mconfigure_keystone_federation\033[0m Set up Keystone federation."
    echo -e "  \033[1;34mconfigure_keystone_apache\033[0m Configure Keystone Apache settings."
    echo -e "\n\033[1;31mError:\033[0m You must specify at least one valid option to run the script."
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

is_file_exist() {
    # Check if the CSV file exists
    if [[ -f "$1" ]]; then
        return 0  # File exists (success)
    else
        return 1  # File does not exist (failure)
    fi
}



# Function to check if a command exists
# $1: Command to check
# $2: Component name (for error message)
# $3: Dependency type ("independent" or "dependent")
check_command_exists() {
    local cmd="$1"
    local component_name="$2"
    local dependency_type="$3"

    if [ "$dependency_type" == "independent" ]; then
        if type "$cmd" >/dev/null 2>&1; then
            echo -e "\n\033[1;31mError:\033[0m $component_name is already installed or available. Exiting..."
            exit 1
        fi
    elif [ "$dependency_type" == "dependent" ]; then
        if ! type "$cmd" >/dev/null 2>&1; then
            echo -e "\n\033[1;31mError:\033[0m $component_name is NOT installed or available. Please install it first. Exiting..."
            exit 1
        fi
    else
        echo -e "\n\033[1;31mError:\033[0m Invalid dependency type provided to check_command_exists. Exiting..."
        exit 1
    fi
}



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
    tail -n +2 "$idp_csv_file" | while IFS=";" read -r fqdn idp_entity_id idp_backup_file idp_keystone_name idp_horizon_name idp_mapping_rules; do
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

register_idps(){
    check_command_exists "shibd" "Shibboleth-SP" "dependent"
    
    #Step 1: Add IdPs as <MetadataProvider .../> elements in /etc/shibboleth/shibboleth2.xml file:
    add_idps
    
    #Step 2: check the syntax of the file /etc/shibboleth/shibboleth2.xml:
    validate_xml_file "$SHIBBOLETH_XML"
    
    echo "Shibboleth SP configuration complete!"
    
    #Step 3: Restart the affected systems:
    echo "Restarting services to apply changes..."
    sudo systemctl restart shibd.service
    sudo systemctl restart apache2.service
    
    # Step 8: Test shibd configuration and to run over all the IdP <MetadataProvider .../> elements and get their Metadata cached at: /var/cache/shibboleth/:
    echo "Testing Shibboleth daemon configuration..."
    sudo shibd -t || { echo "shibd configuration test failed. Check logs."; exit 1; }

    echo -e "\n\033[1;31mInfo: to fully register the IdPs, consider running other functions in the list \"./install_local_sp3.sh <option>\"."
    echo -e "\n\033[1;31mNOTE: \033[0m Add the IdPs domain names with their IPs at the SP's /etc/hosts file and at all your network's /etc/hosts files"
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
    check_command_exists "openstack" "OpenStack CLI" "independent"
    
    # Step 1: Add stack user
    if ! id -u $STACK_USER >/dev/null 2>&1; then
	echo "Adding stack user..."
	sudo useradd -s /bin/bash -d $STACK_USER_HOME -m $STACK_USER
    else
	echo "User ${STACK_USER} already exists."
    fi
    
    
    # Step 2: Set the stack user's home directory executable by ALL
    echo "Setting home directory permissions for $STACK_USER..."
    sudo  chmod a+x $STACK_USER_HOME
    
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
cd $STACK_USER_HOME

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



    # Step 10.1: Update and upgrade the system
    echo "Updating and upgrading system packages..."
    sudo apt update && sudo apt-get upgrade -y --no-install-recommends

    # Step 10.2: Install required Access Control List (acl) package
    echo "Installing ACL package..."
    sudo apt install -y acl

    # Step 11: let the user: "$STACK_USER" have access to all required files in the original $USER's home directory
    sudo setfacl -R -m u:$STACK_USER:r-x "$HOME"
    sudo setfacl -R -d -m u:$STACK_USER:r-x "$HOME"

    sudo setfacl -R -m u:$STACK_USER:r-x "$MAIN_DIRECTORY_LOCATION"
    sudo setfacl -R -d -m u:$STACK_USER:r-x "$MAIN_DIRECTORY_LOCATION"

    
    # Step 12: Test Accessing Horizon
    echo "DevStack installation complete!"
    echo "You can access the Horizon dashboard at: http://$HOST_IP/dashboard"
}




# Function to set up Shibboleth SP
#source "$MAIN_DIRECTORY_LOCATION/setup_shib_sp.sh"
# Include the Shibboleth SP setup function
install_shib_sp() {
    # Check if Shibboleth-SP is already installed
    check_command_exists "shibd" "Shibboleth-SP" "independent"
    
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
    # check_dependency "SHIBSP_INSTALLED"
    check_command_exists "shibd" "Shibboleth-SP" "dependent"
    

    echo "Starting Shibboleth SP configuration..."
    local RANDOM_UUID="$(uuidgen)"
    local SP_ENTITY_ID="http://devstack.sait.${RANDOM_UUID}/shibboleth"
    local SP_METADATA_FILE="/etc/shibboleth/devstack.sait.${RANDOM_UUID}-metadata.xml"

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

    echo "Download the shibboleth-SP Metadata"
    sudo wget "http://${HOST_IP}/Shibboleth.sso/Metadata" -O "${SP_METADATA_FILE}"
    sudo chown _shibd: "${SP_METADATA_FILE}"
    echo "SP metadata available at ${SP_METADATA_FILE}"

    # Step 9: copy attribute-map.xml file to the shibboleth working directory:
    sudo cp "${SUPPORTING_FILES}/attribute-map.xml" /etc/shibboleth/

}



# Function to enable debugging for Keystone
configure_keystone_debugging() {
    # check_dependency "DEVSTACK_INSTALLED"
    check_command_exists "openstack" "OpenStack CLI" "dependent"
    
    # we  Must Run it as user: stack
    echo "Configuring Keystone debugging..."

    if [ -z "$STACK_USER" ] || [ -z "$KEYSTONE_MAIN_CONF" ]; then
	echo "Error: STACK_USER or KEYSTONE_MAIN_CONF is not defined."
	exit 1
    fi
    
    
    # switch to the stack usre and perform the operations:
    sudo -i -u $STACK_USER bash <<EOF
cd $STACK_USER_HOME || { echo "Error: Cannot access $STACK_USER_HOME"; exit 1; }

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


configure_horizon_websso(){
    # check_dependency "DEVSTACK_INSTALLED"
    check_command_exists "openstack" "OpenStack CLI" "dependent"
    

    echo "Configuring Horizon for SSO..."
    # sudo chown stack:stack "$MAIN_DIRECTORY_LOCATION/configure_horizon_websso.py"
    # sudo chmod 744 "$MAIN_DIRECTORY_LOCATION/configure_horizon_websso.py"

    sudo -i -u $STACK_USER bash <<EOF
cd $STACK_USER_HOME || { echo "Error: Cannot access $STACK_USER_HOME"; exit 1; }
python3 $MAIN_DIRECTORY_LOCATION/configure_horizon_websso.py
if [ $? -eq 0 ]; then
   echo "Horizon configuration completed successfully."
else
   echo "Error occurred during Horizon configuration."
   exit 1
fi
EOF
    sudo systemctl restart apache2.service
}


create_federation_resources_at_keystone_cli() {
    # check_dependency "DEVSTACK_INSTALLED"
    check_command_exists "openstack" "OpenStack CLI" "dependent"
    
    echo "Creating federation resources in Keystone..."

    local idp_csv_file="${SUPPORTING_FILES}/idp_list.csv"
    if ! is_file_exist $idp_csv_file; then
        echo "File ${$idp_csv_file} does not exist."
        exit 1
    fi


    # Ensure we are running as the stack user
    sudo -u "$STACK_USER" bash << EOF
    
    # Move to the DevStack directory
    cd "$DEVSTACK_HOME" || { echo "Error: Cannot access $DEVSTACK_HOME"; exit 1; }
    whoami
    pwd

    # Source OpenStack admin credentials
    source openrc admin admin

    # test if we can access the cloud resources:
    openstack image list

    # Read the IDP list from the CSV file
    idp_csv_file="$SUPPORTING_FILES/idp_list.csv"
    tail -n +2 "$idp_csv_file" | while IFS=";" read -r fqdn idp_entity_id idp_backup_file idp_keystone_name idp_horizon_name idp_mapping_rules; do
        echo "Processing Identity Provider: \$idp_keystone_name"

        # Step 1: Create the Identity Provider object
        if openstack identity provider list | grep -qw "\$idp_keystone_name"; then
            echo "Identity Provider '\$idp_keystone_name' already exists. Skipping creation."
        else
            openstack identity provider create "\$idp_keystone_name" --remote-id "\$idp_entity_id"
            echo "Identity Provider \"\$idp_keystone_name\" created."
        fi

        # Step 2: Create the mapping rules JSON file
        mapping_rules_file="/tmp/\${idp_mapping_rules}_rules.json"
        cat <<RULES > "\$mapping_rules_file"
[
  {
    "local": [
      {
        "user": {
          "name": "{0}"
        },
        "group": {
          "domain": {
            "name": "Default"
          },
          "name": "federated_users_\${idp_keystone_name}"
        }
      }
    ],
    "remote": [
      {
        "type": "REMOTE_USER"
      }
    ]
  }
]
RULES

        # Step 3: Create the mapping object
        if openstack mapping list | grep -qw "\$idp_mapping_rules"; then
            echo "Mapping \"\$idp_mapping_rules\" already exists. Skipping creation."
        else
            openstack mapping create "\$idp_mapping_rules" --rules "\$mapping_rules_file"
            echo "Mapping '\$idp_mapping_rules' created."
        fi

        # Step 4: Create the federated_users group if it doesn't exist
        if ! openstack group list | grep -qw "federated_users_\${idp_keystone_name}"; then
            openstack group create "federated_users_\${idp_keystone_name}"
            echo "Group \"federated_users_\${idp_keystone_name}\" created."
        else
            echo "Group \"federated_users_\${idp_keystone_name}\" already exists. Skipping creation."
        fi

        # Step 5: Create the federated_project project if it doesn't exist
        if ! openstack project list | grep -qw "federated_project_\${idp_keystone_name}"; then
            openstack project create "federated_project_\${idp_keystone_name}"
            echo "Project \"federated_project_\${idp_keystone_name}\" created."
        else
            echo "Project \"federated_project_\${idp_keystone_name}\" already exists. Skipping creation."
        fi

        # Step 6: Assign the member role to the federated_users group in the federated_project
        if ! openstack role assignment list --group "federated_users_\${idp_keystone_name}" --project "federated_project_\${idp_keystone_name}" | grep -qw "member"; then
            openstack role add --group "federated_users_\${idp_keystone_name}" --project "federated_project_\${idp_keystone_name}" member
            echo "Role 'member' assigned to group \"federated_users_\${idp_keystone_name}\" in project \"federated_project_\${idp_keystone_name}\"."
        else
            echo "Role 'member' already assigned to group \"federated_users_\${idp_keystone_name}\" in project \"federated_project_\${idp_keystone_name}\"."
        fi

        # Step 7: Create the federation protocol
        if openstack federation protocol list --identity-provider "\${idp_keystone_name}" | grep -qw "saml2"; then
            echo "Federation protocol 'saml2' for Identity Provider \"\$idp_keystone_name\" already exists. Skipping creation."
        else
            openstack federation protocol create saml2 --identity-provider "\${idp_keystone_name}" --mapping "\${idp_mapping_rules}"
            echo "Federation protocol 'saml2' created for Identity Provider \"\${idp_keystone_name}\"."
        fi

#         # Clean up temporary file
#         rm -f "$mapping_rules_file"

    done
EOF

    echo "Federation resources created successfully."
}


configure_keystone_federation(){
    # check_dependency "DEVSTACK_INSTALLED"
    check_command_exists "openstack" "OpenStack CLI" "dependent"
    
    echo "Configuring DevStack for SAML Federation..."

    # Define variables
    local keystone_conf="/etc/keystone/keystone.conf"
    local sso_template_source="/opt/stack/keystone/etc/sso_callback_template.html"
    local sso_template_target="/etc/keystone/sso_callback_template.html"
    local trusted_dashboard_url="http://$HOST_IP/dashboard/auth/websso/"
    local remote_id_attribute_conf_section="federation"      # saml2 OR federation


    if [[ "$remote_id_attribute_conf_section" != "saml2" && "$remote_id_attribute_conf_section" != "federation" ]]; then
        remote_id_attribute_conf_section="federation"
    fi

    # Modify Keystone configuration as root
    sudo bash <<EOF
    # Update [auth] methods
    if grep -q '^\[auth\]' "$keystone_conf"; then
        if grep -q '^methods' "$keystone_conf"; then
            sed -i 's/^methods\s*=.*/methods = password,token,saml2,openid/' "$keystone_conf"
        else
            sed -i '/^\[auth\]/a methods = password,token,saml2,openid' "$keystone_conf"
        fi
    else
        echo -e "\n\n[auth]\nmethods = password,token,saml2,openid" >> "$keystone_conf"
    fi

    # # Remove 'external' if it exists in methods
    # sed -i 's/,external//' "$keystone_conf"


    # Configure [saml2] or [federation] remote_id_attribute
    if grep -q '^\[$remote_id_attribute_conf_section\]' "$keystone_conf"; then
        if ! grep -q 'remote_id_attribute' "$keystone_conf"; then
            sed -i '/^\[$remote_id_attribute_conf_section\]/a remote_id_attribute = Shib-Identity-Provider' "$keystone_conf"
        fi
    else
        echo -e "\n\n[$remote_id_attribute_conf_section]\nremote_id_attribute = Shib-Identity-Provider" >> "$keystone_conf"
    fi


    # Add trusted_dashboard under [federation]
    if grep -q '^\[federation\]' "$keystone_conf"; then
        if ! grep -q 'trusted_dashboard' "$keystone_conf"; then
            sed -i "/^\[federation\]/a trusted_dashboard = $trusted_dashboard_url" "$keystone_conf"
        fi
    else
        echo -e "\n\n[federation]\ntrusted_dashboard = $trusted_dashboard_url" >> "$keystone_conf"
    fi
    
    

    # Add sso_callback_template
    if ! grep -q 'sso_callback_template' "$keystone_conf"; then
        sed -i "/^\[federation\]/a sso_callback_template = $sso_template_target" "$keystone_conf"
    fi

    # Copy the SSO callback template file
    if [ ! -f "$sso_template_target" ]; then
        cp "$sso_template_source" "$sso_template_target"
    fi

    # Change ownership and permissions
    chown stack:stack "$keystone_conf"
    chmod 600 "$keystone_conf"
EOF

    # Restart Keystone, Apache, and Shibboleth services
    echo "Restarting services..."
    sudo systemctl restart devstack@keystone.service
    sudo systemctl restart apache2.service
    sudo systemctl restart shibd.service

    echo "DevStack SAML federation configuration completed."
}









# Add fixed directives if not already present
add_fixed_directives() {
    echo "Adding fixed directives to Apache configuration if not present..."
    local KEYSTONE_APACHE_CONFIG_PATH="/etc/apache2/sites-available/keystone-wsgi-public.conf"
    local PROTOCOL="saml2"  # Protocol used for federation

    # Check and add "Proxypass Shibboleth.sso !" if not present
    if ! grep -q "Proxypass Shibboleth.sso !" "$KEYSTONE_APACHE_CONFIG_PATH"; then
        cat <<EOF >> "$KEYSTONE_APACHE_CONFIG_PATH"

# Fixed Directives
Proxypass Shibboleth.sso !

EOF
        echo "Fixed directive: \"Proxypass Shibboleth.sso !\" added."
    else
        echo "Fixed directive: \"Proxypass Shibboleth.sso !\" already present. Skipping."
    fi




    # Check and add "<Location /Shibboleth.sso>" block if not present
    if ! grep -q "<Location /Shibboleth.sso>" "$KEYSTONE_APACHE_CONFIG_PATH"; then
        cat <<EOF >> "$KEYSTONE_APACHE_CONFIG_PATH"

<Location /Shibboleth.sso>
   SetHandler shib
</Location>

EOF
        echo "Fixed directive: \"<Location /Shibboleth.sso>\" added."
    else
        echo "Fixed directive: \"<Location /Shibboleth.sso>\" already present. Skipping."
    fi


    # Check and add "<Location /identity/v3/auth/OS-FEDERATION/websso/$PROTOCOL>" block if not present
    if ! grep -q "<Location /identity/v3/auth/OS-FEDERATION/websso/$PROTOCOL>" "$KEYSTONE_APACHE_CONFIG_PATH"; then
        cat <<EOF >> "$KEYSTONE_APACHE_CONFIG_PATH"

<Location /identity/v3/auth/OS-FEDERATION/websso/$PROTOCOL>
    Require valid-user
    AuthType shibboleth
    ShibRequestSetting requireSession 1
    ShibExportAssertion off
    <IfVersion < 2.4>
        ShibRequireSession On
        ShibRequireAll On
    </IfVersion>
</Location>

EOF
        echo "Fixed directive: \"<Location /identity/v3/auth/OS-FEDERATION/websso/$PROTOCOL>\" added."
    else
        echo "Fixed directive: \"<Location /identity/v3/auth/OS-FEDERATION/websso/$PROTOCOL>\" already present. Skipping."
    fi

}

# Add IDP-specific directives if not already present
add_idp_directives() {
    echo "Adding IDP-specific directives to Apache configuration..."
    local IDP_LIST_FILE="$SUPPORTING_FILES/idp_list.csv"
    local KEYSTONE_APACHE_CONFIG_PATH="/etc/apache2/sites-available/keystone-wsgi-public.conf"
    local PROTOCOL="saml2"

    # Skip header and process each IDP
    tail -n +2 "$IDP_LIST_FILE" | while IFS=";" read -r fqdn idp_entity_id idp_backup_file idp_keystone_name idp_horizon_name idp_mapping_rules; do
        echo "Processing IDP: $idp_keystone_name"

        # Check if the IDP-specific directives already exist
        if ! grep -q "/identity/v3/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/auth" "$KEYSTONE_APACHE_CONFIG_PATH"; then
            cat <<CONF >> "$KEYSTONE_APACHE_CONFIG_PATH"

# Directive for $idp_keystone_name
<Location /identity/v3/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/auth>
    Require valid-user
    AuthType shibboleth
    ShibRequestSetting requireSession 1
    ShibRequestSetting entityID $idp_entity_id
    ShibExportAssertion off
    <IfVersion < 2.4>
        ShibRequireSession On
        ShibRequireAll On
    </IfVersion>
</Location>
CONF
        echo "Directive for $idp_keystone_name: \"<Location /identity/v3/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/auth>\" added."
    else
        echo "Directive for $idp_keystone_name: \"<Location /identity/v3/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/auth>\" already present. Skipping."
    fi




    # Check if the IDP-specific directives already exist
    if ! grep -q "/identity/v3/auth/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/websso" "$KEYSTONE_APACHE_CONFIG_PATH"; then
        cat <<CONF >> "$KEYSTONE_APACHE_CONFIG_PATH"
# Directive for $idp_keystone_name
<Location /identity/v3/auth/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/websso>
    Require valid-user
    AuthType shibboleth
    ShibRequestSetting requireSession 1
    ShibRequestSetting entityID $idp_entity_id
    ShibExportAssertion off
    <IfVersion < 2.4>
        ShibRequireSession On
        ShibRequireAll On
    </IfVersion>
</Location>

CONF
        echo "Directive for $idp_keystone_name: \"<Location /identity/v3/auth/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/websso>\" added."
    else
        echo "Directive for $idp_keystone_name: \"<Location /identity/v3/auth/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/websso>\" already present. Skipping."
    fi

    done
}

configure_keystone_apache(){
    # check_dependency "DEVSTACK_INSTALLED"
    check_command_exists "openstack" "OpenStack CLI" "dependent"
    
    echo "Configuring Keystone's Apache conf file..."
    local KEYSTONE_APACHE_CONFIG_PATH="/etc/apache2/sites-available/keystone-wsgi-public.conf"
    local PROXYPASS_DIRECTIVE='ProxyPass "/identity" "unix:/var/run/uwsgi/keystone-wsgi-public.socket|uwsgi://uwsgi-uds-keystone-wsgi-public" retry=0 acquire=1'

    # Ensure we are running as root
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This function must be run as root."
        exit 1
    fi

    # Ensure the ProxyPass directive exists at the top of the file
    if ! grep -Fxq "$PROXYPASS_DIRECTIVE" "$KEYSTONE_APACHE_CONFIG_PATH"; then
        echo "Adding required ProxyPass directive to the top of $KEYSTONE_APACHE_CONFIG_PATH..."
        sudo sed -i "1i $PROXYPASS_DIRECTIVE" "$KEYSTONE_APACHE_CONFIG_PATH"
        echo "ProxyPass directive added."
    else
        echo "ProxyPass directive already present. Skipping."
    fi

    add_fixed_directives

    add_idp_directives
    
    # Restart Apache service
    echo "Restarting Apache service..."
    if sudo systemctl restart apache2.service; then
        echo "Apache service restarted successfully."
    else
        echo "Error: Failed to restart Apache service."
        exit 1
    fi

    echo "Keystone Apache configuration updated successfully."
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
        register_idps)
            register_idps
            ;;
        configure_keystone_debugging)
            configure_keystone_debugging
            ;;
        horizon_websso)
            configure_horizon_websso
            ;;
        configure_keystone_cli)
            create_federation_resources_at_keystone_cli
            ;;
        configure_keystone_federation)
            configure_keystone_federation
            ;;
        configure_keystone_apache)
            configure_keystone_apache
            ;;
        *)
            echo "Invalid option: $option"
            usage
            ;;
    esac
done

