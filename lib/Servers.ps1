# Servers.ps1 - start / stop / status for Apache and MySQL.
#
# A "server" here is just a normal Windows program (httpd.exe, mysqld.exe)
# that keeps running and listens on a network port. Starting = launching the
# .exe with the right arguments. Stopping = asking it to exit.

# Runs a command-line program, waits for it, and returns its exit code + output.
# (Avoids PowerShell 5.1 turning a program's stderr text into script errors.)
function Invoke-Native {
    param([string]$Exe, [string]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()   # no keyboard input: a tool that waits for some gets EOF instead of hanging
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out.Result + $err.Result).Trim() }
}

# True if something on this computer accepts connections on the port.
function Test-Port {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        return ($connect.AsyncWaitHandle.WaitOne(500) -and $client.Connected)
    } catch { return $false } finally { $client.Close() }
}

# Which program is listening on a port? Returns a Process or $null.
function Get-PortOwner {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($conn) { return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue }
    return $null
}

# Polls a condition until it's true or the timeout runs out.
function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return [bool](& $Condition)
}

function Show-LogTail {
    param([string]$Path, [int]$Lines = 8)
    if (Test-Path $Path) {
        Write-Host "  Last lines of $Path`:" -ForegroundColor DarkGray
        Get-Content $Path -Tail $Lines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------- status

function Get-ApacheProcesses { param($Cfg) @(Get-Process -Name httpd -ErrorAction SilentlyContinue) }
function Get-MySqlProcesses  { param($Cfg) @(Get-Process -Name mysqld -ErrorAction SilentlyContinue) }

function Test-MySqlAlive {
    param($Cfg)
    $r = Invoke-Native $Cfg.MySqlAdmin "-uroot --host=127.0.0.1 --port=$($Cfg.MySqlPort) --connect-timeout=2 ping"
    return ($r.ExitCode -eq 0)
}

function Show-Status {
    param($Cfg)
    Write-Host ''
    $apache = Get-ApacheProcesses $Cfg
    if ($apache.Count -gt 0 -and (Test-Port $Cfg.ApachePort)) {
        Write-Host '  Apache : RUNNING' -ForegroundColor Green -NoNewline
        Write-Host "  (port $($Cfg.ApachePort), PIDs $($apache.Id -join ', '))"
    } elseif ($apache.Count -gt 0) {
        Write-Host '  Apache : STARTING / NOT ANSWERING' -ForegroundColor Yellow -NoNewline
        Write-Host "  (PIDs $($apache.Id -join ', '))"
    } else {
        Write-Host '  Apache : STOPPED' -ForegroundColor Red
    }

    $mysql = Get-MySqlProcesses $Cfg
    if ($mysql.Count -gt 0 -and (Test-MySqlAlive $Cfg)) {
        Write-Host '  MySQL  : RUNNING' -ForegroundColor Green -NoNewline
        Write-Host "  (port $($Cfg.MySqlPort), PIDs $($mysql.Id -join ', '))"
    } elseif ($mysql.Count -gt 0) {
        Write-Host '  MySQL  : STARTING / NOT ANSWERING' -ForegroundColor Yellow -NoNewline
        Write-Host "  (PIDs $($mysql.Id -join ', '))"
    } else {
        Write-Host '  MySQL  : STOPPED' -ForegroundColor Red
    }

    if (Get-Process -Name laragon -ErrorAction SilentlyContinue) {
        Write-Host ''
        Write-Host '  Note: the Laragon app is open. Its Start/Stop buttons do not know' -ForegroundColor DarkYellow
        Write-Host '        about wplm, so use one or the other, not both.' -ForegroundColor DarkYellow
    }
    Write-Host ''
}

# ---------------------------------------------------------------- Apache

# "httpd -t" checks every config file (including all site .conf files)
# without starting. A bad file would otherwise make Apache exit silently.
function Test-ApacheConfig {
    param($Cfg)
    Invoke-Native $Cfg.Httpd "-t -d `"$($Cfg.ApacheDir)`""
}

function Start-Apache {
    param($Cfg)
    if ((Get-ApacheProcesses $Cfg).Count -gt 0) {
        Write-Host '  Apache already running - skipped.' -ForegroundColor DarkGray
        return
    }
    $owner = Get-PortOwner $Cfg.ApachePort
    if ($owner) {
        throw "Port $($Cfg.ApachePort) is already used by '$($owner.ProcessName)' (PID $($owner.Id)). Close that program first."
    }

    $check = Test-ApacheConfig $Cfg
    if ($check.ExitCode -ne 0) { throw "Apache config has an error:`n$($check.Output)" }

    Write-Host '  Starting Apache...' -NoNewline
    Start-Process -FilePath $Cfg.Httpd -ArgumentList "-d `"$($Cfg.ApacheDir)`"" `
        -WorkingDirectory $Cfg.ApacheDir -WindowStyle Hidden
    if (Wait-Until { Test-Port $Cfg.ApachePort } 20) {
        Write-Host ' running.' -ForegroundColor Green
    } else {
        Write-Host ' FAILED.' -ForegroundColor Red
        Show-LogTail $Cfg.ApacheLog
        throw 'Apache did not start.'
    }
}

function Stop-Apache {
    param($Cfg)
    $procs = Get-ApacheProcesses $Cfg
    if ($procs.Count -eq 0) {
        Write-Host '  Apache not running - skipped.' -ForegroundColor DarkGray
        return
    }
    # Apache keeps no data that can be corrupted, so ending it directly is safe.
    Write-Host '  Stopping Apache...' -NoNewline
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Wait-Until { (Get-ApacheProcesses $Cfg).Count -eq 0 } 15) {
        Write-Host ' stopped.' -ForegroundColor Green
    } else {
        Write-Host ' still running.' -ForegroundColor Red
        throw 'Apache did not stop.'
    }
}

# ---------------------------------------------------------------- MySQL

function Start-MySql {
    param($Cfg)
    if ((Get-MySqlProcesses $Cfg).Count -gt 0) {
        Write-Host '  MySQL already running - skipped.' -ForegroundColor DarkGray
        return
    }
    $owner = Get-PortOwner $Cfg.MySqlPort
    if ($owner) {
        throw "Port $($Cfg.MySqlPort) is already used by '$($owner.ProcessName)' (PID $($owner.Id)). Close that program first."
    }

    # --defaults-file must be the FIRST argument. It points mysqld at my.ini,
    # which says where the databases live (datadir).
    $mysqldArgs = "--defaults-file=`"$($Cfg.MySqlIni)`" --log-error=`"$($Cfg.MySqlLog)`""
    Write-Host '  Starting MySQL...' -NoNewline
    Start-Process -FilePath $Cfg.Mysqld -ArgumentList $mysqldArgs `
        -WorkingDirectory $Cfg.MySqlDir -WindowStyle Hidden
    if (Wait-Until { Test-MySqlAlive $Cfg } 40) {
        Write-Host ' running.' -ForegroundColor Green
    } else {
        Write-Host ' FAILED.' -ForegroundColor Red
        Show-LogTail $Cfg.MySqlLog
        throw 'MySQL did not start.'
    }
}

function Stop-MySql {
    param($Cfg)
    if ((Get-MySqlProcesses $Cfg).Count -eq 0) {
        Write-Host '  MySQL not running - skipped.' -ForegroundColor DarkGray
        return
    }
    # Ask MySQL to shut itself down so it finishes writing data to disk.
    # Never force-kill mysqld: that can leave tables needing recovery.
    Write-Host '  Stopping MySQL...' -NoNewline
    $r = Invoke-Native $Cfg.MySqlAdmin "-uroot --host=127.0.0.1 --port=$($Cfg.MySqlPort) shutdown"
    if ($r.ExitCode -ne 0) {
        Write-Host ' FAILED.' -ForegroundColor Red
        throw "mysqladmin shutdown failed:`n$($r.Output)"
    }
    if (Wait-Until { (Get-MySqlProcesses $Cfg).Count -eq 0 } 60) {
        Write-Host ' stopped.' -ForegroundColor Green
    } else {
        Write-Host ' still shutting down.' -ForegroundColor Yellow
        Write-Host '  MySQL is finishing up. Run "wplm status" again in a moment.' -ForegroundColor Yellow
    }
}
