# ==============================================================
# main.ps1 - Agent IT - Entry point
# ==============================================================
# WHAT THIS FILE DOES:
#   1. Sets execution policy and encoding
#   2. Detects script root (works as .ps1 or compiled .exe)
#   3. Loads language.psm1 and logging.psm1 (bootstrap)
#   4. Checks for module updates via Supabase Edge Function
#   5. Downloads modules from GitHub into memory (never to disk)
#   6. Decodes and loads all modules from memory
#   7. Shows language selection dialog
#   8. Shows splash screen logo
#   9. Opens the main WPF window (blocking call)
#
# SECURITY ARCHITECTURE:
#   Modules are stored on GitHub as private repository files.
#   They are downloaded, decoded and loaded directly into
#   PowerShell memory - never written to disk permanently.
#   This means:
#     - No .psm1 files in ProgramData for anyone to read
#     - No GitHub token in the code (Supabase holds it as secret)
#     - No way to copy module files from the machine
#   The only files on disk are:
#     - AgentIT.exe    (compiled binary)
#     - version.txt    (version number only)
#     - assets\        (logo and icon)
#
# OFFLINE FALLBACK:
#   If Supabase or GitHub is unreachable, the app loads modules
#   from the previously downloaded version (version.txt unchanged)
#   or falls back to local modules\ folder in development mode.
#
# TO COMPILE AS EXE:
#   Invoke-PS2EXE -InputFile "main.ps1" -OutputFile "AgentIT.exe" `
#     -IconFile "icon.ico" -NoConsole -Title "Agent IT" -Version "1.0.0.0"
# ==============================================================

Set-ExecutionPolicy Bypass -Scope Process -Force

# Set UTF-8 encoding - wrapped in try/catch because
# [Console] throws when compiled with -NoConsole (no console exists)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding  = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8
try { chcp 65001 | Out-Null } catch {}

# ==============================================================
# ADMIN MODE DETECTION
# Set when the EXE relaunches itself via RunAs with --admin flag.
# Also verifies the process is actually elevated — prevents
# spoofing by passing --admin without real elevation.
# ==============================================================
$Global:AdminMode = $false
if ($args -contains "--admin") {
    $principal    = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isElevated   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $Global:AdminMode = $isElevated
}

# ==============================================================
# AMBIENTE: PRODUCTION ou STAGING
# --------------------------------------------------------------
# Esta e a UNICA linha que deve diferir entre o .exe de producao e
# o .exe de teste. Ao compilar a versao de staging, troque o valor
# abaixo para "STAGING" antes de rodar o Invoke-PS2EXE - todo o
# resto do arquivo (e de todos os modulos) permanece identico.
#
# O que isso controla:
#   1. Qual Edge Function de update e chamada (get-modules-prod vs
#      get-modules-staging) - cada uma aponta pra uma branch/pasta
#      diferente no GitHub (main vs staging).
#   2. Pasta local separada (version.txt e logs) - assim testar o
#      staging na mesma maquina nunca conflita com a instalacao de
#      producao.
#   3. Indicador visual na janela (cor da barra de titulo + texto)
#      para o tecnico nunca confundir qual versao esta usando -
#      ver Launch-MainWindow em ui.psm1.
# ==============================================================
$Global:Environment = "PRODUCTION"   # Trocar para "STAGING" na build de teste

# ==============================================================
# CONFIGURATION
# ==============================================================
# !! CONFIGURAR: Atualize com os dados do Supabase da empresa !!
# -------------------------------------------------------------- 
# Supabase Dashboard -> Project Settings -> API -> Project URL
# Supabase Dashboard -> Project Settings -> API -> anon/public key
#
# Supabase Edge Function URL (get version + signed download URLs)
#
# FIX (v1.2.0): antes existia uma unica URL/Edge Function. Agora
# existem DUAS (prod/staging), escolhidas automaticamente com base
# em $Global:Environment acima. As duas vivem no MESMO projeto
# Supabase (nao precisa de projeto separado) - so apontam pra
# branches diferentes do GitHub (main vs staging) e tem seu proprio
# CURRENT_VERSION independente.
$SUPABASE_URL_PROD    = "https://sluhfuoazyykrhhgestg.supabase.co/functions/v1/get-modules-prod"
$SUPABASE_URL_STAGING = "https://sluhfuoazyykrhhgestg.supabase.co/functions/v1/get-modules-staging"

$SUPABASE_URL = if ($Global:Environment -eq "STAGING") { $SUPABASE_URL_STAGING } else { $SUPABASE_URL_PROD }

# Supabase anon public key (safe to expose - read-only access)
# A mesma anon key serve para as duas Edge Functions (mesmo projeto).
$SUPABASE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNsdWhmdW9henl5a3JoaGdlc3RnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY3MzE4OTgsImV4cCI6MjEwMjMwNzg5OH0.TmUVK4zf9_d-DGXAnl141zopV9ZvoVUwYeqtqN64xPg"
# ==============================================================

# Local paths
#
# FIX (v1.2.0): pasta com sufixo de ambiente - staging nunca conflita
# com producao se as duas forem testadas na mesma maquina.
$PastaSufixo  = if ($Global:Environment -eq "STAGING") { " - STAGING" } else { "" }
$VERSION_FILE = "C:\ProgramData\IT Support Agent$PastaSufixo\version.txt"
$INSTALL_PATH = "C:\ProgramData\IT Support Agent$PastaSufixo"

