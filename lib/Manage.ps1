# Manage.ps1 - list / open / delete existing sites.
#
# Works for sites made by wplm AND by Laragon (same folder, vhost and hosts
# formats). A site's database name is read from its wp-config.php - never
# guessed from the folder name, because Laragon-made sites may differ.

$script:DbBackupDir = Join-Path (Split-Path $PSScriptRoot) 'backups\databases'

# DB_NAME from wp-config.php, or $null (no WordPress / computed dynamically).
function Get-WpDbName {
    param([string]$SitePath)
    $config = Join-Path $SitePath 'wp-config.php'
    if (-not (Test-Path $config)) { return $null }
    $text = Get-Content $config -Raw
    if ($text -match "define\(\s*['`"]DB_NAME['`"]\s*,\s*['`"]([^'`"]+)['`"]") { return $Matches[1] }
    return $null
}

function Get-AllDatabases {
    param($Cfg)
    @((Invoke-MySqlQuery $Cfg 'SHOW DATABASES') -split "`r?`n" | Where-Object { $_ })
}

# One row per folder in www: what exists for it.
function Get-Sites {
    param($Cfg)
    $hosts  = @(Get-TestHostEntries | Where-Object Ip -eq '127.0.0.1' | ForEach-Object Host)
    $vhosts = @(Get-Vhosts $Cfg | ForEach-Object Site)
    $dbs    = if ((Get-MySqlProcesses $Cfg).Count -gt 0) { Get-AllDatabases $Cfg } else { $null }
    foreach ($dir in Get-ChildItem $Cfg.WwwDir -Directory | Sort-Object Name) {
        $hostName = "$($dir.Name.ToLower()).test"
        $db = Get-WpDbName $dir.FullName
        [pscustomobject]@{
            Name      = $dir.Name
            Url       = "http://$hostName"
            Path      = $dir.FullName
            WordPress = Test-Path (Join-Path $dir.FullName 'wp-config.php')
            Database  = $db
            DbExists  = if ($null -eq $dbs -or -not $db) { $null } else { $dbs -contains $db }
            HasVhost  = $vhosts -contains $hostName
            HasHosts  = $hosts -contains $hostName
        }
    }
}

function Show-Sites {
    param($Cfg)
    $sites = @(Get-Sites $Cfg)
    $mysqlUp = (Get-MySqlProcesses $Cfg).Count -gt 0
    Write-Host ''
    Write-Host ('  {0,-38} {1,-4} {2,-34} {3}' -f 'SITE', 'WP', 'DATABASE', 'STATUS')
    foreach ($s in $sites) {
        $problems = @()
        if (-not $s.HasVhost) { $problems += 'no Apache config' }
        if (-not $s.HasHosts) { $problems += 'no hosts line' }
        if ($s.DbExists -eq $false) { $problems += 'database missing' }
        $status = if ($problems) { $problems -join ', ' } else { 'ok' }
        $db = if ($s.Database) { $s.Database } elseif ($s.WordPress) { '(set in code)' } else { '-' }
        $line = '  {0,-38} {1,-4} {2,-34} {3}' -f $s.Name, $(if ($s.WordPress) { 'yes' } else { '-' }), $db, $status
        Write-Host $line -ForegroundColor $(if ($problems) { 'Yellow' } else { 'Gray' })
    }
    Write-Host ''
    Write-Host "  $($sites.Count) sites in $($Cfg.WwwDir)" -ForegroundColor DarkGray
    if (-not $mysqlUp) { Write-Host '  MySQL is stopped, so databases were not checked.' -ForegroundColor DarkGray }
    Write-Host ''
}

function Get-SiteOrThrow {
    param($Cfg, [string]$Name)
    $hostName = ConvertTo-TestHost $Name
    $siteName = $hostName -replace '\.test$', ''
    $path = Join-Path $Cfg.WwwDir $siteName
    [pscustomobject]@{ Name = $siteName; Host = $hostName; Path = $path; Exists = (Test-Path $path) }
}

function Open-Site {
    param($Cfg, [string]$Name, [switch]$Admin)
    $site = Get-SiteOrThrow $Cfg $Name
    if (-not $site.Exists) { throw "No site folder at $($site.Path)" }
    Start-MySql $Cfg
    Start-Apache $Cfg
    $url = if ($Admin) { "http://$($site.Host)/wp-admin/" } else { "http://$($site.Host)/" }
    Write-Host "  Opening $url" -ForegroundColor Green
    Start-Process $url
}

# ---------------------------------------------------------------- delete

