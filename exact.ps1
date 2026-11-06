#Requires -Version 5.1
<#
  setup-vnc.ps1
  Installs TightVNC (loopback-only, password auth), noVNC + websockify,
  and opens a Cloudflare quick tunnel (*.trycloudflare.com) to it.

  Usage:
    ./setup-vnc.ps1 -VncPassword "abc12345"
    ./setup-vnc.ps1 -VncPassword "abc12345" -KeepAliveMinutes 60

  Notes:
  - VNC password is capped at 8 chars; that's a VNC protocol limit, not this script's choice.
  - TightVNC is bound to loopback only. The tunnel is the only path in from outside.
  - trycloudflare.com URLs are public and unauthenticated past the VNC password.
    Don't run this unattended on anything you care about without understanding that.
#>

[CmdletBinding()]
param(
    [ValidateScript({ $_.Length -le 8 -and $_.Length -ge 1 })]
    [string]$VncPassword
)

$ErrorActionPreference = "Stop"

# Fall back to env var so a CI secret can be injected without ever
# appearing in a command-line arg, which would be visible in process listings and logs.
if (-not $VncPassword) {
    if ($env:VNC_PASSWORD) {
        $VncPassword = $env:VNC_PASSWORD
    } else {
        throw "No password supplied. Pass -VncPassword, or set the VNC_PASSWORD environment variable."
    }
}
if ($VncPassword.Length -gt 8) { throw "VNC_PASSWORD must be 8 characters or fewer (VNC protocol limit)." }
$work = Join-Path $env:TEMP "vnc-setup-$(Get-Random)"
New-Item -ItemType Directory -Path $work | Out-Null

function Require-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Run this script from an elevated (Administrator) PowerShell session." }
}
Require-Admin

Write-Host "`n[1/4] Installing TightVNC..." -ForegroundColor Cyan
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Chocolatey not found, installing it first..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

$installArgs = "SET_USEVNCAUTHENTICATION=1 VALUE_OF_USEVNCAUTHENTICATION=1 " +
               "SET_PASSWORD=1 VALUE_OF_PASSWORD=$VncPassword " +
               "SET_ALLOWLOOPBACK=1 VALUE_OF_ALLOWLOOPBACK=1 " +
               "SET_LOOPBACKONLY=1 VALUE_OF_LOOPBACKONLY=1"
choco install tightvnc -y --no-progress --installarguments "'$installArgs'" | Out-Null

Start-Sleep -Seconds 5
Start-Service -Name tvnserver -ErrorAction SilentlyContinue
$vncUp = (Test-NetConnection -ComputerName 127.0.0.1 -Port 5900 -WarningAction SilentlyContinue).TcpTestSucceeded
if (-not $vncUp) { throw "TightVNC isn't listening on 127.0.0.1:5900. Check the tvnserver service." }
Write-Host "TightVNC is up on loopback:5900." -ForegroundColor Green

Write-Host "`n[2/4] Installing noVNC + websockify..." -ForegroundColor Cyan
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python 3 is required for websockify. Install it first (choco install python -y) and re-run."
}
python -m pip install --quiet --upgrade pip websockify

$novncZip = Join-Path $work "novnc.zip"
Invoke-WebRequest -Uri "https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.zip" -OutFile $novncZip
Expand-Archive -Path $novncZip -DestinationPath (Join-Path $work "novnc") -Force
$webRoot = (Get-ChildItem (Join-Path $work "novnc") -Directory | Select-Object -First 1).FullName
Copy-Item (Join-Path $webRoot "vnc.html") (Join-Path $webRoot "index.html") -Force

Write-Host "`n[3/4] Starting websockify on :6080..." -ForegroundColor Cyan
$wsLog = Join-Path $work "websockify.log"
Start-Process -FilePath python `
    -ArgumentList "-m", "websockify", "--web", "`"$webRoot`"", "6080", "127.0.0.1:5900" `
    -RedirectStandardOutput $wsLog -RedirectStandardError $wsLog -WindowStyle Hidden

Start-Sleep -Seconds 3
$novncUp = (Test-NetConnection -ComputerName 127.0.0.1 -Port 6080 -WarningAction SilentlyContinue).TcpTestSucceeded
if (-not $novncUp) { throw "websockify isn't listening on :6080. Check $wsLog." }
Write-Host "noVNC is up on :6080." -ForegroundColor Green

Write-Host "`n[4/4] Opening Cloudflare quick tunnel..." -ForegroundColor Cyan
$cfExe = Join-Path $work "cloudflared.exe"
Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cfExe
$cfLog = Join-Path $work "cloudflared.log"
Start-Process -FilePath $cfExe `
    -ArgumentList "tunnel", "--url", "http://127.0.0.1:6080", "--no-autoupdate" `
    -RedirectStandardOutput $cfLog -RedirectStandardError $cfLog -WindowStyle Hidden

$tunnelUrl = $null
for ($i = 0; $i -lt 40 -and -not $tunnelUrl; $i++) {
    Start-Sleep -Seconds 3
    $logContent = Get-Content $cfLog -ErrorAction SilentlyContinue | Out-String
    if ($logContent -match 'https://[a-z0-9-]+\.trycloudflare\.com') { $tunnelUrl = $Matches[0] }
}

if (-not $tunnelUrl) {
    Get-Content $cfLog -ErrorAction SilentlyContinue
    throw "Couldn't find the tunnel URL in cloudflared's log (see above)."
}

Write-Host "`n==================================================" -ForegroundColor Yellow
Write-Host " noVNC URL:  $tunnelUrl/vnc.html?autoconnect=1&resize=scale" -ForegroundColor Yellow
Write-Host " Password:   (the one you passed to -VncPassword)" -ForegroundColor Yellow
Write-Host "==================================================`n" -ForegroundColor Yellow