# ==============================================================
# DETECT SCRIPT ROOT
# Works as .ps1 in development and as compiled .exe in production
# ==============================================================
if ($PSScriptRoot) {
    $ScriptPath = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $ScriptPath = Split-Path $MyInvocation.MyCommand.Path -Parent
} else {
    $ScriptPath = Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent
}

# Normalize ScriptPath to avoid 8.3 short name issues (e.g. USURIO~2)
# Always use ProgramData as base when running as installed .exe
#
# FIX (v1.2.5): faltava o $PastaSufixo aqui - $INSTALL_PATH e
# $VERSION_FILE ja incluiam o sufixo de staging (" - STAGING"), mas
# esta variavel nao, o que fazia a build de staging apontar pra pasta
# de modules/assets da PRODUCAO por engano (risco de contaminacao
# cruzada entre os dois ambientes).
$ProgramDataPath = "C:\ProgramData\IT Support Agent$PastaSufixo"

# Determine module path:
# Use ProgramData\modules only if it exists AND has modules inside
# Otherwise fall back to local ScriptPath\modules (development mode)
$pgDataModules = Join-Path $ProgramDataPath "modules"
$localModules  = Join-Path $ScriptPath "modules"

$hasModulesInPgData = (Test-Path $pgDataModules) -and
    ((Get-ChildItem $pgDataModules -Filter "*.psm1" -ErrorAction SilentlyContinue).Count -gt 0)

# Detect if running as installed .exe by checking the process path.
# When installed, always use ProgramData as base to avoid 8.3 short
# name issues (e.g. C:\Users\USURIO~2) with accented usernames.
$currentExe  = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$isInstalled = $currentExe -like "*ProgramData*" -or (Test-Path $INSTALL_PATH)

if ($isInstalled) {
    # Production: use ProgramData regardless of module state
    $Global:AssetsPath = Join-Path $ProgramDataPath "assets"
    $LocalModulePath   = if ($hasModulesInPgData) { $pgDataModules } else { $localModules }
    Set-Location $ProgramDataPath
} else {
    # Development: use script folder
    $Global:AssetsPath = Join-Path $ScriptPath "assets"
    $LocalModulePath   = $localModules
    Set-Location $ScriptPath
}

# ==============================================================
# BOOTSTRAP - Load priority modules
# language.psm1 and logging.psm1 are embedded directly in
# main.ps1 so they are ALWAYS available regardless of whether
# ProgramData\modules\ exists or not.
# This fixes the "path not found" error on first install when
# the modules folder hasn't been created yet by auto-update.
# After auto-update runs, ALL modules are reloaded from GitHub.
# ==============================================================
Add-Type -AssemblyName System.Windows.Forms

# Try loading from disk first (faster, uses cached version)
# Both modules must exist for disk load to be considered successful
$langPath = Join-Path $LocalModulePath "language.psm1"
$logPath  = Join-Path $LocalModulePath "logging.psm1"
$bootstrapLoaded = $false

if ((Test-Path $langPath) -and (Test-Path $logPath)) {
    try {
        Import-Module $langPath -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop
        Import-Module $logPath  -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop
        $bootstrapLoaded = $true
    } catch {
        $bootstrapLoaded = $false
    }
}

