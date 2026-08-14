# ==============================================================
# gerar-licenca.ps1 - Gerador de licencas por cliente
# ==============================================================
# WHAT THIS DOES:
#   Script administrativo que voce roda na SUA maquina quando
#   fechar um novo contrato. Ele faz 3 coisas automaticamente:
#
#   1. Gera um token unico para o cliente
#   2. Insere o cliente no Supabase (tabela companies)
#   3. Gera um install.ps1 personalizado com o token do cliente
#      pronto para empacotar no Intune ou enviar ao IT do cliente
#
# COMO USAR:
#   1. Abra o PowerShell como Administrador
#   2. cd "C:\IT Support V3"
#   3. .\gerar-licenca.ps1
#   4. Preencha as informacoes do cliente quando solicitado
#   5. O install.ps1 personalizado sera salvo em:
#      C:\IT Support V3\Licencas\NomeEmpresa\install.ps1
#
# O QUE VOCE ENTREGA AO CLIENTE:
#   A pasta gerada em Licencas\NomeEmpresa\ contem:
#   - install.ps1   (com o token ja dentro)
#   - AgenteTI.exe  (copiado automaticamente)
#   - assets\       (logo e icone)
#   - uninstall.ps1
#
#   O IT do cliente executa o install.ps1 como admin
#   (ou voce empacota como .intunewin para Intune)
#
# DEPENDENCIAS:
#   Requer conexao com internet para inserir no Supabase
#   PowerShell 5+ (nao precisa de modulos extras)
#
# SEGURANCA:
#   O token gerado e unico por empresa - se vazar, voce pode
#   desativar so aquele cliente no Supabase sem afetar outros.
#   Token format: agenteti-[slug]-[random8chars]
#   Exemplo: agenteti-empresa-xyz-a8f3k2b1
# ==============================================================

Set-ExecutionPolicy Bypass -Scope Process -Force
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ==============================================================
# CONFIGURACAO - Nao mude a menos que troque de projeto Supabase
# ==============================================================
# SECURITY NOTE:
#   Este script usa a SERVICE_ROLE key para inserir no Supabase.
#   Isso e seguro porque gerar-licenca.ps1 roda APENAS na maquina
#   do administrador (voce) — nunca e distribuido ao cliente.
#   A SERVICE_ROLE bypassa o RLS — necessario para INSERT em companies.
#   NUNCA inclua esta key no AgenteTI.exe ou no install.ps1.
# ==============================================================
$SUPABASE_URL          = "https://eerqqecfumqqnqhpdkru.supabase.co"
$SUPABASE_SERVICE_ROLE = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVlcnFxZWNmdW1xcW5xaHBka3J1Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NzI0NDA1MCwiZXhwIjoyMDkyODIwMDUwfQ.Lt4lKOc5BvmUDmJoHcOahpT-8fQUhM9ENZ60EgQ2Dq0"

# ==============================================================
# HMAC SECRET — must match the value compiled into AgenteTI.exe
# This is used to sign the license.key file so that manual edits
# are detected by the app. Update this whenever you recompile
# the EXE with a new HMAC_SECRET.
# ==============================================================
$HMAC_SECRET = "AgTI-2026-S3cur3-K3y-Ch4ng3-B3f0r3-Pr0d"

# Pasta raiz do projeto (onde esta o AgenteTI.exe)
$SCRIPT_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Path
$EXE_PATH     = Join-Path $SCRIPT_DIR "AgenteTI.exe"
$ASSETS_PATH  = Join-Path $SCRIPT_DIR "assets"
$UNINSTALL_PS = Join-Path $SCRIPT_DIR "uninstall.ps1"
$OUTPUT_BASE  = Join-Path $SCRIPT_DIR "Licencas"

# ==============================================================
# CABECALHO
# ==============================================================
Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Magenta
Write-Host "   Agente TI - Gerador de Licencas por Cliente" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Magenta
Write-Host ""

