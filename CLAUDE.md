# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

**`PLAN.md` is the authoritative plan.** It records the decisions already made: PowerShell 5.1, a CLI named `wplm`, WP-CLI for WordPress, Laragon's own vhost and hosts formats, and HTTP only. It also lists the phases with their "done when" criteria. The user does not want to make technical decisions, so follow the plan and choose sensible defaults instead of asking. Work through the phases in order.

Background docs (superseded by `PLAN.md` where they differ):

- `discussion.md`: technology options that were considered.
- `final.md`: the original target design.
- `notes-laragon-servers-without-laragon.md`: verified, working commands for running Laragon's servers by hand. Treat this as the source of truth for paths and commands.

## Commands

There is no build step and no test suite. Test by running the commands against the real Laragon install:

- `wplm help` lists all commands. `bin\` is on the user PATH (`wplm setup`), so `wplm <command>` works in cmd, PowerShell and Git Bash.
- From this folder without PATH: `.\bin\wplm.cmd <command>` (cmd/PowerShell) or `./bin/wplm <command>` (Git Bash).
- Direct: `powershell -NoProfile -ExecutionPolicy Bypass -File wplm.ps1 <command>`
- GUI: `wplm gui`, or the "WP Local Manager" Desktop/Start Menu shortcut, runs `wplm-gui.ps1`.

`bin\` holds only the wrappers. **Never put the repo root on PATH.** This machine's default execution policy is Restricted, so PowerShell would resolve `wplm` to `wplm.ps1` and refuse to run it.

The GUI (WinForms) only displays state. Each action launches `wplm.ps1 <cmd> --pause` in its own console window, which keeps the UAC prompt and delete's typed confirmation working; the window refreshes when that process exits. `--pause` waits for Enter after `new`, `delete` or any error, and otherwise closes after 3 seconds. `--done-file <path>` makes the command write its exit code there *before* pausing. The GUI treats that file as "task finished" and refreshes, because the console may sit at "Press Enter" for a long time. Separately, the GUI timer reloads the site list whenever `Get-SiteSignature` changes (www folder names + vhost file names + hosts file timestamp), so changes made from the terminal show up too.

**Never launch the GUI with a Hidden window style.** Windows applies the launch style to the first window the process shows, so the form itself becomes invisible. Shortcuts and `wplm gui` launch Minimized and pass `-WindowStyle Hidden` to PowerShell, which hides only the console.

The app icon is `assets\app-icon.png`. `Get-AppIcon` (in `lib\Setup.ps1`) builds `assets\app-icon.ico` from it, with PNG-compressed sizes from 16 to 256, whenever the PNG is newer. `wplm setup` applies it to the shortcuts, and the GUI sets its title-bar icon straight from the PNG. Don't use `.GetNewClosure()` for WinForms handlers: closures can't see this script's functions. Use plain `{ Invoke-Safe { ... } }` blocks.

`wplm.ps1` dot-sources `lib\*.ps1`. `Get-WplmConfig` (in `lib\Config.ps1`) auto-detects the version folders under `C:\laragon\bin`, and every function takes that config object.

Code conventions:

- Target **Windows PowerShell 5.1** and keep `.ps1` files ASCII-only. Without a BOM, 5.1 reads them as ANSI.
- Run external `.exe` tools through `Invoke-Native`, not `& exe 2>&1`. Under `$ErrorActionPreference = 'Stop'`, PowerShell 5.1 turns a program's stderr output into a terminating error.
- Don't name a variable `$args`; PowerShell reserves it.
- Launch servers with `Start-Process -WindowStyle Hidden` so they outlive the terminal.
- Edit the user PATH only through the raw registry value (`DoNotExpandEnvironmentNames`, written back as `ExpandString`; see `lib\Setup.ps1`). `[Environment]::SetEnvironmentVariable('Path', ...)` would expand and lose the existing `%USERPROFILE%` entry. The pre-setup PATH is saved in `backups\user-path-before-setup.txt`.
- `wplm autostart on|off` manages a shortcut in the user's Startup folder that runs `wplm.ps1 start`. It is off by default because `new` and `open` start the servers on demand, and RAM is tight.
- Hosts-file writes (`lib\Hosts.ps1`) run directly when the process is already admin. Otherwise they re-run `wplm.ps1 _hosts-add|_hosts-remove <host> <result-file>` through a UAC prompt, and the result file carries the outcome back.
- Claude Code's terminal on this machine is already elevated, so the UAC path can only be tested by the user from a normal terminal.
- Every hosts change first backs up the file to `backups\hosts\`, keeping the newest 20.
- WordPress (`lib\WordPress.ps1`): **don't use `wp core download`.** It unpacks a `.tar.gz` with PHP's PharData, which truncates long file names on Windows and fails. Its `tar` fallback isn't found either. Instead, `Get-WordPressZip` fetches the official zip, checks its SHA-1, caches it in `tools\cache\` and unzips it with .NET. WP-CLI (`tools\wp-cli.phar`, SHA-512-verified, run with Laragon's `php.exe`) does `config create` and `core install`. Databases are created through `mysql.exe` (`Invoke-MySqlQuery`), not `wp db create`, which needs `mysql` on PATH. `tools\` and `backups\` are generated at runtime.
- Never pass WP-CLI flags that read STDIN, such as `--extra-php`. `Invoke-Native` closes stdin so a tool that expects input gets EOF instead of hanging.
- `wplm new` (`lib\Site.ps1`): checks run first and change nothing. The hosts line (the UAC step) comes next, then WordPress, then the vhost, and Apache starts last. On failure, `Undo-NewSite` removes the folder, DB and vhost. This is safe only because the checks proved none of them existed beforehand.
- `list`/`open`/`delete` (`lib\Manage.ps1`) also manage Laragon-made sites. **Read a site's DB name from its `wp-config.php` (`Get-WpDbName`); never derive it from the folder name.** Laragon keeps hyphens (`omg-entertainment-new`), while wplm converts them to `_`. `delete` dumps the DB to `backups\databases\` with `--databases` (so the file recreates the DB on restore), refuses to drop a DB another site's `wp-config.php` also uses, and sends the folder to the Recycle Bin.
- Check whether a database exists by exact match on `information_schema.SCHEMATA`, not `SHOW DATABASES LIKE`, where `_` is a wildcard.
- Vhosts (`lib\Vhost.ps1`) are written from `templates\vhost.conf` (Laragon's format) as `sites-enabled\auto.<name>.test.conf`. The sequence is: check `httpd -t` before writing → write the file → check `httpd -t` again, deleting the new file if it fails → restart Apache only if it was running. Apache on Windows has no graceful reload outside service mode, so a restart means stop plus start.

## What is being built

**WP Local Manager** is a lightweight Windows app that does what the Laragon GUI does for WordPress sites, without opening Laragon. It reuses Laragon's installed Apache, PHP, MySQL and `C:\laragon\www`. The goal is a tool that runs without the Laragon GUI. It is not a way around Laragon's license, so don't modify, patch or crack Laragon itself.

"Create site" flow: create the folder in `C:\laragon\www\<name>` → download and extract WordPress → `CREATE DATABASE` → write the Apache vhost → add the hosts entry → start or verify Apache and MySQL → open `http://<name>.test`. Later steps: `wp-config.php` generation and WP-CLI install.