# Exports a database to backups\databases\<db>-<timestamp>.sql. Returns the path.
function Backup-Database {
    param($Cfg, [string]$DbName)
    New-Item -ItemType Directory -Force -Path $script:DbBackupDir | Out-Null
    $file = Join-Path $script:DbBackupDir ("{0}-{1}.sql" -f $DbName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $dump = Join-Path $Cfg.MySqlDir 'bin\mysqldump.exe'
    # --databases puts "CREATE DATABASE" + "USE" in the file, so restoring it
    # recreates the database by itself.
    $r = Invoke-Native $dump ("-uroot --host=127.0.0.1 --port=$($Cfg.MySqlPort) --single-transaction " +
        "--routines --triggers --default-character-set=utf8mb4 --result-file=`"$file`" --databases $DbName")
    if ($r.ExitCode -ne 0 -or -not (Test-Path $file) -or (Get-Item $file).Length -eq 0) {
        throw "Database backup failed, so nothing was deleted:`n$($r.Output)"
    }
    return $file
}

# Sends a folder to the Recycle Bin (restorable) instead of deleting it outright.
function Remove-ToRecycleBin {
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

function Remove-WpSite {
    param($Cfg, [string]$Name, [switch]$Yes)
    $site = Get-SiteOrThrow $Cfg $Name
    if ((Get-MySqlProcesses $Cfg).Count -eq 0) { Start-MySql $Cfg }

    # Work out what exists before touching anything.
    $dbName = if ($site.Exists) { Get-WpDbName $site.Path } else { $null }
    $dbExists = $dbName -and (Test-Database $Cfg $dbName)
    $sharedWith = @()
    if ($dbExists) {
        $sharedWith = @(Get-Sites $Cfg | Where-Object { $_.Database -eq $dbName -and $_.Name -ne $site.Name } | ForEach-Object Name)
    }
    $hasVhost = Test-Path (Get-VhostPath $Cfg $site.Host)
    $hasHosts = [bool](Find-HostEntry $site.Host)
    if (-not ($site.Exists -or $hasVhost -or $hasHosts)) { throw "Nothing found for $($site.Host)." }

    Write-Host ''
    Write-Host "  This will delete $($site.Host):" -ForegroundColor Yellow
    if ($site.Exists) { Write-Host "    folder    $($site.Path)  (to the Recycle Bin)" }
    if ($dbExists -and -not $sharedWith) { Write-Host "    database  $dbName  (backed up first)" }
    if ($dbExists -and $sharedWith) { Write-Host "    database  $dbName  is KEPT - also used by: $($sharedWith -join ', ')" }
    if ($site.Exists -and -not $dbName) { Write-Host '    database  none found in wp-config.php - no database is touched' }
    if ($hasVhost) { Write-Host '    Apache config' }
    if ($hasHosts) { Write-Host '    hosts line' }
    Write-Host ''
    if (-not $Yes) {
        $answer = Read-Host "  Type the site name ($($site.Name)) to confirm"
        if ($answer.Trim().ToLower() -ne $site.Name.ToLower()) { Write-Host '  Cancelled - nothing deleted.'; return }
    }

    $dropDb = $dbExists -and -not $sharedWith
    if ($dropDb) {
        $backup = Backup-Database $Cfg $dbName
        Write-Host "  Database backed up to $backup" -ForegroundColor Green
    }
    # Hosts first: it may ask for admin, and saying No should leave the site intact.
    if ($hasHosts) { Remove-HostEntry $site.Host | Out-Null; Write-Host '  Removed hosts line' -ForegroundColor Green }
    if ($hasVhost) { Remove-Vhost $Cfg $site.Host | Out-Null; Write-Host '  Removed Apache config' -ForegroundColor Green }
    if ($dropDb) {
        Invoke-MySqlQuery $Cfg "DROP DATABASE ``$dbName``" | Out-Null
        Write-Host "  Dropped database $dbName" -ForegroundColor Green
    }
    if ($site.Exists) {
        try { Remove-ToRecycleBin $site.Path }
        catch { throw "Could not move the folder to the Recycle Bin (is a file open in an editor?): $($_.Exception.Message)" }
        Write-Host '  Moved folder to the Recycle Bin' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host "  $($site.Host) deleted." -ForegroundColor Green
    if ($dropDb) {
        $mysql = Join-Path $Cfg.MySqlDir 'bin\mysql.exe'
        Write-Host '  To restore the database later, run:' -ForegroundColor DarkGray
        Write-Host "    cmd /c '`"$mysql`" -uroot < `"$backup`"'" -ForegroundColor DarkGray
    }
    Write-Host ''
}
