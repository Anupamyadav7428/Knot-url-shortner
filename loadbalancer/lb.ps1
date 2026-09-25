<#
.SYNOPSIS
    Manages the URL shortener stack: 4 Spring Boot instances behind Nginx.

.DESCRIPTION
    .\lb.ps1 start     Build, then start any instance/nginx that isn't running; waits for health.
    .\lb.ps1 stop      Gracefully stop all app instances and this project's nginx.
                       (nginx is left running if Windows would block restarting it; -Force overrides.)
    .\lb.ps1 restart   Build, then rolling restart (one instance at a time - no downtime).
    .\lb.ps1 status    Show each instance's PID and health, plus nginx and /health via the LB.
    .\lb.ps1 logs      Tail an instance's log (-Port 8081 by default).

    Exits non-zero on any failure, so it can be used from Task Scheduler / CI.

    Processes are launched through WMI (Win32_Process.Create) so they are NOT
    children of this shell: closing the terminal, VS Code, or the task that ran
    this script no longer kills the backends (which is what used to leave nginx
    up serving 502s).

    Config/secrets: put DB_PASSWORD etc. in a .env file next to this script
    (see .env.example). The apps read it on startup.

    IMPORTANT: this machine also runs "Local" (WordPress dev tool), which bundles its
    own nginx. Never target nginx/java by image name (taskkill /IM, Get-Process |
    Stop-Process) - that kills Local's processes too. This script only ever touches
    processes whose command line references this project's jar or nginx.conf.

.EXAMPLE
    .\lb.ps1 start
    .\lb.ps1 restart -SkipBuild
    .\lb.ps1 logs -Port 8083
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "restart", "status", "logs")]
    [string]$Command = "status",

    [switch]$SkipBuild,

    # stop: stop nginx even if Windows would block starting it again
    [switch]$Force,

    [int]$Port = 8081
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

# ---------------------------------------------------------------- configuration
# Override any of these with environment variables instead of editing the script.

function Get-Setting($name, $default) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $default }
    return $value
}

$ProjectDir     = $PSScriptRoot
$JavaHome       = Get-Setting "LB_JAVA_HOME" "C:\Program Files\Java\jdk-21.0.10"
$NginxDir       = Get-Setting "LB_NGINX_DIR" "C:\Users\Innostax-01-04-25\Downloads\nginx-1.30.4\nginx-1.30.4"
$JavaOpts       = Get-Setting "LB_JAVA_OPTS" "-Xms256m -Xmx512m -XX:+ExitOnOutOfMemoryError"
$AppPorts       = @(8081, 8082, 8083, 8084)
$LbPort         = 9090
$StartupTimeout = [int](Get-Setting "LB_STARTUP_TIMEOUT" 120)   # seconds per instance
$StopTimeout    = 30                                             # seconds before force kill
# Where nginx runs: "windows" (nginx.exe), "wsl" (nginx inside WSL, needs mirrored
# networking) or "auto" (WSL if nginx.exe is blocked by Windows, otherwise Windows).
$NginxMode      = Get-Setting "LB_NGINX_MODE" "auto"

$Javaw        = Join-Path $JavaHome "bin\javaw.exe"   # javaw: no console window
$NginxExe     = Join-Path $NginxDir "nginx.exe"
$NginxConf    = Join-Path $ProjectDir "nginx.conf"
$BuiltJar     = Join-Path $ProjectDir "build\libs\loadbalancer-0.0.1-SNAPSHOT.jar"
$ReleaseDir   = Join-Path $ProjectDir "releases"
$LogDir       = Join-Path $ProjectDir "run-logs"

# ---------------------------------------------------------------- helpers

function Write-Step($msg) { Write-Host "`n== $msg ==" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ OK ] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "  [ .. ] $msg" }
function Write-Bad($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

function Test-PortOpen([int]$p) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $p, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-Health([int]$p) {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$p/actuator/health" -TimeoutSec 3 -UseBasicParsing
        return [string]$r.status
    } catch {
        # A DOWN instance answers 503 with a JSON body - report that rather than "unreachable"
        if ($_.Exception.PSObject.Properties["Response"] -and $_.Exception.Response) { return "DOWN" }
        return $null
    }
}

