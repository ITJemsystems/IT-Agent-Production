# ==============================================================
# uninstall.ps1 - IT Support Agent V3 - Silent uninstaller
# ==============================================================
# Removes all files, shortcuts and registry entries.
# Required by Intune for Win32 app packaging.
# ==============================================================

$INSTALL_DIR = "C:\ProgramData\IT Support Agent"
$DESKTOP     = [Environment]::GetFolderPath("CommonDesktopDirectory")
$STARTMENU   = [Environment]::GetFolderPath("CommonPrograms")

# Kill the app if running
Get-Process "SuporteTI" -ErrorAction SilentlyContinue | Stop-Process -Force

# Remove installation folder
if (Test-Path $INSTALL_DIR) {
    Remove-Item $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
}

# Remove shortcuts
$shortcuts = @(
    "$DESKTOP\IT Support Agent.lnk",
    "$STARTMENU\IT Support Agent.lnk"
)
foreach ($s in $shortcuts) {
    if (Test-Path $s) { Remove-Item $s -Force -ErrorAction SilentlyContinue }
}

# Remove from Add/Remove Programs
$regPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ITSupportAgent"
if (Test-Path $regPath) {
    Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
