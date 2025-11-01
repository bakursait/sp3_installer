When you move to a Discovery Service (DS) flow, you stop exposing per-IdP buttons in Horizon and you let **Shibboleth SP** handle IdP selection via DS. 
Below is a clear, end-to-end plan—what to change in Horizon, Keystone/Apache, and Shibboleth SP—plus why each change is needed and how the flow works afterward.

---

# What changes when you use a Discovery Service?

* **Horizon UI**: No per-IdP choices. You give users a single “Sign in with SAML” option (generic protocol). Horizon just redirects the browser to **Keystone’s generic WebSSO endpoint**. ([docs.openstack.org][1])
* **Keystone Apache**: You keep **only the generic** SAML2 protected `<Location>` (no per-IdP `<Location … entityID …>` blocks). The request arrives at Shibboleth SP; **SP triggers DS** to let the user pick an IdP. ([docs.openstack.org][2])
* **Shibboleth SP**: You configure **discoveryProtocol + discoveryURL** (or run the local **Embedded Discovery Service (EDS)**). The SP uses DS to choose an IdP, sends AuthnRequest, consumes the SAML Response, and passes attributes to Keystone. ([shibboleth.atlassian.net][3])

---

# Step-by-step changes

## 1) Horizon (Dashboard)

In `/opt/stack/horizon/openstack_dashboard/local/local_settings.py`:

* Keep WebSSO **enabled**:

  ```python
  WEBSSO_ENABLED = True
  ```

* Make the choices **generic** (no per-IdP rows). E.g.:

  ```python
  from django.utils.translation import gettext_lazy as _

  WEBSSO_CHOICES = (
      ("credentials", _("Keystone Credentials")),
      ("saml2",      _("Single Sign-On (SAML2)")),
  )
  ```

  (No `WEBSSO_IDP_MAPPING` here—removing it stops Horizon from building per-IdP URLs; it will use the **generic** protocol endpoint for SAML2.) ([docs.openstack.org][1])

* (Optional) Make the SSO option selected by default on the login page:

  ```python
  WEBSSO_INITIAL_CHOICE = "saml2"
  ```

  Horizon’s WebSSO logic and these settings are documented in the Horizon/Keystone WebSSO pages. ([docs.openstack.org][1])

> After this, Horizon will redirect to **Keystone’s generic** URL:
>
> ```
> http://<keystone>/identity/v3/auth/OS-FEDERATION/websso/saml2
> ```
>
> not to per-IdP endpoints. ([docs.openstack.org][4])

---

## 2) Keystone (Apache vhost) — keep only generic WebSSO

In your Keystone Apache site (newer DevStack uses `/etc/apache2/sites-available/keystone-api.conf`), keep:

* **Exclude the Shibboleth handler** from proxy:

  ```
  ProxyPass /Shibboleth.sso !
  ```
* **Shibboleth handler**:

  ```apache
  <Location /Shibboleth.sso>
    SetHandler shib
  </Location>
  ```
* **Generic WebSSO** (no `entityID` here):

  ```apache
  <Location /identity/v3/auth/OS-FEDERATION/websso/saml2>
    Require valid-user
    AuthType shibboleth
    ShibRequestSetting requireSession 1
    ShibExportAssertion off
  </Location>
  ```

You can **remove or comment out** the per-IdP `<Location>` blocks such as:

```
/identity/v3/OS-FEDERATION/identity_providers/<idp>/protocols/saml2/auth
/identity/v3/auth/OS-FEDERATION/identity_providers/<idp>/protocols/saml2/websso
```

They’re not used in a DS flow. The generic endpoint will cause Shibboleth SP to invoke the DS. ([docs.openstack.org][2])

Keystone settings remain as you already had for federation:

* `keystone.conf` → `[auth] methods = password,token,saml2,openid`
* `keystone.conf` → `[federation] remote_id_attribute = Shib-Identity-Provider`
* `keystone.conf` → `[federation] trusted_dashboard = http://<horizon>/auth/websso/` (and/or `/dashboard/auth/websso/`)
* `keystone.conf` → `[federation] sso_callback_template = /etc/keystone/sso_callback_template.html` ([docs.openstack.org][2])

---

## 3) Shibboleth SP — enable DS (or EDS)

Edit `/etc/shibboleth/shibboleth2.xml`:

* In `<ApplicationDefaults>`, define **SSO** with **discoveryProtocol** and **discoveryURL** (for a central DS) **or** configure the **EDS** (local, JS-based).

  ```xml
  <SSO discoveryProtocol="SAMLDS"
       discoveryURL="https://ds.example.org/DS/WAYF">
    SAML2
  </SSO>
  ```

  * `discoveryProtocol` is usually `SAMLDS` (modern SAML DS protocol; `WAYF` is legacy).
  * `discoveryURL` points to your Discovery Service (central DS or EDS page). ([shibboleth.atlassian.net][3])

* **If you run the Embedded Discovery Service (EDS)** on the same host:

  * Install and publish the EDS assets and configure Shibboleth’s **DiscoveryFeed** handler (so EDS can list your IdPs from metadata).
  * Shibboleth docs describe EDS requirements and the `/DiscoFeed` JSON feed. ([shibboleth.atlassian.net][5])

* Ensure **MetadataProvider** includes **all IdPs** you want users to select in the DS (exactly as you already do). DS/EDS needs a list of IdPs; SP also needs this metadata to validate SAML. ([shibboleth.atlassian.net][5])