# Starts a process outside this shell's process tree / job object so it keeps
# running after the shell exits. Returns the new PID.
function Start-Detached([string]$commandLine, [string]$workingDir) {
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine               = $commandLine
        CurrentDirectory          = $workingDir
        ProcessStartupInformation = $startup
    }
    if ($result.ReturnValue -ne 0) {
        throw "Failed to launch process (Win32_Process.Create returned $($result.ReturnValue)): $commandLine"
    }
    return [int]$result.ProcessId
}

function Get-AppProcess([int]$p) {
    Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*loadbalancer*.jar*" -and $_.CommandLine -match "--server\.port=$p(\s|$)" }
}

function Get-NginxProcess {
    $confPattern = [regex]::Escape($NginxConf)
    Get-CimInstance Win32_Process -Filter "Name='nginx.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $confPattern }
}

function Show-LogTail([int]$p, [int]$lines = 25) {
    $log = Join-Path $LogDir "app-$p.log"
    if (Test-Path $log) {
        Write-Host "  --- last $lines lines of $log ---" -ForegroundColor DarkGray
        Get-Content $log -Tail $lines | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------- build / release

function Assert-Prerequisites {
    if (-not (Test-Path $Javaw))    { throw "JDK not found at $JavaHome - set LB_JAVA_HOME." }
    if (-not (Test-Path $NginxExe)) { throw "nginx not found at $NginxDir - set LB_NGINX_DIR." }
}

# Builds the jar and copies it to releases\ so running instances hold a lock on
# the release copy, not on build\libs (Windows won't let Gradle overwrite a jar
# that a running JVM has open).
function New-Release {
    if ($SkipBuild) {
        $latest = Get-ChildItem $ReleaseDir -Filter "app-*.jar" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) { Write-Info "Skipping build, using $($latest.Name)"; return $latest.FullName }
        if (-not (Test-Path $BuiltJar)) { throw "-SkipBuild given but no jar exists yet. Run without -SkipBuild." }
    } else {
        Write-Step "Building"
        Push-Location $ProjectDir
        try {
            & .\gradlew.bat bootJar -x test --console=plain -q | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Gradle build failed (exit $LASTEXITCODE)." }
        } finally {
            Pop-Location
        }
        if (-not (Test-Path $BuiltJar)) { throw "Build did not produce $BuiltJar" }
    }

    New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
    $release = Join-Path $ReleaseDir ("app-{0}.jar" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Copy-Item $BuiltJar $release
    Write-Ok "Release $(Split-Path $release -Leaf)"

    # Keep the last 3 releases for rollback; older ones may still be locked by a JVM, that's fine.
    Get-ChildItem $ReleaseDir -Filter "app-*.jar" | Sort-Object Name -Descending | Select-Object -Skip 3 |
        ForEach-Object { Remove-Item $_.FullName -ErrorAction SilentlyContinue }
    return $release
}

# ---------------------------------------------------------------- app instances

function Start-App([int]$p, [string]$jar) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $log = Join-Path $LogDir "app-$p.log"
    # Bound to loopback: only nginx should reach the instances. The shutdown endpoint
    # is enabled here (not in application.properties) purely so stop is graceful.
    $cmd = "`"$Javaw`" $JavaOpts -jar `"$jar`" --server.port=$p --server.address=127.0.0.1 " +
           "--logging.file.name=`"$log`" " +
           "--management.endpoints.web.exposure.include=health,metrics,shutdown " +
           "--management.endpoint.shutdown.access=unrestricted"
    $procId = Start-Detached $cmd $ProjectDir
    Write-Info "Started instance :$p (PID $procId), log: run-logs\app-$p.log"
    return $procId
}

function Wait-AppHealthy([int]$p, [int]$procId) {
    $deadline = (Get-Date).AddSeconds($StartupTimeout)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
            Write-Bad "Instance :$p exited during startup."
            Show-LogTail $p
            return $false
        }
        if ((Get-Health $p) -eq "UP") { Write-Ok "Instance :$p healthy"; return $true }
        Start-Sleep -Seconds 2
    }
    Write-Bad "Instance :$p not healthy after ${StartupTimeout}s."
    Show-LogTail $p
    return $false
}

function Stop-App([int]$p) {
    $procs = @(Get-AppProcess $p)
    if ($procs.Count -eq 0) { Write-Info "Instance :$p not running"; return }

    try {
        # Explicit JSON body: PS 5.1 otherwise sends form-urlencoded, which actuator rejects (415)
        Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$p/actuator/shutdown" -ContentType "application/json" `
            -Body "{}" -TimeoutSec 5 -UseBasicParsing | Out-Null
    } catch {
        Write-Info "Instance :$p did not accept graceful shutdown, will force stop"
    }

    foreach ($proc in $procs) {
        $gone = $false
        $deadline = (Get-Date).AddSeconds($StopTimeout)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue)) { $gone = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $gone) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Info "Instance :$p force-stopped (PID $($proc.ProcessId))"
        } else {
            Write-Ok "Instance :$p stopped (PID $($proc.ProcessId))"
        }
    }
}

