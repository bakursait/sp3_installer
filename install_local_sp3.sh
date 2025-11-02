#!/bin/bash

set -e
set -o pipefail

# Export Variables:
MAIN_DIRECTORY_LOCATION="$(cd "$(dirname "$0")" && pwd)"
SUPPORTING_FILES="${MAIN_DIRECTORY_LOCATION}/sp3_supporting_files"
IDP_LIST_FILE="${SUPPORTING_FILES}/idp_list.csv"

INSTALLER_LOG_FILE="/var/log/shib-sp-installer.log"
# Define variables
SHIBBOLETH_XML="/etc/shibboleth/shibboleth2.xml"

DEVSTACK_BRANCH="stable/2025.2"
STACK_USER="stack"
STACK_USER_HOME="/opt/${STACK_USER}"
DEVSTACK_HOME="${STACK_USER_HOME}/devstack"
HOST_IP="192.168.4.221"
ADMIN_PASSWORD="secret"
SHIB_HOSTNAME="sp1.localtest2.lab"

KEYSTONE_MAIN_CONF="/etc/keystone/keystone.conf"
HORIZON_SETTINGS_FILE="~/horizon/openstack_dashboard/local/local_settings.py"



# Ensure non-interactive mode for apt-get
export DEBIAN_FRONTEND=noninteractive

#ensure the current user has the full
if ! [[ -f "/etc/sudoers.d/${USER}" ]] && [[ $(id -u) != 0 ]]; then
    echo "User is not set as a sudoer.. setting the user..."
    echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER
else
    echo "the user is already set as a sudoer. Skipping..."
fi

echo_message(){
    local message=$1
    echo
    echo "----- ${message} -----"
    echo
}



usage() {
    echo -e "\n\033[1;33mUsage:\033[0m $0 {option}"
    echo -e "\n\033[1;32mAvailable Options:\033[0m"
    echo -e "  \033[1;34mset_hostname\033[0m              Setup Hostname."
    echo -e "  \033[1;34mshibsp\033[0m                    Install and configure Shibboleth-SP."
    echo -e "  \033[1;34mconfigure_shibsp\033[0m          Configure Shibboleth-SP settings."
    echo -e "  \033[1;34mdevstack\033[0m                  Download, Install and configure DevStack."
    echo -e "  \033[1;34mregister_idps\033[0m             Register IdPs from idp_list.csv file into shibboleth2.xml as MetadataProvider elements."
    echo -e "  \033[1;34mconfigure_keystone_debugging\033[0m Enable debugging for Keystone."
    echo -e "  \033[1;34mhorizon_websso\033[0m          Configure Horizon for WebSSO."
    echo -e "  \033[1;34mconfigure_keystone_cli\033[0m   Configure Keystone CLI settings."
    echo -e "  \033[1;34mconfigure_keystone_federation\033[0m Set up Keystone federation."
    echo -e "  \033[1;34mconfigure_keystone_apache\033[0m Configure Keystone Apache settings."
    echo -e "\n\033[1;31mError:\033[0m You must specify at least one valid option to run the script."
    exit 1
}

