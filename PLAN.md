# WP Local Manager: Build Plan

Goal: create a new WordPress site, and start or stop the servers, **without ever opening the Laragon GUI**.

End result, typed in any terminal:

```text
wplm start              → Apache + MySQL running
wplm new myshop         → http://myshop.test opens with WordPress installed, logged-in ready
wplm stop               → servers stopped cleanly
```

---

## Decisions (made, not open questions)

| Question | Decision | Why |
|---|---|---|
| Language | **PowerShell 5.1** (built into Windows) | Nothing to install. It is native to Windows processes, the hosts file and admin elevation. It is light on RAM, which matters on a ~6 GB machine. |
| Interface | **Command line first** (`wplm <command>`), with an optional small GUI at the very end | A CLI is fastest to build and use. The GUI only wraps the same commands. |
| Servers | **Reuse Laragon's** Apache 2.4.62, PHP 8.3.16 and MySQL 8.4.3 in `C:\laragon\bin` | They are already installed and configured, and all existing sites keep working. |
| Sites folder | `C:\laragon\www\<name>` | Same place as all existing sites. |
| WordPress setup | **WP-CLI** (`wp-cli.phar`, run with Laragon's PHP) | One tool downloads WordPress, writes `wp-config.php`, creates the DB and runs the installer. That is less custom code than downloading and unzipping by hand. PHP already has curl, openssl, zip and mysqli. |
| Vhost format | Copy Laragon's exact `auto.<name>.test.conf` format into `C:\laragon\etc\apache2\sites-enabled\` | Proven to work. Laragon will also recognise these sites if it is ever opened again. |
| Hosts entry | `127.0.0.1  <name>.test  #laragon magic!` | Same tag as Laragon, so both tools stay compatible. |
| HTTP vs HTTPS | **HTTP only** (`http://<name>.test`) | Laragon's `laragon.crt` only lists the domains Laragon generated it for, so new sites would show certificate warnings over HTTPS. |
| DB naming | Site name with `-` replaced by `_` (e.g. `my-shop` → `my_shop`) | Avoids quoting problems in SQL. |
| Local WP login | `admin` / `admin`, email `admin@<name>.test` | Local-only dev sites, so the login should be easy to remember. It is printed after every install. |
| Admin rights | Only for the hosts-file step. The script relaunches itself elevated (one UAC prompt) just for that | Everything else runs as a normal user. |

---

## Folder layout

```text
WPLocalManager\
├── wplm.ps1            ← the single entry point: wplm <command>
├── wplm.cmd            ← tiny wrapper so "wplm" works from cmd/PowerShell/Git Bash
├── lib\
│   ├── Config.ps1      ← finds Laragon paths (auto-detects version folders)
│   ├── Servers.ps1     ← start / stop / status of Apache + MySQL
│   ├── Hosts.ps1       ← add / remove hosts-file lines (elevated)
│   ├── Vhost.ps1       ← write / remove Apache .conf files
│   └── WordPress.ps1   ← WP-CLI wrapper: download, config, install
├── tools\
│   └── wp-cli.phar     ← downloaded once in Phase 4
└── templates\
    └── vhost.conf      ← copy of Laragon's vhost format with {{NAME}} placeholders
```

---

## Phases

Each phase ends with something you can run and see working. Before writing the code for a phase, Claude explains what Laragon did for that step, what replaces it and what can go wrong.

### Phase 1: Start, stop and status of servers
- `wplm status`: is `httpd.exe` running? Is `mysqld.exe` running (`mysqladmin ping`)? Is anything already on port 80 or 3306?
- `wplm start`: start each server **only if it isn't already running** (avoids the double-start errors in the notes). Run them hidden in the background, then wait for them to answer.
- `wplm stop`: `mysqladmin -uroot shutdown` for MySQL (never force-kill it); `taskkill` for Apache.
- `wplm restart`
- Auto-detect version folders under `C:\laragon\bin\apache\` and `C:\laragon\bin\mysql\` instead of hard-coding them.
- **Done when:** `wplm start` makes an existing site such as `http://taskband.test` load, and `wplm stop` stops it.

### Phase 2: Hosts file
- `Add-HostEntry` / `Remove-HostEntry`: back up `hosts` first, never duplicate a line, and elevate via UAC only for this step.
- Flush DNS afterwards (`ipconfig /flushdns`).
- **Done when:** a test entry can be added and removed safely.

### Phase 3: Apache vhost
- Write `auto.<name>.test.conf` from the template.
- Validate with `httpd.exe -t` **before** reloading. If the config is broken, delete the new file so Apache still starts.
- Restart Apache if it's running.
- **Done when:** an empty folder with an `index.php` is served at `http://<name>.test`.

### Phase 4: WordPress via WP-CLI
- Download `wp-cli.phar` once into `tools\`.
- Download the official WordPress `.zip` (SHA-1 checked, cached in `tools\cache\`) and unzip it → create the DB with `mysql.exe` → `wp config create` (DB `root`, no password, host `127.0.0.1`) → `wp core install`.
- *Changed during the build:* `wp core download` fails on Windows because PHP's tar reader cuts long file names short. That is why the download step uses the zip instead.
- Also added: `wplm wp <name> <args>`, which runs any WP-CLI command on a site.

### Phase 5: `wplm new <name>`, the one-command flow
Ties everything together in this order (as built):
1. Validate the name (lowercase letters, digits and hyphens; max 50 characters; not a reserved Windows name). Refuse if the folder, DB or vhost already exists, or if the hosts entry points somewhere other than this computer. A leftover `127.0.0.1` hosts line is reused.
2. Add the hosts entry **first**, so the single UAC prompt appears up front and the rest runs unattended.
3. Create the folder → unzip WordPress → DB → `wp-config` → install.
4. Write the vhost and validate it.
5. Start Apache and MySQL if they aren't running. Apache starts last, so it reads the new vhost once.
6. Open `http://<name>.test/wp-admin` in the browser and print the login.
- If any step fails, `wplm` automatically removes the folder, DB and vhost this run created. The hosts line stays: it's harmless and gets reused.
- **Done when:** `wplm new demo` gives a working WordPress site with no Laragon window opened.

### Phase 6: Housekeeping commands
- `wplm list`: all sites in `www`, showing whether each has a vhost, hosts entry and DB.
- `wplm open <name>`
- `wplm delete <name>`: you type the site name to confirm. It **exports the DB to a backup first**, then removes the hosts entry, vhost and DB. The folder goes **to the Recycle Bin**. The DB name is read from `wp-config.php`, and a DB shared with another site is kept.

### Phase 7: Convenience (as built)
- `wplm setup` puts `bin\` (wrappers only) on the user PATH and creates Desktop and Start Menu shortcuts. `wplm setup remove` undoes this.
- `wplm autostart on|off` uses a Startup-folder shortcut (no admin needed) and is **off by default**, because `new` and `open` start the servers when needed.
- `wplm gui` / the shortcut open a WinForms window with server status, Start/Stop/Restart, Create site, a site list, and Open / Admin / Folder / Delete buttons. Each action runs the normal `wplm` command in a console window.

---

## Known risks and how the plan handles them

| Risk | Handling |
|---|---|
| Server already running → misleading errors | Every start checks first (Phase 1). |
| Laragon GUI opened later while our servers run | `wplm status` shows that they are running. Stop with `wplm stop` before opening Laragon. |
| Broken vhost stops Apache for **all** sites | `httpd -t` check, and remove the bad file before restarting. |
| Corrupting the hosts file | Back it up first, append only, never rewrite other lines. |
| Low RAM kills processes | Servers run detached, so they survive terminal closes. `status` reports their real state. |
| Laragon upgrade changes version folders | Paths are auto-detected, not hard-coded. |