# ---------------------------------------------------------------- nginx

# nginx on Windows resolves logs\ and temp\ relative to its working directory,
# so every call runs from $NginxDir. Native stderr must not be promoted to a
# terminating error (nginx -t reports on stderr even on success).
function Invoke-Nginx([string[]]$nginxArgs) {
    $ErrorActionPreference = "Continue"
    Push-Location $NginxDir
    try {
        $out = & $NginxExe -c $NginxConf @nginxArgs 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    } finally {
        Pop-Location
    }
}

$NginxBlockedHelp = "Windows is blocking nginx.exe (Smart App Control / Application Control policy: it is an " +
    "unsigned download). Install nginx in WSL instead (wsl sudo apt-get install -y nginx) and re-run this command."

# False when Windows refuses to execute nginx.exe - then nginx can neither be
# started nor reloaded (reload spawns new worker processes).
function Test-NginxRunnable {
    try {
        Invoke-Nginx @("-v") | Out-Null
        return $true
    } catch {
        if ($_.Exception.Message -match "Application Control|blocked") { return $false }
        throw
    }
}

function Get-NginxMaster {
    $procs = @(Get-NginxProcess)
    $ids = @($procs | ForEach-Object { $_.ProcessId })
    $procs | Where-Object { $ids -notcontains $_.ParentProcessId } | Select-Object -First 1
}

# "nginx -s <sig>" on Windows just sets the named event Global\ngx_<sig>_<masterPid>.
# Setting it directly works without executing nginx.exe and without logs\nginx.pid.
function Send-NginxSignal([string]$sig) {
    $master = Get-NginxMaster
    if (-not $master) { return $false }
    try {
        $evt = [System.Threading.EventWaitHandle]::OpenExisting("Global\ngx_${sig}_$($master.ProcessId)")
        [void]$evt.Set()
        $evt.Close()
        return $true
    } catch {
        return $false
    }
}

# Returns error.log lines written since $offset that indicate a failed start/reload.
function Get-NginxErrorsSince([long]$offset) {
    $log = Join-Path $NginxDir "logs\error.log"
    if (-not (Test-Path $log)) { return @() }
    $fs = [System.IO.File]::Open($log, "Open", "Read", "ReadWrite")
    try {
        [void]$fs.Seek([Math]::Min($offset, $fs.Length), "Begin")
        $text = (New-Object System.IO.StreamReader $fs).ReadToEnd()
    } finally {
        $fs.Close()
    }
    return @($text -split "`r?`n" | Where-Object { $_ -match "\[(emerg|alert|crit)\]" })
}

function Get-NginxLogLength {
    $log = Join-Path $NginxDir "logs\error.log"
    if (Test-Path $log) { return (Get-Item $log).Length }
    return 0
}

function Start-WinNginx {
    if (-not (Test-NginxRunnable)) {
        if (@(Get-NginxProcess).Count -gt 0) {
            Write-Bad "nginx is running but config changes can't be applied: $NginxBlockedHelp"
            return $false
        }
        throw $NginxBlockedHelp
    }

    $r = Invoke-Nginx @("-t")
    if ($r.ExitCode -ne 0) {
        $r.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "nginx.conf failed validation."
    }

    if (@(Get-NginxProcess).Count -gt 0) {
        # Already ours - reload so config changes take effect without dropping connections.
        $mark = Get-NginxLogLength
        if (-not (Send-NginxSignal "reload")) { throw "Could not signal the running nginx to reload." }
        Start-Sleep -Seconds 2
        $errors = @(Get-NginxErrorsSince $mark)
        if ($errors.Count -gt 0) {
            $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            throw "nginx reload failed - it is still serving the previous config."
        }
        Write-Ok "nginx already running, config reloaded"
        return $true
    }
    if (Test-PortOpen $LbPort) {
        throw "Port $LbPort is in use by something other than this project's nginx."
    }
    Start-Detached "`"$NginxExe`" -c `"$NginxConf`"" $NginxDir | Out-Null
    for ($i = 0; $i -lt 10 -and -not (Test-PortOpen $LbPort); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-PortOpen $LbPort)) { throw "nginx did not start - check $NginxDir\logs\error.log" }
    Write-Ok "nginx listening on :$LbPort"
    return $true
}

