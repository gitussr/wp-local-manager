# Hosts.ps1 - add / remove "127.0.0.1  name.test" lines in the Windows hosts file.
#
# Windows checks this file before asking DNS servers. A line
#     127.0.0.1   myshop.test
# means "myshop.test is this computer", so the browser reaches local Apache.
# Only Administrators may change the file, so writes run elevated (UAC prompt).

$script:HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$script:HostsTag  = '#laragon magic!'   # same tag as Laragon, so both tools recognise the lines
$script:HostsBackupDir = Join-Path (Split-Path $PSScriptRoot) 'backups\hosts'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# "my-shop" or "my-shop.test" -> "my-shop.test". Rejects anything unsafe.
function ConvertTo-TestHost {
    param([string]$Name)
    $h = $Name.Trim().ToLower()
    if ($h -notlike '*.test') { $h = "$h.test" }
    if ($h -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.test$') {
        throw "Invalid site name '$Name'. Use lowercase letters, digits and hyphens (e.g. my-shop)."
    }
    return $h
}

# Turns one hosts line into { Ip, Names } or $null for blank/comment lines.
function Split-HostsLine {
    param([string]$Line)
    $body = ($Line -split '#', 2)[0].Trim()
    if (-not $body) { return $null }
    $parts = @($body -split '\s+')
    if ($parts.Count -lt 2) { return $null }
    [pscustomobject]@{ Ip = $parts[0]; Names = @($parts[1..($parts.Count - 1)]) }
}

function Get-HostsLines { @([IO.File]::ReadAllLines($script:HostsPath)) }

# All lines that mention the host name: { Index, Ip, Names, Line }
function Find-HostEntry {
    param([string]$HostName, [string[]]$Lines = (Get-HostsLines))
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $e = Split-HostsLine $Lines[$i]
        if ($e -and ($e.Names -contains $HostName)) {
            [pscustomobject]@{ Index = $i; Ip = $e.Ip; Names = $e.Names; Line = $Lines[$i] }
        }
    }
}

# Every *.test name currently mapped in the hosts file.
function Get-TestHostEntries {
    foreach ($line in Get-HostsLines) {
        $e = Split-HostsLine $line
        if (-not $e) { continue }
        foreach ($n in $e.Names) {
            if ($n -like '*.test') { [pscustomobject]@{ Host = $n; Ip = $e.Ip } }
        }
    }
}

# Same column layout Laragon writes: IP padded to 15, name padded to 20.
function Format-HostsLine {
    param([string]$HostName)
    '{0,-15}{1,-20} {2}   ' -f '127.0.0.1', $HostName, $script:HostsTag
}

function Backup-HostsFile {
    New-Item -ItemType Directory -Force -Path $script:HostsBackupDir | Out-Null
    $dest = Join-Path $script:HostsBackupDir ("hosts-{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $script:HostsPath $dest -Force
    # Keep only the 20 newest backups.
    Get-ChildItem $script:HostsBackupDir -Filter 'hosts-*.bak' | Sort-Object Name -Descending |
        Select-Object -Skip 20 | Remove-Item -Force
    return $dest
}

# Writes the file as UTF-8 without BOM (a BOM can break the first line),
# retrying briefly in case antivirus or the DNS service has it open.
function Write-HostsLines {
    param([string[]]$Lines)
    $text = ($Lines -join "`r`n") + "`r`n"
    $enc = New-Object System.Text.UTF8Encoding $false
    for ($try = 1; $try -le 5; $try++) {
        try { [IO.File]::WriteAllText($script:HostsPath, $text, $enc); return }
        catch [System.IO.IOException] {
            if ($try -eq 5) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Clear-DnsCache { Invoke-Native "$env:SystemRoot\System32\ipconfig.exe" '/flushdns' | Out-Null }

# ---------------------------------------------------------------- direct (needs admin)

# Returns 'added' or 'exists'.
function Add-HostEntryDirect {
    param([string]$HostName)
    $lines = Get-HostsLines
    $found = @(Find-HostEntry $HostName $lines)
    if ($found | Where-Object { $_.Ip -eq '127.0.0.1' }) { return 'exists' }
    if ($found) {
        throw "$HostName is already in the hosts file pointing at $($found[0].Ip). Not changing it."
    }
    Backup-HostsFile | Out-Null
    Write-HostsLines ($lines + (Format-HostsLine $HostName))
    Clear-DnsCache
    return 'added'
}

# Returns 'removed' or 'absent'. Only removes lines that map just this one
# name to this computer; anything else is left for a human to look at.
function Remove-HostEntryDirect {
    param([string]$HostName)
    $lines = Get-HostsLines
    $found = @(Find-HostEntry $HostName $lines)
    if (-not $found) { return 'absent' }
    foreach ($f in $found) {
        if ($f.Names.Count -ne 1 -or $f.Ip -notin @('127.0.0.1', '::1')) {
            throw "Line $($f.Index + 1) is not a simple local entry ('$($f.Line.Trim())'). Edit the hosts file by hand."
        }
    }
    Backup-HostsFile | Out-Null
    $drop = $found.Index
    Write-HostsLines @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -notin $drop) { $lines[$i] } })
    Clear-DnsCache
    return 'removed'
}

# ---------------------------------------------------------------- public (elevates if needed)

# Re-runs wplm.ps1 as Administrator for one internal command. The elevated
# window is hidden, so it reports back through a small temp file.
function Invoke-ElevatedWplm {
    param([string]$InternalCommand, [string]$HostName)
    $resultFile = Join-Path $env:TEMP ("wplm-{0}.txt" -f [guid]::NewGuid())
    $wplm = Join-Path (Split-Path $PSScriptRoot) 'wplm.ps1'
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$wplm`" $InternalCommand $HostName `"$resultFile`""
    Write-Host '  Windows will ask for administrator permission to edit the hosts file...' -ForegroundColor DarkGray
    try {
        $p = Start-Process powershell -Verb RunAs -ArgumentList $argList -WindowStyle Hidden -Wait -PassThru
    } catch {
        throw 'Administrator permission was not given, so the hosts file was not changed.'
    }
    $msg = ''
    if (Test-Path $resultFile) { $msg = (Get-Content $resultFile -Raw).Trim(); Remove-Item $resultFile -Force }
    if ($p.ExitCode -ne 0) { throw "Hosts file update failed: $msg" }
    return $msg
}

function Add-HostEntry {
    param([string]$HostName)
    if (Test-IsAdmin) { return Add-HostEntryDirect $HostName }
    Invoke-ElevatedWplm '_hosts-add' $HostName
}

function Remove-HostEntry {
    param([string]$HostName)
    if (Test-IsAdmin) { return Remove-HostEntryDirect $HostName }
    Invoke-ElevatedWplm '_hosts-remove' $HostName
}