# If disk load failed, load embedded bootstrap modules
# These are compiled into the .exe and always available
if (-not $bootstrapLoaded) {
    try {
        # Embedded language.psm1 - dot-source directly from string
        $embeddedLang = {# ==============================================================
# language.psm1 - All user-visible text strings (PT and EN)
# ==============================================================
# WHAT THIS MODULE DOES:
#   Stores every string shown to the user in a nested hashtable.
#   Get-Text "KeyName" returns the string for the current language.
#   The language is set in main.ps1 via the selection dialog.
#
# STRUCTURE:
#   $Global:Texts = @{
#     PT = @{ "KeyName" = "Portuguese text" }
#     EN = @{ "KeyName" = "English text"    }
#   }
#
# KEY CATEGORIES:
#   UI.Menu.N    - Sidebar button labels (N = action number 1-13)
#   UI.Title.N   - Content area title shown when button is selected
#   UI.Desc.N    - Content area description shown when button is selected
#   UI.SectionX  - Sidebar section header labels (Comm/Prod/Sistema)
#   Step.App.*   - Progress step labels for app restart actions
#   Step.Clean.* - Progress step labels for cache cleanup (action 5)
#   Step.Net.*   - Progress step labels for network diagnostic (action 12)
#   Step.Diag.*  - Progress step labels for PC diagnostic (action 13)
#   AppClosing   - "Closing X..." messages used in Barra-Progresso calls
#   AppStarting  - "Starting X..." messages used in Barra-Progresso calls
#   System.*     - Strings used in system.psm1 result windows
#   Email*       - Strings for the support ticket email body

function Get-Text {
    param([string]$Key)
    $lang = if ($Global:Language) { $Global:Language } else { "PT" }
    if ($Global:Texts -and $Global:Texts[$lang] -and $Global:Texts[$lang][$Key]) {
        return $Global:Texts[$lang][$Key]
    }
    return $Key
}

$Global:Texts = @{
    PT = @{
        MenuTitle   = "AGENTE TI - SUPORTE"
        MenuIntro   = "Se voce esta tendo problemas no computador, temos algumas opcoes automatizadas que podem ajudar."
        MenuChoose  = "Selecione o numero correspondente ao problema e pressione ENTER."
        MenuOptions = "Opcoes disponiveis:"
        OptionExit  = "0 - Sair"
        VoltarMenu  = "Pressione ENTER ou B para voltar ao menu..."
        ResolvidoTitulo = "Agente TI"
        ResolvidoTexto  = "Uma correcao automatica foi executada.`n`nO problema foi resolvido?`n`n- Clique em Resolvido para voltar ao menu.`n- Clique em Nao Resolvido para abrir um chamado."
        BtnResolvido    = "Resolvido - Voltar ao Menu"
        BtnNaoResolvido = "Nao Resolvido - Abrir Chamado"
        DriverTitulo    = "Atualizacao de Driver Wi-Fi Necessaria"
        DriverTexto     = "Seu driver Wi-Fi esta desatualizado.`n`nO download foi iniciado.`nA equipe de TI deve concluir a instalacao.`n`nClique abaixo para abrir o chamado."
        BtnAbrirTicket  = "Abrir Chamado"
        EmailSubject         = "Execucao de Auto-Correcao"
        EmailGreeting        = "Ola Equipe de TI,"
        EmailEquipInfo       = "Informacoes do equipamento:"
        EmailUser            = "Usuario:"
        EmailMachine         = "Maquina:"
        EmailThanks          = "Obrigado."
        EmailExecuted        = "Executei a funcao:"
        EmailPersist         = "Porem, o problema ainda persiste."
        EmailSupport         = "Por favor, auxilie com o suporte adicional."
        EmailUnknownFunction = "Funcao nao identificada"
        LogoTitle            = "Agent IT"

        # === Sidebar menu labels (N matches action number in switch) ===
        "UI.Menu.1"  = "Microsoft Teams"
        "UI.Menu.2"  = "Outlook"
        "UI.Menu.3"  = "Google Drive"
        "UI.Menu.4"  = "Slack"
        "UI.Menu.5"  = "Limpeza de Cache"
        "UI.Menu.6"  = "Zoom"
        "UI.Menu.7"  = "OneDrive"
        "UI.Menu.8"  = "Google Chrome"
        "UI.Menu.9"  = "Cisco Webex"
        "UI.Menu.10" = "WhatsApp"
        "UI.Menu.11" = "Dropbox"
        "UI.Menu.12" = "Diagnostico de Rede"
        "UI.Menu.13" = "Diagnostico do PC"
        "UI.Menu.14" = "Otimizar Registro"
        "UI.Title.1" = "Microsoft Teams"
        "UI.Title.2" = "Microsoft Outlook"
        "UI.Title.3" = "Google Drive"
        "UI.Title.4" = "Slack"
        "UI.Title.5" = "Limpeza de Cache"
        "UI.Title.6" = "Zoom"
        "UI.Title.7" = "OneDrive"
        "UI.Title.8" = "Google Chrome"
        "UI.Title.9" = "Cisco Webex"
        "UI.Title.10"= "WhatsApp Desktop"
        "UI.Title.11"= "Dropbox"
        "UI.Title.12"= "Diagnostico de Rede"
        "UI.Title.13"= "Diagnostico do PC"
        "UI.Title.14"= "Otimizar Registro HKCU"
        "UI.Desc.1"  = "Encerra e reinicia o Teams. Corrige chamadas, status e carregamento."
        "UI.Desc.2"  = "Fecha e reinicia Outlook. Corrige sincronizacao e problemas de inicializacao."
        "UI.Desc.3"  = "Reinicia Google Drive File Stream. Corrige arquivos que nao sincronizam."
        "UI.Desc.4"  = "Reinicia Slack. Corrige notificacoes e mensagens que nao carregam."
        "UI.Desc.5"  = "Limpa arquivos temporarios, cache do navegador e lixeira."
        "UI.Desc.6"  = "Encerra e reinicia Zoom. Corrige audio, video e problemas de conexao."
        "UI.Desc.7"  = "Reinicia OneDrive. Corrige sincronizacao de arquivos com o servidor."
        "UI.Desc.8"  = "Reinicia Chrome e limpa cache. Corrige lentidao e erros de carregamento."
        "UI.Desc.9"  = "Encerra e reinicia Webex. Corrige audio, video e erros de reuniao."
        "UI.Desc.10" = "Reinicia WhatsApp Desktop. Corrige mensagens que nao carregam."
        "UI.Desc.11" = "Reinicia Dropbox. Corrige sincronizacao de arquivos."
        "UI.Desc.12" = "Testa latencia, DNS e driver Wi-Fi. Repara automaticamente se possivel."
        "UI.Desc.13" = "Mostra CPU, RAM, disco, saude do PC e tempo de atividade."
        "UI.Desc.14" = "Limpa entradas MRU, chaves orfas e variaveis temporarias do registro de usuario."
        "UI.SectionComm"  = "COMUNICACAO"
        "UI.SectionProd"  = "PRODUTIVIDADE"
        "UI.SectionApps"  = "APLICATIVOS"
        # === Progress step labels (displayed below the donut during execution) ===
        "Step.App.Close"      = "Fechando aplicativo..."
        "Step.Waiting"        = "Aguardando..."
        "Step.App.Start"      = "Iniciando aplicativo..."
        "Step.Clean.Scan"     = "Verificando cache..."
        "Step.Clean.Apps"     = "Fechando aplicativos..."
        "Step.Clean.Temp"     = "Limpando temporarios..."
        "Step.Clean.Browser"  = "Limpando cache do navegador..."
        "Step.Clean.Recycle"  = "Esvaziando lixeira..."
        "Step.Net.Interface"  = "Detectando interface..."
        "Step.Net.Latency"    = "Testando latencia..."
        "Step.Net.DNS"        = "Testando DNS..."
        "Step.Net.Repair"     = "Executando reparo automatico..."
        "Step.Net.Wifi"       = "Verificando driver Wi-Fi..."
        "Step.Diag.SysInfo"   = "Coletando informacoes do sistema..."
        "Step.Diag.CPU"       = "Lendo uso de CPU..."
        "Step.Diag.RAM"       = "Lendo memoria RAM..."
        "Step.Diag.Disk"      = "Lendo disco..."
        "Step.Diag.Health"    = "Calculando health score..."
        "Step.Diag.Uptime"    = "Verificando tempo de atividade..."
        "Step.Reg.Scan"   = "Escaneando registro HKCU..."
        "Step.Reg.MRU"    = "Limpando listas de recentes (MRU)..."
        "Step.Reg.Orphan" = "Removendo chaves orfas de apps..."
        "Step.Reg.Temp"   = "Limpando variaveis temporarias..."
        "Step.Reg.Done"   = "Registro otimizado!"
        "UI.SectionSys"   = "SISTEMA"
        "UI.BtnViewLog"   = "Ver Log"
        "UI.Selected"     = "Selecionado"
    }
    EN = @{
        MenuTitle   = "IT SELF-HEALING SUPPORT"
        MenuIntro   = "If you are experiencing issues on your computer, we have some automated options that may help."
        MenuChoose  = "Select the number corresponding to the issue and press ENTER."
        MenuOptions = "Available options:"
        OptionExit  = "0 - Exit"
        VoltarMenu  = "Press ENTER or B to return to menu..."
        ResolvidoTitulo = "Agent IT"
        ResolvidoTexto  = "An automatic correction was executed.`n`nWas the issue resolved?`n`n- Click Resolved to return to menu.`n- Click Not Resolved to open a ticket."
        BtnResolvido    = "Resolved - Return to Menu"
        BtnNaoResolvido = "Not Resolved - Open Ticket"
        DriverTitulo    = "Wi-Fi Driver Update Required"
        DriverTexto     = "Your Wi-Fi driver is outdated.`n`nThe download has started.`nThe IT team must complete the installation.`n`nClick below to open the ticket."
        BtnAbrirTicket  = "Open Ticket"
        EmailSubject         = "Self-Healing Execution"
        EmailGreeting        = "Hello IT Team,"
        EmailEquipInfo       = "Device information:"
        EmailUser            = "User:"
        EmailMachine         = "Machine:"
        EmailThanks          = "Thank you."
        EmailExecuted        = "I executed the function:"
        EmailPersist         = "However, the issue still persists."
        EmailSupport         = "Please assist with further troubleshooting."
        EmailUnknownFunction = "Function not identified"
        LogoTitle            = "Agent IT"
        ChooseOption = "Choose an option"
        AppNotFound     = "Application not found on this computer."
        "NetworkRepairTitle"        = "INTERNET DIAGNOSTICS AND REPAIR"
        "TestingLatency"            = "Testing latency..."
        "TestingDNS"                = "Testing DNS..."
        "NetworkResult"             = "RESULT"
        "AutoFixTitle"              = "AUTO CORRECTION"
        "NetworkProblemDetected"    = "Issue detected. Running basic repairs..."
        "RepairsApplied"            = "Repairs applied."
        "InternetNormal"            = "Internet appears normal."
        "WifiCheckingTitle"         = "CHECKING WIFI DRIVER"
        "WifiNotFound"              = "WiFi adapter not found."
        "WifiDriverNotFound"        = "Unable to locate WiFi driver."
        "WifiOutdated"              = "WIFI DRIVER OUTDATED!"
        "WifiDriverOK"              = "WiFi driver is up to date."
        "DiagTitle"                 = "PC DIAGNOSTIC"
        "DiagOS"                    = "Operating System:"
        "DiagProcessor"             = "Processor:"
        "DiagRAM"                   = "RAM:"
        "DiagDisk"                  = "Disk (C:):"
        "DiagUptime"                = "Uptime:"
        "DiagDays"                  = "days"
        "DiagHours"                 = "hours"
        "DiagMinutes"               = "minutes"
        "DiagCPUUsage"              = "CPU Usage:"
        "DiagRAMUsage"              = "RAM Usage:"
        "DiagDiskUsage"             = "Disk Usage:"
        "DiagHealthScore"           = "Health Score:"
        "DiagHealthGood"            = "Good"
        "DiagHealthWarning"         = "Warning"
        "DiagHealthCritical"        = "Critical"
        "UI.Menu.1"  = "Microsoft Teams"
        "UI.Menu.2"  = "Outlook"
        "UI.Menu.3"  = "Google Drive"
        "UI.Menu.4"  = "Slack"
        "UI.Menu.5"  = "Cache Cleanup"
        "UI.Menu.6"  = "Zoom"
        "UI.Menu.7"  = "OneDrive"
        "UI.Menu.8"  = "Google Chrome"
        "UI.Menu.9"  = "Cisco Webex"
        "UI.Menu.10" = "WhatsApp"
        "UI.Menu.11" = "Dropbox"
        "UI.Menu.12" = "Network Diagnostic"
        "UI.Menu.13" = "PC Diagnostic"
        "UI.Menu.14" = "Optimize Registry"
        "UI.Title.1" = "Microsoft Teams"
        "UI.Title.2" = "Microsoft Outlook"
        "UI.Title.3" = "Google Drive"
        "UI.Title.4" = "Slack"
        "UI.Title.5" = "Cache Cleanup"
        "UI.Title.6" = "Zoom"
        "UI.Title.7" = "OneDrive"
        "UI.Title.8" = "Google Chrome"
        "UI.Title.9" = "Cisco Webex"
        "UI.Title.10"= "WhatsApp Desktop"
        "UI.Title.11"= "Dropbox"
        "UI.Title.12"= "Network Diagnostic"
        "UI.Title.13"= "PC Diagnostic"
        "UI.Title.14"= "Optimize Registry (HKCU)"
        "UI.Desc.1"  = "Closes and restarts Teams. Fixes calls, status and loading issues."
        "UI.Desc.2"  = "Closes and restarts Outlook. Fixes sync and startup issues."
        "UI.Desc.3"  = "Restarts Google Drive File Stream. Fixes files that won't sync."
        "UI.Desc.4"  = "Restarts Slack. Fixes notifications and messages not loading."
        "UI.Desc.5"  = "Clears temp files, browser cache and recycle bin."
        "UI.Desc.6"  = "Closes and restarts Zoom. Fixes audio, video and connection issues."
        "UI.Desc.7"  = "Restarts OneDrive. Fixes file sync with server."
        "UI.Desc.8"  = "Restarts Chrome and clears cache. Fixes slowness and loading errors."
        "UI.Desc.9"  = "Closes and restarts Webex. Fixes audio, video and meeting errors."
        "UI.Desc.10" = "Restarts WhatsApp Desktop. Fixes messages not loading."
        "UI.Desc.11" = "Restarts Dropbox. Fixes file sync issues."
        "UI.Desc.12" = "Tests latency, DNS and Wi-Fi driver. Auto-repairs if possible."
        "UI.Desc.13" = "Shows CPU, RAM, disk, PC health and uptime."
        "UI.Desc.14" = "Clears MRU entries, orphan keys and temp registry variables."
        "UI.SectionComm"  = "COMMUNICATION"
        "UI.SectionProd"  = "PRODUCTIVITY"
        "UI.SectionApps"  = "APPLICATIONS"
        "Step.App.Close"      = "Closing application..."
        "Step.Waiting"        = "Waiting..."
        "Step.App.Start"      = "Starting application..."
        "Step.Clean.Scan"     = "Scanning cache..."
        "Step.Clean.Apps"     = "Closing applications..."
        "Step.Clean.Temp"     = "Clearing temp files..."
        "Step.Clean.Browser"  = "Clearing browser cache..."
        "Step.Clean.Recycle"  = "Emptying recycle bin..."
        "Step.Net.Interface"  = "Detecting interface..."
        "Step.Net.Latency"    = "Testing latency..."
        "Step.Net.DNS"        = "Testing DNS..."
        "Step.Net.Repair"     = "Running auto repair..."
        "Step.Net.Wifi"       = "Checking Wi-Fi driver..."
        "Step.Diag.SysInfo"   = "Collecting system information..."
        "Step.Diag.CPU"       = "Reading CPU usage..."
        "Step.Diag.RAM"       = "Reading RAM usage..."
        "Step.Diag.Disk"      = "Reading disk usage..."
        "Step.Diag.Health"    = "Calculating health score..."
        "Step.Diag.Uptime"    = "Checking uptime..."
        "Step.Reg.Scan"   = "Scanning HKCU registry..."
        "Step.Reg.MRU"    = "Clearing MRU lists..."
        "Step.Reg.Orphan" = "Removing orphan app keys..."
        "Step.Reg.Temp"   = "Clearing temp variables..."
        "Step.Reg.Done"   = "Registry optimized!"
        "UI.SectionSys"   = "SYSTEM"
        "UI.BtnViewLog"   = "View Log"
        "UI.Selected"     = "Selected"
    }
}

Export-ModuleMember -Function Get-Text
}

        $tempLangPath = Join-Path $env:TEMP "lang_bootstrap_$(Get-Random).psm1"
        [System.IO.File]::WriteAllText($tempLangPath, $embeddedLang.ToString(), [System.Text.Encoding]::UTF8)
        Import-Module $tempLangPath -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop
        Remove-Item $tempLangPath -Force -ErrorAction SilentlyContinue

        # Embedded logging.psm1 - minimal bootstrap version (local log only)
        $embeddedLog = {
function Escrever-Log {
    param(
        [string]$Mensagem,
        [string]$FunctionName,
        [string]$Action,
        [string]$Status = "INFO",
        [string]$Details,
        [string]$Application
    )
    $pastaLog = "C:\IT Support Agent\Logs"
    if (!(Test-Path $pastaLog)) { New-Item -ItemType Directory -Path $pastaLog | Out-Null }
    $arquivoLog = "$pastaLog\Log_$(Get-Date -Format yyyy-MM-dd).txt"
    $dataHora   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linhaLog   = "[$dataHora] [$($env:COMPUTERNAME)] [$($env:USERNAME)] $Mensagem"
    Add-Content -Path $arquivoLog -Value $linhaLog -Encoding UTF8 -ErrorAction SilentlyContinue
}
Export-ModuleMember -Function Escrever-Log
}
        $tempLogPath = Join-Path $env:TEMP "log_bootstrap_$(Get-Random).psm1"
        [System.IO.File]::WriteAllText($tempLogPath, $embeddedLog.ToString(), [System.Text.Encoding]::UTF8)
        Import-Module $tempLogPath -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop
        Remove-Item $tempLogPath -Force -ErrorAction SilentlyContinue

    } catch {
        # Bootstrap failed - show a minimal error and exit
        [System.Windows.Forms.MessageBox]::Show(
            "Erro critico ao inicializar.`nContate o suporte de TI.`n`nCritical initialization error.`nPlease contact IT support.",
            "Agent IT",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit
    }
}

Escrever-Log -Mensagem "=== INICIO Agent IT ===" -FunctionName "MAIN"

# ==============================================================
# SECURITY - TLS PROTOCOL ENFORCEMENT
#
# Force TLS 1.2 minimum for all HTTPS requests in this process.
# This prevents downgrade attacks to older, vulnerable protocols
# (SSL3, TLS 1.0, TLS 1.1).
#
# NOTE: We do NOT set a global ServerCertificateValidationCallback
# because that would apply to ALL requests including GitHub module
# downloads - causing silent failures if any cert in the chain
# has a minor issue.
# ==============================================================
[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.SecurityProtocolType]::Tls12 -bor `
    [System.Net.SecurityProtocolType]::Tls13

# ==============================================================
# CHECK FOR UPDATES
# Call Supabase Edge Function to get the current version and
# signed GitHub download URLs for all modules.
#
# SUCCESS: returns { version, module_urls }
# NETWORK ERROR: skip update, use existing modules (version.txt unchanged)
# ==============================================================
$updateCheckResult = $null

try {
    # FIX (v1.2.2): Edge Functions do Supabase exigem "Authorization: Bearer"
    # (verificacao de JWT feita pelo proprio portao de entrada do Supabase,
    # antes mesmo do codigo da funcao rodar) - so "apikey" sozinho retorna
    # 401 Unauthorized. A anon key JA E um JWT valido (role=anon), entao
    # serve para os dois cabecalhos.
    $updateCheckResult = Invoke-RestMethod `
        -Uri         $SUPABASE_URL `
        -Method      Post `
        -Body        '{}' `
        -ContentType "application/json" `
        -Headers     @{ "apikey" = $SUPABASE_ANON; "Authorization" = "Bearer $SUPABASE_ANON" } `
        -TimeoutSec  10 `
        -ErrorAction Stop

} catch {
    # Network error or Supabase unreachable - skip update silently
    # App will load from the previously downloaded version
    $updateCheckResult = $null
}

