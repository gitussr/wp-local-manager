# Config.ps1 - finds where Laragon's servers live.
#
# Laragon puts each server in a folder whose name includes the version
# (e.g. bin\mysql\mysql-8.4.3-winx64). Instead of hard-coding those names,
# we look for them, so a Laragon upgrade doesn't break wplm.

function Get-NewestDir {
    param([string]$Parent, [string]$Filter)
    $dirs = Get-ChildItem -Path $Parent -Directory -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    if (-not $dirs) { throw "No folder matching '$Filter' found in $Parent" }
    return $dirs[0].FullName
}

# Reads one "key=value" setting from an .ini file (first match wins).
function Get-IniValue {
    param([string]$Path, [string]$Key)
    foreach ($line in Get-Content $Path) {
        if ($line -match "^\s*$Key\s*=\s*`"?([^`"]+)`"?\s*$") { return $Matches[1] }
    }
    return $null
}

function Get-WplmConfig {
    # Override with the WPLM_LARAGON environment variable if Laragon lives elsewhere.
    $root = if ($env:WPLM_LARAGON) { $env:WPLM_LARAGON } else { 'C:\laragon' }
    if (-not (Test-Path $root)) { throw "Laragon folder not found: $root" }

    $apacheDir = Get-NewestDir "$root\bin\apache" 'httpd-*'
    $mysqlDir  = Get-NewestDir "$root\bin\mysql"  'mysql-*'
    $phpDir    = Get-NewestDir "$root\bin\php"    'php-*'

    $myIni   = Join-Path $mysqlDir 'my.ini'
    $dataDir = (Get-IniValue $myIni 'datadir') -replace '/', '\'

    [pscustomobject]@{
        LaragonRoot  = $root
        WwwDir       = "$root\www"
        SitesEnabled = "$root\etc\apache2\sites-enabled"

        ApacheDir    = $apacheDir
        Httpd        = "$apacheDir\bin\httpd.exe"
        ApacheLog    = "$apacheDir\logs\error.log"
        ApachePort   = 80

        MySqlDir     = $mysqlDir
        Mysqld       = "$mysqlDir\bin\mysqld.exe"
        MySqlAdmin   = "$mysqlDir\bin\mysqladmin.exe"
        MySqlIni     = $myIni
        MySqlDataDir = $dataDir
        MySqlLog     = "$dataDir\mysqld.log"   # same log file Laragon uses
        MySqlPort    = [int](Get-IniValue $myIni 'port')

        PhpDir       = $phpDir
        Php          = "$phpDir\php.exe"
    }
}