The phases are in `PLAN.md`, and each one must work before the next starts.

## Learning-oriented: required working style

The user is learning (HTML/CSS/JS background) and explicitly wants the complexity shown, not hidden. Before implementing each major feature, explain:

- what Laragon normally does
- what is being replaced and why the replacement works
- what Windows, Apache or MySQL is doing underneath
- what could go wrong

Then implement it step by step.

## The local environment (from verified notes)

- **MySQL 8.4.3**: `C:/laragon/bin/mysql/mysql-8.4.3-winx64/bin/mysqld.exe --defaults-file="C:/laragon/bin/mysql/mysql-8.4.3-winx64/my.ini"`. `--defaults-file` is required because `my.ini` sets `datadir=C:/laragon/data/mysql-8.4`. Root has no password (`-uroot`).
  - Health check: `mysqladmin.exe -uroot ping` returns "mysqld is alive".
  - Stop: `mysqladmin.exe -uroot shutdown`. Never use `taskkill /F` on mysqld, because a forced kill can leave tables needing recovery.
- **Apache 2.4.62**: `C:/laragon/bin/apache/httpd-2.4.62-240904-win64-VS17/bin/httpd.exe -d "<that httpd dir>"`. `-d` sets ServerRoot, which relative paths in `conf/httpd.conf` resolve against.
  - `httpd.conf` already contains `IncludeOptional C:/laragon/etc/apache2/sites-enabled/*.conf`, with one vhost file per site (Laragon names them `auto.<domain>.conf`), and `Include C:/laragon/etc/apache2/mod_php.conf` (PHP 8.3 as a module). New sites only need a new `.conf` file there.
  - Stop: `taskkill //IM httpd.exe //F` is safe. Two `httpd.exe` processes (parent + worker) is normal.
- **Hosts file**: `.test` domains work through lines like `127.0.0.1 <site>.test #laragon magic!` in the Windows hosts file. Writing to it requires admin rights.
- Both servers run in the foreground, so launch them detached or in the background.

## Gotchas

- **Check that a server isn't already running before starting it.** In Git Bash use `tasklist //FI "IMAGENAME eq mysqld.exe"`, with `//` because Git Bash otherwise mangles `/FI` into a path. A second copy fails with misleading errors while the first keeps running:
  - MySQL: `Data Dictionary initialization failed` (see `C:\laragon\data\mysql-8.4\*.err`)
  - Apache: `AH00015: Unable to open logs`
- Server processes outlive the shell that launched them.
- Laragon's tray app doesn't know about servers started this way, and pressing its Start causes the double-start errors above.
- The machine has about 6 GB RAM with little free, and MySQL alone uses about 450 MB. Keep tooling lightweight; this is one reason Electron was judged overkill.
- Version numbers are baked into the paths above. Prefer discovering them under `C:\laragon\bin\` over hard-coding them.
