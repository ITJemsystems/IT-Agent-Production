# ==============================================================
# apps.psm1 - Corporate application restart functions
# ==============================================================
# WHAT THIS MODULE DOES:
#   Each function handles the full restart cycle for one app:
#     1. Barra-Progresso (33%) - Kill all processes for that app
#     2. Start-Sleep 3s        - Wait for OS to release resources
#     3. Barra-Progresso (66%) - Locate and launch the executable
#     4. Start-Sleep 5s        - Wait for app to load before dialog
#     5. Barra-Progresso (100%)- Signal completion to ui.psm1
#
# ACTION NUMBERS (must match ui.psm1 switch and ActionSteps):
#   1=Teams  2=Outlook  3=GoogleDrive  4=Slack
#   6=Zoom   7=OneDrive 8=Chrome       9=Webex
#   10=WhatsApp  11=Dropbox
#
# PATH DETECTION STRATEGY:
#   Most apps try an array of known installation paths.
#   Zoom/Webex/Dropbox also use Get-ChildItem -Recurse to find
#   versioned subfolders (e.g. Dropbox\67.4.100\Dropbox.exe).
#   Teams and WhatsApp additionally check the MS Store (AppxPackage).
#
# ADDING A NEW APP:
#   1. Create Reiniciar-NomeApp below following the same pattern
#   2. Add it to the Export-ModuleMember line at the bottom
#   3. Add a new button in ui.psm1 XAML sidebar with a new Tag number
#   4. Add the Tag to $sidebarButtons array in Launch-MainWindow
#   5. Add the case to the switch statement in the Run Action block
#   6. Add 3-step ActionSteps entry in Build-ActionSteps
#   7. Add language keys in language.psm1 (PT and EN sections)
# ==============================================================


