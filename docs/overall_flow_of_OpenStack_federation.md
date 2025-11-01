Let’s walk the whole **SAML WebSSO** flow in DevStack + Shibboleth-SP setup, end-to-end, and call out **exact files, components, and URLs** that get involved at each hop. I’ll cover both the **generic protocol** button (e.g., “SAML2”) and the **per-IdP** button (e.g., “idp1.localtest2.lab”), and explain how Apache picks the right `<Location …>` block and how Keystone hands the user back to Horizon.

---

# 0) The players and their config files

* **Horizon (Dashboard)**

  * Django app served by Apache (or uwsgi+Apache), shows the login page and WebSSO choices.
  * Key file: `/opt/stack/horizon/openstack_dashboard/local/local_settings.py`

    * `WEBSSO_ENABLED = True`
    * `WEBSSO_CHOICES` and (optionally) `WEBSSO_IDP_MAPPING` configure the buttons and map them to Keystone IdP+protocol. ([docs.openstack.org][1])

* **Keystone (Identity API)**

  * WSGI app behind Apache’s vhost and `ProxyPass` to a uwsgi socket.
  * Key file: `/etc/keystone/keystone.conf`

    * `[auth] methods = password,token,saml2,openid`
    * `[federation] remote_id_attribute = Shib-Identity-Provider` (typical for Shibboleth)
    * `[federation] trusted_dashboard = http://<horizon>/auth/websso/` (and/or `/dashboard/auth/websso/`)
    * `[federation] sso_callback_template = /etc/keystone/sso_callback_template.html` ([docs.openstack.org][2])