# ==============================================================
# VERIFICACOES INICIAIS
# Garante que os arquivos necessarios existem antes de continuar
# ==============================================================
$erros = @()
if (-not (Test-Path $EXE_PATH)) {
    $erros += "AgenteTI.exe nao encontrado em: $EXE_PATH"
}
if (-not (Test-Path $ASSETS_PATH)) {
    $erros += "Pasta assets\ nao encontrada em: $ASSETS_PATH"
}
if ($erros.Count -gt 0) {
    Write-Host "  ERRO - Arquivos necessarios nao encontrados:" -ForegroundColor Red
    $erros | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Execute este script da pasta C:\IT Support V3\" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Pressione Enter para sair"
    exit 1
}

# ==============================================================
# COLETA DE DADOS DO CLIENTE
# ==============================================================
Write-Host "  Preencha as informacoes do novo cliente:" -ForegroundColor White
Write-Host ""

# Nome da empresa
do {
    $nomeEmpresa = Read-Host "  Nome da empresa"
    $nomeEmpresa = $nomeEmpresa.Trim()
    if ([string]::IsNullOrEmpty($nomeEmpresa)) {
        Write-Host "  Nome nao pode ser vazio." -ForegroundColor Red
    }
} while ([string]::IsNullOrEmpty($nomeEmpresa))

# Quantidade maxima de devices
do {
    $maxDevicesStr = Read-Host "  Maximo de dispositivos permitidos [default: 10]"
    if ([string]::IsNullOrEmpty($maxDevicesStr)) { $maxDevicesStr = "10" }
    $maxDevices = 0
    $validNum = [int]::TryParse($maxDevicesStr, [ref]$maxDevices)
    if (-not $validNum -or $maxDevices -lt 1) {
        Write-Host "  Digite um numero valido (minimo 1)." -ForegroundColor Red
    }
} while (-not $validNum -or $maxDevices -lt 1)

# Data de expiracao (opcional)
Write-Host ""
Write-Host "  Data de expiracao da licenca:" -ForegroundColor Gray
Write-Host "  Exemplos: 2026-12-31 | Deixe vazio para sem expiracao" -ForegroundColor Gray
$expiracaoStr = Read-Host "  Expiracao"
$expiracaoStr = $expiracaoStr.Trim()

# Valida a data se foi informada
$expiracaoISO = $null
if (-not [string]::IsNullOrEmpty($expiracaoStr)) {
    try {
        $expDate = [datetime]::ParseExact($expiracaoStr, "yyyy-MM-dd", $null)
        $expiracaoISO = $expDate.ToString("yyyy-MM-ddT00:00:00")
    } catch {
        Write-Host "  Data invalida - licenca sera criada sem expiracao." -ForegroundColor Yellow
        $expiracaoISO = $null
    }
}

# ==============================================================
# HMAC HELPER — computes SHA256 HMAC signature
# Same implementation as in main.ps1 / AgenteTI.exe
# The token written to license.key will be: "token|hmac"
# ==============================================================
function Compute-LicenseHMAC {
    param([string]$Message, [string]$Secret)
    $keyBytes  = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $msgBytes  = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $hmac      = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    $hashBytes = $hmac.ComputeHash($msgBytes)
    $hmac.Dispose()
    return ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ''
}

# ==============================================================
# GERACAO DO TOKEN
# Token unico no formato: agenteti-[slug]-[8 chars aleatorios]
# Slug = nome da empresa em lowercase, sem espacos ou especiais
# Exemplo: agenteti-empresaxyz-a8f3k2b1
# ==============================================================
# Remove caracteres especiais e espacos do nome para criar o slug
$slug = $nomeEmpresa.ToLower()
$slug = $slug -replace "[^a-z0-9]", ""

if ($slug.Length -gt 12) { $slug = $slug.Substring(0, 12) }  # Limita o tamanho

