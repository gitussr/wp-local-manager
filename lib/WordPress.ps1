# WordPress.ps1 - installs WordPress with WP-CLI and creates its database.
#
# WP-CLI (wp-cli.phar) is the official WordPress command-line tool. It is one
# PHP file, run with Laragon's php.exe. It does what the browser installer does:
# write wp-config.php, create tables and the admin user. (Downloading the
# WordPress files is done here in PowerShell - see Get-WordPressZip.)

$script:WpCliPath = Join-Path (Split-Path $PSScriptRoot) 'tools\wp-cli.phar'
$script:WpCliUrl  = 'https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar'

# Local-only dev login, printed after every install (see PLAN.md).
$script:WpAdminUser = 'admin'
$script:WpAdminPass = 'admin'

# "my-shop" -> "my_shop". Hyphens in database names need quoting in SQL.
function ConvertTo-DbName {
    param([string]$SiteName)
    $SiteName -replace '-', '_'
}

# Downloads wp-cli.phar once and checks it against the published SHA-512 hash.
function Install-WpCli {
    if (Test-Path $script:WpCliPath) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path $script:WpCliPath) | Out-Null
    # Windows PowerShell 5.1 defaults to old TLS versions that GitHub rejects.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host '  Downloading WP-CLI (one time only)...' -NoNewline
    $tmp = "$script:WpCliPath.download"
    Invoke-WebRequest -Uri $script:WpCliUrl -OutFile $tmp -UseBasicParsing
    $expected = (Invoke-WebRequest -Uri "$script:WpCliUrl.sha512" -UseBasicParsing).Content
    if ($expected -is [byte[]]) { $expected = [Text.Encoding]::ASCII.GetString($expected) }
    $expected = ($expected.Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $tmp -Algorithm SHA512).Hash.ToLower()
    if ($actual -ne $expected) {
        Remove-Item $tmp -Force
        throw 'WP-CLI download failed its checksum - it may be corrupted or tampered with. Not using it.'
    }
    Move-Item $tmp $script:WpCliPath -Force
    Write-Host ' done.' -ForegroundColor Green
}

# Runs one WP-CLI command against a site folder. Throws on failure.
function Invoke-Wp {
    param($Cfg, [string]$SitePath, [string]$Arguments)
    Install-WpCli
    $r = Invoke-Native $Cfg.Php "`"$script:WpCliPath`" --path=`"$SitePath`" $Arguments"
    if ($r.ExitCode -ne 0) { throw "wp $Arguments`n$($r.Output)" }
    return $r.Output
}

# ---------------------------------------------------------------- WordPress files

# We fetch WordPress ourselves instead of "wp core download": that command
# unpacks a .tar.gz with PHP's tar reader, which cuts long file names short on
# Windows (e.g. "...Interface." without "php") and then fails. The official
# .zip keeps full names, and Windows can unzip it natively.
$script:WpCacheDir = Join-Path (Split-Path $PSScriptRoot) 'tools\cache'

# Returns the path of the latest WordPress zip, downloading it if not cached.
# Offline: falls back to the newest zip already in the cache.
function Get-WordPressZip {
    New-Item -ItemType Directory -Force -Path $script:WpCacheDir | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $offer = (Invoke-RestMethod 'https://api.wordpress.org/core/version-check/1.7/' -UseBasicParsing).offers[0]
    } catch {
        $cached = Get-ChildItem $script:WpCacheDir -Filter 'wordpress-*.zip' | Sort-Object Name -Descending | Select-Object -First 1
        if ($cached) { Write-Host "  Offline - using cached $($cached.Name)" -ForegroundColor DarkGray; return $cached.FullName }
        throw 'Cannot reach wordpress.org and no WordPress zip is cached yet.'
    }
    $zip = Join-Path $script:WpCacheDir "wordpress-$($offer.version).zip"
    if (Test-Path $zip) { return $zip }

    Write-Host "  Downloading WordPress $($offer.version)..." -NoNewline
    $tmp = "$zip.download"
    Invoke-WebRequest -Uri $offer.download -OutFile $tmp -UseBasicParsing
    $expected = (Invoke-WebRequest -Uri "$($offer.download).sha1" -UseBasicParsing).Content
    if ($expected -is [byte[]]) { $expected = [Text.Encoding]::ASCII.GetString($expected) }
    $expected = ($expected.Trim() -split '\s+')[0].ToLower()
    if ((Get-FileHash $tmp -Algorithm SHA1).Hash.ToLower() -ne $expected) {
        Remove-Item $tmp -Force
        throw 'WordPress download failed its checksum - not using it.'
    }
    Move-Item $tmp $zip -Force
    Write-Host ' done.' -ForegroundColor Green
    return $zip
}