# ==============================================================
# AUTO-UPDATE WITH IN-MEMORY MODULE LOADING
#
# HOW IT WORKS:
#   1. Edge Function returns the latest version number
#   2. If different from local version.txt, update is needed
#   3. Edge Function also returns signed GitHub URLs (with token)
#      The GitHub PAT is stored as a Supabase secret - never here
#   4. Each module is downloaded as Base64 encoded content
#   5. Decoded in memory and stored for loading
#   6. Nothing is written to disk permanently
#
# FALLBACK:
#   If update fails, loads from local folder (development)
#   or from previously cached version if available
# ==============================================================
$Global:ModulesInMemory = @{}
$updateNeeded  = $false
$latestVersion = "0.0.0"

if ($null -ne $updateCheckResult -and $updateCheckResult.version) {
    $latestVersion = $updateCheckResult.version
    $localVersion  = "0.0.0"

    if (Test-Path $VERSION_FILE) {
        $localVersion = (Get-Content $VERSION_FILE -Raw -ErrorAction SilentlyContinue).Trim()
    }

    $updateNeeded = ($latestVersion -ne $localVersion)
}

if ($updateNeeded) {
    # Show minimal update notification to user
    $updateForm               = New-Object System.Windows.Forms.Form
    $updateForm.Text          = "Agent IT"
    $updateForm.Width         = 380
    $updateForm.Height        = 120
    $updateForm.StartPosition = "CenterScreen"
    $updateForm.BackColor     = [System.Drawing.Color]::FromArgb(26, 10, 46)
    $updateForm.FormBorderStyle = "FixedDialog"
    $updateLbl                = New-Object System.Windows.Forms.Label
    $updateLbl.Text           = "Atualizando para v$latestVersion ..."
    $updateLbl.ForeColor      = [System.Drawing.Color]::FromArgb(45, 247, 185)
    $updateLbl.Font           = "Segoe UI, 11"
    $updateLbl.AutoSize       = $true
    $updateLbl.Location       = [System.Drawing.Point]::new(24, 36)
    $updateForm.Controls.Add($updateLbl)
    $updateForm.Show()
    [System.Windows.Forms.Application]::DoEvents()

    # Module list to download - order matters for dependencies
    $moduleNames = @("language.psm1","logging.psm1","apps.psm1","network.psm1","system.psm1","ui.psm1")
    $updateOk    = $true

    foreach ($modName in $moduleNames) {
        try {
            # Get signed URL from Edge Function response
            # Falls back to direct GitHub URL if not provided (development)
            if ($updateCheckResult.PSObject.Properties["module_urls"] -and
                $updateCheckResult.module_urls.PSObject.Properties[$modName]) {
                $downloadUrl = $updateCheckResult.module_urls.$modName
            } else {
                # ==================================================
                # !! CONFIGURAR: URL base do repositorio GitHub da empresa !!
                # Formato: https://raw.githubusercontent.com/EMPRESA/REPO/main/modules/
                # Apenas para repos publicos - repos privados exigem a Edge Function
                # ==================================================
                $downloadUrl = "https://raw.githubusercontent.com/EMPRESA/REPOSITORIO/main/modules/$modName"
            }

            # Build headers with auth token if present in URL
            $headers  = @{ "User-Agent" = "AgentIT/1.0.0" }
            $cleanUrl = $downloadUrl
            $moduleContent = $null

            # Extract token from URL (?token=ghp_xxx or ?ref=main&token=ghp_xxx)
            if ($downloadUrl -match "[?&]token=([^&]+)") {
                $ghToken  = $Matches[1]
                $headers["Authorization"] = "token $ghToken"
                # Remove token from URL - goes in header instead
                $cleanUrl = $downloadUrl -replace "[?&]token=[^&]+", "" -replace "[?&]$", "" -replace "\?&", "?"
                if ($cleanUrl -match "[?]$") { $cleanUrl = $cleanUrl -replace "[?]$", "" }
            }

            # GitHub API URL (/contents/) returns JSON with base64 content
            # GitHub raw URL (raw.githubusercontent.com) returns content directly
            if ($cleanUrl -match "api\.github\.com.*contents") {
                # GitHub API - parse JSON response and base64-decode content
                $apiResponse   = Invoke-WebRequest `
                    -Uri             $cleanUrl `
                    -Headers         $headers `
                    -UseBasicParsing `
                    -ErrorAction     Stop

                $apiJson       = $apiResponse.Content | ConvertFrom-Json
                $base64Clean   = $apiJson.content -replace "`n", "" -replace "`r", ""
                $decodedBytes  = [System.Convert]::FromBase64String($base64Clean)
                $moduleContent = [System.Text.Encoding]::UTF8.GetString($decodedBytes)

            } else {
                # Raw URL - download content directly
                $response = Invoke-WebRequest `
                    -Uri             $cleanUrl `
                    -Headers         $headers `
                    -UseBasicParsing `
                    -ErrorAction     Stop

                if ($response.Content -is [byte[]]) {
                    $moduleContent = [System.Text.Encoding]::UTF8.GetString($response.Content)
                } else {
                    $moduleContent = $response.Content
                }
            }

            $Global:ModulesInMemory[$modName] = $moduleContent

        } catch {
            $updateOk = $false
            break
        }
    }

    # Close update form safely
    try { $updateForm.Close() } catch {}

    # Save version.txt ONLY if ALL modules were downloaded successfully.
    # Partial download must NOT update version.txt - forces retry next startup.
    #
    # FIX (v1.2.4): escrita agora protegida por try/catch. Antes, se a
    # pasta nao tivesse permissao de escrita para o usuario comum (bug
    # de ACL corrigido no install.ps1 - ver comentario la), este
    # Set-Content lancava um erro nao tratado, travando o app com uma
    # tela de erro visivel para o usuario. Agora, se a escrita falhar
    # por qualquer motivo, o app simplesmente continua normalmente -
    # o unico efeito colateral e checar a atualizacao de novo na
    # proxima abertura, em vez de lembrar que ja atualizou.
    $modulesDownloaded = $Global:ModulesInMemory.Count
    if ($modulesDownloaded -eq $moduleNames.Count) {
        try {
            if (-not (Test-Path $INSTALL_PATH)) {
                New-Item -ItemType Directory -Path $INSTALL_PATH -Force | Out-Null
            }
            Set-Content -Path $VERSION_FILE -Value $latestVersion -Encoding UTF8 -ErrorAction Stop
        } catch {
            # Nao trava o app - so significa que vai checar de novo
            # na proxima abertura. Ver FIX (v1.2.4) acima.
        }
    }

    # If download was incomplete, clear memory and use local files
    if (-not $updateOk) {
        $Global:ModulesInMemory = @{}
    }
}

