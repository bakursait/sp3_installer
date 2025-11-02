# OpenStack + Shibboleth SP3 Installer (DevStack-2025.x)

This repository automates the full setup of a **federated OpenStack environment (DevStack)** integrated with **Shibboleth Service Provider v3 (SP3)** using SAML2.
It configures Keystone, Horizon (Dashboard), Apache, and Shibboleth end-to-end for SSO federation with one or more Identity Providers (IdPs).

The installer ensures **idempotent**, **modular**, and **version-aware** configuration—tested on **DevStack 2025.x/2026.1** with **Ubuntu 22.04**.

---

## 🚀 Key Features

* **Automated setup** of DevStack and Shibboleth SP3 (SAML2).
* **Automatic creation of Keystone federation resources**:

  * Identity Providers, mappings, groups, projects, roles, and federation protocols.
* **Horizon WebSSO configuration** with correct dashboard URLs.
* **Apache (Keystone vhost) configuration** for SAML federation:

  * Generic WebSSO directives.
  * Optional per-IdP directives (for non-DS mode).
* **Discovery Service (DS or EDS)** support:

  * Optional Embedded Discovery Service integration.
* **Error-safe and idempotent**: safe to re-run for reconfiguration.
* **Version compatibility** with new `keystone-api.conf` layout in DevStack ≥ 2025.x.

---

## 🧠 System Requirements

| Component    | Recommended                               |
| ------------ | ----------------------------------------- |
| **OS**       | Ubuntu 22.04 LTS                          |
| **RAM**      | ≥ 4 GB                                    |
| **CPU**      | 2+ cores                                  |
| **Disk**     | 100 GB                                    |
| **DevStack** | 2025.x or newer (`stable/2025.2` branch)  |
| **SP**       | Shibboleth SP3.x                          |
| **Python**   | 3.10+                                     |

---

## 📦 Directory Overview

```
sp3_installer/
├── install_local_sp3.sh             # main installer
├── sp3_supporting_files/
│   ├── idp_list.csv                 # IdP list used for federation setup
│   └── templates/
│       └── local_settings.py.sample # sample Horizon config
├── docs/
│   ├── doc-devstack.pdf             # release 2025.2
│   ├── doc-horizon.pdf              # release 2025.2
│   ├── doc-Keystone.pdf             # release 2025.2
│   └── list of docs to explain the code
├── /etc/shibboleth/                 # Shibboleth SP config (after install)
└── /etc/apache2/sites-available/
    └── keystone-api.conf            # Keystone vhost (used in new DevStack)
```

---

## ⚙️ Installation Steps

### 1. Clone the repository

```bash
git clone https://github.com/bakursait/sp3_installer.git
cd sp3_installer/
```

### 2. Prepare the environment

Ensure the following packages exist (installer checks automatically):

```bash
sudo apt install -y git curl bash python3 crudini
```

### 3. Edit your IdP list

Edit `sp3_supporting_files/idp_list.csv`:

```csv
fqdn;idp_entity_id;idp_backup_file;idp_keystone_name;idp_horizon_name;idp_mapping_rules
idp1.localtest2.lab;https://idp1.localtest2.lab/idp/shibboleth;idp1.xml;demoidp1;demoidp1-websso;demoidp1
```

Each field means:

| Field               | Description                                      |
| ------------------- | ------------------------------------------------ |
| `fqdn`              | IdP hostname                                     |
| `idp_entity_id`     | The SAML entityID for the IdP                    |
| `idp_backup_file`   | Metadata backup filename (in `/etc/shibboleth/`) |
| `idp_keystone_name` | Keystone name for this IdP                       |
| `idp_horizon_name`  | Display label in Horizon WebSSO                  |
| `idp_mapping_rules` | Keystone mapping JSON name                       |

---

## 🧩 Available Installer Options

| Command                                                 | Description                                                           |
| ------------------------------------------------------- | --------------------------------------------------------------------- |
| `./install_local_sp3.sh devstack`                       | Installs and configures DevStack                                      |
| `./install_local_sp3.sh shibsp`                         | Installs and configures Shibboleth SP3                                |
| `./install_local_sp3.sh horizon_websso`                 | Configures Horizon for SAML WebSSO                                    |
| `./install_local_sp3.sh configure_keystone_cli`         | Creates Keystone federation resources (IdP, mapping, groups, etc.)    |
| `./install_local_sp3.sh configure_keystone_federation`  | Updates Keystone federation settings in `/etc/keystone/keystone.conf` |
| `sudo ./install_local_sp3.sh configure_keystone_apache` | Adds SAML2 directives to Keystone’s Apache vhost                      |
| `sudo ./install_local_sp3.sh configure_shibsp`          | Reconfigures Shibboleth SP handlers and metadata (if needed)          |

> Each function checks prerequisites and runs idempotently (safe to re-run).

---

## 🧮 Function Workflow

