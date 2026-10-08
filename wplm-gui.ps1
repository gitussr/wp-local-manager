# wplm-gui.ps1 - the WP Local Manager window (Windows Forms).
#
# The window only SHOWS state and LAUNCHES commands. Every action runs the
# normal "wplm <command>" in its own console window, so the progress output,
# the UAC prompt and delete's type-the-name confirmation work exactly as in a
# terminal. When that console closes, the window refreshes itself.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. "$PSScriptRoot\lib\Config.ps1"
. "$PSScriptRoot\lib\Servers.ps1"
. "$PSScriptRoot\lib\Hosts.ps1"
. "$PSScriptRoot\lib\Vhost.ps1"
. "$PSScriptRoot\lib\WordPress.ps1"
. "$PSScriptRoot\lib\Manage.ps1"

$cfg = Get-WplmConfig
$wplm = Join-Path $PSScriptRoot 'wplm.ps1'
$script:task = $null       # the console process currently running a command
$script:taskName = ''
$script:doneFile = $null   # the command writes its exit code here when its work is done
$script:siteSignature = '' # quick fingerprint of sites on disk, to spot changes

[System.Windows.Forms.Application]::EnableVisualStyles()
$font = New-Object System.Drawing.Font('Segoe UI', 9)
$bold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

# ---------------------------------------------------------------- helpers

function New-Control {
    param([string]$Type, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '')
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    $c.Text = $Text
    $c.Font = $font
    return $c
}

function Show-Message {
    param([string]$Text)
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'WP Local Manager')
}

# Runs "wplm <arguments>" in a visible console. One task at a time.
function Start-WplmTask {
    param([string]$Arguments, [string]$Label)
    if ($script:task -and -not $script:task.HasExited) {
        Show-Message "Still busy with: $script:taskName`nWait for its console window to finish."
        return
    }
    $script:taskName = $Label
    $script:doneFile = Join-Path $env:TEMP ("wplm-done-{0}.txt" -f [guid]::NewGuid())
    $statusLabel.Text = "Running: $Label ..."
    $script:task = Start-Process powershell -PassThru -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$wplm`" $Arguments --pause --done-file `"$script:doneFile`""
}

# A task is finished once it has written its done-file - which happens BEFORE
# its console waits for Enter - or once its console has closed.
function Complete-TaskIfDone {
    if (-not $script:task) { return }
    $written = Test-Path $script:doneFile
    if (-not ($written -or $script:task.HasExited)) { return }
    $failed = $written -and ((Get-Content $script:doneFile -Raw).Trim() -ne '0')
    if ($written) { Remove-Item $script:doneFile -Force -ErrorAction SilentlyContinue }
    $script:task = $null
    $statusLabel.Text = if ($failed) { "Failed: $script:taskName - see its console window" } else { "Finished: $script:taskName" }
    Update-ServerLabels
    Update-SiteList
}

# Folder names in www + Apache config file names + hosts file timestamp.
# Cheap to compute, and it changes whenever a site is added or removed by
# anything (this window, the wplm command, or Laragon).
function Get-SiteSignature {
    $folders = (Get-ChildItem $cfg.WwwDir -Directory | ForEach-Object Name) -join ','
    $vhosts  = (Get-ChildItem $cfg.SitesEnabled -Filter '*.conf' | ForEach-Object Name) -join ','
    $hosts   = (Get-Item "$env:SystemRoot\System32\drivers\etc\hosts").LastWriteTimeUtc.Ticks
    "$folders|$vhosts|$hosts"
}

function Get-SelectedSite {
    if ($siteList.SelectedItems.Count -eq 0) { Show-Message 'Select a site in the list first.'; return $null }
    return $siteList.SelectedItems[0].Text
}

function Test-ServersUp {
    ((Get-ApacheProcesses $cfg).Count -gt 0) -and (Test-Port $cfg.ApachePort) -and
    ((Get-MySqlProcesses $cfg).Count -gt 0) -and (Test-Port $cfg.MySqlPort)
}

# Opens a URL right away if the servers are up; otherwise lets "wplm open"
# start them first.
function Open-SiteUrl {
    param([string]$Name, [switch]$Admin)
    if (Test-ServersUp) {
        $url = "http://$($Name.ToLower()).test/"
        if ($Admin) { $url += 'wp-admin/' }
        Start-Process $url
    } else {
        $extra = if ($Admin) { ' admin' } else { '' }
        Start-WplmTask "open $Name$extra" "open $Name"
    }
}