# Unzips WordPress into $Path. The zip holds everything inside a "wordpress\"
# folder, so we extract to a temporary folder next to it and move the contents up.
function Expand-WordPress {
    param([string]$Zip, [string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $staging = Join-Path $Path '.wplm-extract'
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $staging)
    Get-ChildItem (Join-Path $staging 'wordpress') -Force | Move-Item -Destination $Path
    Remove-Item $staging -Recurse -Force
}

# ---------------------------------------------------------------- database

# Runs SQL through MySQL's own command-line client as root.
function Invoke-MySqlQuery {
    param($Cfg, [string]$Sql)
    $mysql = Join-Path $Cfg.MySqlDir 'bin\mysql.exe'
    $r = Invoke-Native $mysql "-uroot --host=127.0.0.1 --port=$($Cfg.MySqlPort) --batch --skip-column-names -e `"$Sql`""
    if ($r.ExitCode -ne 0) { throw "MySQL error: $($r.Output)" }
    return $r.Output
}

function Test-Database {
    param($Cfg, [string]$DbName)
    # Exact match (SHOW DATABASES LIKE would treat "_" as a wildcard).
    [bool](Invoke-MySqlQuery $Cfg "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DbName'")
}

function New-Database {
    param($Cfg, [string]$DbName)
    Invoke-MySqlQuery $Cfg "CREATE DATABASE ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" | Out-Null
}

# ---------------------------------------------------------------- install

# Installs a fresh WordPress into C:\laragon\www\<name> with database <name>.
# Refuses if the folder already has files or the database already exists.
function Install-WordPress {
    param($Cfg, [string]$HostName, [string]$Title)
    $name   = $HostName -replace '\.test$', ''
    $path   = Join-Path $Cfg.WwwDir $name
    $dbName = ConvertTo-DbName $name
    if (-not $Title) { $Title = $name }

    if ((Test-Path $path) -and (Get-ChildItem $path -Force | Select-Object -First 1)) {
        throw "Folder already exists and is not empty: $path"
    }
    if ((Get-MySqlProcesses $Cfg).Count -eq 0) { Start-MySql $Cfg }
    if (Test-Database $Cfg $dbName) { throw "Database '$dbName' already exists. Not touching it." }

    Install-WpCli
    $zip = Get-WordPressZip
    New-Item -ItemType Directory -Force -Path $path | Out-Null

    Write-Host '  Unpacking WordPress...' -NoNewline
    Expand-WordPress $zip $path
    Write-Host ' done.' -ForegroundColor Green

    Write-Host "  Creating database $dbName..." -NoNewline
    New-Database $Cfg $dbName
    Write-Host ' done.' -ForegroundColor Green

    Write-Host '  Writing wp-config.php...' -NoNewline
    # WP_ENVIRONMENT_TYPE=local tells WordPress and plugins this is a dev site.
    Invoke-Wp $Cfg $path ("config create --dbname=$dbName --dbuser=root --dbpass= " +
        "--dbhost=127.0.0.1 --dbcharset=utf8mb4") | Out-Null
    Invoke-Wp $Cfg $path 'config set WP_ENVIRONMENT_TYPE local' | Out-Null
    Write-Host ' done.' -ForegroundColor Green

    Write-Host '  Installing WordPress...' -NoNewline
    Invoke-Wp $Cfg $path ("core install --url=http://$HostName --title=`"$Title`" " +
        "--admin_user=$script:WpAdminUser --admin_password=$script:WpAdminPass " +
        "--admin_email=admin@$HostName --skip-email") | Out-Null
    Write-Host ' done.' -ForegroundColor Green

    [pscustomobject]@{ Path = $path; Database = $dbName; Url = "http://$HostName"
                       User = $script:WpAdminUser; Password = $script:WpAdminPass }
}
