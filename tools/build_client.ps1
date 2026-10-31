# 產生兩種版本的發佈包，輸出到 dist/：
#   Deadlock_zhTW_Updater_GUI.zip    圖形介面版（2 個 exe，需要 ps2exe，只能在 Windows 上編）
#   Deadlock_zhTW_Updater_NoGUI.zip  命令列版（bat + ps1，不需要編譯）
# 用法：  powershell -ExecutionPolicy Bypass -File tools\build_client.ps1 [-SkipGui]
param([switch]$SkipGui)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$core = Join-Path $root 'client\core\deadlock_zhtw_localization.ps1'
$dist = Join-Path $root 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null

# ---------------- NoGUI
$no = Join-Path $dist 'Deadlock_zhTW_Updater_NoGUI'
New-Item -ItemType Directory -Path $no | Out-Null
Copy-Item $core $no
Copy-Item (Join-Path $root 'client\nogui\*.bat') $no
Compress-Archive -Path $no -DestinationPath (Join-Path $dist 'Deadlock_zhTW_Updater_NoGUI.zip')
Write-Host 'OK  NoGUI zip' -ForegroundColor Green

if ($SkipGui) { return }

# ---------------- GUI
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module ps2exe -Repository PSGallery -Scope CurrentUser -Force
}
Import-Module ps2exe

$gui = Join-Path $dist 'Deadlock_zhTW_Updater_GUI'
New-Item -ItemType Directory -Path $gui | Out-Null
$ico = Join-Path $root 'client\gui\app.ico'
$common = @{ noConsole = $true; iconFile = $ico; company = 'deadlock_zhtw_localization'; version = '1.2.0.0' }

# 圖形介面（-STA：剪貼簿與視窗元件需要）。更新邏輯已內嵌，不需要另外附 .ps1
Invoke-ps2exe -inputFile $core -outputFile (Join-Path $gui 'deadlock_zhtw_updater.exe') `
              -title 'Deadlock zh-TW Updater' -product 'Deadlock zh-TW Updater' -STA @common
# Steam 啟動器（無視窗）：先呼叫 updater.exe -Quiet，再啟動遊戲
Invoke-ps2exe -inputFile (Join-Path $root 'client\gui\launcher.ps1') -outputFile (Join-Path $gui 'deadlock_zhtw_launcher.exe') `
              -title 'Deadlock zh-TW Launcher' -product 'Deadlock zh-TW Launcher' @common

Compress-Archive -Path $gui -DestinationPath (Join-Path $dist 'Deadlock_zhTW_Updater_GUI.zip')
Write-Host 'OK  GUI zip' -ForegroundColor Green
