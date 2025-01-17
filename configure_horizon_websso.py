import os
import sys
import csv
from config_utils import find_block_bounds, ensure_simple_config


# Path to the Horizon local_settings.py file
LOCAL_SETTINGS_PATH = "/opt/stack/horizon/openstack_dashboard/local/local_settings.py"

## Path of the currently running script:
# .
# ├── configure_horizon.py
# ├── install_local_sp3.sh
# └── sp3_supporting_files
#     ├── idp_list.csv
MAIN_DIRECTORY_LOCATION = os.path.dirname(os.path.abspath(__file__))
SUPPORTING_FILES_DIRECTORY = os.path.join(MAIN_DIRECTORY_LOCATION, "sp3_supporting_files")
# Path to the idp_list.csv file
IDP_LIST_FILE = os.path.join(SUPPORTING_FILES_DIRECTORY, "idp_list.csv")




# Function to check if a configuration already exists in the file
def config_exists(config_name, file_path):
    with open(file_path, "r") as file:
        for line in file:
            if line.strip().startswith(config_name):
                return True
    return False





def remove_config(config_name, file_path):
    with open(file_path, "r") as file:
        lines = file.readlines()

    # Find the block bounds
    start_index, end_index = find_block_bounds(config_name, lines)
    if start_index is not None and end_index is not None:
        print(f"Block starts at line {start_index} and ends at line {end_index}")
        print("Block content:")
        print("".join(lines[start_index:end_index+1]))
    else:
        print("Block not found or not properly closed.")

    # Remove the block if found
    if start_index is not None and end_index is not None:
        del lines[start_index:end_index + 1]
        print(f"Removed configuration: {config_name}")
    else:
        print(f"Configuration block '{config_name}' not found or improperly formatted in {file_path}.")

    # Write the updated lines back to the file
    with open(file_path, "w") as file:
        file.writelines(lines)





# Function to add or update a configuration in the file
def add_or_update_config(config_name, config_value, file_path):
    # Remove the old config first
    remove_config(config_name, file_path)

    # Add the new config
    with open(file_path, "a") as file:
        file.write(f"\n{config_name} = {config_value}\n")
    print(f"Added or updated configuration: {config_name}")






# Function to read the IDP list from the CSV file
def read_idp_list(csv_file):
    idp_list = []
    with open(csv_file, "r") as file:
        reader = csv.DictReader(file, delimiter=";")
        for row in reader:
            idp_list.append({
                "idp_horizon_name": row["idp_horizon_name"],
                "idp_keystone_name": row["idp_keystone_name"],
                "display_name": row["fqdn"]  # Use idp_horizon_name as the display name
            })
    return idp_list






# Main function to configure Horizon
def configure_horizon():
    # Step 1: Enable WEBSSO_ENABLED if it doesn't exist
    ensure_simple_config("WEBSSO_ENABLED", "True", LOCAL_SETTINGS_PATH)

    # Step 2: Read the IDP list from the CSV file
    idp_list = read_idp_list(IDP_LIST_FILE)

    # Step 3: Remove existing WEBSSO_CHOICES and WEBSSO_IDP_MAPPING
    remove_config("WEBSSO_CHOICES", LOCAL_SETTINGS_PATH)
    remove_config("WEBSSO_IDP_MAPPING", LOCAL_SETTINGS_PATH)

    # Step 4: Build WEBSSO_CHOICES
    web_sso_choices = [
        '("credentials", _("Keystone Credentials"))'
    ] + [f'("{idp["idp_horizon_name"]}", "{idp["display_name"]}")' for idp in idp_list]
    web_sso_choices_str = "(\n    " + ",\n    ".join(web_sso_choices) + "\n)"

    # Step 5: Build WEBSSO_IDP_MAPPING
    web_sso_mapping = {
        idp["idp_horizon_name"]: (idp["idp_keystone_name"], "saml2")
        for idp in idp_list
    }
    web_sso_mapping_str = "{\n    " + ",\n    ".join(
        [f'"{k}": ("{v[0]}", "{v[1]}")' for k, v in web_sso_mapping.items()]
    ) + "\n}"

    # # Step 6: Add or update WEBSSO_CHOICES and WEBSSO_IDP_MAPPING
    add_or_update_config("WEBSSO_CHOICES", web_sso_choices_str, LOCAL_SETTINGS_PATH)
    add_or_update_config("WEBSSO_IDP_MAPPING", web_sso_mapping_str, LOCAL_SETTINGS_PATH)

    # Step 7: Set WEBSSO_INITIAL_CHOICE to the first IDP
    if idp_list:
        ensure_simple_config("WEBSSO_INITIAL_CHOICE", "credentials", LOCAL_SETTINGS_PATH)

    print("Horizon SSO configuration updated successfully.")





# Run the configuration
if __name__ == "__main__":
    configure_horizon()