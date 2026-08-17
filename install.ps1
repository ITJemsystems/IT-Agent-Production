# ==============================================================
# install.ps1 - Agent IT - Silent installer
# ==============================================================
# WHAT THIS DOES:
#   - Runs as SYSTEM via Intune (or as admin manually)
#   - Sets ExecutionPolicy for the machine
#   - Creates C:\ProgramData\IT Support Agent\
#   - Copies all files (installs or updates silently)
#   - Creates Desktop and Start Menu shortcuts
#   - Registers in Add/Remove Programs
#
# USAGE:
#   Manual:  Right-click -> Run as Administrator
#   Intune:  Use as install command in Win32 app package
#            Command: powershell.exe -ExecutionPolicy Bypass -File install.ps1
#
# INTUNE PACKAGING:
#   1. Coloque nesta mesma pasta: AgentIT.exe (ja assinado),
#      install.ps1 (este arquivo), assets\ (icon.ico, logos), e
#      JEMSystemsCodeSigning.cer (a parte publica do certificado -
#      exportada uma vez com Export-Certificate, sem senha).
#   2. Use o Microsoft Win32 Content Prep Tool para empacotar essa
#      pasta inteira em um .intunewin:
#        IntuneWinAppUtil.exe -c "C:\IT Support - JEM - Prod" -s install.ps1 -o "C:\output"
#   3. Upload no Intune -> Apps -> Windows -> Add (Win32)
#
#   O pacote resultante ja contem tudo: instala o app E estabelece
#   confianca no certificado de assinatura, sem precisar de nenhum
#   perfil de configuracao separado no Intune.
# ==============================================================

# ==============================================================
# ASSINATURA DE CODIGO (Code Signing) - RECOMENDADO PARA PRODUCAO
# --------------------------------------------------------------
# Para eliminar o aviso "Publisher unknown" no Windows ao abrir
# o AgentIT.exe, assine o executavel com um certificado de
# assinatura de codigo (Code Signing Certificate).
#
# OPCAO A - Certificado comercial (recomendado para distribuicao):
#   Adquira um certificado Code Signing em DigiCert ou Sectigo.
#   Custo aprox. R$800-2000/ano. Windows confia automaticamente.
#   Apos obter o certificado (.pfx), assine com:
#     $cert = Get-PfxCertificate -FilePath "certificado.pfx"
#     Set-AuthenticodeSignature -FilePath "AgentIT.exe" -Certificate $cert
#
# OPCAO B - Certificado interno via Active Directory (gratuito):
#   Se a empresa usa AD com Certificate Services (AD CS):
#     1. Solicite um Code Signing certificate pelo AD CS
#     2. Exporte como .pfx
#     3. Use o comando acima para assinar
#   As maquinas do dominio ja confiam no certificado raiz do AD.
#   Ideal para deploy interno via Intune/GPO sem custo adicional.
#
# Descomente o bloco abaixo apos configurar o certificado:
# ==============================================================
<#
$certPath     = Join-Path $SOURCE "certificado.pfx"
$certPassword = ConvertTo-SecureString "SENHA-DO-CERTIFICADO" -AsPlainText -Force

if (Test-Path $certPath) {
    $cert = Get-PfxCertificate -FilePath $certPath -Password $certPassword
    Set-AuthenticodeSignature -FilePath "$INSTALL_DIR\AgentIT.exe" -Certificate $cert | Out-Null
}
#>

# ==============================================================
# OPCAO C (EM USO): certificado self-signed da JEM Systems
# --------------------------------------------------------------
# Diferente das opcoes A/B acima, o AgentIT.exe deste pacote ja
# chega ASSINADO (assinatura feita uma unica vez, na maquina do
# time de TI, com Set-AuthenticodeSignature, ANTES de gerar o
# .intunewin). Este script nao assina nada - ele so precisa
# ensinar cada maquina de destino a CONFIAR nessa assinatura,
# que e o que o bloco logo abaixo faz (ver "CONFIANCA NO
# CERTIFICADO", apos $SOURCE ser definido).
# ==============================================================
# Installation paths
$INSTALL_DIR = "C:\ProgramData\IT Support Agent"
$ASSETS_DIR  = "$INSTALL_DIR\assets"
$DESKTOP     = [Environment]::GetFolderPath("CommonDesktopDirectory")
$STARTMENU   = [Environment]::GetFolderPath("CommonPrograms")

# Source path (where install.ps1 is located)
$SOURCE = Split-Path -Parent $MyInvocation.MyCommand.Path