# ==============================================================
# LOAD ALL MODULES
#
# Priority order (dependencies must load first):
#   1. language.psm1  - Get-Text function
#   2. logging.psm1   - Escrever-Log function
#   3. apps.psm1      - App restart functions
#   4. network.psm1   - Network diagnostic
#   5. system.psm1    - PC diagnostic and cleanup
#   6. ui.psm1        - WPF interface (loads last - needs all others)
#
# Downloaded modules are written to a hidden temp folder with a
# random name, loaded, then immediately deleted from disk.
# The window of exposure is milliseconds.
# ==============================================================
$loadOrder = @("language.psm1","logging.psm1","apps.psm1","network.psm1","system.psm1","ui.psm1")

$tempBase   = if ($isInstalled) { $ProgramDataPath } else { $env:TEMP }
$tempFolder = Join-Path $tempBase ("ITAgent_" + [System.Guid]::NewGuid().ToString("N"))

try {
    # FIX (v1.2.5): antes, se um modulo falhasse no download E nao
    # existisse localmente (caso normal de uma instalacao via Intune,
    # que nunca tem uma pasta modules\ local), o codigo simplesmente
    # NAO CARREGAVA o modulo, sem avisar nada aqui. O app so quebrava
    # bem mais tarde, com erros confusos tipo "Launch-MainWindow is
    # not recognized" - sem nenhuma pista do que realmente aconteceu.
    # Agora rastreamos cada falha e mostramos um erro claro e acionavel
    # assim que o carregamento termina, antes de qualquer outra coisa
    # tentar rodar.
    $failedModules = @()

    foreach ($modName in $loadOrder) {

        if ($Global:ModulesInMemory.ContainsKey($modName) -and
            -not [string]::IsNullOrEmpty($Global:ModulesInMemory[$modName])) {

            if (-not (Test-Path $tempFolder)) {
                New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
                (Get-Item $tempFolder).Attributes = "Hidden"
            }

            $tempFile = Join-Path $tempFolder $modName
            [System.IO.File]::WriteAllText($tempFile, $Global:ModulesInMemory[$modName],
                [System.Text.Encoding]::UTF8)

            Import-Module $tempFile -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop

            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

        } else {
            # Fallback to local file (development mode, ou instalacao
            # via Intune que inclui uma copia local - ver install.ps1)
            $localPath = Join-Path $LocalModulePath $modName
            if (Test-Path $localPath) {
                Import-Module $localPath -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop
            } else {
                # Nem o download nem o fallback local funcionaram para
                # este modulo - registra para avisar o usuario a seguir
                $failedModules += $modName
            }
        }
    }

    if ($failedModules.Count -gt 0) {
        Add-Type -AssemblyName System.Windows.Forms
        $listaModulos = $failedModules -join "`n  - "
        [System.Windows.Forms.MessageBox]::Show(
            "Nao foi possivel carregar os seguintes componentes do Agent IT:`n`n  - $listaModulos`n`n" +
            "Isso geralmente acontece por instabilidade de rede/internet no momento da abertura.`n`n" +
            "Feche e abra o Agent IT novamente. Se o problema persistir, contate o suporte de TI.",
            "Agent IT - Falha ao Carregar",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit
    }

} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Erro ao carregar modulos:`n$_",
        "Agent IT - Erro",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit
} finally {
    # Always clean up temp folder and clear memory - no traces left
    if (Test-Path $tempFolder) {
        Remove-Item $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Global:ModulesInMemory = @{}
}

# ==============================================================
# DESKTOP SHORTCUT
# Creates a shortcut on the public desktop (visible to all users)
# pointing to the current executable.
# Only creates if shortcut doesn't already exist.
# ==============================================================
try {
    $currentExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $currentDir = Split-Path $currentExe -Parent

    if ($currentExe -like "*powershell*" -or $currentExe -like "*pwsh*") {
        $exePath = Join-Path $ScriptPath "AgentIT.exe"
    } else {
        $exePath = $currentExe
    }

    if (Test-Path $exePath) {
        $desktop  = [Environment]::GetFolderPath("CommonDesktopDirectory")
        $shortcut = Join-Path $desktop "Agent IT.lnk"

        if (-not (Test-Path $shortcut)) {
            $wsh = New-Object -ComObject WScript.Shell
            $lnk = $wsh.CreateShortcut($shortcut)
            $lnk.TargetPath       = $exePath
            $lnk.WorkingDirectory = Split-Path $exePath -Parent
            $lnk.Description      = "Agent IT - Suporte Corporativo"
            $icoPath = Join-Path $ScriptPath "icon.ico"
            if (Test-Path $icoPath) { $lnk.IconLocation = $icoPath }
            $lnk.Save()
        }
    }
} catch {
    # Silently ignore - shortcut is a convenience, not required
}

# ==============================================================
# LANGUAGE SELECTION DIALOG
# ==============================================================
$langForm                 = New-Object System.Windows.Forms.Form
$langForm.Text            = "Agent IT"
$langForm.Width           = 340
$langForm.Height          = 180
$langForm.StartPosition   = "CenterScreen"
$langForm.BackColor       = [System.Drawing.Color]::FromArgb(26, 10, 46)
$langForm.FormBorderStyle = "FixedDialog"
$langForm.MaximizeBox     = $false

$lbl           = New-Object System.Windows.Forms.Label
$lbl.Text      = "Select Language / Selecione o Idioma"
$lbl.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$lbl.Font      = "Segoe UI, 10"
$lbl.AutoSize  = $true
$lbl.Location  = [System.Drawing.Point]::new(24, 20)
$langForm.Controls.Add($lbl)

$btnColor    = [System.Drawing.Color]::FromArgb(110, 39, 122)
$btnColorHov = [System.Drawing.Color]::FromArgb(142, 58, 154)

$btnPT           = New-Object System.Windows.Forms.Button
$btnPT.Text      = "Portugues Brasil"
$btnPT.Width     = 130
$btnPT.Height    = 40
$btnPT.Location  = [System.Drawing.Point]::new(24, 60)
$btnPT.BackColor = $btnColor
$btnPT.ForeColor = [System.Drawing.Color]::White
$btnPT.FlatStyle = "Flat"
$btnPT.FlatAppearance.BorderSize = 0
$btnPT.Add_MouseEnter({ $btnPT.BackColor = $btnColorHov })
$btnPT.Add_MouseLeave({ $btnPT.BackColor = $btnColor })
$btnPT.Add_Click({ $Global:Language = "PT"; $langForm.Close() })
$langForm.Controls.Add($btnPT)

$btnEN           = New-Object System.Windows.Forms.Button
$btnEN.Text      = "English"
$btnEN.Width     = 130
$btnEN.Height    = 40
$btnEN.Location  = [System.Drawing.Point]::new(168, 60)
$btnEN.BackColor = $btnColor
$btnEN.ForeColor = [System.Drawing.Color]::White
$btnEN.FlatStyle = "Flat"
$btnEN.FlatAppearance.BorderSize = 0
$btnEN.Add_MouseEnter({ $btnEN.BackColor = $btnColorHov })
$btnEN.Add_MouseLeave({ $btnEN.BackColor = $btnColor })
$btnEN.Add_Click({ $Global:Language = "EN"; $langForm.Close() })
$langForm.Controls.Add($btnEN)

$Global:Language = $null
$langForm.ShowDialog() | Out-Null

if ($null -eq $Global:Language) {
    [Environment]::Exit(0)
}

# ==============================================================
# SPLASH SCREEN
# ==============================================================
Mostrar-Logo

# ==============================================================
# MAIN WPF WINDOW
# Blocking call - returns only when user closes the app.
# ==============================================================
Launch-MainWindow

[Environment]::Exit(0)
