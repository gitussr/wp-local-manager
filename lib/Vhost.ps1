# Vhost.ps1 - Apache "virtual host" files: which folder serves which .test name.
#
# Apache's httpd.conf loads every C:\laragon\etc\apache2\sites-enabled\*.conf.
# Each auto.<name>.test.conf says "requests for <name>.test are served from
# C:\laragon\www\<name>". Apache only reads config at startup, so a running
# Apache must be restarted to pick up a change.

$script:VhostTemplate = Join-Path (Split-Path $PSScriptRoot) 'templates\vhost.conf'

# Laragon's naming: auto.<host>.conf
function Get-VhostPath {
    param($Cfg, [string]$HostName)
    Join-Path $Cfg.SitesEnabled "auto.$HostName.conf"
}

# Apache must restart to read new config. Only restarts if it was running.
function Restart-ApacheIfRunning {
    param($Cfg)
    if ((Get-ApacheProcesses $Cfg).Count -eq 0) {
        Write-Host '  Apache is stopped - it will read the new config when it starts.' -ForegroundColor DarkGray
        return
    }
    Stop-Apache $Cfg
    Start-Apache $Cfg
}

# Every vhost file in sites-enabled, with the name and folder it maps.
function Get-Vhosts {
    param($Cfg)
    foreach ($f in Get-ChildItem $Cfg.SitesEnabled -Filter '*.conf') {
        $text = Get-Content $f.FullName -Raw
        $site = if ($text -match '(?m)^\s*define\s+SITE\s+"([^"]+)"') { $Matches[1] }
                elseif ($text -match '(?m)^\s*ServerName\s+(\S+)') { $Matches[1] }
        $root = if ($text -match '(?m)^\s*define\s+ROOT\s+"([^"]+)"') { $Matches[1] }
                elseif ($text -match '(?m)^\s*DocumentRoot\s+"([^"]+)"') { $Matches[1] }
        [pscustomobject]@{ File = $f.Name; Site = $site; Root = $root }
    }
}

# Returns 'added' or 'exists'. $Root defaults to C:\laragon\www\<name>.
function Add-Vhost {
    param($Cfg, [string]$HostName, [string]$Root)
    $name = $HostName -replace '\.test$', ''
    if (-not $Root) { $Root = Join-Path $Cfg.WwwDir $name }
    if (-not (Test-Path $Root -PathType Container)) { throw "Site folder does not exist: $Root" }

    $path = Get-VhostPath $Cfg $HostName
    if (Test-Path $path) { return 'exists' }

    # Make sure the config is healthy BEFORE we touch it, so a failure
    # afterwards can only be caused by our new file.
    $before = Test-ApacheConfig $Cfg
    if ($before.ExitCode -ne 0) { throw "Apache config is already broken - fix this first:`n$($before.Output)" }

    $conf = (Get-Content $script:VhostTemplate -Raw).
        Replace('{{ROOT}}', ($Root -replace '\\', '/')).
        Replace('{{SITE}}', $HostName).
        Replace('{{SSLDIR}}', ("$($Cfg.LaragonRoot)\etc\ssl" -replace '\\', '/'))
    # ASCII + CRLF, same as the files Laragon writes.
    [IO.File]::WriteAllText($path, ($conf -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)

    $after = Test-ApacheConfig $Cfg
    if ($after.ExitCode -ne 0) {
        Remove-Item $path -Force
        throw "The new vhost broke Apache's config, so it was removed:`n$($after.Output)"
    }
    Restart-ApacheIfRunning $Cfg
    return 'added'
}

# Returns 'removed' or 'absent'. Only touches auto.<host>.conf.
function Remove-Vhost {
    param($Cfg, [string]$HostName)
    $path = Get-VhostPath $Cfg $HostName
    if (-not (Test-Path $path)) { return 'absent' }
    Remove-Item $path -Force
    $check = Test-ApacheConfig $Cfg
    if ($check.ExitCode -ne 0) { throw "Apache config has an error after removing the vhost:`n$($check.Output)" }
    Restart-ApacheIfRunning $Cfg
    return 'removed'
}
