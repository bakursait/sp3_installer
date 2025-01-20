# OpenStack & Shibboleth-SP Automation Script

This repository provides a fully automated script to install and configure OpenStack (DevStack) and Shibboleth Service Provider (SP), along with the required integrations for SAML-based federation. The script simplifies the process of setting up a federated environment for OpenStack.

---

## Features

- **Automated Installation**: Install and configure DevStack and Shibboleth-SP.
- **Dependency Verification**: Ensures required components are installed before executing dependent functions.
- **SAML Federation Configuration**: Automates the setup of Identity Providers (IdPs) and related federation resources in Keystone.
- **Horizon WebSSO Configuration**: Configures the Horizon dashboard for SSO authentication.
- **Apache Configuration**: Updates the Keystone Apache configuration for SAML federation.
- **State Management**: Tracks installation status across script runs to prevent redundant operations.

---

## OS requirements
We tested the system on:
- OS: Ubuntu:22.04
- Hardware: 
  - Memory: 4096 MB
  - Prcessors: 2
  - HDD: 100 GB
- Devstack version: 2023.2

---

## Prerequisites

- Installed tools: `bash`, `python3`, `git`, `curl`, and other dependencies handled by the script.
- A valid list of Identity Providers (IdPs) provided in a CSV file (`sp3_supporting_files/idp_list.csv`). Samples are provided.

---

## Installation

1. **Clone the Repository**:
   ```bash
   git clone git@github.com:bakursait/sp3_installer.git
   cd sp3_supporting_files/
   ```

2. **Run the Script**:
   ```bash
   ./install_local_sp3.sh <option>
   ```

---

## Usage

### Available Options
The script supports the following operations:
- **`devstack`**: Install and configure OpenStack DevStack.
- **`shibsp`**: Install and configure Shibboleth Service Provider (SP).
- **`configure_shibsp`**: Configure Shibboleth-SP for federation.
- **`configure_keystone_debugging`**: Enable debugging in Keystone.
- **`horizon_websso`**: Configure Horizon for WebSSO.
- **`configure_keystone_cli`**: Create federation resources in Keystone CLI.
- **`configure_keystone_federation`**: Complete federation configuration in Keystone.
- **`configure_keystone_apache`**: Update the Keystone Apache vhost configuration. -- **MUST** run with `sudo` privileges.

### Example Usage
```bash
# Install DevStack
./install_local_sp3.sh devstack

# Install Shibboleth SP
./install_local_sp3.sh shibsp

# Configure Horizon for WebSSO
./install_local_sp3.sh horizon_websso

# Configure Keystone endpoints for Apache
sudo ./install_local_sp3.sh configure_keystone_apache
```

### Function Hierarchy
The following diagram illustrates the relationship between independent and dependent functions in the script:
```bash
setup_devstack()
└── configure_keystone_debugging()
└── horizon_websso()
└── configure_keystone_cli()
└── configure_keystone_federation()
└── configure_keystone_apache()

install_shib_sp()
└── configure_shib_sp()
```
To install the dependent functions such as `configure_keystone_debugging()` you need to install its parent function first: `setup_devstack()`

---

## Configuration

### Identity Providers (IdPs)
- Add your IdPs to the CSV file at `sp3_supporting_files/idp_list.csv` in the following format:
  ```
  fqdn;idp_entity_id;idp_backup_file;idp_keystone_name;idp_horizon_name;idp_mapping_rules
  ```
- Column Descriptions:
    - `fqdn`: The FQDN (hostname) of the IdP (e.g., idp.localtest).
    - `idp_entity_id`: The SAML Entity ID of the IdP (e.g., https://idp.localtest/idp/shibboleth).
    - `idp_backup_file`: File name for Shib-SP caching the IdP's metadata (e.g., idp.localtest-metadata.xml) in `/etc/cache/shibboleth/`.
    - `idp_keystone_name`: Unique name for the IdP in Keystone (e.g., demoidp).
    - `idp_horizon_name`: Display name for the IdP in Horizon's WebSSO (e.g., demoidp-websso).
    - `idp_mapping_rules`: Name for the mapping rules to link the IdP to Keystone (e.g., demoidp).
- Many functions depend on the existance of the file: `sp3_supporting_files/idp_list.csv`. Please add your IdPs there.

### `/etc/hosts` Configuration
- Ensure all Identity Providers (IdPs) are added to the Service Provider's (SP's) `/etc/hosts` file. Example:
  ```
  192.168.4.101 idp.localtest
  192.168.4.102 idp.localtest1
  ```

---

## Script Details

### Dependency Verification
The script ensures dependent components are installed before executing:
- Independent functions like `setup_devstack()` and `install_shib_sp()` verify their own prerequisites.
- Dependent functions (e.g., `configure_shibsp()`) check the installation state of their parent components before proceeding.

### State Management
- By using `type` command, we determine if the dependent function is allowed to be installed or not. 
- The condition is set to test if the parent functions like `setup_devstack()` is installed or not.
- preventing the user by mistakenly reinstall the parent functions.

### Key Functionalities
- **Fixed and IDP-Specific Directives**: Updates Keystone Apache configuration with both fixed and IdP-specific directives.
- **Federation Resources**: Automates creation of Identity Provider objects, mappings, groups, projects, and roles in Keystone.

---

## Contributions
Contributions to improve the script or add new features are welcome. Please submit a pull request or open an issue for discussion.

---

## Troubleshooting
- Ensure the script is executed with appropriate privileges (root or sudo).
- Verify the `/etc/hosts` file includes all required IdPs.
- Use the logs in `/var/log` for debugging issues.

---

## Resources
mainly focused on the following resources:

- [Devstack's Official Docs](https://docs.openstack.org/devstack/2023.2/)
- [GAAR's How-To tutorial for installing shibboleth SP v3](https://github.com/ConsortiumGARR/idem-tutorials/blob/master/idem-fedops/HOWTO-Shibboleth/Service%20Provider/Debian/HOWTO%20Install%20and%20Configure%20a%20Shibboleth%20SP%20v3.x%20on%20Debian-Ubuntu%20Linux.md)
- [Demystifying Keystone Federation](http://www.gazlene.net/demystifying-keystone-federation.html)
