# Notes — running Laragon's MySQL + Apache without the Laragon app

## The core idea

Laragon's "Start All" button just launches two normal programs that live in `C:\laragon\bin`. Laragon itself does nothing special at runtime — so you can start them yourself, as long as you point each one at the config Laragon already wrote.

## MySQL

```bash
/c/laragon/bin/mysql/mysql-8.4.3-winx64/bin/mysqld.exe --defaults-file="C:/laragon/bin/mysql/mysql-8.4.3-winx64/my.ini"
```

- `--defaults-file` is the important part. `my.ini` contains `datadir="C:/laragon/data/mysql-8.4"` — that's where all your databases actually are. Without it, mysqld looks in its own folder, finds no data, and fails.
- It runs in the foreground (never "returns"), so I ran it in the background.
- Check it's up:
  ```bash
  /c/laragon/bin/mysql/mysql-8.4.3-winx64/bin/mysqladmin.exe -uroot ping   # → "mysqld is alive"
  ```
- Root user has no password locally, hence plain `-uroot`.

## Apache

```bash
/c/laragon/bin/apache/httpd-2.4.62-240904-win64-VS17/bin/httpd.exe -d "C:/laragon/bin/apache/httpd-2.4.62-240904-win64-VS17"
```

- `-d` = ServerRoot. Relative paths in `httpd.conf` (like `logs/error.log`) resolve from there.
- Everything else comes from `conf/httpd.conf`, which Laragon already wired up at the bottom:
  - `IncludeOptional C:/laragon/etc/apache2/sites-enabled/*.conf` → one vhost per site, e.g. `auto.pivotalconnectwithmegamenu.test.conf` maps `pivotalconnectwithmegamenu.test` → `C:/laragon/www/pivotalconnectwithmegamenu`
  - `Include C:/laragon/etc/apache2/mod_php.conf` → loads PHP 8.3 as an Apache module
- Also foreground → run in background.
- Check it's up:
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" http://pivotalconnectwithmegamenu.test/   # → 200
  ```

## Why the .test domain still works

The Windows hosts file already has `127.0.0.1 pivotalconnectwithmegamenu.test #laragon magic!` — Laragon added it once when the site was created. It's permanent, it doesn't need Laragon running.

## Is it already running?

```bash
tasklist //FI "IMAGENAME eq mysqld.exe"
tasklist //FI "IMAGENAME eq httpd.exe"
```

(`//FI` not `/FI` — Git Bash would otherwise mangle the slash into a path.) Apache normally shows 2 processes (parent + worker); that's normal.

## Gotcha I hit: starting it twice

When I "restarted" them, both new attempts failed — because the old ones were still running:

| Server | Error from the second copy | Real meaning |
|---|---|---|
| MySQL | `Data Dictionary initialization failed` (in `C:\laragon\data\mysql-8.4\*.err`) | Data folder already locked by the running server |
| Apache | `AH00015: Unable to open logs` | Log files / port 80 already held by the running server |

Both look scary, both are harmless. **Check `tasklist` before starting.** The running copy is unaffected.

Why they were still running: Claude Code killed the *shell session* that launched them (low memory), but the server processes themselves survived.

## Stopping them

No Laragon "Stop" button in this setup, so:

```bash
/c/laragon/bin/mysql/mysql-8.4.3-winx64/bin/mysqladmin.exe -uroot shutdown   # clean MySQL stop — prefer this
taskkill //IM httpd.exe //F                                                     # Apache has no data to corrupt
```

Avoid `taskkill /F` on mysqld — a forced kill can leave tables needing recovery.

## Should you do this?

- Fine for a quick test, scripting, or when Laragon's UI is closed.
- Laragon's tray app won't know about these processes (its buttons will look "stopped"). Pressing Start in Laragon while they're running → the same double-start errors above. Stop these first, then use Laragon.
- This machine has ~6 GB RAM with ~0.5 GB free — MySQL alone was using ~450 MB. Close stuff if they keep getting killed.
