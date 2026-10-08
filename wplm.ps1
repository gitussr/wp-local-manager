# wplm - WP Local Manager. Runs Laragon's servers without the Laragon app.
# Usage: wplm <command>     (see Show-Help below)

param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'

# Flags added by the GUI, which runs commands in their own console window:
#   --pause             keep that window open long enough to read the result
#   --done-file <path>  write the exit code there when the work is finished (before
#                       pausing), so the GUI can refresh without waiting for Enter
$Pause = $false
$DoneFile = $null
$all = @($Rest | Where-Object { $null -ne $_ })   # no arguments -> empty array, not @($null)
$kept = @()
for ($i = 0; $i -lt $all.Count; $i++) {
    if ($all[$i] -eq '--pause') { $Pause = $true }
    elseif ($all[$i] -eq '--done-file') { $DoneFile = $all[$i + 1]; $i++ }
    else { $kept += $all[$i] }
}
$Rest = $kept

. "$PSScriptRoot\lib\Config.ps1"
. "$PSScriptRoot\lib\Servers.ps1"
. "$PSScriptRoot\lib\Hosts.ps1"
. "$PSScriptRoot\lib\Vhost.ps1"
. "$PSScriptRoot\lib\WordPress.ps1"
. "$PSScriptRoot\lib\Site.ps1"
. "$PSScriptRoot\lib\Manage.ps1"
. "$PSScriptRoot\lib\Setup.ps1"

function Show-Help {
    Write-Host @'

  wplm - WP Local Manager

    wplm new <name> [title]   Create a complete WordPress site at http://<name>.test
                              and open it. Login: admin / admin
                              Add --no-browser to skip opening the browser.
    wplm list                 Show all sites and whether each is fully set up
    wplm open <name> [admin]  Open a site (or its wp-admin); starts servers if needed
    wplm delete <name>        Delete a site: DB backed up first, folder to Recycle Bin.
                              Asks you to type the name. --yes skips the question.
    wplm gui                  Open the WP Local Manager window

    wplm status               Show whether Apache and MySQL are running
    wplm start                Start Apache and MySQL (skips any already running)
    wplm stop                 Stop Apache and MySQL safely
    wplm restart              Stop, then start

    wplm hosts list           Show all .test names in the Windows hosts file
    wplm hosts add <name>     Point <name>.test at this computer (asks for admin)
    wplm hosts remove <name>  Remove <name>.test from the hosts file (asks for admin)

    wplm vhost list           Show which .test name Apache serves from which folder
    wplm vhost add <name>     Serve C:\laragon\www\<name> at <name>.test (restarts Apache)
    wplm vhost remove <name>  Remove that Apache config (restarts Apache)

    wplm wp <name> <args...>  Run any WP-CLI command on a site
                              e.g.  wplm wp myshop plugin list

    wplm setup                Put "wplm" on PATH + Desktop/Start Menu shortcuts
    wplm setup remove         Undo that
    wplm autostart on|off     Start Apache + MySQL automatically at Windows login

'@
}

