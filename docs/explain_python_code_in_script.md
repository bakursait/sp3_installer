# Introduction:
Oct-10-2025
Below is a new update to the implementation of the function `configure_horizon_websso()`. the function is one of the primary steps in the main script `install_local_sp3.sh`. it reads the Horizon configuration file `local_settings.py`, enable WebSSO tools to the Horizon, add IdPs and their protocols to the Horizon's list so the enduser see dropdown options to pick their corresponding IdP, and finally link these settings to the Keystone Service.

---
# Improvements:

- The old version of this function `configure_horizon_websso()` calls python script `configure_horizon_websso.py` to do this job. The new script improved and it will avoid calling the python script, because we let the function spawn a python script within the function `configure_horizon_websso()`.
- Instead of writing to the main Horizon conf file `openstack_dashboard/local/local_settings.py`, [Horizon Docs](https://docs.openstack.org/horizon/latest/configuration/settings.html?utm_source=chatgpt.com#introduction) suggests that we "Add .py settings snippets to the `openstack_dashboard/local/local_settings.d/` directory." 
  - All files within this directory, `openstack_dashboard/local/local_settings.d/`, must begine with underscore `_`.
- The code we provide here write the those settings to a file inside the directory `openstack_dashboard/local/local_settings.d/`, as suggested by the [Horizon Docs](https://docs.openstack.org/horizon/latest/configuration/settings.html?utm_source=chatgpt.com#introduction).

---

# The function (reference)

```bash
# Generate Horizon WebSSO settings as a snippet and restart Horizon
configure_horizon_websso() {
  echo "Configuring Horizon for SSO (snippet-based)..."

  # --- Paths & prerequisites (host-side) ---
  : "${STACK_USER:=stack}"
  : "${STACK_USER_HOME:=/opt/stack}"  # DevStack default
  # Your CSV lives with the installer repo; adjust if different:
  local CSV_ON_HOST="${MAIN_DIRECTORY_LOCATION:-/home/${SUDO_USER:-$USER}/sp3_installer}/sp3_supporting_files/idp_list.csv"

  # Destination snippet loaded AFTER local_settings.py (preferred by Horizon)
  local SNIPPET_ON_HOST="/opt/stack/horizon/openstack_dashboard/local/local_settings.d/_10_websso.py"

  if [[ ! -r "$CSV_ON_HOST" ]]; then
    echo "Error: CSV file not found or unreadable: $CSV_ON_HOST"
    exit 1
  fi

  # --- Run as stack: parse CSV and (re)write the snippet atomically ---
  # Pass env vars into the heredoc so nounset (-u) is safe inside.
  sudo -i -u "$STACK_USER" CSV_ON_HOST="$CSV_ON_HOST" SNIPPET_ON_HOST="$SNIPPET_ON_HOST" bash <<'EOF'
set -euo pipefail

# Ensure snippet directory exists and is readable by Horizon
install -d -m 755 "$(dirname "$SNIPPET_ON_HOST")"

python3 - <<'PY'
import csv, pathlib, sys

csv_path   = pathlib.Path(__import__('os').environ['CSV_ON_HOST'])
snippet    = pathlib.Path(__import__('os').environ['SNIPPET_ON_HOST'])

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
```

---

# What the function is doing (high level)

1. It **prepares paths and defaults** for the `stack` user, the CSV input, and the destination snippet (`_10_websso.py`).
2. It **runs a heredoc as the `stack` user**, with strict shell safety (`set -euo pipefail`).
3. Inside that heredoc, it **creates the snippet directory**, then **runs a Python block** that:

   * reads your IdP CSV,
   * builds the four Horizon WebSSO settings,
   * writes them to `_10_websso.py` atomically.
4. It **restarts Apache** so Horizon reloads settings.
5. It **reports success or failure**.

This approach is **idempotent** (safe to run repeatedly), **upgrade-safe** (uses `local_settings.d/`), and **simple** (no fragile regex edits to Python).

---

# Detailed explanation (line by line, grouped)

## 1) Defaults and paths (host-side Bash)

```bash
: "${STACK_USER:=stack}"
: "${STACK_USER_HOME:=/opt/stack}"
```

* `: "${VAR:=default}"` means “if VAR is unset or empty, set it to default.”
* So this guarantees `STACK_USER` is `stack` and `STACK_USER_HOME` is `/opt/stack` unless you override them before calling the function.

```bash
local CSV_ON_HOST="${MAIN_DIRECTORY_LOCATION:-/home/${SUDO_USER:-$USER}/sp3_installer}/sp3_supporting_files/idp_list.csv"
```

* Builds the expected **CSV path**. If `MAIN_DIRECTORY_LOCATION` isn’t set, it falls back to your home’s `sp3_installer/sp3_supporting_files/idp_list.csv`.
* You can override `MAIN_DIRECTORY_LOCATION` if you store the CSV somewhere else.

```bash
local SNIPPET_ON_HOST="/opt/stack/horizon/openstack_dashboard/local/local_settings.d/_10_websso.py"
```

* This is where Horizon expects override snippets. Files in `local_settings.d/` are loaded **after** `local_settings.py`. This is the recommended Horizon pattern because it preserves your changes across upgrades and avoids editing the main file.

```bash
if [[ ! -r "$CSV_ON_HOST" ]]; then
  echo "Error: CSV file not found or unreadable: $CSV_ON_HOST"
  exit 1
fi
```

* Fails early if the CSV is missing or unreadable—saves you from restarting services with bad state.

---

## 2) Running as the `stack` user + heredoc

```bash
sudo -i -u "$STACK_USER" CSV_ON_HOST="$CSV_ON_HOST" SNIPPET_ON_HOST="$SNIPPET_ON_HOST" bash <<'EOF'
```

* Switches to an **interactive login shell** for user `stack` (`-i -u stack`).
* Passes two environment variables into that shell (`CSV_ON_HOST`, `SNIPPET_ON_HOST`) so the inner block can reference them safely (even with `set -u`).
* Uses **quoted heredoc** (`<<'EOF'`), which means: “don’t expand variables here in the *outer* shell; let the inner shell handle everything.”

```bash
set -euo pipefail
```

* Shell safety flags:

  * `-e`: exit on any command error.
  * `-u`: nounset—error if you reference an **unset** variable (helps catch typos/missing env).
  * `-o pipefail`: if any command in a pipeline fails, the whole pipeline fails.
    These make the block fail **fast and loudly** on mistakes.

```bash
install -d -m 755 "$(dirname "$SNIPPET_ON_HOST")"
```

* Creates the **destination directory** (if missing) and sets mode `755`.
* Using `install -d -m 755` is a concise, atomic way to do `mkdir -p` + `chmod 755`.
* Horizon (Apache) must be able to **traverse** the directories and read the file.

---

## 3) The Python block (CSV → snippet)

We embed a Python script inline for convenience:

```bash
python3 - <<'PY'
...
PY
```

Inside Python:

```python
csv_path   = pathlib.Path(__import__('os').environ['CSV_ON_HOST'])
snippet    = pathlib.Path(__import__('os').environ['SNIPPET_ON_HOST'])
```

* Reads the two env vars the heredoc passed in, and turns them into `Path` objects.

```python
rows = []
with csv_path.open(newline="") as f:
    r = csv.DictReader(f, delimiter=";")
    for row in r:
        if not row.get("idp_keystone_name") or not row.get("idp_horizon_name"):
            continue
        rows.append(row)
```

* Opens your **semicolon-delimited** CSV (as you’ve used before).
* Skips incomplete rows.
* Collects valid IdPs into `rows`.

```python
choices = [("credentials", "Keystone Credentials")]
mapping = {}
```

* `choices` → the Horizon UI dropdown. We start with the built-in **“Keystone Credentials”** option.
* `mapping` → maps a dropdown key to a Keystone IdP and protocol.

```python
for row in rows:
    horizon_name  = row["idp_horizon_name"]              # dropdown key
    display_name  = row.get("fqdn") or horizon_name      # label in the UI
    keystone_name = row["idp_keystone_name"]             # Keystone IdP
    protocol      = "saml2"                              # or "oidc"

    choices.append((horizon_name, display_name))
    mapping[horizon_name] = (keystone_name, protocol)
```

* For each CSV row, we add an entry to the dropdown and to the mapping table.
* **Important relation**: keys in `WEBSSO_CHOICES` (first element of each tuple) must match the keys in `WEBSSO_IDP_MAPPING`.
* If you have OIDC IdPs, set `protocol = "oidc"` (you can even drive it from the CSV later, if you want).

```python
initial = "credentials"
# Optionally default to the first IdP:
# if len(choices) > 1:
#     initial = choices[1][0]
```

* Controls which option is pre-selected on the login page.
* Defaulting to local Keystone is safe; if you want to auto-pick the first IdP, uncomment that bit.

Helper functions to render **valid, readable Python** for the snippet:

```python
def py_tuple(t):   # ("a","b") with proper quoting
def py_choices(seq):  # multiline tuple for WEBSSO_CHOICES
def py_mapping(d):   # multiline dict for WEBSSO_IDP_MAPPING
```

Then we assemble the file content:

```python
content = f"""# Auto-generated WebSSO settings (do not edit by hand)
WEBSSO_ENABLED = True

WEBSSO_CHOICES = {py_choices(choices)}

WEBSSO_IDP_MAPPING = {py_mapping(mapping)}

WEBSSO_INITIAL_CHOICE = {initial!r}
"""
```

* `WEBSSO_ENABLED = True` turns WebSSO on in Horizon.
* `WEBSSO_CHOICES` is the dropdown content.
* `WEBSSO_IDP_MAPPING` connects dropdown keys → (keystone idp, protocol).
* `WEBSSO_INITIAL_CHOICE` determines the default choice (we used `{initial!r}` so the string is properly quoted in the generated Python file).

Finally, we write the snippet **atomically**:

```python
snippet.parent.mkdir(parents=True, exist_ok=True)
tmp = snippet.with_suffix(".tmp")
tmp.write_text(content)
tmp.replace(snippet)
```

* Write to a temporary file first, then `replace()` (atomic on the same filesystem).
* This prevents a half-written file if the process is interrupted.

---

## 4) Restart Horizon (Apache) and verify

```bash
sudo systemctl restart apache2.service
if systemctl is-active --quiet apache2.service; then
  echo "Horizon (apache2) restarted OK."
else
  echo "ERROR: apache2 failed to restart — check 'journalctl -u apache2 -n 200'."
  exit 1
fi
```

* Reloads Horizon so it picks up your new `_10_websso.py`.
* If Apache fails to restart (syntax error in snippet, permissions issue, etc.), you’ll see it immediately.

---

# Why this approach is solid

* **Follows Horizon’s recommended pattern**: put overrides in `local_settings.d/*`.
* **Idempotent**: safe to re-run; it replaces the same snippet file each time.
* **Atomic writes**: avoids partial files during write.
* **Clear separation of concerns**:

  * Bash handles users, permissions, and service control.
  * Python handles CSV parsing and generating valid Python config.
* **Easy to extend**: want OIDC? Pull a `protocol` column from the CSV and set it per-row.

---

# Common customizations you can add later

* **Per-IdP protocol**: read a `protocol` column from your CSV and set `protocol = row["protocol"]` with validation (`saml2`/`oidc`).
* **Custom display names**: add a `display_name` column and use that instead of `fqdn`.
* **Default choice policy**: add a CLI flag or CSV field to pick the initial default.

---

# Quick verification commands

After running the function:

```bash
# show the generated snippet
sed -n '1,200p' /opt/stack/horizon/openstack_dashboard/local/local_settings.d/_10_websso.py

# sanity-import the snippet with Python
sudo -u stack python3 - <<'PY'
from importlib.util import spec_from_file_location, module_from_spec
p="/opt/stack/horizon/openstack_dashboard/local/local_settings.d/_10_websso.py"
s=spec_from_file_location("_10_websso", p); m=module_from_spec(s); s.loader.exec_module(m)
for k in ("WEBSSO_ENABLED","WEBSSO_CHOICES","WEBSSO_IDP_MAPPING","WEBSSO_INITIAL_CHOICE"):
    print(k, "=>", getattr(m, k, "<missing>"))
PY

# check Horizon service
systemctl is-active apache2 && echo "apache2 active"
journalctl -u apache2 -n 60 --no-pager
```

---

