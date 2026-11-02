#Requires -Version 5.1
<#
bootstrap-windows.ps1
一次性装齐 Sideloadly 在 Windows 上签名安装 iOS 应用所需的全部组件。
需要管理员权限：脚本会自己请求 UAC 重新启动。

用法（任选其一）：
  右键 -> 使用 PowerShell 运行
  powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-windows.ps1 -NoPause   # 非交互

消息全部用英文，避免 PowerShell 5.1 读 UTF-8 无 BOM 文件时的编码坑。
#>
param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Administrator rights required. Relaunching with UAC prompt..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoPause) { $argList += '-NoPause' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

function Install-Pkg {
    param([string]$Id, [string]$Label)
    Write-Host "=== $Label ($Id) ===" -ForegroundColor Cyan
    winget install --id $Id -e --silent --accept-package-agreements `
        --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  -> winget exited $LASTEXITCODE (usually means already installed)" -ForegroundColor DarkYellow
    }
}

Install-Pkg -Id 'Apple.AppleMobileDeviceSupport'  -Label 'Step 1/4: Apple Mobile Device Support (USB driver + service)'
Install-Pkg -Id 'Apple.AppleApplicationSupport.x64' -Label 'Step 2/4: Apple Application Support 64-bit'
Install-Pkg -Id 'Apple.Bonjour'                    -Label 'Step 3/4: Bonjour'

Write-Host "=== Step 4/4: Sideloadly ===" -ForegroundColor Cyan
$dst = Join-Path $env:USERPROFILE 'Downloads\SideloadlySetup64.exe'
$url = 'https://sideloadly.io/SideloadlySetup64.exe'
try {
    Write-Host "  downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 180
    Write-Host "  saved: $dst"
    Start-Process -FilePath $dst -ArgumentList '/S' -Wait
    Write-Host "  Sideloadly installed" -ForegroundColor Green
} catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  sideloadly.io seems blocked on this network. Fallbacks:" -ForegroundColor Red
    Write-Host "    - download Sideloadly manually in a browser, then run the installer"
    Write-Host "    - AltServer for Windows: https://altstore.io (same free-Apple-ID flow)"
}

Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Green
foreach ($p in @(
    'C:\Program Files\Common Files\Apple\Apple Application Support',
    'C:\Program Files\Common Files\Apple\Mobile Device Support',
    'C:\Program Files\Bonjour'
)) {
    if (Test-Path $p) { Write-Host "  [OK]   $p" } else { Write-Host "  [MISS] $p" -ForegroundColor DarkYellow }
}
$sl = @(
    'C:\Program Files\Sideloadly\Sideloadly.exe',
    "$env:LOCALAPPDATA\Programs\Sideloadly\Sideloadly.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($sl) { Write-Host "  [OK]   $sl" } else { Write-Host "  [MISS] Sideloadly" -ForegroundColor DarkYellow }

Write-Host ""
Write-Host "Next: bash scripts/fetch-ipa.sh   (pull the unsigned ipa from GitHub Actions)"
Write-Host "Then: drag ipa into Sideloadly, enter your free Apple ID, Start."

if (-not $NoPause) { Read-Host "Press Enter to close" }
