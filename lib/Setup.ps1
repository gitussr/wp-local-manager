# Setup.ps1 - puts wplm on PATH, adds shortcuts, optional start-at-login.
# Everything here is per-user (no admin needed) and fully reversible.

$script:AppRoot = Split-Path $PSScriptRoot
$script:BinDir  = Join-Path $script:AppRoot 'bin'
$script:IconPng = Join-Path $script:AppRoot 'assets\app-icon.png'   # replace this to change the icon
$script:IconIco = Join-Path $script:AppRoot 'assets\app-icon.ico'   # generated from the PNG
$script:ShortcutName = 'WP Local Manager.lnk'
$script:AutostartName = 'WP Local Manager - start servers.lnk'

# ---------------------------------------------------------------- PATH

# Read/write the user PATH straight from the registry, without expanding
# %VARIABLES%, so existing entries are kept exactly as they were.
function Get-UserPathRaw {
    (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
}

function Set-UserPathRaw {
    param([string]$Value)
    Set-ItemProperty 'HKCU:\Environment' -Name Path -Value $Value -Type ExpandString
    # Setting any user variable through .NET broadcasts "environment changed"
    # to Windows, so newly opened terminals see the new PATH.
    [Environment]::SetEnvironmentVariable('WPLM_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('WPLM_REFRESH', $null, 'User')
}

function Add-WplmToPath {
    $parts = @((Get-UserPathRaw) -split ';' | Where-Object { $_ })
    if ($parts -contains $script:BinDir) { return $false }
    Set-UserPathRaw (($parts + $script:BinDir) -join ';')
    return $true
}

function Remove-WplmFromPath {
    $parts = @((Get-UserPathRaw) -split ';' | Where-Object { $_ })
    if ($parts -notcontains $script:BinDir) { return $false }
    Set-UserPathRaw (($parts | Where-Object { $_ -ne $script:BinDir }) -join ';')
    return $true
}

# ---------------------------------------------------------------- icon

# Shortcuts need a .ico file. An .ico is a small container holding the same
# picture at several sizes; since Windows Vista each size may be stored as PNG.
function ConvertTo-Ico {
    param([string]$Png, [string]$Ico)
    Add-Type -AssemblyName System.Drawing
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $src = [Drawing.Image]::FromFile($Png)
    try {
        $images = foreach ($s in $sizes) {
            $bmp = New-Object Drawing.Bitmap $s, $s
            $g = [Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = 'HighQualityBicubic'
            $g.SmoothingMode = 'HighQuality'
            $g.PixelOffsetMode = 'HighQuality'
            $g.DrawImage($src, 0, 0, $s, $s)
            $g.Dispose()
            $ms = New-Object IO.MemoryStream
            $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            , $ms.ToArray()   # leading comma: keep each byte[] as one item
        }
    } finally { $src.Dispose() }

    $w = New-Object IO.BinaryWriter ([IO.File]::Create($Ico))
    try {
        # Header: reserved, type 1 (= icon), number of images.
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
        # One 16-byte directory entry per image, then the image data.
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }   # 0 means 256
            $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32)
            $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
            $offset += $images[$i].Length
        }
        foreach ($img in $images) { $w.Write([byte[]]$img) }
    } finally { $w.Close() }
}

# Returns the .ico path, (re)building it when the PNG is newer. Falls back to a
# Windows icon if there is no PNG.
function Get-AppIcon {
    if (-not (Test-Path $script:IconPng)) { return "$env:SystemRoot\System32\imageres.dll,1" }
    if (-not (Test-Path $script:IconIco) -or
        (Get-Item $script:IconPng).LastWriteTime -gt (Get-Item $script:IconIco).LastWriteTime) {
        ConvertTo-Ico $script:IconPng $script:IconIco
    }
    return $script:IconIco
}

# ---------------------------------------------------------------- shortcuts

function New-Shortcut {
    param([string]$LinkPath, [string]$Arguments, [string]$Description)
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($LinkPath)
    $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = $Arguments
    $s.WorkingDirectory = $script:AppRoot
    $s.WindowStyle = 7   # minimized: the console doesn't flash up. Never "hidden" - that would hide the GUI form too.
    $s.IconLocation = Get-AppIcon
    $s.Description = $Description
    $s.Save()
}

function Get-GuiShortcutPaths {
    @((Join-Path ([Environment]::GetFolderPath('Desktop')) $script:ShortcutName),
      (Join-Path ([Environment]::GetFolderPath('Programs')) $script:ShortcutName))
}

function Install-WplmShortcuts {
    $guiArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:AppRoot\wplm-gui.ps1`""
    foreach ($p in Get-GuiShortcutPaths) { New-Shortcut $p $guiArgs 'Local WordPress sites without the Laragon app' }
}

function Uninstall-WplmShortcuts {
    foreach ($p in Get-GuiShortcutPaths) { if (Test-Path $p) { Remove-Item $p -Force } }
}

# ---------------------------------------------------------------- start at login

# A shortcut in the user's Startup folder runs "wplm start" at every login.
# (Simpler than Task Scheduler and needs no admin; delete it to undo.)
function Get-AutostartPath { Join-Path ([Environment]::GetFolderPath('Startup')) $script:AutostartName }

function Set-Autostart {
    param([bool]$On)
    $path = Get-AutostartPath
    if ($On) {
        New-Shortcut $path "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:AppRoot\wplm.ps1`" start" `
            'Starts Apache and MySQL at login'
    } elseif (Test-Path $path) {
        Remove-Item $path -Force
    }
}

function Test-Autostart { Test-Path (Get-AutostartPath) }
