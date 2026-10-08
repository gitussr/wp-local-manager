# Site.ps1 - "wplm new <name>": one command from nothing to a working WordPress site.
#
# Order matters:
#   1. check everything first (nothing is changed if a check fails)
#   2. hosts entry - the only step needing admin, so the UAC prompt comes
#      up front and the rest can run unattended
#   3. WordPress files + database + install (MySQL was started by the checks)
#   4. Apache vhost, then start Apache last so it reads the new config once
#   5. open the browser
# If a step fails, everything this run created is removed again (except the
# harmless hosts line), so "wplm new" can simply be run again.

# Folder names Windows itself refuses to create.
$script:ReservedNames = @('con', 'prn', 'aux', 'nul') + (1..9 | ForEach-Object { "com$_"; "lpt$_" })

function Assert-NewSiteAllowed {
    param($Cfg, [string]$HostName)
    $name = $HostName -replace '\.test$', ''
    if ($name.Length -gt 50) { throw "Site name is too long (max 50 characters)." }
    if ($name -in $script:ReservedNames) { throw "'$name' is a reserved Windows name. Pick another." }

    $path = Join-Path $Cfg.WwwDir $name
    if (Test-Path $path) { throw "Folder already exists: $path" }

    $vhost = Get-Vhosts $Cfg | Where-Object { $_.Site -eq $HostName }
    if ($vhost) { throw "Apache already has a config for $HostName ($($vhost[0].File))." }

    $other = Find-HostEntry $HostName | Where-Object { $_.Ip -ne '127.0.0.1' }
    if ($other) { throw "$HostName is in the hosts file pointing at $($other[0].Ip), not this computer." }

    if ((Get-MySqlProcesses $Cfg).Count -eq 0) { Start-MySql $Cfg }
    $db = ConvertTo-DbName $name
    if (Test-Database $Cfg $db) { throw "Database '$db' already exists." }
}

# Removes whatever this run created. Only called after Assert-NewSiteAllowed
# proved none of these existed beforehand, so nothing pre-existing is touched.
function Undo-NewSite {
    param($Cfg, [string]$HostName)
    $name = $HostName -replace '\.test$', ''
    Write-Host '  Cleaning up what this run created...' -ForegroundColor Yellow
    try { if ((Remove-Vhost $Cfg $HostName) -eq 'removed') { Write-Host '    removed Apache config' } }
    catch { Write-Host "    could not remove Apache config: $($_.Exception.Message)" -ForegroundColor Red }
    try {
        $db = ConvertTo-DbName $name
        if (Test-Database $Cfg $db) { Invoke-MySqlQuery $Cfg "DROP DATABASE ``$db``" | Out-Null; Write-Host "    dropped database $db" }
    } catch { Write-Host "    could not drop database: $($_.Exception.Message)" -ForegroundColor Red }
    $path = Join-Path $Cfg.WwwDir $name
    if (Test-Path $path) {
        try { Remove-Item $path -Recurse -Force; Write-Host "    deleted $path" }
        catch { Write-Host "    could not delete $path`: $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host "    (the hosts line for $HostName was kept - it is harmless and will be reused)" -ForegroundColor DarkGray
}

function New-WpSite {
    param($Cfg, [string]$Name, [string]$Title, [switch]$NoBrowser)
    $hostName = ConvertTo-TestHost $Name
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ''
    Write-Host "  Creating WordPress site $hostName" -ForegroundColor Cyan
    Write-Host ''

    Write-Host '  [1/5] Checking name, folder, database and Apache config'
    Assert-NewSiteAllowed $Cfg $hostName

    Write-Host "  [2/5] Pointing $hostName at this computer (hosts file)"
    if ((Add-HostEntry $hostName) -eq 'exists') { Write-Host '  Hosts line already there - reusing it.' -ForegroundColor DarkGray }

    try {
        Write-Host '  [3/5] Installing WordPress'
        $site = Install-WordPress $Cfg $hostName $Title

        Write-Host '  [4/5] Telling Apache about the site'
        Add-Vhost $Cfg $hostName | Out-Null   # restarts Apache only if it was running

        Write-Host '  [5/5] Making sure Apache and MySQL are running'
        Start-MySql $Cfg
        Start-Apache $Cfg
    } catch {
        Write-Host ''
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Undo-NewSite $Cfg $hostName
        throw "Site was not created. Fix the problem above and run 'wplm new $Name' again."
    }

    Write-Host ''
    Write-Host "  Done in $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Green
    Write-Host ''
    Write-Host "    Site     : $($site.Url)"
    Write-Host "    Admin    : $($site.Url)/wp-admin"
    Write-Host "    Login    : $($site.User) / $($site.Password)"
    Write-Host "    Folder   : $($site.Path)"
    Write-Host "    Database : $($site.Database)"
    Write-Host ''
    if (-not $NoBrowser) { Start-Process "$($site.Url)/wp-admin/" }
}