setup_the_environment(){
    echo "Installing required packages..."
    sudo apt-get install -y ca-certificates
    sudo apt-get install -y emacs
    sudo apt-get install -y openssl
    sudo apt-get install -y xmlstarlet
    sudo apt-get install -y curl
    sudo apt-get install -y wget
    sudo apt-get install -y crudini
    sudo apt-get install -y acl
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


xml_set_attr_once() {
    # Example:
    # xml_set_attr_once /etc/shibboleth/shibboleth2.xml '//sp:Sessions/@cookieProps' 'http'
    local file="$1" xpath="$2" value="$3"
    if ! xmlstarlet sel -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
         -t -v "$xpath" "$file" >/dev/null 2>&1; then
	# If attribute missing entirely, you might want to insert its parent or skip
	:
    fi
    sudo xmlstarlet ed -P -L -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
	 -u "$xpath" -v "$value" "$file"
}



setup_hostname(){
    echo_message "SETUP HOSTNAME"
    #Note: we escaped the dots in the regex so they match literal dots
    sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${SHIB_HOSTNAME}/" /etc/hosts
    if ! grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
	echo -e "127.0.1.1 ${SHIB_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
    fi

    
    if [[ "${SHIB_HOSTNAME}" == "$(hostname)" ]]; then
        echo "Hostname is already set to: $(hostname)"
    else
	echo "resetting machine's hostname to ${SHIB_HOSTNAME}"
	hostnamectl hostname "${SHIB_HOSTNAME}"
	systemctl restart systemd-hostnamed.service
    fi
    echo "verifying Hostname: $(hostname)"
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

	exists=$(
	    xmlstarlet sel -N sp="urn:mace:shibboleth:3.0:native:sp:config" -t -v "boolean(/sp:SPConfig/sp:ApplicationDefaults/sp:MetadataProvider[@url='${idp_entity_id}'])" "$SHIBBOLETH_XML")
	

	#if grep -q "<MetadataProvider .* url=\"$idp_entity_id\"" "${SHIBBOLETH_XML}"; then
	#    echo "The IdP: \"$idp_entity_id\", is alredy register in: \"${SHIBBOLETH_XML}\"... Skip it"
	#    continue
	#fi

	# Create provider node only if it does not already exist for this URL
	if [ "$exists" = "true" ]; then
	    echo "The IdP: \"$idp_entity_id\" is already registered in \"$SHIBBOLETH_XML\" — skipping."
	else
	    sudo xmlstarlet ed -P -L \
		 -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
		 -s "/sp:SPConfig/sp:ApplicationDefaults" -t elem -n "MetadataProviderTMP" -v "" \
		 -i "/sp:SPConfig/sp:ApplicationDefaults/MetadataProviderTMP" -t attr -n "type"            -v "XML" \
		 -i "/sp:SPConfig/sp:ApplicationDefaults/MetadataProviderTMP" -t attr -n "validate"        -v "true" \
		 -i "/sp:SPConfig/sp:ApplicationDefaults/MetadataProviderTMP" -t attr -n "url"             -v "$idp_entity_id" \
		 -i "/sp:SPConfig/sp:ApplicationDefaults/MetadataProviderTMP" -t attr -n "backingFilePath" -v "$idp_backup_file" \
		 -i "/sp:SPConfig/sp:ApplicationDefaults/MetadataProviderTMP" -t attr -n "maxRefreshDelay" -v "720000" \
		 -r "/sp:SPConfig/sp:ApplicationDefaults/MetadataProviderTMP" -v "MetadataProvider" \
		 "$SHIBBOLETH_XML"
	fi

	## Use sed to add the MetadataProvider entry after <Errors /> -- we replaced the following (old) with above (new) which uses xmlstarlet.
	## add validate=\"true\"
	#sudo sed -i "/<Errors/s|/>|/>\n\n    <MetadataProvider type=\"XML\" validate=\"true\" url=\"$idp_entity_id\" backingFilePath=\"$idp_backup_file\" maxRefreshDelay=\"720000\" />|" "${SHIBBOLETH_XML}" || { echo "failed adding idps. Check logs."; exit 1; }
    done
}

register_idps(){
    #check_command_exists "shibd" "Shibboleth-SP" "dependent"
    
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
    #check_command_exists "openstack" "OpenStack CLI" "independent"
    
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
sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$ADMIN_PASSWORD/" local.conf

sed -i "s/^DATABASE_PASSWORD=.*/DATABASE_PASSWORD=$ADMIN_PASSWORD/" local.conf

sed -i "s/^RABBIT_PASSWORD=.*/RABBIT_PASSWORD=$ADMIN_PASSWORD/" local.conf

sed -i "s/^SERVICE_PASSWORD=.*/SERVICE_PASSWORD=$ADMIN_PASSWORD/" local.conf



#sed -i "s/^#HOST_IP=.*/HOST_IP=$HOST_IP/" local.conf
#sed -i "s/^HOST_IP=.*/HOST_IP=$HOST_IP/g" local.conf
#sed -i "s/^HOST_IP=.*/HOST_IP=172.0.0.1/g" local.conf


# Step 9: Install DevStack
echo "Starting DevStack installation. This might take some time..."
echo 'have some coffee and enjoy :)'
./stack.sh || { echo "DevStack installation failed"; exit 1; }
EOF



    # Step 10.1: Update and upgrade the system
    echo "Updating and upgrading system packages..."
    sudo apt-get update

    # Step 10.2: Install required Access Control List (acl) package
    echo "Installing ACL package..."
    setup_the_environment
    #sudo apt-get install -y acl

    # Step 11: let the user: "$STACK_USER" have access to all required files in the original $USER's home directory
    sudo setfacl -R -m u:$STACK_USER:r-x "$HOME"
    sudo setfacl -R -d -m u:$STACK_USER:r-x "$HOME"

    sudo setfacl -R -m u:$STACK_USER:r-x "$MAIN_DIRECTORY_LOCATION"
    sudo setfacl -R -d -m u:$STACK_USER:r-x "$MAIN_DIRECTORY_LOCATION"

    # Step 12: Test Accessing Horizon
    if curl -k "http://${HOST_IP}/dashboard"; then
	echo "DevStack installation complete!"
	echo "You can access the Horizon dashboard at: http://$HOST_IP/dashboard"
    else
	echo "[ERROR] DevStack installation FAILED!"
	echo "something went wrong while configuring DevStack -v ${DEVSTACK_BRANCH}"
	echo "please revisit the installation log file at: ${INSTALLER_LOG_FILE}"
    fi
    
    
}




# Function to set up Shibboleth SP
#source "$MAIN_DIRECTORY_LOCATION/setup_shib_sp.sh"
# Include the Shibboleth SP setup function
install_shib_sp() {
    # Check if Shibboleth-SP is already installed
    #check_command_exists "shibd" "Shibboleth-SP" "independent"
    
    echo "Starting installation of Shibboleth SP..."

    # Step 1: Update and upgrade the system; do not upgrade.. this will cause HTTP 429 error: too many requests.
    echo "Updating system packages..."
    sudo apt-get update

    # Step 2: Install required packages
    echo "Installing required packages..."
    setup_the_environment
    #sudo apt-get install -y ca-certificates emacs openssl xmlstarlet curl wget crudini acl

    # Step 3: Install Shibboleth SP
    echo "Installing Shibboleth SP and related packages..."
    sudo apt-get install -y apache2 libapache2-mod-shib ntp --no-install-recommends

    # Step 4: Enable Shibboleth module in Apache
    echo "Enabling Shibboleth module in Apache..."
    sudo a2enmod shib
    sudo systemctl restart apache2.service

    echo "Shibboleth SP installation complete!"
}







configure_shib_sp() {
    # check_dependency "SHIBSP_INSTALLED"
    #check_command_exists "shibd" "Shibboleth-SP" "dependent"
    

    echo "Starting Shibboleth SP configuration..."
    local RANDOM_UUID="$(uuidgen)"
    local SP_ENTITY_ID="http://devstack.sait.${RANDOM_UUID}/shibboleth"
    local SP_METADATA_FILE="/etc/shibboleth/devstack.sait.${RANDOM_UUID}-metadata.xml"

    echo "Our Shibboleth-SP EntityID would be: ${SP_ENTITY_ID}"

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
    sudo xmlstarlet ed --inplace -P \
	 -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
	 -u '//sp:ApplicationDefaults/@entityID' -v "${SP_ENTITY_ID}" "${SHIBBOLETH_XML}"
    
    echo "Configuring <Sessions> directive..."
    sudo xmlstarlet ed --inplace -P \
	 -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
	 -u '//sp:ApplicationDefaults/sp:Sessions/@handlerSSL'  -v 'false' "${SHIBBOLETH_XML}"
    
    sudo xmlstarlet ed --inplace -P \
	 -N sp="urn:mace:shibboleth:3.0:native:sp:config" \
	 -u '//sp:ApplicationDefaults/sp:Sessions/@cookieProps' -v 'http'  "${SHIBBOLETH_XML}"


    

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
    # the configurations below are mentioned in the Keystone doc:
    ## https://docs.openstack.org/keystone/latest/configuration/config-options.html
    echo "Configuring Keystone debugging..."
    if [ -z "$STACK_USER" ] || [ -z "$KEYSTONE_MAIN_CONF" ]; then
        echo "Error: STACK_USER or KEYSTONE_MAIN_CONF is not defined."
        exit 1
    fi
    echo "$KEYSTONE_MAIN_CONF"

    sudo -i -u "$STACK_USER" bash <<EOF
set -euo pipefail
# Use sudo for system files since we’re the stack user here
if ! command -v crudini >/dev/null 2>&1; then
  sudo apt-get update -y
  setup_the_environment
  #sudo apt-get install -y crudini
fi

CONF="$KEYSTONE_MAIN_CONF"

# DEFAULT section (debugging + file logging)
sudo crudini --set "$KEYSTONE_MAIN_CONF" DEFAULT debug True
sudo crudini --set "$KEYSTONE_MAIN_CONF" DEFAULT insecure_debug True
sudo crudini --set "$KEYSTONE_MAIN_CONF" DEFAULT log_dir /var/log/keystone
sudo crudini --set "$KEYSTONE_MAIN_CONF" DEFAULT log_file keystone.log

# [log] section level
sudo crudini --set "$KEYSTONE_MAIN_CONF" log level DEBUG

# Ensure log dir exists and is writable by stack (DevStack often expects this)
sudo mkdir -p /var/log/keystone
sudo chown -R stack:stack /var/log/keystone

# Keep keystone.conf writable by stack for your workflow (optional)
sudo chown stack:stack "$KEYSTONE_MAIN_CONF"

# Restart Keystone (DevStack service unit)
echo "Restarting Keystone service..."
sudo systemctl restart devstack@keystone.service || true
if systemctl is-active --quiet devstack@keystone.service; then
  echo "Keystone service restarted successfully."
else
  echo "Error: Keystone service failed to restart. Check logs."
fi
EOF

    echo "Keystone debugging configured."
}


configure_horizon_websso(){
    # the configurations below are mentioned in the KeyStone doc,chapter: "Configuring Keystone for Federation", section: "Configuring Keystone for Federation"
    ## https://docs.openstack.org/keystone/2025.2/admin/federation/configure_federation.html#configuring-horizon-as-a-websso-frontend
    # Horizon also has some useful information:
    ## https://docs.openstack.org/horizon/latest/configuration/settings.html#keystone
    # -------------------------------#

    
    
    # check_dependency "DEVSTACK_INSTALLED"
    #check_command_exists "openstack" "OpenStack CLI" "dependent"
    
    echo "Configuring Horizon for SSO..."


    echo "Configuring Horizon for SSO (snippet-based)..."

  # --- Paths & prerequisites (host-side) ---
  : "${STACK_USER:=stack}"
  : "${STACK_USER_HOME:=/opt/stack}"  # DevStack default
  # Your CSV lives with the installer repo; adjust if different:
  local CSV_ON_HOST="${MAIN_DIRECTORY_LOCATION:-/home/${SUDO_USER:-$USER}/sp3_installer}/sp3_supporting_files/idp_list.csv"

  # Destination snippet loaded AFTER local_settings.py (preferred by Horizon)
  local CUSTOM_HORIZON_CONF_FILE="/opt/stack/horizon/openstack_dashboard/local/local_settings.d/_10_websso.py"

  if [[ ! -r "${IDP_LIST_FILE}" ]]; then
    echo "Error: CSV file not found or unreadable: ${IDP_LIST_FILE}"
    exit 1
  fi

  # --- Run as stack: parse CSV and (re)write the snippet atomically ---
  # Pass env vars into the heredoc so nounset (-u) is safe inside.
  sudo -i -u "$STACK_USER" IDP_LIST_FILE="${IDP_LIST_FILE}" CUSTOM_HORIZON_CONF_FILE="${CUSTOM_HORIZON_CONF_FILE}" bash <<'EOF'
set -euo pipefail

# Ensure snippet directory exists and is readable by Horizon
install -d -m 755 "$(dirname "${CUSTOM_HORIZON_CONF_FILE}")"

python3 - <<'PY'
import csv, pathlib, sys

csv_path   = pathlib.Path(__import__('os').environ['IDP_LIST_FILE'])
snippet    = pathlib.Path(__import__('os').environ['CUSTOM_HORIZON_CONF_FILE'])

# Read CSV (semicolon-delimited)
rows = []
with csv_path.open(newline="") as f:
    r = csv.DictReader(f, delimiter=";")
    for row in r:
        # Require the two key columns we need to build choices/mapping
        if not row.get("idp_keystone_name") or not row.get("idp_horizon_name"):
            continue
        rows.append(row)

# Build choices and mapping
choices = [("credentials", "Keystone Credentials")]
mapping = {}
for row in rows:
    horizon_name  = row["idp_horizon_name"]              # dropdown key (UI label id)
    display_name  = row.get("fqdn") or horizon_name      # what user sees
    keystone_name = row["idp_keystone_name"]             # keystone IdP resource name
    protocol      = "saml2"                              # adjust to "oidc" if needed

    choices.append((horizon_name, display_name))
    mapping[horizon_name] = (keystone_name, protocol)

# Pick initial choice: keep local credentials by default
initial = "credentials"
# If you prefer first IdP by default, uncomment the next two lines:
# if len(choices) > 1:
#     initial = choices[1][0]

def py_tuple(t):
    return "(" + ", ".join(repr(x) for x in t) + ")"

def py_choices(seq):
    inner = ",\n    ".join(py_tuple(x) for x in seq)
    return "(\n    " + inner + "\n)"

def py_mapping(d):
    lines = [f"{k!r}: ({v[0]!r}, {v[1]!r})" for k, v in d.items()]
    return "{\n    " + ",\n    ".join(lines) + "\n}"

content = f"""# Auto-generated WebSSO settings (do not edit by hand)
WEBSSO_ENABLED = True

WEBSSO_CHOICES = {py_choices(choices)}

WEBSSO_IDP_MAPPING = {py_mapping(mapping)}

WEBSSO_INITIAL_CHOICE = {initial!r}
"""

snippet.parent.mkdir(parents=True, exist_ok=True)
tmp = snippet.with_suffix(".tmp")
tmp.write_text(content)
tmp.replace(snippet)

print(f"Wrote {snippet} with {len(rows)} IdP(s).")
PY
EOF

  # --- Restart Horizon (Apache) and report status ---
  sudo systemctl restart apache2.service
  if systemctl is-active --quiet apache2.service; then
    echo "Horizon (apache2) restarted OK."
  else
    echo "ERROR: apache2 failed to restart — check 'journalctl -u apache2 -n 200'."
    exit 1
  fi
  
  echo "Horizon WebSSO configuration complete."

}




# Create Keystone federation resources (IdP, mapping, group, project, role, protocol) per CSV row.
create_federation_resources_at_keystone_cli() {
  echo "Creating federation resources in Keystone…"

  # ---- Host-side validation & defaults
  #: "${STACK_USER:=stack}"
  #: "${DEVSTACK_HOME:=/opt/stack/devstack}"

  if [[ ! -r "${IDP_LIST_FILE}" ]]; then
    echo "ERROR: CSV not found or unreadable: ${IDP_LIST_FILE}"
    return 1
  fi

  # ---- Run as stack with a login shell so DevStack paths/rc behave as expected
  # Pass needed vars via env to avoid unbound-var issues inside 'set -u'
  sudo -i -u "$STACK_USER" IDP_CSV="${IDP_LIST_FILE}" DEVSTACK_HOME="${DEVSTACK_HOME}" bash <<'EOSU'
set -eo pipefail
set -u                   # we still want nounset overall


echo ${IDP_CSV}
echo ${DEVSTACK_HOME}

cd "$DEVSTACK_HOME" || { echo "ERROR: Cannot cd to $DEVSTACK_HOME"; exit 1; }

# Source admin credentials (devstack's openrc lives here)
# shellcheck disable=SC1091
echo 1
# --- DevStack env files are not nounset-safe; relax just for sourcing:
set +u
# shellcheck disable=SC1091
source "$DEVSTACK_HOME/openrc" admin admin
set -u
# --- back to strict mode

echo 2
# Quick sanity check that CLI works (and we have admin token)
command -v openstack >/dev/null 2>&1 || { echo "ERROR: openstack CLI not found"; exit 1; }
openstack token issue >/dev/null || { echo "ERROR: cannot issue token"; exit 1; }


echo 3
# Some helpers for idempotent checks
have_idp()        { openstack identity provider show "$1"     >/dev/null 2>&1; }
have_mapping()    { openstack mapping show "$1"               >/dev/null 2>&1; }
have_group()      { openstack group show "$1"                 >/dev/null 2>&1; }
have_project()    { openstack project show "$1"               >/dev/null 2>&1; }
have_role()       { openstack role show "$1"                  >/dev/null 2>&1; }
have_protocol()   { openstack federation protocol show "$2" --identity-provider "$1" >/dev/null 2>&1; }

# Prefer the modern 'member' role if present; otherwise fall back to legacy '_member_'
resolve_member_role() {
  if have_role member; then echo member; elif have_role _member_; then echo _member_; else echo ""; fi
}

echo 4

member_role="$(resolve_member_role)"
if [[ -z "$member_role" ]]; then
  echo "ERROR: Neither 'member' nor '_member_' role exists in this deployment."
  echo "       Create one (e.g., 'openstack role create member') and re-run."
  exit 1
fi

echo 5

# Read CSV (skip header), semicolon-delimited
tail -n +2 "$IDP_CSV" | while IFS=";" read -r fqdn idp_entity_id idp_backup_file idp_keystone_name idp_horizon_name idp_mapping_rules; do
  # Skip blank lines
  [[ -z "${idp_keystone_name:-}" ]] && continue

  echo
  echo "=== Processing IdP: ${idp_keystone_name} (${idp_entity_id}) ==="

  # 1) Identity Provider
  if have_idp "$idp_keystone_name"; then
    echo "IdP '$idp_keystone_name' already exists."
  else
    openstack identity provider create "$idp_keystone_name" --remote-id "$idp_entity_id"
    echo "Created IdP '$idp_keystone_name'."
  fi

  # 2) Mapping rules (write to a temp file, then create mapping if missing)
  rules_file="$(mktemp /tmp/${idp_keystone_name}_rules.XXXX.json)"
  # Here-doc unquoted so variables expand inside JSON where needed
  cat >"$rules_file" <<JSON
[
  {
    "local": [
      {
        "user": { "name": "{0}" },
        "group": {
          "domain": { "name": "Default" },
          "name": "federated_users_${idp_keystone_name}"
        }
      }
    ],
    "remote": [ { "type": "REMOTE_USER" } ]
  }
]
JSON
  echo 6
  if have_mapping "$idp_mapping_rules"; then
    echo "Mapping '$idp_mapping_rules' already exists."
  else
    openstack mapping create "$idp_mapping_rules" --rules "$rules_file"
    echo "Created mapping '$idp_mapping_rules'."
  fi
  rm -f "$rules_file"
  echo 7
  # 3) Group (one per IdP to gather all its users, if that's your model)
  group_name="federated_users_${idp_keystone_name}"
  if have_group "$group_name"; then
    echo "Group '$group_name' already exists."
  else
    openstack group create "$group_name"
    echo "Created group '$group_name'."
  fi
  echo 8
  # 4) Project (a landing project per IdP, adjust to your tenancy model)
  project_name="federated_project_${idp_keystone_name}"
  if have_project "$project_name"; then
    echo "Project '$project_name' already exists."
  else
    openstack project create "$project_name"
    echo "Created project '$project_name'."
  fi
  echo 9
  # 5) Role assignment (group → project)
  # Use --project-domain if you use non-default domains; DevStack uses Default by default.
  if openstack role assignment list --group "$group_name" --project "$project_name" -f value -c Role | grep -qx "$member_role"; then
    echo "Role '$member_role' already assigned to group '$group_name' on project '$project_name'."
  else
    openstack role add --group "$group_name" --project "$project_name" "$member_role"
    echo "Assigned role '$member_role' to group '$group_name' on project '$project_name'."
  fi
  echo 10
  # 6) Federation protocol (saml2) bound to this IdP with the mapping above
  if have_protocol "$idp_keystone_name" saml2; then
    echo "Federation protocol 'saml2' already exists for IdP '$idp_keystone_name'."
  else
    openstack federation protocol create saml2 --identity-provider "$idp_keystone_name" --mapping "$idp_mapping_rules"
    echo "Created federation protocol 'saml2' for IdP '$idp_keystone_name'."
  fi
  echo 11
  echo "=== Done: ${idp_keystone_name} ==="
done
EOSU
  echo 12
  echo "Federation resources created (idempotent)."
}




configure_keystone_federation() {
  echo "Configuring DevStack for SAML Federation..."

  local keystone_conf="/etc/keystone/keystone.conf"
  local sso_template_source="/opt/stack/keystone/etc/sso_callback_template.html"
  local sso_template_target="/etc/keystone/sso_callback_template.html"
  

  # Horizon WebSSO endpoint(s). Keystone allows multiple trusted_dashboard entries.
  # Add both variants to be robust across layouts:
  local dash1="http://$HOST_IP/auth/websso/"
  local dash2="http://$HOST_IP/dashboard/auth/websso/"

  # This is the attribute Keystone will use to identify WHICH IdP handled the login.
  # With Shibboleth SP via Apache, the common header is `Shib-Identity-Provider`.
  # (Some setups expose it as HTTP_SHIB_IDENTITY_PROVIDER; adjust if needed.)
  local remote_id_attribute_conf_section="federation"      # saml2 OR federation
  if [[ "$remote_id_attribute_conf_section" != "saml2" && "$remote_id_attribute_conf_section" != "federation" ]]; then
      remote_id_attribute_conf_section="federation"
  fi
  local remote_id_attr="Shib-Identity-Provider"

  # Ensure crudini is available
  if ! command -v crudini >/dev/null 2>&1; then
      sudo apt-get update -y
      setup_the_environment  
      #sudo apt-get install -y crudini
  fi

  sudo bash <<EOF
set -euo pipefail

# 1) Enable federation methods in [auth]
crudini --set "$keystone_conf" auth methods "password,token,saml2,openid"

# 2) remote_id_attribute (usually under [federation])
crudini --set "$keystone_conf" "${remote_id_attribute_conf_section}" remote_id_attribute "$remote_id_attr"

# 3) trusted_dashboard is multi-valued; add both likely Horizon paths idempotently
#    (crudini doesn't do 'add-many', so we guard with grep before appending)
ensure_td() {
  local value="\$1"
  if ! awk -F '=' '/^\[federation\]/{f=1} f && /^[[:space:]]*trusted_dashboard[[:space:]]*=/{print \$2}' "$keystone_conf" | grep -qx "[[:space:]]*\$value[[:space:]]*"; then
    # append another trusted_dashboard line
    printf '%s\n' "trusted_dashboard = \$value" >> "$keystone_conf"
  fi
}

# make sure [federation] exists
crudini --set "$keystone_conf" federation dummy_key will_be_deleted >/dev/null 2>&1 || true
crudini --del "$keystone_conf" federation dummy_key || true

ensure_td "$dash1"
ensure_td "$dash2"

# 4) sso_callback_template
crudini --set "$keystone_conf" federation sso_callback_template "$sso_template_target"

# 5) Install the callback template if missing (Keystone’s default template is fine)
if [ ! -f "$sso_template_target" ]; then
  cp "$sso_template_source" "$sso_template_target"
fi

# Reasonable perms/ownership for devstack-style deployments
chown stack:stack "$keystone_conf" || true
chmod 600 "$keystone_conf" || true
EOF

  echo "Restarting Keystone, Apache, and Shibboleth…"
  sudo systemctl restart devstack@keystone.service
  sudo systemctl restart apache2.service
  sudo systemctl restart shibd.service


  for service in "devstack@keystone" "apache2.service" "shibd.service"; do
      if systemctl is-active "${service}" >/dev/null; then
	  echo "${service} restarted successfully"
      else
	  echo "something went wrong with restarting ${service}"
	  exit 1
      fi
  done
  


  echo "DevStack SAML federation configuration completed."
}


# Add fixed directives that are not IdP-specific
add_fixed_directives() {
  echo "Adding fixed directives to Apache configuration if not present..."
  local CFG_old="/etc/apache2/sites-available/keystone-wsgi-public.conf"
  local CFG="/etc/apache2/sites-available/keystone-api.conf"
  local PROTOCOL="saml2"

  [[ -f "$CFG" ]] || { echo "ERROR: $CFG not found"; return 1; }

  # 1) Exclude the Shibboleth handler from generic ProxyPass:
  # Correct form: ProxyPass /Shibboleth.sso !
  if ! grep -Fq 'ProxyPass /Shibboleth.sso !' "$CFG"; then
    echo 'Appending Shibboleth.sso ProxyPass exclusion…'
    printf '\n# Shibboleth handler is served locally (exclude from ProxyPass)\nProxyPass /Shibboleth.sso !\n' | sudo tee -a "$CFG" >/dev/null
  else
    echo 'ProxyPass /Shibboleth.sso ! already present.'
  fi

  # 2) Shibboleth handler location
  if ! grep -Fq '<Location /Shibboleth.sso>' "$CFG"; then
    echo 'Appending <Location /Shibboleth.sso> handler…'
    sudo tee -a "$CFG" >/dev/null <<'EOF'
# Shibboleth handler endpoint
<Location /Shibboleth.sso>
  SetHandler shib
</Location>
EOF
  else
    echo '<Location /Shibboleth.sso> already present.'
  fi

  # 3) Generic WebSSO (protocol) endpoint — protect with Shibboleth (no entityID here)
  #    /identity/v3/auth/OS-FEDERATION/websso/saml2
  if ! grep -Fq '<Location /identity/v3/auth/OS-FEDERATION/websso/saml2>' "$CFG"; then
    echo "Appending generic WebSSO protection for $PROTOCOL…"
    sudo tee -a "$CFG" >/dev/null <<EOF
# Generic WebSSO endpoint for protocol: $PROTOCOL
<Location /identity/v3/auth/OS-FEDERATION/websso/$PROTOCOL>
  Require valid-user
  AuthType shibboleth
  ShibRequestSetting requireSession 1
  ShibExportAssertion off
</Location>
EOF
  else
    echo "<Location /identity/v3/auth/OS-FEDERATION/websso/$PROTOCOL> already present."
  fi
}

# Add per-IdP directives (entityID binding and per-IdP WebSSO)
add_idp_directives() {
  echo "Adding IDP-specific directives to Apache configuration..."
  local CFG_old="/etc/apache2/sites-available/keystone-wsgi-public.conf"
  local CFG="/etc/apache2/sites-available/keystone-api.conf"
  local CSV="$SUPPORTING_FILES/idp_list.csv"
  local PROTOCOL="saml2"

  [[ -f "$CFG" ]] || { echo "ERROR: $CFG not found"; return 1; }
  [[ -r "$CSV" ]] || { echo "ERROR: $CSV not readable"; return 1; }

  # Basic CSV sanity: exactly 6 columns per row (skip header)
  #if ! awk -F';' 'NR>1 && NF!=6 {bad=1} END{exit bad}' "$CSV"; then
  #  echo "ERROR: $CSV has row(s) not containing exactly 6 semicolon-separated fields."
  #  return 1
  #fi

  tail -n +2 "$CSV" | while IFS=";" read -r fqdn idp_entity_id idp_backup_file idp_keystone_name idp_horizon_name idp_mapping_rules; do
      if [[ -z "$idp_keystone_name" ]]; then
	  continue
      fi
      
    echo "Processing IdP: $idp_keystone_name"


    echo
    echo

    echo "fqdn: $fqdn"
    echo "idp_entity_id: $idp_entity_id"
    echo "idp_backup_file: $idp_backup_file"
    echo "idp_keystone_name: $idp_keystone_name"
    echo "idp_horizon_name: $idp_horizon_name"
    echo "idp_mapping_rules: $idp_mapping_rules"
    echo
    echo

    # 1) Per-IdP AUTH endpoint (entityID bound)
    #    /identity/v3/OS-FEDERATION/identity_providers/<idp>/protocols/<proto>/auth
    loc="/identity/v3/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/auth"
    if ! grep -Fq "<Location $loc>" "$CFG"; then
      echo "Appending <Location $loc>…"
      sudo tee -a "$CFG" >/dev/null <<CONF

# Per-IdP AUTH endpoint
<Location $loc>
  Require valid-user
  AuthType shibboleth
  ShibRequestSetting requireSession 1
  ShibRequestSetting entityID $idp_entity_id
  ShibExportAssertion off
</Location>
CONF
    else
      echo "<Location $loc> already present."
    fi

    # 2) Per-IdP WebSSO endpoint
    #    /identity/v3/auth/OS-FEDERATION/identity_providers/<idp>/protocols/<proto>/websso
    loc2="/identity/v3/auth/OS-FEDERATION/identity_providers/$idp_keystone_name/protocols/$PROTOCOL/websso"
    if ! grep -Fq "<Location $loc2>" "$CFG"; then
      echo "Appending <Location $loc2>…"
      sudo tee -a "$CFG" >/dev/null <<CONF

# Per-IdP WebSSO endpoint
<Location $loc2>
  Require valid-user
  AuthType shibboleth
  ShibRequestSetting requireSession 1
  ShibRequestSetting entityID $idp_entity_id
  ShibExportAssertion off
</Location>
CONF
    else
      echo "<Location $loc2> already present."
    fi

 done
}

configure_keystone_apache() {
  echo "Configuring Keystone's Apache conf file..."
  local CFG_old="/etc/apache2/sites-available/keystone-wsgi-public.conf"
  local CFG="/etc/apache2/sites-available/keystone-api.conf"
  local UWSGI='unix:/var/run/uwsgi/keystone-wsgi-public.socket|uwsgi://uwsgi-uds-keystone-wsgi-public'
  local API='unix:/var/run/uwsgi/keystone-api.socket|uwsgi://uwsgi-uds-keystone-api'
  local PROXYLINE="ProxyPass \"/identity\" \"$API\" retry=0 acquire=1"

  # Must be root
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This function must be run as root."
    exit 1
  fi

  [[ -f "$CFG" ]] || { echo "ERROR: $CFG not found"; exit 1; }

  # One-time backup
  if [[ ! -f "${CFG}.bak" ]]; then
    sudo cp -a "$CFG" "${CFG}.bak"
  fi

  # Ensure required Apache modules are enabled (idempotent)
  a2enmod proxy >/dev/null 2>&1 || true
  a2enmod proxy_uwsgi >/dev/null 2>&1 || true
  a2enmod shib >/dev/null 2>&1 || true

  # Ensure site is enabled (DevStack usually enables it already)
  a2ensite keystone-wsgi-public >/dev/null 2>&1 || true

  # Ensure ProxyPass to Keystone UWSGI exists near the top (once)
  if ! grep -Fq "$PROXYLINE" "$CFG"; then
    echo "Adding required ProxyPass for /identity → UWSGI socket…"
    sudo sed -i "1i $PROXYLINE" "$CFG"
  else
    echo "ProxyPass for /identity already present."
  fi

  # Add Shibboleth and federation Location blocks
  add_fixed_directives
  add_idp_directives

  # Validate Apache config and restart
  echo "Validating Apache configuration (apachectl -t)…"
  if ! apachectl -t; then
    echo "ERROR: Apache config test failed. Reverting changes."
    [[ -f "${CFG}.bak" ]] && sudo cp -a "${CFG}.bak" "$CFG"
    exit 1
  fi

  echo "Restarting Apache service…"
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
        set_hostname)
            setup_hostname | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        shibsp)
            install_shib_sp | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        configure_shibsp)
            configure_shib_sp | tee -a "${INSTALLER_LOG_FILE}"
            ;;
	devstack)
            setup_devstack | tee -a "${INSTALLER_LOG_FILE}"
            ;;
	register_idps)
            register_idps | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        configure_keystone_debugging)
            configure_keystone_debugging | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        horizon_websso)
            configure_horizon_websso | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        configure_keystone_cli)
            create_federation_resources_at_keystone_cli | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        configure_keystone_federation)
            configure_keystone_federation | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        configure_keystone_apache)
            configure_keystone_apache | tee -a "${INSTALLER_LOG_FILE}"
            ;;
        *)
            echo "Invalid option: $option" | tee -a "${INSTALLER_LOG_FILE}"
            usage
            ;;
    esac
done