# Gera 8 caracteres aleatorios (apenas letras e numeros)
$chars  = 'abcdefghijklmnopqrstuvwxyz0123456789'
$random = -join (1..8 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
$token  = "agenteti-$slug-$random"

Write-Host ""
Write-Host "  Token gerado: " -NoNewline -ForegroundColor Gray
Write-Host $token -ForegroundColor Cyan

# ==============================================================
# CONFIRMACAO ANTES DE INSERIR NO SUPABASE
# ==============================================================
Write-Host ""
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Resumo da licenca:" -ForegroundColor White
Write-Host "   Empresa:     $nomeEmpresa" -ForegroundColor White
Write-Host "   Token:       $token" -ForegroundColor White
Write-Host "   Dispositivos: $maxDevices" -ForegroundColor White
Write-Host "   Expiracao:   $(if ($expiracaoISO) { $expiracaoStr } else { 'Sem expiracao' })" -ForegroundColor White
Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

$confirma = Read-Host "  Confirmar e inserir no Supabase? (S/N)"
if ($confirma.Trim().ToUpper() -ne "S") {
    Write-Host ""
    Write-Host "  Operacao cancelada." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Pressione Enter para sair"
    exit 0
}

# ==============================================================
# INSERIR NO SUPABASE
# Usa a REST API do Supabase para inserir na tabela companies
# O anon key tem permissao de insert na tabela companies (RLS off)
# Se precisar de seguranca extra, use service_role key aqui
# ==============================================================
Write-Host ""
Write-Host "  Inserindo no Supabase..." -ForegroundColor Gray

# Monta o body do insert
$insertBody = @{
    name        = $nomeEmpresa
    token       = $token
    max_devices = $maxDevices
    active      = $true
}

# Adiciona expiracao apenas se foi informada
if ($expiracaoISO) {
    $insertBody["expires_at"] = $expiracaoISO
}

try {
    $response = Invoke-RestMethod `
        -Uri         "$SUPABASE_URL/rest/v1/companies" `
        -Method      Post `
        -Body        ($insertBody | ConvertTo-Json) `
        -ContentType "application/json" `
        -Headers     @{
            "apikey"        = $SUPABASE_SERVICE_ROLE
            "Authorization" = "Bearer $SUPABASE_SERVICE_ROLE"
            "Prefer"        = "return=representation"
        } `
        -ErrorAction Stop

    Write-Host "  Supabase: OK - Empresa registrada com sucesso!" -ForegroundColor Green

} catch {
    Write-Host ""
    Write-Host "  ERRO ao inserir no Supabase: $_" -ForegroundColor Red
    Write-Host "  Verifique sua conexao com internet e as credenciais." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Pressione Enter para sair"
    exit 1
}

# ==============================================================
# GERAR PASTA DE ENTREGA DO CLIENTE
# Cria uma pasta com todos os arquivos necessarios para o cliente
# ja com o install.ps1 personalizado com o token correto
# ==============================================================
Write-Host "  Gerando pacote de instalacao..." -ForegroundColor Gray

# Cria nome de pasta seguro (remove caracteres invalidos)
$pastaSlug   = $nomeEmpresa -replace '[\\/:*?"<>|]', '' -replace '\s+', '_'
$outputDir   = Join-Path $OUTPUT_BASE $pastaSlug
$outputDate  = Get-Date -Format "yyyy-MM-dd"

# Cria a pasta de saida
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Copia o executavel principal
Copy-Item $EXE_PATH (Join-Path $outputDir "AgenteTI.exe") -Force

# Copia a pasta de assets (logo, icone)
if (Test-Path $ASSETS_PATH) {
    Copy-Item $ASSETS_PATH (Join-Path $outputDir "assets") -Recurse -Force
}

# Copia o uninstall.ps1 se existir
if (Test-Path $UNINSTALL_PS) {
    Copy-Item $UNINSTALL_PS (Join-Path $outputDir "uninstall.ps1") -Force
}

# Copia o icone se existir na raiz
$icoPath = Join-Path $SCRIPT_DIR "icon.ico"
if (Test-Path $icoPath) {
    Copy-Item $icoPath (Join-Path $outputDir "icon.ico") -Force
}

# ==============================================================
# GERAR install.ps1 PERSONALIZADO
# Baseado no install.ps1 padrao mas com o token do cliente
# ja preenchido automaticamente
# ==============================================================
$installContent = @"
# ==============================================================
# install.ps1 - Agente TI - Instalador para: $nomeEmpresa
# ==============================================================
# Gerado automaticamente em: $outputDate
# Token: $token
# Dispositivos: $maxDevices
# Expiracao: $(if ($expiracaoISO) { $expiracaoStr } else { 'Sem expiracao' })
#
# COMO INSTALAR:
#   Manual:  Clique direito -> Executar como Administrador
#   Intune:  powershell.exe -ExecutionPolicy Bypass -File install.ps1
#
# DETECCAO PARA INTUNE:
#   Tipo: Arquivo
#   Caminho: C:\ProgramData\IT Support Agent\AgenteTI.exe
#   Existe: Sim
# ==============================================================

# Token de licenca desta empresa - NAO ALTERAR
`$LICENSE_TOKEN = "$token"
`$LICENSE_HMAC  = "$( Compute-LicenseHMAC -Message $token -Secret $HMAC_SECRET )"
`$LICENSE_SIGNED = "`$LICENSE_TOKEN|`$LICENSE_HMAC"

# Caminhos de instalacao
`$INSTALL_DIR  = "C:\ProgramData\IT Support Agent"
`$ASSETS_DIR   = "`$INSTALL_DIR\assets"
`$DESKTOP      = [Environment]::GetFolderPath("CommonDesktopDirectory")
`$STARTMENU    = [Environment]::GetFolderPath("CommonPrograms")
`$SOURCE       = Split-Path -Parent `$MyInvocation.MyCommand.Path

# Libera execucao de scripts PowerShell na maquina
# Wrapped in try/catch - em ambientes com GPO isso pode falhar mas nao impede a instalacao
Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
try { Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction SilentlyContinue } catch {}

# Cria diretorios de instalacao
New-Item -ItemType Directory -Path `$INSTALL_DIR -Force | Out-Null
New-Item -ItemType Directory -Path `$ASSETS_DIR  -Force | Out-Null

# Copia executavel principal
Copy-Item "`$SOURCE\AgenteTI.exe" "`$INSTALL_DIR\AgenteTI.exe" -Force

# Copia assets (logo, icone)
if (Test-Path "`$SOURCE\assets") {
    Copy-Item "`$SOURCE\assets\*" `$ASSETS_DIR -Recurse -Force
}

# Copia icone para pasta raiz
if (Test-Path "`$SOURCE\icon.ico") {
    Copy-Item "`$SOURCE\icon.ico" "`$INSTALL_DIR\icon.ico" -Force
}

# Grava token de licenca assinado (token|hmac) — NAO ALTERAR
# O app verifica o HMAC na inicializacao para detectar adulteracao
Set-Content -Path "`$INSTALL_DIR\license.key" -Value `$LICENSE_SIGNED -Encoding UTF8 -Force

# Grava versao inicial como 0.0.0 para forcar auto-update no primeiro uso
Set-Content -Path "`$INSTALL_DIR\version.txt" -Value "0.0.0" -Encoding UTF8 -Force

# Copia uninstall.ps1 para permitir desinstalacao limpa
if (Test-Path "`$SOURCE\uninstall.ps1") {
    Copy-Item "`$SOURCE\uninstall.ps1" "`$INSTALL_DIR\uninstall.ps1" -Force
}

# Cria atalho na area de trabalho publica (todos os usuarios)
`$wsh      = New-Object -ComObject WScript.Shell
`$shortcut = `$wsh.CreateShortcut("`$DESKTOP\Agente TI.lnk")
`$shortcut.TargetPath       = "`$INSTALL_DIR\AgenteTI.exe"
`$shortcut.WorkingDirectory = `$INSTALL_DIR
`$shortcut.Description      = "Agente TI - Suporte Corporativo"
if (Test-Path "`$INSTALL_DIR\icon.ico") {
    `$shortcut.IconLocation = "`$INSTALL_DIR\icon.ico"
}
`$shortcut.Save()

# Cria atalho no menu iniciar
`$startShortcut = `$wsh.CreateShortcut("`$STARTMENU\Agente TI.lnk")
`$startShortcut.TargetPath       = "`$INSTALL_DIR\AgenteTI.exe"
`$startShortcut.WorkingDirectory = `$INSTALL_DIR
`$startShortcut.Description      = "Agente TI - Suporte Corporativo"
if (Test-Path "`$INSTALL_DIR\icon.ico") {
    `$startShortcut.IconLocation = "`$INSTALL_DIR\icon.ico"
}
`$startShortcut.Save()

# Registra em Programas e Recursos do Windows (aparece em Apps instalados)
`$regPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgenteTI"
New-Item -Path `$regPath -Force | Out-Null
Set-ItemProperty -Path `$regPath -Name "DisplayName"     -Value "Agente TI"
Set-ItemProperty -Path `$regPath -Name "DisplayVersion"  -Value "1.0.0"
Set-ItemProperty -Path `$regPath -Name "Publisher"       -Value "Agente TI"
Set-ItemProperty -Path `$regPath -Name "InstallLocation" -Value `$INSTALL_DIR
Set-ItemProperty -Path `$regPath -Name "UninstallString" -Value "powershell.exe -ExecutionPolicy Bypass -File ```"`$INSTALL_DIR\uninstall.ps1```""
Set-ItemProperty -Path `$regPath -Name "DisplayIcon"     -Value "`$INSTALL_DIR\AgenteTI.exe"
Set-ItemProperty -Path `$regPath -Name "NoModify"        -Value 1
Set-ItemProperty -Path `$regPath -Name "NoRepair"        -Value 1