```
install_local_sp3.sh
│
├── setup_devstack()
│   ├── configure_keystone_debugging()
│   ├── horizon_websso()
│   ├── configure_keystone_cli()
│   ├── configure_keystone_federation()
│   └── configure_keystone_apache()
│
└── install_shib_sp()
    └── configure_shib_sp()
```

---

## 🌐 Configuration Highlights

### 1. Keystone (Identity)

* **Main config**: `/etc/keystone/keystone.conf`

  ```ini
  [auth]
  methods = password,token,saml2,openid

  [federation]
  remote_id_attribute = Shib-Identity-Provider
  trusted_dashboard = http://192.168.4.221/dashboard/auth/websso/
  sso_callback_template = /etc/keystone/sso_callback_template.html
  ```
* Federation resources (created via CLI):

  * IdPs, mappings, groups, projects, and roles.
  * Protocol: `saml2`

---

### 2. Horizon (Dashboard)

* File: `/opt/stack/horizon/openstack_dashboard/local/local_settings.py`
* **Generic WebSSO (default)**:

  ```python
  WEBSSO_ENABLED = True
  WEBSSO_CHOICES = (
      ("credentials", _("Keystone Credentials")),
      ("saml2", _("Federated Login (SAML2)")),
  )
  WEBSSO_INITIAL_CHOICE = "saml2"
  ```
* Optional per-IdP mapping (if you don’t use DS):

  ```python
  WEBSSO_IDP_MAPPING = {
      "demoidp1-websso": ("demoidp1", "saml2"),
  }
  ```
* Horizon redirects the browser to Keystone’s WebSSO endpoint(s).
  The returned SAML token is verified, then Horizon establishes the session.

---

### 3. Keystone Apache (vhost)

* DevStack 2025+ uses: `/etc/apache2/sites-available/keystone-api.conf`

  ```apache
  ProxyPass "/identity" "unix:/var/run/uwsgi/keystone-api.socket|uwsgi://uwsgi-uds-keystone-api" retry=0 acquire=1
  ProxyPass /Shibboleth.sso !
  <Location /Shibboleth.sso>
      SetHandler shib
  </Location>
  
  <!-- generic WebSSO block -->
  <Location /identity/v3/auth/OS-FEDERATION/websso/saml2>
      AuthType shibboleth
      ShibRequestSetting requireSession 1
      Require valid-user
  </Location>
  ```
* Per-IdP `<Location>` blocks are automatically added by the script if `idp_list.csv` is present. for example, we get the following `<Location>` blocks for the IdP: `idp1.localtest2.lab`:
  ```apache
  # Per-IdP AUTH endpoint
  <Location /identity/v3/OS-FEDERATION/identity_providers/demo-idp1-localtest2-lab/protocols/saml2/auth>
    Require valid-user
    AuthType shibboleth
    ShibRequestSetting requireSession 1
    ShibRequestSetting entityID https://idp1.localtest2.lab/idp/shibboleth
    ShibExportAssertion off
  </Location>

  # Per-IdP WebSSO endpoint
  <Location /identity/v3/auth/OS-FEDERATION/identity_providers/demo-idp1-localtest2-lab/protocols/saml2/websso>
    Require valid-user
    AuthType shibboleth
    ShibRequestSetting requireSession 1
    ShibRequestSetting entityID https://idp1.localtest2.lab/idp/shibboleth
    ShibExportAssertion off
  </Location>
  ```

* In DS mode, you only keep the generic WebSSO block.

---

### 4. Shibboleth SP

* Config file: `/etc/shibboleth/shibboleth2.xml`

  ```xml
  <ApplicationDefaults entityID="https://sp1.localtest2.lab/shibboleth"
                       homeURL="http://192.168.4.221/"
                       REMOTE_USER="eppn persistent-id targeted-id">

      <!--
	      <SSO discoveryProtocol="SAMLDS"
		   discoveryURL="http://192.168.4.210/shibboleth-ds">
		  SAML2
	      </SSO>
      -->
      <Sessions lifetime="28800" timeout="3600" relayState="ss:mem">
          <Handler type="Metadata" Location="/Metadata" />
          <Handler type="Status" Location="/Status" />
          <Handler type="Session" Location="/Session" showAttributeValues="true"/>
      </Sessions>
  </ApplicationDefaults>
  ```

* Attributes exposed to Keystone:

  * `Shib-Identity-Provider`
  * `REMOTE_USER` or `eppn`
  * others defined in `/etc/shibboleth/attribute-map.xml`
* Since the OpenStack-Shib-SP system will be connected to multiple IdPs, the block `<SSO/>` is going to be ignored. 
* In our code, each IdP has its representative directives, as discussed above. At each directive, we have the property: `ShibRequestSetting entityID https://idp1.localtest2.lab/idp/shibboleth`. This property is what lead Keystone to identify the IdP's entityID. if not provided, Keystone will ask the Shib-SP for the IdP that is defined in `/etc/shibboleth/shibboleth2.xml` in tag `<SSO/>`.