function Stop-WinNginx {
    if (@(Get-NginxProcess).Count -eq 0) { Write-Info "nginx not running"; return }
    if (-not $Force -and -not (Test-NginxRunnable)) {
        Write-Bad "Leaving nginx running: it could not be started again. $NginxBlockedHelp (Use -Force to stop it anyway.)"
        return
    }
    [void](Send-NginxSignal "quit")
    for ($i = 0; $i -lt 20 -and @(Get-NginxProcess).Count -gt 0; $i++) { Start-Sleep -Milliseconds 500 }

    # Fall back to killing only the nginx processes started with our config.
    $left = @(Get-NginxProcess)
    if ($left.Count -gt 0) {
        $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Info "nginx force-stopped (PIDs $(($left | ForEach-Object { $_.ProcessId }) -join ', '))"
    } else {
        Write-Ok "nginx stopped"
    }
}

# ---------------------------------------------------------------- nginx in WSL
# Used when Windows blocks nginx.exe. Runs as the normal WSL user (port 9090 needs
# no root) with all state under ~/.lb-nginx. Requires WSL mirrored networking so
# WSL's 127.0.0.1 is the same as Windows' - the same nginx.conf works unchanged.
# nginx runs in the foreground under a detached wsl.exe, which also keeps the
# WSL VM alive for as long as nginx is running.

