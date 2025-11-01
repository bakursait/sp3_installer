## 🧩 1. Purpose of `idp_list.csv`

This file is **critical** for your installer because it acts like a database for your **Identity Providers (IdPs)**.
Each line represents **one IdP**, and the script uses it to configure Shibboleth SP, Horizon (WebSSO), and Keystone federation mappings.

It tells the installer **which IdPs exist**, and for each IdP it provides the parameters needed to:

* Insert the IdP’s metadata into `/etc/shibboleth/shibboleth2.xml`
* Register that IdP in Keystone as an **identity provider**
* Create the **mapping rules**, **groups**, and **projects** in Keystone
* Configure **Horizon WebSSO** dropdown entries (via the `configure_horizon_websso()` function)

So:
💡 Think of `idp_list.csv` as a “master list” of all your federated IdPs — like a small registry.

---

## 📄 2. Structure of the CSV

It’s **semicolon (`;`) separated**, with **six columns**.
Here’s the header row (you must keep it):

```
fqdn;idp_entity_id;idp_backup_file;idp_keystone_name;idp_horizon_name;idp_mapping_rules
```

Let’s break these down:

| Column                   | Example                                      | Used by                       | Meaning                                                                                                     |
| ------------------------ | -------------------------------------------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **1. fqdn**              | `idp1.localtest2.lab`                        | Optional (display in Horizon) | The DNS name or host of the IdP. Used only for clarity.                                                     |
| **2. idp_entity_id**     | `https://idp1.localtest2.lab/idp/shibboleth` | Shibboleth SP, Keystone       | The **SAML EntityID** — must match the one in the IdP metadata.                                             |
| **3. idp_backup_file**   | `idp1.localtest2.lab-metadata.xml`           | Shibboleth SP                 | Local filename (in `/etc/shibboleth`) where metadata will be cached.                                        |
| **4. idp_keystone_name** | `demoidp1.localtest2.lab-websso`             | Keystone CLI                  | The short internal name used when registering the IdP in Keystone. Must be unique.                          |
| **5. idp_horizon_name**  | `demoidp1.localtest2.lab`                    | Horizon WebSSO                | The label (key) shown in Horizon’s dropdown list.                                                           |
| **6. idp_mapping_rules** | `demoidp1.localtest2.lab`                    | Keystone CLI                  | The name of the mapping JSON object (the one created with `openstack mapping create`). Also must be unique. |

---

## ✅ 3. Example: Two working IdPs

Here’s a valid, complete example you can rebuild yours from:

```
fqdn;idp_entity_id;idp_backup_file;idp_keystone_name;idp_horizon_name;idp_mapping_rules
idp.localtest1;https://idp.localtest1/idp/shibboleth;idp.localtest1-metadata.xml;demoidp1;demoidp1-websso;demoidp1
idp1.localtest2.lab;https://idp1.localtest2.lab/idp/shibboleth;idp1.localtest2.lab-metadata.xml;demoidp1.localtest2.lab-websso;demoidp1.localtest2.lab;demoidp1.localtest2.lab
```

Each line provides the six expected values.
When you run your function, it will create:

| IdP                            | Mapping                 | Group                                          | Project                                          | Protocol |
| ------------------------------ | ----------------------- | ---------------------------------------------- | ------------------------------------------------ | -------- |
| demoidp1                       | demoidp1                | federated_users_demoidp1                       | federated_project_demoidp1                       | saml2    |
| demoidp1.localtest2.lab-websso | demoidp1.localtest2.lab | federated_users_demoidp1.localtest2.lab-websso | federated_project_demoidp1.localtest2.lab-websso | saml2    |

---

## ⚠️ 4. Common mistakes to avoid

| Mistake                                          | Symptom                                                                            | Fix                                                                     |
| ------------------------------------------------ | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Missing 6th column (`idp_mapping_rules`)         | Error `MappingResource.put() missing 1 required positional argument: 'mapping_id'` | Always ensure 6 columns (even if you reuse the IdP name as mapping ID). |
| Using commas instead of semicolons               | Script misreads fields or fails                                                    | Always use `;` as the delimiter.                                        |
| Trailing spaces or Windows line endings (`\r\n`) | CSV parsing errors or missing data                                                 | Use `dos2unix idp_list.csv` and `cat -A` to check.                      |
| Duplicated IdP names                             | Keystone says *already exists*                                                     | Keep all `idp_keystone_name` unique.                                    |

---

## 🧠 5. How to remember easily

Think of the six columns in **logical workflow order**:

1️⃣ What’s the IdP host → `fqdn`
2️⃣ Where is it on the web → `idp_entity_id`
3️⃣ Where do I store its metadata → `idp_backup_file`
4️⃣ What do I call it inside Keystone → `idp_keystone_name`
5️⃣ What name shows up in Horizon → `idp_horizon_name`
6️⃣ What mapping object connects it → `idp_mapping_rules`

Mnemonic:
**“From Host → EntityID → Metadata → Keystone → Horizon → Mapping”**

---

## 🧩 6. Quick validation before running

Run this check any time before executing your installer:

```bash
awk -F';' 'NR>1 && NF!=6 {print "❌ Line", NR, "has", NF, "fields"}' sp3_supporting_files/idp_list.csv
```

If no output — ✅ your CSV is valid.

---