* The block `<SSO>` refers to ONLY ONE IdP or Discovery Service.
---

## 🧭 (Optional) Enabling Discovery Service (DS/EDS)

* Note: This service is NOT configured here. Just show you the overall process.

If you want users to select their IdP on a **DS page** instead of Horizon’s dropdown:

1. **In Horizon**:

   * Keep only the generic SAML2 choice:

     ```python
     WEBSSO_CHOICES = (("saml2", _("Single Sign-On (SAML2)")),)
     ```
   * Remove or comment `WEBSSO_IDP_MAPPING`.

2. **In Keystone Apache**:

   * Remove all per-IdP `<Location>` blocks.
   * Keep only:

     ```apache
     <Location /identity/v3/auth/OS-FEDERATION/websso/saml2>
       AuthType shibboleth
       Require valid-user
       ShibRequestSetting requireSession 1
     </Location>
     ```

3. **In Shibboleth SP (`shibboleth2.xml`)**:

   * Set discovery service parameters:

     ```xml
     <SSO discoveryProtocol="SAMLDS"
          discoveryURL="http://192.168.4.210/shibboleth-ds">
         SAML2
     </SSO>
     ```
   * (Optional) configure local **Embedded Discovery Service (EDS)** for internal networks.

4. **Restart Services**:

   ```bash
   sudo systemctl restart shibd apache2 devstack@keystone
   ```
5. **NOTES**:
   * Since we want to configure DS, we configure the element `<SSO/>` in the shibboleth-sp configuration file `/etc/shibboleth/shibboleth2.xml` to accept DS. 
   * This way, Keystone sees a request comes from Horizon with no IdP info provided, only the protocol SAML2. so it calls the generic block endpoint `/identity/v3/auth/OS-FEDERATION/websso/saml2`.
---

## 🛠️ Troubleshooting Tips

| Problem                                    | Cause                                                    | Fix                                                           |
| ------------------------------------------ | -------------------------------------------------------- | ------------------------------------------------------------- |
| Browser loops between Horizon and Keystone | `trusted_dashboard` missing or wrong in `keystone.conf`  | Add both: `/auth/websso/` and `/dashboard/auth/websso/`       |
| 400 error in mapping                       | Mapping name or `remote_id_attribute` mismatch           | Ensure `Shib-Identity-Provider` matches IdP `entityID`        |
| “No metadata for IdP”                      | Metadata not loaded in `/etc/shibboleth/shibboleth2.xml` | Add `<MetadataProvider>` for each IdP or metadata aggregate   |
| SAML works, but Keystone denies            | Mapping rules incorrect                                  | Test mapping with `openstack mapping list --long`             |
| Apache shows 404 on `/Shibboleth.sso`      | Missing `ProxyPass /Shibboleth.sso !` directive          | Add before all `ProxyPass /identity` lines                    |
| Token post fails                           | `trusted_dashboard` mismatch or not HTTPS                | Use the same scheme (http/https) between Keystone and Horizon |

---

## 🔍 Logs & Diagnostics

| Component         | Log Path                                  |
| ----------------- | ----------------------------------------- |
| Keystone          | `/opt/stack/logs/keystone.log`            |
| Apache (Keystone) | `/var/log/apache2/keystone-api-error.log` |
| Shibboleth SP     | `/var/log/shibboleth/shibd.log`           |
| Horizon           | `/opt/stack/logs/horizon.log`             |

---

## 📚 References

* [OpenStack Keystone Federation Guide (2025.x)](https://docs.openstack.org/keystone/latest/admin/federation/introduction.html)
* [Horizon WebSSO Configuration](https://docs.openstack.org/horizon/latest/configuration/settings.html#websso)
* [DevStack Configuration Reference](https://docs.openstack.org/devstack/latest/)
* [Shibboleth SP3 Documentation](https://shibboleth.atlassian.net/wiki/spaces/SP3/overview)
* [Embedded Discovery Service (EDS)](https://shibboleth.atlassian.net/wiki/spaces/EDS/pages/24805892/EDS)
* [GARR Tutorial – Install & Configure Shibboleth SP3](https://github.com/ConsortiumGARR/idem-tutorials/blob/master/idem-fedops/HOWTO-Shibboleth/Service%20Provider/Debian/HOWTO%20Install%20and%20Configure%20a%20Shibboleth%20SP%20v3.x%20on%20Debian-Ubuntu%20Linux.md)
* [Demystifying Keystone Federation](http://www.gazlene.net/demystifying-keystone-federation.html)

---

Would you like me to also generate a **diagram (architecture + flow)** to include in this README — showing the path from Horizon → Keystone → Shibboleth SP → IdP → back to Horizon?
It would make the README much clearer visually.