function Invoke-Wsl([string]$bashScript) {
    $ErrorActionPreference = "Continue"
    $out = & wsl.exe -e bash -c $bashScript 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

$WslPrefix = $null
function Get-WslPrefix {
    if (-not $script:WslPrefix) {
        $r = Invoke-Wsl 'echo $HOME/.lb-nginx'
        if ($r.ExitCode -ne 0 -or -not $r.Output) { throw "Could not run WSL: $($r.Output -join ' ')" }
        $script:WslPrefix = ([string]@($r.Output)[0]).Trim()
    }
    return $script:WslPrefix
}

# Full path to nginx in WSL: "wsl -e" doesn't use a login shell, so /usr/sbin
# (where Ubuntu installs it) isn't on PATH.
$WslNginxBin = $null
function Get-WslNginxBin {
    if (-not $script:WslNginxBin) {
        $r = Invoke-Wsl 'PATH=$PATH:/usr/sbin:/sbin command -v nginx'
        if ($r.ExitCode -eq 0 -and $r.Output) { $script:WslNginxBin = ([string]@($r.Output)[0]).Trim() }
    }
    return $script:WslNginxBin
}

function Test-WslNginxInstalled {
    try { return [bool](Get-WslNginxBin) } catch { return $false }
}

function Get-WslNginxArgs {
    $pre = Get-WslPrefix
    return @("-p", "$pre/", "-e", "$pre/error.log", "-c", "$pre/nginx.conf", "-g", "daemon off; pid $pre/nginx.pid;")
}

# Copies nginx.conf into WSL, pointing log/temp paths (which default to root-owned
# /var dirs on Ubuntu) into ~/.lb-nginx.
function Sync-WslNginxConf {
    $pre = Get-WslPrefix
    $paths = "http {`n" +
        "    access_log $pre/access.log;`n" +
        "    client_body_temp_path $pre/temp/body;`n" +
        "    proxy_temp_path $pre/temp/proxy;`n" +
        "    fastcgi_temp_path $pre/temp/fastcgi;`n" +
        "    uwsgi_temp_path $pre/temp/uwsgi;`n" +
        "    scgi_temp_path $pre/temp/scgi;`n"
    $conf = ((Get-Content $NginxConf -Raw) -replace "`r", "") -replace "(?m)^http \{[ \t]*\n", $paths
    $tmp = Join-Path $env:TEMP "lb-nginx-wsl.conf"
    [System.IO.File]::WriteAllText($tmp, $conf)
    $src = ([string]@((Invoke-Wsl "wslpath -a '$($tmp -replace '\\', '/')'").Output)[0]).Trim()
    $r = Invoke-Wsl "mkdir -p '$pre/temp' && cp '$src' '$pre/nginx.conf'"
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($r.ExitCode -ne 0) { throw "Could not copy nginx.conf into WSL: $($r.Output -join ' ')" }
}

function Invoke-WslNginx([string[]]$extra) {
    $ErrorActionPreference = "Continue"
    $nginxArgs = @(Get-WslNginxArgs) + $extra
    $out = & wsl.exe -e (Get-WslNginxBin) @nginxArgs 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Get-WslNginxProcess {
    Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match "nginx" -and $_.CommandLine -match "\.lb-nginx" -and $_.CommandLine -notmatch " -s | -t" }
}

function Start-WslNginx {
    if (-not (Test-WslNginxInstalled)) {
        throw "nginx is not installed in WSL. Run: wsl sudo apt-get install -y nginx"
    }
    Sync-WslNginxConf
    $r = Invoke-WslNginx @("-t")
    if ($r.ExitCode -ne 0) {
        $r.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "nginx.conf failed validation in WSL."
    }

    if (@(Get-WslNginxProcess).Count -gt 0) {
        $r = Invoke-WslNginx @("-s", "reload")
        if ($r.ExitCode -ne 0) { throw "nginx (WSL) reload failed: $($r.Output -join ' ')" }
        Write-Ok "nginx (WSL) already running, config reloaded"
        return $true
    }

    # Cut over from a Windows nginx still holding the port (it can be restarted via WSL now)
    if (@(Get-NginxProcess).Count -gt 0) {
        Write-Info "Replacing Windows nginx with WSL nginx"
        $script:Force = $true
        Stop-WinNginx
    }
    if (Test-PortOpen $LbPort) { throw "Port $LbPort is in use by something other than this project's nginx." }

    $argLine = (Get-WslNginxArgs | ForEach-Object { if ($_ -match "\s") { "`"$_`"" } else { $_ } }) -join " "
    Start-Detached "wsl.exe -e $(Get-WslNginxBin) $argLine" $ProjectDir | Out-Null
    for ($i = 0; $i -lt 20 -and -not (Test-PortOpen $LbPort); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-PortOpen $LbPort)) {
        $log = Invoke-Wsl "tail -n 5 '$(Get-WslPrefix)/error.log'"
        $log.Output | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw ("nginx (WSL) is not reachable on localhost:$LbPort. If it started, WSL networking is " +
               "probably not mirrored - add networkingMode=mirrored under [wsl2] in %USERPROFILE%\.wslconfig and run 'wsl --shutdown'.")
    }
    Write-Ok "nginx (WSL) listening on :$LbPort"
    return $true
}

function Stop-WslNginx {
    if (@(Get-WslNginxProcess).Count -eq 0) { Write-Info "nginx (WSL) not running"; return }
    Invoke-WslNginx @("-s", "quit") | Out-Null
    for ($i = 0; $i -lt 20 -and @(Get-WslNginxProcess).Count -gt 0; $i++) { Start-Sleep -Milliseconds 500 }
    if (@(Get-WslNginxProcess).Count -gt 0) {
        Invoke-Wsl "pkill -f '[.]lb-nginx/nginx.conf'" | Out-Null
        Write-Info "nginx (WSL) force-stopped"
    } else {
        Write-Ok "nginx (WSL) stopped"
    }
}

# ---------------------------------------------------------------- nginx dispatch

$ResolvedNginxMode = $null
function Get-NginxMode {
    if (-not $script:ResolvedNginxMode) {
        switch ($NginxMode) {
            "windows" { $script:ResolvedNginxMode = "windows" }
            "wsl"     { $script:ResolvedNginxMode = "wsl" }
            default {
                if (@(Get-WslNginxProcess).Count -gt 0) { $script:ResolvedNginxMode = "wsl" }
                elseif (Test-NginxRunnable) { $script:ResolvedNginxMode = "windows" }
                elseif (Test-WslNginxInstalled) { $script:ResolvedNginxMode = "wsl" }
                else { $script:ResolvedNginxMode = "windows" }   # reports the Windows block + fix
            }
        }
    }
    return $script:ResolvedNginxMode
}

function Start-Nginx {
    if ((Get-NginxMode) -eq "wsl") { return Start-WslNginx }
    return Start-WinNginx
}

function Stop-Nginx {
    Stop-WslNginx
    Stop-WinNginx
}

# ---------------------------------------------------------------- commands

function Invoke-Start {
    Assert-Prerequisites
    $toStart = @($AppPorts | Where-Object { @(Get-AppProcess $_).Count -eq 0 })
    $jar = $null
    if ($toStart.Count -gt 0) { $jar = New-Release }

    Write-Step "App instances"
    $started = @{}
    foreach ($p in $AppPorts) {
        if ($toStart -contains $p) {
            if (Test-PortOpen $p) { throw "Port $p is in use by a process that isn't this app." }
            $started[$p] = Start-App $p $jar
        } else {
            Write-Info "Instance :$p already running"
        }
    }

    $healthy = $true
    foreach ($p in $started.Keys | Sort-Object) {
        if (-not (Wait-AppHealthy $p $started[$p])) { $healthy = $false }
    }

    Write-Step "Nginx"
    $nginxOk = Start-Nginx

    if (-not $healthy) { throw "One or more instances failed to start (see above)." }
    if (-not $nginxOk) { throw "App instances are up, but nginx is running an outdated config (see above)." }
    Write-Host "`nStack is up: http://localhost:$LbPort/  (health: http://localhost:$LbPort/health)" -ForegroundColor Green
}

function Invoke-Stop {
    Write-Step "App instances"
    foreach ($p in $AppPorts) { Stop-App $p }
    Write-Step "Nginx"
    Stop-Nginx
    Write-Host "`nStopped. MySQL and Redis were left running." -ForegroundColor Green
}

function Invoke-Restart {
    Assert-Prerequisites
    $jar = New-Release
    Write-Step "Rolling restart"
    foreach ($p in $AppPorts) {
        # nginx routes around the instance while it's down (max_fails / proxy_next_upstream)
        Stop-App $p
        $procId = Start-App $p $jar
        if (-not (Wait-AppHealthy $p $procId)) {
            throw "Instance :$p failed on the new release - aborting so the remaining instances keep serving."
        }
    }
    Write-Step "Nginx"
    if (-not (Start-Nginx)) { throw "Instances restarted, but nginx is running an outdated config (see above)." }
    Write-Host "`nRolling restart complete." -ForegroundColor Green
}

function Invoke-Status {
    Write-Step "App instances"
    $allUp = $true
    foreach ($p in $AppPorts) {
        $proc = @(Get-AppProcess $p) | Select-Object -First 1
        if (-not $proc) { Write-Bad ":$p  not running"; $allUp = $false; continue }
        $health = Get-Health $p
        $uptime = (Get-Date) - $proc.CreationDate
        $line = ":{0}  PID {1,-6} {2,-5} up {3:d\.hh\:mm\:ss}" -f $p, $proc.ProcessId, $health, $uptime
        if ($health -eq "UP") { Write-Ok $line } else { Write-Bad $line; $allUp = $false }
    }

    Write-Step "Nginx"
    $ng = @(Get-NginxProcess)
    $wslNg = @(Get-WslNginxProcess)
    if ($wslNg.Count -gt 0) { Write-Ok "running in WSL" }
    elseif ($ng.Count -gt 0) { Write-Ok "running on Windows (PIDs $(($ng | ForEach-Object { $_.ProcessId }) -join ', '))" }
    else { Write-Bad "not running"; $allUp = $false }

    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$LbPort/health" -TimeoutSec 3 -UseBasicParsing
        Write-Ok "GET /health via load balancer: $($r.status)"
    } catch {
        Write-Bad "GET /health via load balancer failed: $($_.Exception.Message)"
        $allUp = $false
    }
    if (-not $allUp) { exit 1 }
}

try {
    switch ($Command) {
        "start"   { Invoke-Start }
        "stop"    { Invoke-Stop }
        "restart" { Invoke-Restart }
        "status"  { Invoke-Status }
        "logs"    { Get-Content (Join-Path $LogDir "app-$Port.log") -Tail 50 -Wait }
    }
} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