# ==============================================================
# 1. MICROSOFT TEAMS
# Supports both MS Store (MSIX/MSTeams) and classic EXE installs.
# Priority: Store -> EXE -> protocol handler fallback.
# The ms-teams: protocol is a last resort because on some Windows 11
# machines it incorrectly opens another app (known Microsoft issue).
# ==============================================================
function Reiniciar-Teams {
    $Global:UltimaFuncaoExecutada = "Microsoft Teams"
    Escrever-Log -Mensagem "Teams | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Microsoft Teams"

    # Step 1 (33%): Kill all known Teams process names
    Barra-Progresso (Get-Text "TeamsClosing")
    @("ms-teams", "msteams", "Teams") | ForEach-Object {
        Get-Process $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Escrever-Log -Mensagem "Teams | Processos encerrados" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Microsoft Teams"

    # Step 2 (66%): Wait for processes to fully terminate
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Launch Teams - try each method in order
    $started = $false

    # Option A: MS Store version (Windows 11 default install)
    # Get-AppxPackage returns $null if not installed, so this is safe
    $store = Get-AppxPackage -Name "MSTeams" -ErrorAction SilentlyContinue
    if ($store) {
        Start-Process "ms-teams:"
        $started = $true
        Escrever-Log -Mensagem "Teams | Iniciado via MS Store (MSIX)" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Microsoft Teams"
    }

    # Option B: Classic EXE installer (older corporate deployments)
    if (-not $started) {
        $exe = @(
            "$env:LOCALAPPDATA\Microsoft\Teams\current\Teams.exe",
            "$env:PROGRAMFILES\Microsoft\Teams\current\Teams.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($exe) {
            Start-Process $exe
            $started = $true
            Escrever-Log -Mensagem "Teams | Iniciado via EXE classico: $exe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Microsoft Teams"
        }
    }

    # Option C: Protocol handler fallback (last resort)
    if (-not $started) {
        Start-Process "ms-teams:"
        Escrever-Log -Mensagem "Teams | Iniciado via protocol handler (fallback)" -FunctionName "APPLICATIONS" -Action "Opened" -Status "WARNING" -Application "Microsoft Teams"
    }

    Barra-Progresso (Get-Text "TeamsStarting")
    Start-Sleep 5   # Wait for Teams to load before showing the resolution dialog
}


# ==============================================================
# 2. MICROSOFT OUTLOOK
# Uses the ms-outlook: protocol which works for both classic
# Outlook (Office 16/365) and the new Outlook app.
# ==============================================================
function Reiniciar-Outlook {
    $Global:UltimaFuncaoExecutada = "Microsoft Outlook"
    Escrever-Log -Mensagem "Outlook | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Microsoft Outlook"

    # Step 1 (33%): Detect which Outlook version is running BEFORE killing.
    # OUTLOOK.EXE = Classic Outlook (Office 365 / Office 16)
    # olk.exe     = New Outlook (Windows 11 default / store version)
    # We capture the executable path now so we can reopen the same one.
    Barra-Progresso (Get-Text "OutlookClosing")

    $classicProc = Get-Process "OUTLOOK" -ErrorAction SilentlyContinue | Select-Object -First 1
    $newProc     = Get-Process "olk"     -ErrorAction SilentlyContinue | Select-Object -First 1

    # Capture exe paths before killing (process object loses path after kill)
    $classicExe = if ($classicProc) {
        try { $classicProc.MainModule.FileName } catch { $null }
    } else { $null }

    $newExe = if ($newProc) {
        try { $newProc.MainModule.FileName } catch { $null }
    } else { $null }

    # Determine which version was active (prefer Classic if both running)
    $wasClassic = $null -ne $classicProc
    $wasNew     = $null -ne $newProc -and -not $wasClassic

    # Kill both just in case
    $classicProc | Stop-Process -Force -ErrorAction SilentlyContinue
    $newProc     | Stop-Process -Force -ErrorAction SilentlyContinue

    Escrever-Log -Mensagem "Outlook | Processos encerrados (Classic=$wasClassic, New=$wasNew)" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Microsoft Outlook"

    # Step 2 (66%): Wait for profile locks to release
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 5

    # Step 3 (100%): Reopen the SAME version that was running
    $started = $false

    if ($wasClassic) {
        # Classic Outlook - try captured path first, then known locations
        $outlookExe = $classicExe
        if (-not $outlookExe -or -not (Test-Path $outlookExe)) {
            $outlookExe = @(
                "${env:ProgramFiles}\Microsoft Office\root\Office16\OUTLOOK.EXE",
                "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE",
                "${env:ProgramFiles}\Microsoft Office\Office16\OUTLOOK.EXE",
                "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OUTLOOK.EXE"
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if ($outlookExe -and (Test-Path $outlookExe)) {
            Start-Process $outlookExe
            $started = $true
            Escrever-Log -Mensagem "Outlook | Classic reiniciado: $outlookExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Microsoft Outlook"
        }
    }

    if ($wasNew -or (-not $started -and $newExe)) {
        # New Outlook - try captured path, then known locations
        $olkExe = $newExe
        if (-not $olkExe -or -not (Test-Path $olkExe)) {
            $olkExe = @(
                "$env:LOCALAPPDATA\Microsoft\WindowsApps\olk.exe",
                "$env:ProgramFiles\Microsoft Office\root\Office16\olk.exe"
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if ($olkExe -and (Test-Path $olkExe)) {
            Start-Process $olkExe
            $started = $true
            Escrever-Log -Mensagem "Outlook | New Outlook reiniciado: $olkExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Microsoft Outlook"
        }
    }

    # Fallback: neither version detected - use protocol (opens default)
    if (-not $started) {
        Start-Process "ms-outlook:"
        Escrever-Log -Mensagem "Outlook | Nenhuma versao detectada, abrindo via protocol (fallback)" -FunctionName "APPLICATIONS" -Action "Opened" -Status "WARNING" -Application "Microsoft Outlook"
    }

    Barra-Progresso (Get-Text "OutlookStarting")
    Start-Sleep 5
}


# ==============================================================
# 3. GOOGLE DRIVE
# Tries the Start Menu shortcut first (most reliable path that
# survives Drive updates), then falls back to locating the
# versioned GoogleDriveFS.exe under Program Files.
# ==============================================================
function Reiniciar-GoogleDrive {
    $Global:UltimaFuncaoExecutada = "Google Drive"
    Escrever-Log -Mensagem "Google Drive | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Google Drive"

    # Step 1 (33%): Kill Google Drive File Stream processes
    Barra-Progresso (Get-Text "DriveClosing")
    @("GoogleDriveFS", "GoogleDrive") | ForEach-Object {
        Get-Process $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Escrever-Log -Mensagem "Google Drive | Processos encerrados" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Google Drive"

    # Step 2 (66%): Wait for file system handles to release
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Launch Drive
    $shortcut = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Google Drive.lnk"
    if (Test-Path $shortcut) {
        # Shortcut is version-independent - survives Drive auto-updates
        Start-Process $shortcut
        Escrever-Log -Mensagem "Google Drive | Iniciado via atalho do menu iniciar" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Google Drive"
    } else {
        # Fallback: find the versioned EXE under Drive File Stream folder
        # Google Drive installs EXE inside a version-numbered subdirectory
        $base = "C:\Program Files\Google\Drive File Stream"
        $driveExe = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 |
            ForEach-Object { Join-Path $_.FullName "GoogleDriveFS.exe" }

        if ($driveExe -and (Test-Path $driveExe)) {
            Start-Process $driveExe
            Escrever-Log -Mensagem "Google Drive | Iniciado via EXE versionado" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Google Drive"
        } else {
            WPF-Log (Get-Text "DriveNotFound") -Color "#F7C02D"
            Escrever-Log -Mensagem "Google Drive | Executavel nao encontrado em nenhum caminho" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "Google Drive"
        }
    }

    Barra-Progresso (Get-Text "DriveStarting")
    Start-Sleep 5
}


# ==============================================================
# 4. SLACK
# Uses CloseMainWindow first (graceful shutdown) before Kill
# to avoid Slack leaving temp files in a bad state.
# Falls back to slack: protocol if EXE not found.
# ==============================================================
function Reiniciar-Slack {
    $Global:UltimaFuncaoExecutada = "Slack"
    Escrever-Log -Mensagem "Slack | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Slack"

    # Step 1 (33%): Graceful shutdown - send close signal, then force kill if needed
    Barra-Progresso (Get-Text "SlackClosing")
    Get-Process slack -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_.CloseMainWindow() | Out-Null   # Ask Slack to close gracefully
            Start-Sleep 2                      # Give it 2s to respond
            if (!$_.HasExited) { $_.Kill() }  # Force kill if still running
        } catch {}
    }
    Escrever-Log -Mensagem "Slack | Processo encerrado" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Slack"

    # Step 2 (66%): Wait for cleanup
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Find and launch Slack
    # Slack can be installed in AppData (user install) or Program Files (admin install)
    $slackExe = @(
        "$env:LOCALAPPDATA\slack\slack.exe",
        "$env:LOCALAPPDATA\Programs\slack\slack.exe",
        "C:\Program Files\slack\slack.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($slackExe) {
        Start-Process $slackExe
        Escrever-Log -Mensagem "Slack | Iniciado via EXE: $slackExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Slack"
    } else {
        # Protocol fallback for Store version
        try { Start-Process "slack:" } catch {}
        Escrever-Log -Mensagem "Slack | EXE nao encontrado, tentou protocol fallback" -FunctionName "APPLICATIONS" -Action "Opened" -Status "WARNING" -Application "Slack"
    }

    Barra-Progresso (Get-Text "SlackStarting")
    Start-Sleep 5
}


# ==============================================================
# 6. ZOOM
# NOTE: zoommtg: protocol is intentionally NOT used as fallback.
# On Windows 11, that protocol incorrectly opens Microsoft Teams
# due to a protocol handler conflict. If no EXE is found, the
# function logs a "not found" message instead.
# ==============================================================
function Reiniciar-Zoom {
    $Global:UltimaFuncaoExecutada = "Zoom"
    Escrever-Log -Mensagem "Zoom | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Zoom"

    # Step 1 (33%): Kill Zoom and all its helper processes
    Barra-Progresso (Get-Text "ZoomClosing")
    @("Zoom", "CptHost", "zCrashSvc", "zTscoder") | ForEach-Object {
        Get-Process $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Escrever-Log -Mensagem "Zoom | Processos encerrados" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Zoom"

    # Step 2 (66%): Wait for Zoom helper processes to terminate
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Find Zoom EXE - can be in AppData or Program Files
    $zoomExe = @(
        "$env:APPDATA\Zoom\bin\Zoom.exe",
        "$env:PROGRAMFILES\Zoom\bin\Zoom.exe",
        "${env:PROGRAMFILES(X86)}\Zoom\bin\Zoom.exe",
        "$env:LOCALAPPDATA\Zoom\bin\Zoom.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($zoomExe) {
        Start-Process $zoomExe
        Escrever-Log -Mensagem "Zoom | Iniciado: $zoomExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Zoom"
    } else {
        # Do NOT use zoommtg: - it opens Teams on Windows 11
        WPF-Log (Get-Text "ZoomNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "Zoom | Executavel nao encontrado. Usuario deve instalar em zoom.us/download" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "Zoom"
    }

    Barra-Progresso (Get-Text "ZoomStarting")
    Start-Sleep 5
}


# ==============================================================
# 7. ONEDRIVE
# OneDrive installs to LocalAppData for user-level installs
# and to Program Files for machine-wide (admin) installs.
# ==============================================================
function Reiniciar-OneDrive {
    $Global:UltimaFuncaoExecutada = "OneDrive"
    Escrever-Log -Mensagem "OneDrive | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "OneDrive"

    # Step 1 (33%): Kill the OneDrive process
    Barra-Progresso (Get-Text "OneDriveClosing")
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Escrever-Log -Mensagem "OneDrive | Processo encerrado" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "OneDrive"

    # Step 2 (66%): Wait for sync handles to release
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Launch OneDrive
    $odExe = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",    # User install
        "$env:PROGRAMFILES\Microsoft OneDrive\OneDrive.exe",    # Machine install
        "${env:PROGRAMFILES(X86)}\Microsoft OneDrive\OneDrive.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($odExe) {
        Start-Process $odExe
        Escrever-Log -Mensagem "OneDrive | Iniciado: $odExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "OneDrive"
    } else {
        WPF-Log (Get-Text "OneDriveNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "OneDrive | Executavel nao encontrado" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "OneDrive"
    }

    Barra-Progresso (Get-Text "OneDriveStarting")
    Start-Sleep 5
}


# ==============================================================
# 8. GOOGLE CHROME
# In addition to restarting Chrome, this function clears the
# Cache, Code Cache, and GPUCache folders from the Default
# profile. These are safe to delete (Chrome rebuilds them)
# and solve most "Chrome is slow/broken" complaints.
# Profile data (bookmarks, passwords, extensions) is NOT touched.
# ==============================================================
function Reiniciar-Chrome {
    $Global:UltimaFuncaoExecutada = "Google Chrome"
    Escrever-Log -Mensagem "Chrome | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Google Chrome"

    # Step 1 (33%): Kill Chrome (all renderer/helper processes use the same name)
    Barra-Progresso (Get-Text "ChromeClosing")
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Escrever-Log -Mensagem "Chrome | Processos encerrados" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Google Chrome"

    # Step 2 (66%): Clear cache while Chrome is closed
    # Only deleting cache folders - bookmarks/passwords/extensions are safe
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 2

    $cachePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\GPUCache"
    )
    foreach ($path in $cachePaths) {
        if (Test-Path $path) {
            try {
                Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            } catch {}  # Silently skip files locked by OS
        }
    }
    Escrever-Log -Mensagem "Chrome | Cache limpo (Default/Cache, Code Cache, GPUCache)" -FunctionName "APPLICATIONS" -Action "CacheCleared" -Status "SUCCESS" -Application "Google Chrome"

    # Step 3 (100%): Launch Chrome
    $chromeExe = @(
        "$env:PROGRAMFILES\Google\Chrome\Application\chrome.exe",
        "${env:PROGRAMFILES(X86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"  # Dev/Canary
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($chromeExe) {
        Start-Process $chromeExe
        Escrever-Log -Mensagem "Chrome | Iniciado: $chromeExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Google Chrome"
    } else {
        WPF-Log (Get-Text "ChromeNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "Chrome | Executavel nao encontrado" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "Google Chrome"
    }

    Barra-Progresso (Get-Text "ChromeStarting")
    Start-Sleep 5
}


# ==============================================================
# 9. CISCO WEBEX
# Webex installs in versioned subfolders under LocalAppData\Programs
# so the static path list alone is not enough. The function first
# does a recursive search under known root directories, then
# falls back to the static list.
# NOTE: webexmeetings: protocol is NOT used - it shows a Windows
# "Get an app" dialog on machines where Webex is not installed.
# ==============================================================
function Reiniciar-Webex {
    $Global:UltimaFuncaoExecutada = "Cisco Webex"
    Escrever-Log -Mensagem "Webex | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Cisco Webex"

    # Step 1 (33%): Kill all Webex-related processes
    Barra-Progresso (Get-Text "WebexClosing")
    @("CiscoWebExStart", "WebEx", "ptoneclk", "wbxcsp", "CiscoCollabHost") | ForEach-Object {
        Get-Process $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Escrever-Log -Mensagem "Webex | Processos encerrados" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Cisco Webex"

    # Step 2 (66%): Wait for Webex background services to stop
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Find Webex EXE using static paths first, then recursive search
    # Static paths cover common installation locations
    $webexCandidates = @(
        "$env:LOCALAPPDATA\WebEx\WebEx\WebexHost.exe",
        "$env:LOCALAPPDATA\WebEx\WebexHost.exe",
        "$env:PROGRAMFILES\Webex\CiscoCollabHost.exe",
        "${env:PROGRAMFILES(X86)}\Webex\CiscoCollabHost.exe",
        "$env:PROGRAMFILES\Cisco Spark\CiscoCollabHost.exe",
        "${env:PROGRAMFILES(X86)}\Cisco Spark\CiscoCollabHost.exe"
    )
    $webexExe = $webexCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    # If not found via static paths, do a recursive search under common root dirs
    # Webex often installs under versioned subfolders like:
    # LocalAppData\Programs\Cisco Webex\42.6.0.25671\CiscoCollabHost.exe
    if (-not $webexExe) {
        $roots = @(
            "$env:LOCALAPPDATA\Programs",
            "$env:LOCALAPPDATA\WebEx",
            "$env:PROGRAMFILES\Webex",
            "${env:PROGRAMFILES(X86)}\Webex"
        )
        foreach ($root in $roots) {
            if (Test-Path $root) {
                # Try CiscoCollabHost.exe first, then WebexHost.exe
                $found = Get-ChildItem $root -Filter "CiscoCollabHost.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $found) {
                    $found = Get-ChildItem $root -Filter "WebexHost.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if ($found) { $webexExe = $found.FullName; break }
            }
        }
    }

    # Log the resolved path for debugging (visible in View Log)
    Escrever-Log -Mensagem "Webex | Path resolvido: $webexExe" -FunctionName "APPLICATIONS" -Action "PathSearch" -Status "INFO" -Application "Cisco Webex"

    if ($webexExe) {
        Start-Process $webexExe
        Escrever-Log -Mensagem "Webex | Iniciado: $webexExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Cisco Webex"
    } else {
        WPF-Log (Get-Text "WebexNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "Webex | Nao encontrado. Instalar em webex.com" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "Cisco Webex"
    }

    Barra-Progresso (Get-Text "WebexStarting")
    Start-Sleep 5
}


# ==============================================================
# 10. WHATSAPP DESKTOP
# WhatsApp on Windows can be either:
#   A) EXE installer: LocalAppData\WhatsApp\WhatsApp.exe
#   B) MS Store MSIX: 5319275A.WhatsAppDesktop
#
# CLOSE strategy: Kill by process name AND by window title.
# The Store version may run under a different process name
# depending on the Windows version, so title matching is safer.
#
# OPEN strategy: EXE first (most reliable), then Store via
# explorer shell:AppsFolder (avoids protocol handler issues).
# The whatsapp: protocol is NOT used because it can open
# a browser tab instead of the app on some configurations.
# ==============================================================
function Reiniciar-WhatsApp {
    $Global:UltimaFuncaoExecutada = "WhatsApp Desktop"
    Escrever-Log -Mensagem "WhatsApp | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "WhatsApp Desktop"

    # Step 1 (33%): Kill by name AND by window title (covers all versions)
    Barra-Progresso (Get-Text "WhatsAppClosing")
    Get-Process WhatsApp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process | Where-Object { $_.MainWindowTitle -like "*WhatsApp*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2  # Allow the kill to complete before checking for survivors
    Escrever-Log -Mensagem "WhatsApp | Processos encerrados" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "WhatsApp Desktop"

    # Step 2 (66%): Wait for WebSocket connections to close
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Launch WhatsApp - EXE preferred over protocol
    $started = $false

    # Option A: EXE installer (most reliable launch method)
    $waExe = @(
        "$env:LOCALAPPDATA\WhatsApp\WhatsApp.exe",
        "$env:PROGRAMFILES\WhatsApp\WhatsApp.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($waExe) {
        Start-Process $waExe
        $started = $true
        Escrever-Log -Mensagem "WhatsApp | Iniciado via EXE: $waExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "WhatsApp Desktop"
    }

    # Option B: Store version via explorer shell (avoids bad protocol behavior)
    # shell:AppsFolder\{PackageFamilyName}!App is the correct way to launch
    # a Store app without relying on a protocol handler
    if (-not $started) {
        $store = Get-AppxPackage -Name "5319275A.WhatsAppDesktop" -ErrorAction SilentlyContinue
        if ($store) {
            $appId = $store.PackageFamilyName + "!App"
            Start-Process "explorer.exe" "shell:AppsFolder\$appId"
            $started = $true
            Escrever-Log -Mensagem "WhatsApp | Iniciado via Store shell: $appId" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "WhatsApp Desktop"
        }
    }

    if (-not $started) {
        WPF-Log (Get-Text "WhatsAppNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "WhatsApp | Nao encontrado em nenhum caminho" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "WhatsApp Desktop"
    }

    Barra-Progresso (Get-Text "WhatsAppStarting")
    Start-Sleep 5
}


# ==============================================================
# 11. DROPBOX
# Dropbox installs its EXE inside a versioned subfolder, e.g.:
#   LocalAppData\Dropbox\120.4.4756\Dropbox.exe
# So we search recursively (newest file first) rather than
# using a static path that would break after every Dropbox update.
# ==============================================================
function Reiniciar-Dropbox {
    $Global:UltimaFuncaoExecutada = "Dropbox"
    Escrever-Log -Mensagem "Dropbox | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "Dropbox"

    # Step 1 (33%): Kill Dropbox
    Barra-Progresso (Get-Text "DropboxClosing")
    Get-Process Dropbox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Escrever-Log -Mensagem "Dropbox | Processo encerrado" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "Dropbox"

    # Step 2 (66%): Wait for sync to stop and file handles to release
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Find Dropbox EXE - search recursively to handle versioned paths
    # Sort by LastWriteTime descending to get the newest version if multiple exist
    $dbSearch = Get-ChildItem "$env:LOCALAPPDATA\Dropbox" -Filter "Dropbox.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    $dbExe = if ($dbSearch) {
        $dbSearch.FullName  # Found via recursive search
    } else {
        # Fallback to known static paths
        @(
            "$env:LOCALAPPDATA\Dropbox\client\Dropbox.exe",
            "$env:PROGRAMFILES\Dropbox\client\Dropbox.exe",
            "${env:PROGRAMFILES(X86)}\Dropbox\client\Dropbox.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    Escrever-Log -Mensagem "Dropbox | Path resolvido: $dbExe" -FunctionName "APPLICATIONS" -Action "PathSearch" -Status "INFO" -Application "Dropbox"

    if ($dbExe) {
        Start-Process $dbExe
        Escrever-Log -Mensagem "Dropbox | Iniciado: $dbExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "Dropbox"
    } else {
        WPF-Log (Get-Text "DropboxNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "Dropbox | Executavel nao encontrado" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "Dropbox"
    }

    Barra-Progresso (Get-Text "DropboxStarting")
    Start-Sleep 5
}


# ==============================================================
# 16. ANYDESK
# AnyDesk runs 2-3 processes simultaneously (UI + helper + service).
# As a standard user we kill the user-mode processes we own.
# If AnyDesk is installed as a Windows service (running as SYSTEM),
# that process cannot be stopped without admin - it is silently
# skipped. The user-mode UI restarts normally regardless.
# ==============================================================
function Reiniciar-AnyDesk {
    $Global:UltimaFuncaoExecutada = "AnyDesk"
    Escrever-Log -Mensagem "AnyDesk | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "AnyDesk"

    $knownPaths = @(
        "C:\Program Files (x86)\AnyDesk\AnyDesk.exe",
        "C:\Program Files\AnyDesk\AnyDesk.exe",
        "$env:LOCALAPPDATA\AnyDesk\AnyDesk.exe"
    )

    # Step 1 (33%): Get ALL AnyDesk processes before killing.
    # Capture exe path first - needed to reopen after kill.
    Barra-Progresso (Get-Text "AnyDeskClosing")

    $procs = @(Get-Process "AnyDesk" -ErrorAction SilentlyContinue)

    $detectedExe = $null
    foreach ($p in $procs) {
        try {
            $path = $p.MainModule.FileName
            if ($path) { $detectedExe = $path; break }
        } catch {}
    }

    # Resolve reopen path: running process > known paths on disk
    $targetExe = if ($detectedExe -and (Test-Path $detectedExe)) {
        $detectedExe
    } else {
        $knownPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    # Kill all accessible processes (service process under SYSTEM will silently fail)
    $killed = 0
    foreach ($p in $procs) {
        try { $p | Stop-Process -Force -ErrorAction Stop; $killed++ } catch {}
    }
    Escrever-Log -Mensagem "AnyDesk | $killed processo(s) encerrado(s) | alvo: $targetExe" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "AnyDesk"

    # Step 2 (66%): Wait for connections and audio handles to release
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep 3

    # Step 3 (100%): Reopen
    if ($targetExe) {
        Start-Process $targetExe
        Escrever-Log -Mensagem "AnyDesk | Reiniciado: $targetExe" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "AnyDesk"
    } else {
        WPF-Log (Get-Text "AppNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "AnyDesk | Executavel nao encontrado" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "AnyDesk"
    }

    Barra-Progresso (Get-Text "AnyDeskStarting")
    Start-Sleep 5
}

# ==============================================================
# 12. 8x8 WORK
# --------------------------------------------------------------
# FIX (v1.1.6): a funcao nunca virava um comando valido, em nenhum
# teste (nem via Import-Module, nem via dot-source direto). CAUSA
# REAL ENCONTRADA: o antigo "Export-ModuleMember" deste arquivo
# estava posicionado ANTES desta funcao ser definida no arquivo -
# ou seja, quando o PowerShell executava o script de cima para
# baixo e chegava no Export-ModuleMember, "Reiniciar-8x8Work" ainda
# nao existia (so seria definida linhas depois), entao o nome era
# ignorado silenciosamente. Isso explica por que ela nunca funcionou
# desde o inicio, mesmo antes de qualquer alteracao nesta conversa.
#
# CORRECAO: funcao reescrita do zero aqui, e o Export-ModuleMember
# do arquivo foi movido para o FINAL (depois de todas as 12 funcoes
# estarem definidas) - ver ultima linha do arquivo.
#
# CAMINHO DE INSTALACAO: confirmado na maquina real via Get-Process:
#   $env:LOCALAPPDATA\8x8-Work\current\8x8 Work.exe
# O "\current\" e o padrao do Squirrel (auto-updater usado por apps
# Electron) - uma pasta que sempre aponta pra versao mais recente
# instalada, e por isso sobrevive a atualizacoes futuras do 8x8 Work.
#
# Segue o MESMO padrao de log das outras funcoes deste arquivo
# (RestartStart/Closed/Opened/ExecutableNotFound/LaunchFailed com
# -Action/-Status/-Application) - qualquer dashboard futura que leia
# esses logs vai coletar as acoes do 8x8 Work exatamente como coleta
# as dos outros apps, sem precisar de nenhum tratamento especial.
# ==============================================================
function Reiniciar-8x8Work {
    $Global:UltimaFuncaoExecutada = "8x8 Work"
    Escrever-Log -Mensagem "8x8 Work | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "8x8 Work"

    # Step 1 (33%): encerra todos os processos do 8x8 Work.
    # O app roda varios processos simultaneos (principal + processos
    # internos do Electron) - todos com o mesmo nome, todos encerrados.
    Barra-Progresso (Get-Text "8x8Closing")

    $processos8x8 = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*8x8*" })

    # Caminho do processo em execucao (cobre qualquer instalacao,
    # mesmo que a pasta "current" mude de versao no futuro)
    $caminhoDetectado = $null
    foreach ($processo in $processos8x8) {
        try {
            if ($processo.Path) { $caminhoDetectado = $processo.Path; break }
        } catch {}
    }

    $processosEncerrados = 0
    foreach ($processo in $processos8x8) {
        try {
            Stop-Process -Id $processo.Id -Force -ErrorAction Stop
            $processosEncerrados++
        } catch {}
    }

    # Caminho confirmado na maquina real (fallback se nao havia processo
    # em execucao para detectar o caminho automaticamente)
    $caminhoConfirmado = Join-Path $env:LOCALAPPDATA "8x8-Work\current\8x8 Work.exe"

    $caminhoParaAbrir = if ($caminhoDetectado -and (Test-Path $caminhoDetectado)) {
        $caminhoDetectado
    } elseif (Test-Path $caminhoConfirmado) {
        $caminhoConfirmado
    } else {
        $null
    }

    Escrever-Log -Mensagem "8x8 Work | $processosEncerrados processo(s) encerrado(s) | caminho para reabrir: $caminhoParaAbrir" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "8x8 Work"

    # Step 2 (66%): aguarda liberacao de audio e conexoes VoIP
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep -Seconds 4

    # Step 3 (100%): reabre o 8x8 Work
    Add-Type -AssemblyName System.Windows.Forms
    $idiomaIngles = $Global:Language -eq "EN"

    if ($caminhoParaAbrir) {
        try {
            Start-Process -FilePath $caminhoParaAbrir -ErrorAction Stop
            Escrever-Log -Mensagem "8x8 Work | Reiniciado: $caminhoParaAbrir" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "8x8 Work"
        } catch {
            $erro = $_.ToString()
            $mensagemErro = if ($idiomaIngles) {
                "Found 8x8 Work at:`n$caminhoParaAbrir`n`nBut failed to launch it:`n$erro"
            } else {
                "O 8x8 Work foi encontrado em:`n$caminhoParaAbrir`n`nMas falhou ao abrir:`n$erro"
            }
            [System.Windows.Forms.MessageBox]::Show($mensagemErro, "8x8 Work", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            Escrever-Log -Mensagem "8x8 Work | Falha ao iniciar $caminhoParaAbrir : $erro" -FunctionName "APPLICATIONS" -Action "LaunchFailed" -Status "ERROR" -Application "8x8 Work"
        }
    } else {
        WPF-Log (Get-Text "AppNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "8x8 Work | Nao encontrado (nem processo em execucao, nem caminho confirmado no disco)" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "8x8 Work"

        $mensagemNaoEncontrado = if ($idiomaIngles) {
            "8x8 Work was not found on this computer.`n`nIf it IS installed, contact IT support so we can add its install path to the tool."
        } else {
            "O 8x8 Work nao foi encontrado neste computador.`n`nSe ele estiver instalado, contate o suporte de TI para adicionarmos o caminho de instalacao correto na ferramenta."
        }
        [System.Windows.Forms.MessageBox]::Show($mensagemNaoEncontrado, "8x8 Work", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }

    Barra-Progresso (Get-Text "8x8Starting")
    Start-Sleep -Seconds 5
}

# ==============================================================
# 13. CLICKUP
# --------------------------------------------------------------
# Processo confirmado via Get-Process na maquina real: "ClickUp"
# (7 instancias simultaneas rodando ao mesmo tempo - normal para
# apps Electron, mesmo padrao do 8x8 Work).
#
# Caminho confirmado:
#   $env:LOCALAPPDATA\Programs\desktop\ClickUp.exe
# (repare que a pasta se chama "desktop", nao "ClickUp" - foi assim
# que o instalador criou, confirmado via Get-Process na maquina real)
#
# ATENCAO - NAO usar wildcard "*Click*" pra localizar o processo:
# existe um processo legitimo do Windows/Office chamado
# "OfficeClickToRun" que TAMBEM contem "Click" no nome e seria
# encerrado por engano com um filtro amplo demais. Por isso aqui
# usamos Get-Process -Name "ClickUp" (nome exato, sem wildcard).
# ==============================================================
function Reiniciar-ClickUp {
    $Global:UltimaFuncaoExecutada = "ClickUp"
    Escrever-Log -Mensagem "ClickUp | Restart iniciado" -FunctionName "APPLICATIONS" -Action "RestartStart" -Status "INFO" -Application "ClickUp"

    # Step 1 (33%): encerra todos os processos do ClickUp (nome exato)
    Barra-Progresso (Get-Text "ClickUpClosing")

    $processosClickUp = @(Get-Process -Name "ClickUp" -ErrorAction SilentlyContinue)

    $caminhoDetectado = $null
    foreach ($processo in $processosClickUp) {
        try {
            if ($processo.Path) { $caminhoDetectado = $processo.Path; break }
        } catch {}
    }

    $processosEncerrados = 0
    foreach ($processo in $processosClickUp) {
        try {
            Stop-Process -Id $processo.Id -Force -ErrorAction Stop
            $processosEncerrados++
        } catch {}
    }

    # Caminho confirmado na maquina real (fallback se nao havia processo
    # em execucao para detectar o caminho automaticamente)
    $caminhoConfirmado = "$env:LOCALAPPDATA\Programs\desktop\ClickUp.exe"

    $caminhoParaAbrir = if ($caminhoDetectado -and (Test-Path $caminhoDetectado)) {
        $caminhoDetectado
    } elseif (Test-Path $caminhoConfirmado) {
        $caminhoConfirmado
    } else {
        $null
    }

    Escrever-Log -Mensagem "ClickUp | $processosEncerrados processo(s) encerrado(s) | caminho para reabrir: $caminhoParaAbrir" -FunctionName "APPLICATIONS" -Action "Closed" -Status "SUCCESS" -Application "ClickUp"

    # Step 2 (66%): aguarda liberacao de arquivos/cache antes de reabrir
    Barra-Progresso (Get-Text "CleaningCache")
    Start-Sleep -Seconds 3

    # Step 3 (100%): reabre o ClickUp
    Add-Type -AssemblyName System.Windows.Forms
    $idiomaIngles = $Global:Language -eq "EN"

    if ($caminhoParaAbrir) {
        try {
            Start-Process -FilePath $caminhoParaAbrir -ErrorAction Stop
            Escrever-Log -Mensagem "ClickUp | Reiniciado: $caminhoParaAbrir" -FunctionName "APPLICATIONS" -Action "Opened" -Status "SUCCESS" -Application "ClickUp"
        } catch {
            $erro = $_.ToString()
            $mensagemErro = if ($idiomaIngles) {
                "Found ClickUp at:`n$caminhoParaAbrir`n`nBut failed to launch it:`n$erro"
            } else {
                "O ClickUp foi encontrado em:`n$caminhoParaAbrir`n`nMas falhou ao abrir:`n$erro"
            }
            [System.Windows.Forms.MessageBox]::Show($mensagemErro, "ClickUp", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            Escrever-Log -Mensagem "ClickUp | Falha ao iniciar $caminhoParaAbrir : $erro" -FunctionName "APPLICATIONS" -Action "LaunchFailed" -Status "ERROR" -Application "ClickUp"
        }
    } else {
        WPF-Log (Get-Text "AppNotFound") -Color "#F7C02D"
        Escrever-Log -Mensagem "ClickUp | Nao encontrado (nem processo em execucao, nem caminho confirmado no disco)" -FunctionName "APPLICATIONS" -Action "ExecutableNotFound" -Status "WARNING" -Application "ClickUp"

        $mensagemNaoEncontrado = if ($idiomaIngles) {
            "ClickUp was not found on this computer.`n`nIf it IS installed, contact IT support so we can add its install path to the tool."
        } else {
            "O ClickUp nao foi encontrado neste computador.`n`nSe ele estiver instalado, contate o suporte de TI para adicionarmos o caminho de instalacao correto na ferramenta."
        }
        [System.Windows.Forms.MessageBox]::Show($mensagemNaoEncontrado, "ClickUp", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }

    Barra-Progresso (Get-Text "ClickUpStarting")
    Start-Sleep -Seconds 4
}

# ==============================================================
# EXPORT-MODULEMEMBER
# --------------------------------------------------------------
# FIX (v1.1.6): esta linha foi movida pra AQUI - o final do arquivo,
# depois de TODAS as 12 funcoes ja terem sido definidas acima. Antes
# ela estava entre Reiniciar-AnyDesk e Reiniciar-8x8Work, ou seja,
# ANTES da 8x8Work ser definida - por isso o nome era ignorado
# silenciosamente e a funcao nunca ficava disponivel (ver comentario
# detalhado acima, na funcao Reiniciar-8x8Work).
#
# REGRA PARA O FUTURO: ao adicionar uma funcao nova neste arquivo,
# sempre adicione o nome dela aqui, e SEMPRE mantenha esta linha
# como a ULTIMA coisa do arquivo (depois de toda funcao existir).
# ==============================================================
Export-ModuleMember -Function `
    Reiniciar-Teams, Reiniciar-Outlook, Reiniciar-GoogleDrive, Reiniciar-Slack, `
    Reiniciar-Zoom, Reiniciar-OneDrive, Reiniciar-Chrome, Reiniciar-Webex, `
    Reiniciar-WhatsApp, Reiniciar-Dropbox, Reiniciar-AnyDesk, Reiniciar-8x8Work, Reiniciar-ClickUp