# ---------------------------------------------------------------- refresh

function Update-ServerLabels {
    $apacheUp = ((Get-ApacheProcesses $cfg).Count -gt 0) -and (Test-Port $cfg.ApachePort)
    $mysqlUp  = ((Get-MySqlProcesses $cfg).Count -gt 0) -and (Test-Port $cfg.MySqlPort)
    $apacheLabel.Text = if ($apacheUp) { 'Apache:  RUNNING' } else { 'Apache:  STOPPED' }
    $apacheLabel.ForeColor = if ($apacheUp) { 'ForestGreen' } else { 'Firebrick' }
    $mysqlLabel.Text = if ($mysqlUp) { 'MySQL:  RUNNING' } else { 'MySQL:  STOPPED' }
    $mysqlLabel.ForeColor = if ($mysqlUp) { 'ForestGreen' } else { 'Firebrick' }
}

function Update-SiteList {
    $selected = if ($siteList.SelectedItems.Count) { $siteList.SelectedItems[0].Text } else { $null }
    $siteList.BeginUpdate()
    $siteList.Items.Clear()
    try {
        foreach ($s in Get-Sites $cfg) {
            $problems = @()
            if (-not $s.HasVhost) { $problems += 'no Apache config' }
            if (-not $s.HasHosts) { $problems += 'no hosts line' }
            if ($s.DbExists -eq $false) { $problems += 'database missing' }
            $item = New-Object System.Windows.Forms.ListViewItem($s.Name)
            [void]$item.SubItems.Add($(if ($s.WordPress) { 'yes' } else { '-' }))
            [void]$item.SubItems.Add($(if ($s.Database) { $s.Database } else { '-' }))
            [void]$item.SubItems.Add($(if ($problems) { $problems -join ', ' } else { 'ok' }))
            if ($problems) { $item.ForeColor = 'DarkOrange' }
            if ($s.Name -eq $selected) { $item.Selected = $true }
            [void]$siteList.Items.Add($item)
        }
    } finally { $siteList.EndUpdate() }
    $script:siteSignature = Get-SiteSignature
    $sitesBox.Text = "Sites ($($siteList.Items.Count))  -  double-click to open"
}

# ---------------------------------------------------------------- window

$form = New-Object System.Windows.Forms.Form
$form.Text = 'WP Local Manager'
$form.ClientSize = New-Object System.Drawing.Size(720, 560)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = $font

# Title-bar / taskbar icon, made straight from the PNG (same picture as the shortcuts).
$iconPng = Join-Path $PSScriptRoot 'assets\app-icon.png'
if (Test-Path $iconPng) {
    try {
        $src = [System.Drawing.Image]::FromFile($iconPng)
        $bmp = New-Object System.Drawing.Bitmap $src, 64, 64
        $form.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $src.Dispose()
    } catch { }   # a broken icon file shouldn't stop the window opening
}

# Servers
$serversBox = New-Control GroupBox 12 8 696 64 'Servers'
$apacheLabel = New-Control Label 16 28 150 20; $apacheLabel.Font = $bold
$mysqlLabel  = New-Control Label 170 28 150 20; $mysqlLabel.Font = $bold
$startBtn   = New-Control Button 400 22 90 28 'Start'
$stopBtn    = New-Control Button 496 22 90 28 'Stop'
$restartBtn = New-Control Button 592 22 90 28 'Restart'
$serversBox.Controls.AddRange(@($apacheLabel, $mysqlLabel, $startBtn, $stopBtn, $restartBtn))

# New site
$newBox = New-Control GroupBox 12 80 696 92 'Create a new WordPress site'
$nameLabel  = New-Control Label 16 26 60 20 'Name'
$nameBox    = New-Control TextBox 80 23 180 24
$testLabel  = New-Control Label 262 26 40 20 '.test'
$titleLabel = New-Control Label 310 26 90 20 'Title (optional)'
$titleBox   = New-Control TextBox 404 23 160 24
$createBtn  = New-Control Button 576 21 106 28 'Create site'
$createBtn.Font = $bold
$hintLabel  = New-Control Label 16 58 666 20 'Lowercase letters, digits and hyphens, e.g. my-shop.  Login will be admin / admin.'
$hintLabel.ForeColor = 'DimGray'
$newBox.Controls.AddRange(@($nameLabel, $nameBox, $testLabel, $titleLabel, $titleBox, $createBtn, $hintLabel))