# ==============================================================
# CONFIANCA NO CERTIFICADO DE ASSINATURA (self-signed, JEM Systems)
# --------------------------------------------------------------
# O AgentIT.exe deste pacote ja vem ASSINADO com o certificado de
# assinatura de codigo self-signed da JEM Systems (assinatura feita
# uma vez, na maquina do time de TI, antes de gerar o .intunewin -
# ver "OPCAO C" no comentario acima). O que falta em cada maquina
# de destino e a CONFIANCA nesse certificado - sem isso, o Windows
# ainda mostraria "Editor Desconhecido" mesmo com o arquivo assinado.
#
# Como este script roda como SYSTEM (via Intune), ele tem privilegio
# para importar a parte PUBLICA do certificado (arquivo .cer, sem
# senha, sem chave privada) para os repositorios de confianca da
# maquina - Root (autoridades raiz confiaveis) e TrustedPublisher
# (editores de software confiaveis). E exatamente o mesmo efeito dos
# comandos Import-Certificate que o time de TI rodou manualmente na
# propria maquina para testar - so que aqui roda uma vez por maquina,
# automaticamente, durante a instalacao via Intune.
#
# REQUISITO: o arquivo "JEMSystemsCodeSigning.cer" precisa estar na
# MESMA pasta que este install.ps1 (a mesma pasta usada como -c ao
# gerar o .intunewin com o IntuneWinAppUtil.exe). Copie o .cer para
# essa pasta antes de empacotar - ver instrucoes no topo do arquivo.
#
# Se o arquivo nao existir (ex.: alguem gerar o pacote sem copiar o
# .cer por engano), a instalacao CONTINUA normalmente - so que o
# Windows vai mostrar o aviso de editor desconhecido ao abrir o app,
# ate esse passo ser corrigido e reinstalado.
# ==============================================================
$certFile = Join-Path $SOURCE "JEMSystemsCodeSigning.cer"

if (Test-Path $certFile) {
    try {
        Import-Certificate -FilePath $certFile -CertStoreLocation "Cert:\LocalMachine\Root" -ErrorAction Stop | Out-Null
        Import-Certificate -FilePath $certFile -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" -ErrorAction Stop | Out-Null
    } catch {
        # Nao bloqueia a instalacao se isso falhar - o app continua
        # funcionando, so o aviso de "Editor Desconhecido" continuaria
        # aparecendo ate o problema ser corrigido.
    }
}

# Allow PowerShell scripts to run on this machine
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction SilentlyContinue

# Create installation directories
New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $ASSETS_DIR  -Force | Out-Null

# Copy main executable
Copy-Item "$SOURCE\AgentIT.exe" "$INSTALL_DIR\AgentIT.exe" -Force

# Copy assets (logo, icon)
if (Test-Path "$SOURCE\assets") {
    Copy-Item "$SOURCE\assets\*" $ASSETS_DIR -Recurse -Force
}

# Write initial version (0.0.0 forces auto-update on first run)
# The app will download all modules from GitHub on first launch
Set-Content -Path "$INSTALL_DIR\version.txt" -Value "0.0.0" -Encoding UTF8 -Force

# Create Desktop shortcut (visible to all users)
$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut("$DESKTOP\Agent IT.lnk")
$shortcut.TargetPath       = "$INSTALL_DIR\AgentIT.exe"
$shortcut.WorkingDirectory = $INSTALL_DIR
$shortcut.Description      = "Agent IT - Suporte de TI"
if (Test-Path "$ASSETS_DIR\icon.ico") {
    $shortcut.IconLocation = "$ASSETS_DIR\icon.ico"
}
$shortcut.Save()

# Create Start Menu shortcut
$startShortcut = $WshShell.CreateShortcut("$STARTMENU\Agent IT.lnk")
$startShortcut.TargetPath       = "$INSTALL_DIR\AgentIT.exe"
$startShortcut.WorkingDirectory = $INSTALL_DIR
$startShortcut.Description      = "Agent IT - Suporte de TI"
if (Test-Path "$ASSETS_DIR\icon.ico") {
    $startShortcut.IconLocation = "$ASSETS_DIR\icon.ico"
}
$startShortcut.Save()

# Register in Windows Add/Remove Programs
$regPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentIT"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "DisplayName"     -Value "Agent IT"
Set-ItemProperty -Path $regPath -Name "DisplayVersion"  -Value "1.0.0"
Set-ItemProperty -Path $regPath -Name "Publisher"       -Value "Agent IT"
Set-ItemProperty -Path $regPath -Name "InstallLocation" -Value $INSTALL_DIR
Set-ItemProperty -Path $regPath -Name "UninstallString" -Value "powershell.exe -ExecutionPolicy Bypass -File `"$INSTALL_DIR\uninstall.ps1`""
Set-ItemProperty -Path $regPath -Name "DisplayIcon"     -Value "$INSTALL_DIR\AgentIT.exe"
Set-ItemProperty -Path $regPath -Name "NoModify"        -Value 1
Set-ItemProperty -Path $regPath -Name "NoRepair"        -Value 1

exit 0