exit 0
"@

# Salva o install.ps1 personalizado na pasta do cliente
$installPath = Join-Path $outputDir "install.ps1"
[System.IO.File]::WriteAllText($installPath, $installContent, [System.Text.Encoding]::UTF8)

# ==============================================================
# RESULTADO FINAL
# ==============================================================
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Green
Write-Host "   Licenca gerada com sucesso!" -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Empresa:  $nomeEmpresa" -ForegroundColor White
Write-Host "  Token:    $token" -ForegroundColor Cyan
Write-Host "  Devices:  $maxDevices" -ForegroundColor White
Write-Host "  Pasta:    $outputDir" -ForegroundColor White
Write-Host ""
Write-Host "  Arquivos gerados:" -ForegroundColor Gray
Write-Host "   - install.ps1   (com token do cliente)" -ForegroundColor Gray
Write-Host "   - AgenteTI.exe" -ForegroundColor Gray
Write-Host "   - uninstall.ps1" -ForegroundColor Gray
Write-Host "   - assets\" -ForegroundColor Gray
Write-Host "   - icon.ico" -ForegroundColor Gray
Write-Host ""
Write-Host "  Proximos passos:" -ForegroundColor Yellow
Write-Host "   1. Envie a pasta '$pastaSlug' para o IT do cliente" -ForegroundColor Yellow
Write-Host "   2. Peca para executar install.ps1 como Administrador" -ForegroundColor Yellow
Write-Host "   3. Ou empacote como .intunewin para deploy via Intune" -ForegroundColor Yellow
Write-Host ""

# Abre a pasta gerada no Explorer para facilitar o envio
$abrirPasta = Read-Host "  Abrir pasta no Explorer? (S/N)"
if ($abrirPasta.Trim().ToUpper() -eq "S") {
    Start-Process "explorer.exe" $outputDir
}

Write-Host ""
Write-Host "  Pronto! Guarde o token em local seguro." -ForegroundColor Green
Write-Host ""
Read-Host "  Pressione Enter para sair"