That’s it on the SP side: when a browser hits the **generic** protected URL, mod_shib sees no current SP session and kicks off **discovery** via `discoveryURL`. After the user picks an IdP, the SP redirects to that IdP, receives the SAML Response at `/Shibboleth.sso/SAML2/POST`, establishes an SP session, and forwards the original request to Keystone. ([shibboleth.atlassian.net][3])

---

## 4) Keystone resources still required

You still need Keystone to know your IdPs and how to map users:

* `openstack identity provider create <idp_keystone_name> --remote-id <IdP EntityID>`
* `openstack mapping create <mapping_name> --rules <rules.json>`
* `openstack federation protocol create saml2 --identity-provider <idp> --mapping <mapping_name>`

Keystone uses the `remote_id_attribute` (e.g., `Shib-Identity-Provider`) set by Shibboleth SP to look up the **Identity Provider** object by **remote_id == IdP entityID**. This is independent of DS vs per-IdP buttons—the mapping is still required for token issuance. ([docs.openstack.org][2])

> Note: Keystone supports multiple `remote_ids` on one IdP object if you need that. ([docs.openstack.org][6])

---

# How the new flow looks (DS version)

1. **Horizon** shows only generic “SAML2” (no IdP list) → redirects to
   `http://<keystone>/identity/v3/auth/OS-FEDERATION/websso/saml2`. ([docs.openstack.org][4])
2. **Apache (Keystone vhost)** matches your **generic** `<Location …/websso/saml2>` and invokes **mod_shib**.
3. **mod_shib** sees no SP session → sends the browser to **DS** (per `discoveryProtocol/discoveryURL`). User picks an IdP. ([shibboleth.atlassian.net][3])
4. **IdP** authenticates user → posts SAML Response to SP at `/Shibboleth.sso/SAML2/POST`. ([shibboleth.atlassian.net][3])
5. **mod_shib** validates, creates SP session, exposes attributes (`Shib-Identity-Provider`, etc.) to Keystone.
6. Apache proxies original **generic** WebSSO request to Keystone.
7. **Keystone** matches `remote_id_attribute` to IdP object, applies mapping, issues a token, renders `sso_callback_template` to post the token back to **Horizon** at a `trusted_dashboard` URL. ([docs.openstack.org][2])
8. **Horizon** accepts the token at `/auth/websso/`, establishes a session, and shows the dashboard. ([docs.openstack.org][1])

---

# FAQ / gotchas

* **Should I delete the per-IdP `<Location>` blocks?**
  You can **comment/remove** them for clarity. They’re not used by DS. Keeping only the generic block avoids confusion and guarantees the DS flow is taken. ([docs.openstack.org][2])

* **Do I need to change anything in Keystone besides `trusted_dashboard`, `remote_id_attribute`, `auth.methods`, and the mapping/IdP/protocol objects?**
  No—that’s the standard Keystone federation setup. DS lives in Shibboleth SP; Horizon just points to the generic endpoint. ([docs.openstack.org][2])

* **Which DS to use?**

  * **Central DS** (e.g., federation-hosted) → set `discoveryURL` to that service.
  * **EDS (local)** → deploy the JS app; configure the SP’s **DiscoveryFeed** and point EDS at it. ([shibboleth.atlassian.net][5])

* **Multiple Horizon URLs** (`/auth/websso/` vs `/dashboard/auth/websso/`)?**
  Keystone allows multiple `trusted_dashboard` entries. Add both to be safe if you’re unsure how Horizon is mounted in your build. ([docs.openstack.org][7])

---

## Authoritative references

* **Keystone federation (current admin guide):** creating IdP / mapping / protocol; `remote_id_attribute`, `trusted_dashboard`, `sso_callback_template`. ([docs.openstack.org][2])
* **Horizon WebSSO settings:** `WEBSSO_ENABLED`, `WEBSSO_CHOICES`, `WEBSSO_IDP_MAPPING`, generic-vs-per-IdP behavior. ([docs.openstack.org][1])
* **OS-Federation WebSSO endpoints:** generic vs idp-specific URLs. ([docs.openstack.org][4])
* **Shibboleth SP DS/EDS:** `discoveryProtocol`, `discoveryURL`; Embedded DS and DiscoveryFeed. ([shibboleth.atlassian.net][3])

.

[1]: https://docs.openstack.org/keystone/pike/advanced-topics/federation/websso.html?utm_source=chatgpt.com "Setup Web Single Sign-On (SSO)"
[2]: https://docs.openstack.org/keystone/latest/admin/federation/configure_federation.html?utm_source=chatgpt.com "Configuring Keystone for Federation"
[3]: https://shibboleth.atlassian.net/wiki/spaces/SP3/pages/2065334348/SSO?utm_source=chatgpt.com "SSO - Service Provider 3 - Confluence"
[4]: https://docs.openstack.org/keystone/rocky/advanced-topics/federation/websso.html?utm_source=chatgpt.com "Setup Web Single Sign-On (SSO)"
[5]: https://shibboleth.atlassian.net/wiki/spaces/EDS10/pages/2383446015/Embedded%2BDiscovery%2BService?utm_source=chatgpt.com "Shibboleth Embedded Discovery Service (EDS) - Confluence"
[6]: https://docs.openstack.org/keystone/pike/advanced-topics/federation/configure_federation.html?utm_source=chatgpt.com "Configuring Keystone for Federation"
[7]: https://docs.openstack.org/keystone/stein/admin/federation/configure_federation.html?utm_source=chatgpt.com "Configuring Keystone for Federation"