function Invoke-SetupCommand {
    param([string[]]$SetupArgs)
    if ($SetupArgs -contains 'remove') {
        if (Remove-WplmFromPath) { Write-Host '  Removed wplm from your PATH.' -ForegroundColor Green }
        Uninstall-WplmShortcuts
        Set-Autostart $false
        Write-Host '  Removed shortcuts and start-at-login.' -ForegroundColor Green
        return
    }
    if (Add-WplmToPath) { Write-Host "  Added $script:BinDir to your PATH." -ForegroundColor Green }
    else { Write-Host '  wplm is already on your PATH.' -ForegroundColor DarkGray }
    Install-WplmShortcuts
    Write-Host '  Created "WP Local Manager" shortcuts on the Desktop and in the Start Menu.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Open a NEW terminal and type:  wplm help' -ForegroundColor Cyan
    Write-Host '  (Terminals inside VS Code need VS Code restarted to see the new PATH.)' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-AutostartCommand {
    param([string[]]$AutoArgs)
    switch ("$($AutoArgs | Select-Object -First 1)".ToLower()) {
        'on'  { Set-Autostart $true;  Write-Host '  Apache + MySQL will start automatically when you log in to Windows.' -ForegroundColor Green }
        'off' { Set-Autostart $false; Write-Host '  Start-at-login turned off.' -ForegroundColor Green }
        default {
            $state = if (Test-Autostart) { 'ON' } else { 'OFF' }
            Write-Host "  Start-at-login is $state. Use: wplm autostart on|off"
        }
    }
}

# wplm new <name> [title words...] [--no-browser]
function Invoke-NewCommand {
    param($Cfg, [string[]]$NewArgs)
    $NewArgs = @($NewArgs | Where-Object { $_ })
    if ($NewArgs.Count -lt 1) { throw 'Usage: wplm new <name> [title]   e.g.  wplm new my-shop "My Shop"' }
    $noBrowser = $NewArgs -contains '--no-browser'
    $words = @($NewArgs | Where-Object { $_ -ne '--no-browser' })
    $title = if ($words.Count -gt 1) { $words[1..($words.Count - 1)] -join ' ' } else { $null }
    New-WpSite $Cfg $words[0] $title -NoBrowser:$noBrowser
}

# Passes everything after the site name straight to WP-CLI and shows its output.
function Invoke-WpCommand {
    param($Cfg, [string[]]$WpArgs)
    if ($WpArgs.Count -lt 2) { throw 'Usage: wplm wp <name> <wp-cli command...>' }
    $name = (ConvertTo-TestHost $WpArgs[0]) -replace '\.test$', ''
    $path = Join-Path $Cfg.WwwDir $name
    if (-not (Test-Path "$path\wp-config.php")) { throw "No WordPress site at $path" }
    $quoted = $WpArgs[1..($WpArgs.Count - 1)] | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    Invoke-Wp $Cfg $path ($quoted -join ' ') | Write-Host
}

function Invoke-VhostCommand {
    param($Cfg, [string[]]$VhostArgs)
    $action = if ($VhostArgs.Count -ge 1) { $VhostArgs[0].ToLower() } else { 'list' }
    if ($action -eq 'list') {
        $vhosts = @(Get-Vhosts $Cfg | Where-Object Site | Sort-Object Site)
        Write-Host ''
        Write-Host "  $($vhosts.Count) sites configured in Apache:"
        foreach ($v in $vhosts) { Write-Host ("    {0,-45} -> {1}" -f $v.Site, $v.Root) }
        Write-Host ''
        return
    }
    if ($VhostArgs.Count -lt 2) { throw "Usage: wplm vhost $action <name>" }
    $hostName = ConvertTo-TestHost $VhostArgs[1]
    switch ($action) {
        'add' {
            $r = Add-Vhost $Cfg $hostName
            if ($r -eq 'exists') { Write-Host "  Apache config for $hostName already exists - nothing to do." -ForegroundColor DarkGray }
            else { Write-Host "  Apache now serves $hostName" -ForegroundColor Green }
        }
        'remove' {
            $r = Remove-Vhost $Cfg $hostName
            if ($r -eq 'absent') { Write-Host "  No Apache config for $hostName - nothing to do." -ForegroundColor DarkGray }
            else { Write-Host "  Removed Apache config for $hostName" -ForegroundColor Green }
        }
        default { throw "Unknown vhost action '$action'. Use list, add or remove." }
    }
}

function Invoke-HostsCommand {
    param([string[]]$HostArgs)
    $action = if ($HostArgs.Count -ge 1) { $HostArgs[0].ToLower() } else { 'list' }
    if ($action -eq 'list') {
        $entries = @(Get-TestHostEntries | Sort-Object Host)
        Write-Host ''
        Write-Host "  $($entries.Count) .test names in the hosts file:"
        foreach ($e in $entries) { Write-Host ("    {0,-45} -> {1}" -f $e.Host, $e.Ip) }
        Write-Host ''
        return
    }
    if ($HostArgs.Count -lt 2) { throw "Usage: wplm hosts $action <name>" }
    $hostName = ConvertTo-TestHost $HostArgs[1]
    switch ($action) {
        'add' {
            $r = Add-HostEntry $hostName
            if ($r -eq 'exists') { Write-Host "  $hostName is already in the hosts file - nothing to do." -ForegroundColor DarkGray }
            else { Write-Host "  Added $hostName -> 127.0.0.1" -ForegroundColor Green }
        }
        'remove' {
            $r = Remove-HostEntry $hostName
            if ($r -eq 'absent') { Write-Host "  $hostName is not in the hosts file - nothing to do." -ForegroundColor DarkGray }
            else { Write-Host "  Removed $hostName" -ForegroundColor Green }
        }
        default { throw "Unknown hosts action '$action'. Use list, add or remove." }
    }
}

# Internal commands, run only by the elevated copy that Invoke-ElevatedWplm
# starts. Args: <host> <result-file>. The result file carries the outcome back.
function Invoke-InternalHostsCommand {
    param([string]$Cmd, [string[]]$InternalArgs)
    $resultFile = $InternalArgs[1]
    try {
        $hostName = ConvertTo-TestHost $InternalArgs[0]
        $r = if ($Cmd -eq '_hosts-add') { Add-HostEntryDirect $hostName } else { Remove-HostEntryDirect $hostName }
        Set-Content -Path $resultFile -Value $r
        exit 0
    } catch {
        Set-Content -Path $resultFile -Value $_.Exception.Message
        exit 1
    }
}

try {
    $cfg = Get-WplmConfig
    switch ($Command.ToLower()) {
        'new'           { Invoke-NewCommand $cfg @($Rest) }
        'list'          { Show-Sites $cfg }
        'open'          {
            if (-not $Rest) { throw 'Usage: wplm open <name> [admin]' }
            Open-Site $cfg $Rest[0] -Admin:($Rest -contains 'admin')
        }
        'delete'        {
            $names = @($Rest | Where-Object { $_ -and $_ -ne '--yes' })
            if ($names.Count -ne 1) { throw 'Usage: wplm delete <name> [--yes]' }
            Remove-WpSite $cfg $names[0] -Yes:($Rest -contains '--yes')
        }
        'status'        { Show-Status $cfg }
        'start'         { Start-MySql $cfg; Start-Apache $cfg; Show-Status $cfg }
        'stop'          { Stop-Apache $cfg; Stop-MySql $cfg; Show-Status $cfg }
        'restart'       { Stop-Apache $cfg; Stop-MySql $cfg; Start-MySql $cfg; Start-Apache $cfg; Show-Status $cfg }
        'hosts'         { Invoke-HostsCommand @($Rest) }
        'vhost'         { Invoke-VhostCommand $cfg @($Rest) }
        'wp'            { Invoke-WpCommand $cfg @($Rest) }
        '_hosts-add'    { Invoke-InternalHostsCommand $Command @($Rest) }
        '_hosts-remove' { Invoke-InternalHostsCommand $Command @($Rest) }
        # Minimized, NOT Hidden: Windows applies the launch style to the first window
        # the process shows, so Hidden would make the form itself invisible.
        # (-WindowStyle Hidden inside the arguments then hides just the console.)
        'gui'           { Start-Process powershell -WindowStyle Minimized -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\wplm-gui.ps1`"" }
        'setup'         { Invoke-SetupCommand @($Rest) }
        'autostart'     { Invoke-AutostartCommand @($Rest) }
        default         { Show-Help }
    }
    $exitCode = 0
} catch {
    Write-Host ''
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    $exitCode = 1
}

if ($DoneFile) { Set-Content -Path $DoneFile -Value $exitCode }
if ($Pause) {
    # Results of new/delete (and any error) need reading; quick commands just linger briefly.
    if ($exitCode -ne 0 -or $Command -in @('new', 'delete')) { Read-Host '  Press Enter to close' | Out-Null }
    else { Start-Sleep -Seconds 3 }
}
exit $exitCode