* **Apache vhost for Keystone**

  * DevStack now uses (in this repo's build) `/etc/apache2/sites-available/keystone-api.conf` (older builds used `keystone-wsgi-public.conf`).
  * Must contain:

    * `ProxyPass "/identity" "unix:/var/run/uwsgi/keystone-api.socket|uwsgi://uwsgi-uds-keystone-api" …`
    * `ProxyPass /Shibboleth.sso !` (exclude handler from proxy)
    * `<Location /Shibboleth.sso> SetHandler shib </Location>`
    * **Generic protocol** endpoint protected by Shibboleth:
      `<Location /identity/v3/auth/OS-FEDERATION/websso/saml2> … AuthType shibboleth …`
    * **Per-IdP endpoints** protected by Shibboleth and pinned to that IdP with `ShibRequestSetting entityID <IdP EntityID>`:

      * `/identity/v3/OS-FEDERATION/identity_providers/<idp>/protocols/saml2/auth`
      * `/identity/v3/auth/OS-FEDERATION/identity_providers/<idp>/protocols/saml2/websso` ([docs.openstack.org][2])

* **Shibboleth SP (mod_shib)**

  * Protects Apache locations, initiates SAML, consumes SAML Responses, manages SP session, exposes attributes to Keystone.
  * Key files:

    * `/etc/shibboleth/shibboleth2.xml` (SPConfig; MetadataProvider(s); `<ApplicationDefaults>`; handlers)
    * `/etc/shibboleth/attribute-map.xml` (maps SAML attributes → env/headers for apps)
    * Handler endpoint: `/Shibboleth.sso/...` (ACS, SLO, Metadata, etc.) ([shibboleth.atlassian.net][3])

* **IdP (e.g., `idp1.localtest2.lab`)**

  * Hosts login page, authenticates the user, issues SAML Response back to the SP’s ACS `(https://<sp>/Shibboleth.sso/SAML2/POST)`.

---

# 1) User opens Horizon and clicks a WebSSO choice

**1.1** User visits the Horizon URL in a browser (e.g., `http://<horizon-host>/`).
Horizon renders the login form. Because `WEBSSO_ENABLED = True`, it shows a dropdown/tiles for SSO options from `WEBSSO_CHOICES`. ([docs.openstack.org][1])

**1.2** The user chooses:

* **Generic protocol** “SAML2”: Horizon constructs a redirect to Keystone’s **generic protocol** WebSSO endpoint:
  `http://<keystone-host>/identity/v3/auth/OS-FEDERATION/websso/saml2` ([docs.openstack.org][4])
* **Per-IdP** (e.g., “idp1.localtest2.lab” via `WEBSSO_IDP_MAPPING`): Horizon calls the **per-IdP WebSSO** endpoint:
  `http://<keystone-host>/identity/v3/auth/OS-FEDERATION/identity_providers/<idp_keystone_name>/protocols/saml2/websso` ([docs.openstack.org][4])

> Horizon doesn’t authenticate the user itself when WebSSO is chosen. Instead, it sends the browser to **Keystone’s** WebSSO URL, chosen by protocol or by specific IdP+protocol mapping. ([docs.openstack.org][5])

---

# 2) Apache (Keystone vhost) receives the WebSSO request and invokes Shibboleth

**2.1** The request hits Apache’s Keystone site (`keystone-api.conf`).
Apache routes `/identity/...` through `ProxyPass` to Keystone **except** for locations guarded by Shibboleth, which are **handled by mod_shib first** (because of `<Location …> AuthType shibboleth` blocks).

* For **generic protocol** URL `/identity/v3/auth/OS-FEDERATION/websso/saml2`:
  Apache matches `<Location /identity/v3/auth/OS-FEDERATION/websso/saml2>` block → `AuthType shibboleth`, `Require valid-user`, etc. **mod_shib** enforces a Shibboleth session. If the browser isn’t already in a Shibboleth SP session, mod_shib **initiates SAML**.
* For **per-IdP** URL `/identity/v3/auth/OS-FEDERATION/identity_providers/<idp>/protocols/saml2/websso`:
  Apache hits the per-IdP `<Location>` block that includes `ShibRequestSetting entityID https://idp1.localtest2.lab/idp/shibboleth`. This **pins the SAML initiation** to that specific IdP’s metadata. ([docs.openstack.org][2])

**2.2** SAML initiation and redirect to IdP

* mod_shib constructs an AuthnRequest (using settings from `/etc/shibboleth/shibboleth2.xml` and the `<MetadataProvider>` entries you injected).
* The browser is redirected to the IdP’s SSO endpoint. (This is entirely handled by mod_shib; you don’t proxy this to Keystone.) ([shibboleth.atlassian.net][3])

---

# 3) At the IdP

**3.1** User logs in at the IdP (e.g., `idp1.localtest2.lab`).
**3.2** The IdP issues a **SAML Response** (signed; optionally encrypted), posting it back to the SP’s **Assertion Consumer Service (ACS)** at:
`https://<keystone-host>/Shibboleth.sso/SAML2/POST`
(That’s the standard Shibboleth SP ACS endpoint path.) ([shibboleth.atlassian.net][3])

---

# 4) Shibboleth SP consumes the assertion and creates an SP session

**4.1** mod_shib (Shibboleth SP) validates the SAML Response, checks signatures, conditions, audience, NameID, etc., using the metadata configured in `/etc/shibboleth/shibboleth2.xml` (`<MetadataProvider … url="…">`). ([shibboleth.atlassian.net][3])

**4.2** SP establishes a **Shibboleth session**, and exposes attributes to the protected application (Keystone) via **CGI environment variables/HTTP headers**, according to `/etc/shibboleth/attribute-map.xml`. Commonly you’ll surface:

* the IdP’s entityID as `Shib-Identity-Provider` (the “remote ID” Keystone uses to pick the IdP object), and
* user attributes (e.g., `eduPersonPrincipalName`, `mail`, etc.) for mapping rules.
  (OpenStack docs also caution not to rely on `REMOTE_USER` directly with Shibboleth; use mapped attributes.) ([docs.openstack.org][6])

> This is where Keystone setting **`[federation] remote_id_attribute = Shib-Identity-Provider`** matters. Keystone will read that variable to know *which* IdP authenticated the user so it can apply the right mapping. ([docs.openstack.org][2])

---

# 5) Apache now forwards the request to Keystone (behind ProxyPass)

**5.1** With a valid Shibboleth session in place, Apache proxies the **original** WebSSO URL to Keystone via:
`ProxyPass "/identity" "unix:/var/run/uwsgi/keystone-api.socket|uwsgi://uwsgi-uds-keystone-api" …`
The request carries the Shibboleth-set environment variables/headers to the Keystone WSGI app. (`ProxyPass /Shibboleth.sso !` ensures handler traffic is never proxied.)

**5.2** Keystone receives the request at its **WebSSO** route (either the generic protocol path or the per-IdP path; both are part of Keystone’s OS-FEDERATION v3 extensions). It reads:

* `remote_id_attribute` (e.g., `Shib-Identity-Provider`) to match an **Identity Provider** object created via `openstack identity provider create --remote-id <IdP EntityID>`, and
* the other SAML attributes exposed by Shibboleth, then applies **mapping rules** to derive a local user + group + project (or domain) for token issuance. ([docs.openstack.org][4])

---

# 6) Keystone issues a token and uses the SSO callback template

**6.1** If the IdP is recognized and the mapping succeeds, Keystone creates a token (unscoped or scoped depending on flow/mapping) and returns an HTML page rendered from:
`/etc/keystone/sso_callback_template.html`
**`[federation] sso_callback_template`** setting tells Keystone what template to use. The template’s JS/HTML **POSTs the token** to Horizon’s **trusted dashboard** URL. ([guides.dataverse.org][7])

**6.2** The post target must be on **trusted_dashboard** allow-list, which configured in `[federation]`:

* e.g., `trusted_dashboard = http://<horizon>/auth/websso/`
  (and, for some layouts, also `/dashboard/auth/websso/`). Keystone refuses to post tokens to non-trusted origins. ([docs.openstack.org][2])

---

# 7) Horizon receives the token and logs the user in

**7.1** Horizon’s WebSSO view (`/auth/websso/`) accepts the POST, reads the Keystone token, and exchanges/validates it against the Keystone API it’s configured to use (typically `OPENSTACK_KEYSTONE_URL = "http://<keystone>/v3"`).
**7.2** Horizon creates the user session and redirects to the dashboard.
This behavior hinges on Horizon’s WebSSO settings being enabled and correctly mapped. ([docs.openstack.org][1])

---

# How Apache “picks the right IdP directive”

* **Per-IdP** buttons call a URL that includes the IdP name:

  ```
  /identity/v3/auth/OS-FEDERATION/identity_providers/<idp_keystone_name>/protocols/saml2/websso
  ```

  Your Apache vhost contains **one `<Location …>` block per IdP** with:

  ```apache
  AuthType shibboleth
  ShibRequestSetting requireSession 1
  ShibRequestSetting entityID https://idp1.localtest2.lab/idp/shibboleth
  ```

  That `entityID` line tells mod_shib *which identity provider metadata* to use for the SAML AuthnRequest, so the browser is sent to the correct IdP without any discovery step. Apache “picks” the right block simply by matching the request path to the `<Location …>` you wrote for that IdP. Keystone later confirms it via the `remote_id_attribute` in the incoming environment and matches it with the Keystone **IdP object** whose `remote_id` is the IdP’s EntityID. ([docs.openstack.org][2])

* **Generic protocol** button (no IdP in the URL) hits:

  ```
  /identity/v3/auth/OS-FEDERATION/websso/saml2
  ```

  In this case your generic `<Location …/websso/saml2>` block doesn’t set `entityID` (good). How the IdP is chosen then depends on your Shibboleth SP config (e.g., default `SessionInitiator`, `Discovery` settings) if you use discovery, but in many admin-controlled environments you stick to the per-IdP URLs for a deterministic flow. ([shibboleth.atlassian.net][3])

---

# Typical gotchas (and where each lives)

1. **Wrong Horizon target** in Keystone:

   * Horizon mounted at `/` vs `/dashboard/` → set **both** trusted URLs to be safe:
     `http://<horizon>/auth/websso/` and `http://<horizon>/dashboard/auth/websso/`. ([guides.dataverse.org][7])

2. **`remote_id_attribute` mismatch**:

   * Keystone expects `Shib-Identity-Provider`, but your Apache exposes `HTTP_SHIB_IDENTITY_PROVIDER` or you mapped differently. Align this in `keystone.conf` and/or your attribute map. ([docs.openstack.org][2])

3. **`ProxyPass /Shibboleth.sso !` missing**:

   * If you forget it, Apache might proxy handler requests to Keystone uwsgi instead of letting mod_shib handle them → SAML breakage.

4. **`WEBSSO_CHOICES` vs Keystone resources**:

   * The **ids** listed in Horizon must correspond to actual Keystone IdP+protocol combinations (`openstack identity provider create`, `openstack federation protocol create`). ([OpenDev: Free Software Needs Free Tools][8])

5. **Shibboleth REMOTE_USER behavior**:

   * Historical docs warn not to let Shibboleth set `REMOTE_USER` in a way that conflicts with Keystone’s external auth semantics; rely on mapped attributes instead. ([docs.openstack.org][6])

---

## TL;DR sequence (wire-level)

1. **Browser → Horizon** (login page with WebSSO choices). ([docs.openstack.org][1])
2. **Browser → Keystone WebSSO URL** (generic or per-IdP). ([docs.openstack.org][4])
3. **Apache (Keystone vhost) → mod_shib** (protected `<Location>` requires Shibboleth session).
4. **mod_shib → IdP** (redirect for login; entityID pinned in per-IdP flow). ([shibboleth.atlassian.net][3])
5. **IdP → mod_shib** (POST SAML Response to `/Shibboleth.sso/SAML2/POST`). ([shibboleth.atlassian.net][3])
6. **mod_shib → Apache → Keystone** (forward original WebSSO URL with attributes in env/headers).
7. **Keystone** (matches `remote_id_attribute`, applies mapping, issues token, renders `sso_callback_template`). ([docs.openstack.org][2])
8. **Browser → Horizon** (token POST to trusted_dashboard). ([docs.openstack.org][2])
9. **Horizon ↔ Keystone** (validates token, establishes session, shows dashboard). ([docs.openstack.org][1])

---

## Solid references (for deeper dives)

* **Keystone: Configuring federation (current admin guide)** — `auth.methods`, `trusted_dashboard`, `remote_id_attribute`, templates, and overall flow. ([docs.openstack.org][2])
* **Horizon settings** — `WEBSSO_ENABLED`, `WEBSSO_CHOICES`, `WEBSSO_IDP_MAPPING`, notes on versions. ([docs.openstack.org][1])
* **Keystone OS-FEDERATION API (identity v3 extensions)** — paths used by WebSSO endpoints. ([docs.openstack.org][4])
* **Shibboleth SP handlers & flow** — `/Shibboleth.sso` endpoints and SAML processing model. ([shibboleth.atlassian.net][3])
* **Caution on REMOTE_USER with Shibboleth** — use mapped attributes. ([docs.openstack.org][6])


[1]: https://docs.openstack.org/horizon/latest/configuration/settings.html?utm_source=chatgpt.com "Settings Reference — horizon 25.6.0.dev22 documentation"
[2]: https://docs.openstack.org/keystone/latest/admin/federation/configure_federation.html?utm_source=chatgpt.com "Configuring Keystone for Federation"
[3]: https://shibboleth.atlassian.net/wiki/spaces/SHIB2/pages/2577072366/NativeSPHandler?utm_source=chatgpt.com "Metadata Generation Handler - Shibboleth 2 - Confluence"
[4]: https://docs.openstack.org/api-ref/identity/v3-ext/?utm_source=chatgpt.com "Identity API v3 extensions (CURRENT) — keystone ..."
[5]: https://docs.openstack.org/keystone/pike/advanced-topics/federation/websso.html?utm_source=chatgpt.com "Setup Web Single Sign-On (SSO)"
[6]: https://docs.openstack.org/keystone/9.3.0/federation/shibboleth.html?utm_source=chatgpt.com "Setup Shibboleth — keystone 9.3.0 documentation"
[7]: https://guides.dataverse.org/en/5.4/installation/shibboleth.html?utm_source=chatgpt.com "Shibboleth — Dataverse.org"
[8]: https://opendev.org/openstack/tripleo-heat-templates/commit/829cde2f35a7f2561e747693796fd9292d2920b7?utm_source=chatgpt.com "Merge \"Add horizon WebSSO support for OpenID Connect\""

