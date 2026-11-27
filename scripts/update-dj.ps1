# One-step DJ Windows Installer & Updater
# Installs/updates DJ into %LOCALAPPDATA%\DJ cleanly (without deleting %APPDATA%\DJ\dj_data),
# removes temporary zip files automatically, creates Desktop/Start Menu shortcuts, and launches DJ.
# Usage from PowerShell:
#   irm https://raw.githubusercontent.com/dhanunjayss0306/dj-laptop-agent/main/scripts/update-dj.ps1 | iex

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'DJ'
$tempZip = Join-Path $env:TEMP 'dj-windows-latest.zip'

Write-Host 'Checking latest DJ release on GitHub...'
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/dhanunjayss0306/dj-laptop-agent/releases/latest' -Headers @{ 'User-Agent' = 'dj-updater' }
$asset = $release.assets | Where-Object { $_.name -eq 'dj-windows.zip' } | Select-Object -First 1
if (-not $asset) {
  throw 'Could not find dj-windows.zip in the latest release.'
}

Write-Host "Downloading $($release.tag_name)..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZip -UseBasicParsing

# Stop any running dj.exe so files can be updated cleanly
Get-Process -Name 'dj' -ErrorAction SilentlyContinue | ForEach-Object {
  try { $_.CloseMainWindow() | Out-Null } catch {}
}
Start-Sleep -Milliseconds 600
Get-Process -Name 'dj' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Write-Host "Installing to $installDir..."
Expand-Archive -LiteralPath $tempZip -DestinationPath $installDir -Force
Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue

$exePath = Join-Path $installDir 'dj.exe'
$iconPath = Join-Path $installDir 'tray-icon.ico'

# Create Start Menu & Desktop shortcuts pointing to the permanent install folder
try {
  $wsh = New-Object -ComObject WScript.Shell
  $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DJ.lnk'
  $startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'DJ'
  New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
  $startLnk = Join-Path $startMenuDir 'DJ.lnk'
  foreach ($lnkPath in @($desktopLnk, $startLnk)) {
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = $exePath
    $sc.WorkingDirectory = $installDir
    if (Test-Path $iconPath) { $sc.IconLocation = $iconPath }
    $sc.Save()
  }
} catch {}

Write-Host "Done! Launching DJ $($release.tag_name)..."
Start-Process -FilePath $exePath -WorkingDirectory $installDir
