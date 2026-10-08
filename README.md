# WP Local Manager

Create, open and delete local WordPress sites at `http://<name>.test` with **one command or one click**, using the Apache, PHP and MySQL that [Laragon](https://laragon.org) installs, **without opening the Laragon app**.

```text
wplm new myshop
```

…checks everything, creates the folder, downloads and installs WordPress, creates the database, adds the Apache site and the `myshop.test` address, starts the servers, and opens the WordPress dashboard. It takes about 30 seconds.

**Documentation:** [How it works: the tech stack explained](https://gitussr.github.io/wp-local-manager/)

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [First run: create your first site](#first-run-create-your-first-site)
- [Using the window](#using-the-window)
- [Command reference](#command-reference)
- [Where things are stored](#where-things-are-stored)
- [Using it alongside the Laragon app](#using-it-alongside-the-laragon-app)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Project structure](#project-structure)
- [License](#license)

---

## Features

- **One-step WordPress sites:** `wplm new <name>` gives a fully installed WordPress at `http://<name>.test`.
- **Server control:** start, stop, restart and check Apache and MySQL.
- **Site list:** every site in `C:\laragon\www`, with its database and whether it's fully set up. Sites created by Laragon are included.
- **Safe delete:**
  - You type the site name to confirm.
  - The database is backed up to a `.sql` file first.
  - The folder goes to the **Recycle Bin**, so it can be restored.
- **A desktop window** with buttons, plus the same features as terminal commands.
- **Any WP-CLI command** on any site: `wplm wp myshop plugin install woocommerce --activate`.
- **Safety checks throughout:**
  - Apache's settings are checked before every restart.
  - The hosts file is backed up before every change.
  - A failed `new` cleans up after itself.
  - Nothing that already exists is ever overwritten.
- **Nothing extra to install:** it's written in Windows PowerShell, which every copy of Windows 10 and 11 includes.

---

## Requirements

| Requirement | Details |
|---|---|
| **Operating system** | Windows 10 (version 1803 or newer) or Windows 11, 64-bit. |
| **Windows PowerShell 5.1** | Built into Windows 10/11, so there's nothing to install. Check by running `powershell -c "$PSVersionTable.PSVersion"`. |
| **Laragon** | Installed, by default at `C:\laragon`. Laragon *Full* includes everything needed. It must contain **Apache** (`bin\apache\httpd-*`), **MySQL** (`bin\mysql\mysql-*`; MariaDB isn't supported) and **PHP 8.x** (`bin\php\php-*`). |
| **Laragon started once** | Open Laragon once and click **Start All**, then close it. This creates MySQL's data folder, `my.ini`, and the Apache settings that WP Local Manager reuses. You only need to do this once. |
| **MySQL `root` with no password** | This is Laragon's default. WP Local Manager connects as `root` with an empty password. |
| **Free ports 80 and 3306** | Port 80 is for Apache and 3306 for MySQL. See [Troubleshooting](#troubleshooting) if another program uses them. |
| **Administrator permission** | Needed only when adding or removing a `.test` address in the Windows hosts file. You'll see one Windows "Yes/No" (UAC) prompt per new or deleted site. Your user account needs to be allowed to approve it. |
| **Internet connection** | Needed the first time: WordPress (~37 MB) and WP-CLI (~7 MB) are downloaded and cached. Later sites work offline. |
| **Disk space** | About 50 MB for the cache, plus about 70 MB per WordPress site. |
| **Memory** | MySQL uses about 450 MB while running. 4 GB of RAM or more is recommended. |
| **Git** *(optional)* | Only for installing with `git clone`. You can download a ZIP instead. |

### Laragon somewhere other than `C:\laragon`?

Set the `WPLM_LARAGON` environment variable to its folder, then open a new terminal:

```powershell
[Environment]::SetEnvironmentVariable('WPLM_LARAGON', 'D:\laragon', 'User')
```

---

## Installation

### 1. Put the app in a permanent folder

Choose a folder you won't move or delete, for example `C:\Tools\wp-local-manager`. The PATH entry and shortcuts point there. Avoid your Downloads folder.

**Option A: with Git**

```powershell
git clone https://github.com/gitussr/wp-local-manager.git C:\Tools\wp-local-manager
```

**Option B: without Git**

1. On GitHub, click **Code → Download ZIP**.
2. Right-click the ZIP → **Properties**. If you see an **Unblock** checkbox, tick it and click **OK**.
3. Extract it to `C:\Tools\wp-local-manager`. Make sure that folder directly contains `wplm.ps1`, not another folder inside it.

### 2. Run setup

Open **PowerShell** or **Command Prompt**. It doesn't need to be "Run as administrator".

```powershell
cd C:\Tools\wp-local-manager
.\bin\wplm.cmd setup
```

This:
- adds the app's `bin` folder to **your user PATH**, so `wplm` works in any terminal;
- creates **WP Local Manager** shortcuts on your **Desktop** and in the **Start Menu**.

Setup is per-user, needs no admin rights, and is fully reversible (see [Uninstalling](#uninstalling)).

### 3. Check it works

Open a **new** terminal window, because already-open ones don't see the new PATH. Terminals inside VS Code need VS Code restarted.

```powershell
wplm status
```

You should see:

```text
  Apache : STOPPED      (or RUNNING)
  MySQL  : STOPPED      (or RUNNING)
```

If you see `Laragon folder not found`, check the [Requirements](#requirements).

---

## First run: create your first site

```powershell
wplm new demo
```

1. Windows asks for permission to edit the hosts file. Click **Yes**. That's the only prompt.
2. The first time, WP-CLI and WordPress are downloaded. Later sites reuse the cached copies.
3. When it prints `Done`, your browser opens at `http://demo.test/wp-admin`.
4. Log in with **`admin` / `admin`**.

To add a site title: `wplm new my-shop "My Shop"`.

Site names may contain **lowercase letters, digits and hyphens**, up to 50 characters.

---

## Using the window

Double-click **WP Local Manager** on your Desktop or in the Start Menu, or run `wplm gui`.

- **Servers:** live Apache and MySQL status, with **Start**, **Stop** and **Restart**.
- **Create a new WordPress site:** type a name (and an optional title), then click **Create site** or press **Enter**.
- **Sites:**
  - Double-click a site to open it.
  - **Open admin**, **Open folder** and **Delete...** act on the selected site.
  - The list refreshes automatically, including sites you create from the terminal.

Each button runs the matching `wplm` command in a small console window, so you can watch what happens. After `new` and `delete`, that window waits for **Enter** so you can read the result.

---

## Command reference

| Command | What it does |
|---|---|
| `wplm new <name> [title]` | Create a complete WordPress site at `http://<name>.test` and open it. Add `--no-browser` to skip opening the browser. |
| `wplm list` | Show all sites, their databases, and whether each is fully set up. |
| `wplm open <name> [admin]` | Open a site, or its dashboard with `admin`. Starts the servers if needed. |
| `wplm delete <name>` | Delete a site: you type the name to confirm, the database is backed up first, and the folder goes to the Recycle Bin. `--yes` skips the confirmation. |
| `wplm gui` | Open the WP Local Manager window. |
| `wplm status` | Is Apache and MySQL running? |
| `wplm start` / `stop` / `restart` | Control Apache and MySQL. |
| `wplm hosts list` / `add <name>` / `remove <name>` | Manage `.test` lines in the Windows hosts file. |
| `wplm vhost list` / `add <name>` / `remove <name>` | Manage Apache site configs. |
| `wplm wp <name> <command...>` | Run any [WP-CLI](https://wp-cli.org) command on a site, e.g. `wplm wp demo plugin list`. |
| `wplm setup` / `setup remove` | Add or remove the PATH entry and shortcuts. |
| `wplm autostart on` / `off` | Start Apache and MySQL automatically when you log in to Windows. Off by default. |
| `wplm help` | Show all commands. |

Works in **PowerShell**, **Command Prompt** and **Git Bash**.

---

## Where things are stored

| What | Where |
|---|---|
| Site files | `C:\laragon\www\<name>` |
| Database | MySQL database `<name>`, with hyphens turned into underscores (`my-shop` → `my_shop`) |
| Apache site config | `C:\laragon\etc\apache2\sites-enabled\auto.<name>.test.conf` (Laragon's own format) |
| `.test` address | `C:\Windows\System32\drivers\etc\hosts`, as `127.0.0.1  <name>.test  #laragon magic!` |
| WordPress login | `admin` / `admin`, email `admin@<name>.test` |
| Downloaded WP-CLI and WordPress cache | `<app folder>\tools\` |
| Backups | `<app folder>\backups\`: hosts-file copies (newest 20), database exports of deleted sites, your PATH from before setup |

**Restoring a deleted site's database** (the delete command prints the exact command):

```powershell
cmd /c '"C:\laragon\bin\mysql\<version>\bin\mysql.exe" -uroot < "<app folder>\backups\databases\<file>.sql"'
```

The site's folder is in the **Recycle Bin**: right-click it and choose **Restore**.

---

## Using it alongside the Laragon app

WP Local Manager uses the same files and formats as Laragon, so sites made by either tool work in both. The two apps don't share their running state, though:

- **Use one or the other at a time.** If you start the servers with `wplm`, Laragon's buttons still show them as stopped. Clicking Laragon's **Start All** then gives errors, because the servers are already running.
- Before switching, run `wplm stop`, then use Laragon. Or stop them in Laragon, then use `wplm`.
- `wplm status` warns you when the Laragon app is open.

WP Local Manager doesn't modify Laragon in any way. It starts the Apache, PHP and MySQL programs that Laragon installed. Using Laragon is subject to [Laragon's own license terms](https://laragon.org).

---

## Security notes

These defaults are meant for **local development only**:

- Every site's WordPress login is `admin` / `admin`.
- MySQL's `root` user has no password (Laragon's default).

Don't use these sites or this setup for anything reachable from the internet. If you share a network, consider limiting MySQL to your own computer by adding `bind-address=127.0.0.1` under `[mysqld]` in Laragon's `my.ini`.

Every download is checked against its official fingerprint: SHA-512 for WP-CLI, SHA-1 for WordPress.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `'wplm' is not recognized` | Open a **new** terminal after `wplm setup`. In VS Code, restart VS Code. Or run it directly: `<app folder>\bin\wplm.cmd`. |
| `Laragon folder not found` | Install Laragon, or set `WPLM_LARAGON` (see [Requirements](#requirements)). |
| `No folder matching 'mysql-*'` (or `httpd-*`, `php-*`) | That component is missing from Laragon. Install Laragon *Full*, or add the component through Laragon's menu. |
| `Port 80 is already used by '...'` | Another program uses port 80. Often it's IIS (the *World Wide Web Publishing Service*), Skype, or another local server such as XAMPP. Stop it, then `wplm start`. |
| `Port 3306 is already used` | Another MySQL or MariaDB is running, for example a MySQL Windows service or XAMPP. Stop it. |
| Apache or MySQL won't start | The error shows the last lines of the log. Full logs: `C:\laragon\bin\apache\<version>\logs\error.log` and `C:\laragon\data\mysql-8.4\mysqld.log`. |
| `Administrator permission was not given` | You clicked **No** on the Windows prompt. Run the command again and click **Yes**. |
| The site doesn't open / "This site can't be reached" | Check the servers with `wplm status`, and that `wplm list` shows `ok` for the site. Then make sure you typed `http://` and not `https://`. Some antivirus programs block hosts-file edits; allow it, or add the line yourself. |
| Browser shows a certificate warning | Use `http://`. HTTPS only works for sites whose certificate Laragon generated. |
| `Database '...' already exists` / `Folder already exists` | A site or database with that name already exists. Pick another name, or `wplm delete` the old one first. |
| `running scripts is disabled on this system` | Run `wplm.cmd`, not `wplm.ps1`. The `.cmd` launcher handles PowerShell's script policy for you. |
| Desktop or Start Menu icon looks old | Windows caches icons. Press F5 on the Desktop, or sign out and back in. |

---

## Updating

With Git:

```powershell
cd C:\Tools\wp-local-manager
git pull
```

Without Git, download the ZIP again and extract it over the same folder. Your `tools\` and `backups\` folders aren't in the ZIP, so they're kept.

Updating never touches your sites or databases.

---

## Uninstalling

```powershell
wplm setup remove
```

This removes the PATH entry, the shortcuts and start-at-login. Then delete the app folder.

**Your sites, databases and `.test` addresses are not removed.** They keep working with Laragon. Delete individual sites first with `wplm delete <name>` if you want them gone.

---

## Project structure

```text
wplm.ps1            Main program: reads the command, calls the right functions
wplm-gui.ps1        The desktop window (Windows Forms)
bin\                wplm.cmd + wplm (Git Bash) launchers - this folder goes on PATH
lib\Config.ps1      Finds Laragon's Apache / MySQL / PHP folders
lib\Servers.ps1     Start / stop / status
lib\Hosts.ps1       Hosts file (backups + admin prompt)
lib\Vhost.ps1       Apache site configs (validated with httpd -t)
lib\WordPress.ps1   WordPress download, WP-CLI, database creation
lib\Site.ps1        "wplm new" - the whole flow, with cleanup on failure
lib\Manage.ps1      list / open / delete
lib\Setup.ps1       PATH, shortcuts, icon, autostart
templates\          Apache config template
assets\             App icon (replace app-icon.png and run "wplm setup" to change it)
docs\               Documentation website (GitHub Pages)
```

For a full explanation of how each part works, see the **[documentation](https://gitussr.github.io/wp-local-manager/)**.

---

## License

[MIT](LICENSE). You're free to use, copy, modify and share this project, as long as the license notice is kept.

Laragon, Apache, PHP, MySQL, WordPress and WP-CLI are separate projects under their own licenses. WP Local Manager doesn't include or modify them; it only runs the copies already installed on your computer.