# Sites
$sitesBox = New-Control GroupBox 12 180 696 340 'Sites'
$siteList = New-Control ListView 16 24 664 260
$siteList.View = 'Details'
$siteList.FullRowSelect = $true
$siteList.MultiSelect = $false
$siteList.HideSelection = $false
[void]$siteList.Columns.Add('Site', 230)
[void]$siteList.Columns.Add('WordPress', 75)
[void]$siteList.Columns.Add('Database', 190)
[void]$siteList.Columns.Add('Status', 145)
$openBtn    = New-Control Button 16 294 100 30 'Open site'
$adminBtn   = New-Control Button 122 294 100 30 'Open admin'
$folderBtn  = New-Control Button 228 294 100 30 'Open folder'
$deleteBtn  = New-Control Button 470 294 100 30 'Delete...'
$deleteBtn.ForeColor = 'Firebrick'
$refreshBtn = New-Control Button 580 294 100 30 'Refresh'
$sitesBox.Controls.AddRange(@($siteList, $openBtn, $adminBtn, $folderBtn, $deleteBtn, $refreshBtn))

$statusLabel = New-Control Label 14 530 694 20 'Ready'
$statusLabel.ForeColor = 'DimGray'

$form.Controls.AddRange(@($serversBox, $newBox, $sitesBox, $statusLabel))
$form.AcceptButton = $createBtn   # Enter in the name box = Create

# ---------------------------------------------------------------- events

# An error inside a click handler would otherwise close the whole window,
# so every handler runs its code through Invoke-Safe.
function Invoke-Safe {
    param([scriptblock]$Action)
    try { & $Action } catch { Show-Message $_.Exception.Message }
}

$startBtn.Add_Click({   Invoke-Safe { Start-WplmTask 'start' 'start servers' } })
$stopBtn.Add_Click({    Invoke-Safe { Start-WplmTask 'stop' 'stop servers' } })
$restartBtn.Add_Click({ Invoke-Safe { Start-WplmTask 'restart' 'restart servers' } })

$createBtn.Add_Click({ Invoke-Safe {
    $hostName = ConvertTo-TestHost $nameBox.Text     # throws a readable message if invalid
    $name = $hostName -replace '\.test$', ''
    $title = ($titleBox.Text -replace '"', '').Trim()
    $arguments = "new $name"
    if ($title) { $arguments += " `"$title`"" }
    Start-WplmTask $arguments "create $name"
    $nameBox.Clear(); $titleBox.Clear()
} })

$openBtn.Add_Click({    Invoke-Safe { $n = Get-SelectedSite; if ($n) { Open-SiteUrl $n } } })
$adminBtn.Add_Click({   Invoke-Safe { $n = Get-SelectedSite; if ($n) { Open-SiteUrl $n -Admin } } })
$folderBtn.Add_Click({  Invoke-Safe { $n = Get-SelectedSite; if ($n) { Start-Process explorer.exe (Join-Path $cfg.WwwDir $n) } } })
$deleteBtn.Add_Click({  Invoke-Safe { $n = Get-SelectedSite; if ($n) { Start-WplmTask "delete $n" "delete $n" } } })
$refreshBtn.Add_Click({ Invoke-Safe { Update-ServerLabels; Update-SiteList } })
$siteList.Add_DoubleClick({ Invoke-Safe { $n = Get-SelectedSite; if ($n) { Open-SiteUrl $n } } })

# Every 2 seconds: finish up a completed task, and reload the site list if
# anything on disk changed. Server status is re-checked every 6 seconds.
$script:tick = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    try {
        $script:tick++
        Complete-TaskIfDone
        if ((Get-SiteSignature) -ne $script:siteSignature) { Update-SiteList }
        if ($script:tick % 3 -eq 0) { Update-ServerLabels }
    } catch { $statusLabel.Text = "Refresh failed: $($_.Exception.Message)" }
})

$form.Add_Shown({
    Update-ServerLabels
    try { Update-SiteList } catch { $statusLabel.Text = "Could not read sites: $($_.Exception.Message)" }
    $timer.Start()
    $nameBox.Focus()
})
$form.Add_FormClosed({ $timer.Stop() })

[void]$form.ShowDialog()
