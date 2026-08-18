# ==============================================================
# network.psm1 - Network diagnostics and Wi-Fi driver check
# ==============================================================
# WHAT THIS MODULE DOES:
#   Runs a 5-step network diagnostic and shows a clean WPF result
#   window with cards for: adapter info, latency, DNS, repairs
#   applied, and Wi-Fi driver status.
#
# STEPS (match ActionSteps "12" in ui.psm1 Build-ActionSteps):
#   Step 1 (20%) - Detect active network adapter and IP info
#   Step 2 (40%) - Test latency with 4 pings to 8.8.8.8
#   Step 3 (60%) - Test DNS resolution against google.com
#   Step 4 (80%) - Auto-repair if latency > 15ms or DNS fails
#                  (flushdns + ipconfig /release + /renew)
#   Step 5 (100%)- Check Wi-Fi driver version against baseline
#
# AUTO-REPAIR NOTES:
#   /release + /renew only works on DHCP adapters.
#   On static IP or corporate DHCP with MAC reservation,
#   the IP will not change - this is expected behavior, NOT a bug.
#   The log records IPAntes vs IPDepois for verification.
#
# WI-FI DRIVER BASELINE:
#   Stored in $WifiDriverBaseline hashtable below.
#   Covers Intel AX200/201/210/211 and 9560 adapters.
#   Unknown models use a generic fallback minimum of 24.30.0.0.
#   To add a new model: add a key/value to $WifiDriverBaseline.
#
# RESULT WINDOW:
#   Mostrar-Resultado-Rede opens a separate WPF window with cards.
#   Colors: green=good, yellow=warning, red=critical, gray=N/A.
#   If Wi-Fi driver is outdated, a download button appears that
#   opens the official Intel driver page in the default browser.
# ==============================================================

function Diagnostico-Rede {
    $Global:UltimaFuncaoExecutada = "INTERNET DIAGNOSTIC"

    # Step 1 (20%): Detect the first active network adapter and collect IP info
    Barra-Progresso (Get-Text "Step.Net.Interface")
    Escrever-Log -Mensagem "=== INICIO DIAGNOSTICO DE REDE ===" -FunctionName "NETWORK" -Action "DiagStart" -Status "INFO"

    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if (-not $adapter) {
        WPF-Log "ERRO: Nenhum adaptador ativo." -Color "#E05050"
        return
    }
    $interface  = $adapter.Name
    $tipo       = $adapter.InterfaceDescription
    $speed      = $adapter.LinkSpeed
    $ipInfo     = Get-NetIPConfiguration -InterfaceAlias $interface -ErrorAction SilentlyContinue
    $ipv4       = $ipInfo.IPv4Address.IPAddress
    $gateway    = $ipInfo.IPv4DefaultGateway.NextHop
    $dnsServers = ($ipInfo.DnsServer.ServerAddresses -join ", ")
    Escrever-Log -Mensagem "Interface=$interface | IP=$ipv4 | Gateway=$gateway | Speed=$speed" -FunctionName "NETWORK" -Action "InterfaceDetect" -Status "INFO"

    # Step 2 (40%): Test latency - threshold is 15ms (corporate standard)
    Barra-Progresso (Get-Text "Step.Net.Latency")
    $ping    = Test-Connection 8.8.8.8 -Count 4 -ErrorAction SilentlyContinue
    $avgPing = ($ping | Measure-Object ResponseTime -Average).Average
    if ($avgPing) {
        $pingRounded = [math]::Round($avgPing, 1)
        # FIX (v1.3.0): mensagem mais clara e direta para leitura na
        # dashboard, em vez de so o numero cru "Latencia=X ms".
        $pingMsg = if ($pingRounded -gt 15) {
            "Ping acima do esperado: $pingRounded ms (limite: 15ms)"
        } else {
            "Ping dentro do esperado: $pingRounded ms (menor que 15ms)"
        }
        Escrever-Log -Mensagem $pingMsg -FunctionName "NETWORK" -Action "LatencyTest" -Status $(if ($pingRounded -gt 15) {"WARNING"} else {"SUCCESS"}) -MetricValue $pingRounded -MetricUnit "ms"
    } else {
        $pingRounded = $null
        Escrever-Log -Mensagem "Sem resposta de latencia (host de teste inacessivel)" -FunctionName "NETWORK" -Action "LatencyTest" -Status "FAIL"
    }

    # Step 3 (60%): Test DNS resolution - resolves google.com as a known reliable domain
    Barra-Progresso (Get-Text "Step.Net.DNS")
    try {
        Resolve-DnsName google.com -ErrorAction Stop | Out-Null
        $dnsOk = $true
        Escrever-Log -Mensagem "Resolucao de DNS funcionando normalmente" -FunctionName "NETWORK" -Action "DNSTest" -Status "SUCCESS"
    } catch {
        $dnsOk = $false
        Escrever-Log -Mensagem "Erro de DNS: nao foi possivel resolver nomes de dominio" -FunctionName "NETWORK" -Action "DNSTest" -Status "FAIL"
    }

    # Step 4 (80%): Auto-repair if latency > 15ms OR DNS failed
    # flushdns clears stale DNS cache
    # release+renew requests a new IP from DHCP (no effect on static IPs)
    #
    # FIX (v1.3.0): antes, flush+release+renew eram logados como UM
    # evento combinado ("Reparos aplicados (flushdns+release+renew)").
    # Agora cada passo gera seu proprio evento com mensagem clara,
    # para a dashboard mostrar exatamente qual reparo foi aplicado -
    # ex: "Flush DNS aplicado com sucesso" separado de "IP renovado
    # com sucesso", em vez de um texto so misturando os dois.
    Barra-Progresso (Get-Text "Step.Net.Repair")
    $precisaReparo  = ($pingRounded -gt 15 -or -not $dnsOk)
    $reparoAplicado = $false
    if ($precisaReparo) {
        try {
            & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
            Escrever-Log -Mensagem "Flush DNS aplicado com sucesso" -FunctionName "NETWORK" -Action "FlushDNS" -Status "SUCCESS"
        } catch {
            Escrever-Log -Mensagem "Falha ao aplicar Flush DNS" -FunctionName "NETWORK" -Action "FlushDNS" -Status "ERROR"
        }

        try {
            & "$env:SystemRoot\System32\ipconfig.exe" /release | Out-Null
            Start-Sleep -Seconds 2
            & "$env:SystemRoot\System32\ipconfig.exe" /renew   | Out-Null
            Start-Sleep -Seconds 3
            Escrever-Log -Mensagem "IP renovado com sucesso" -FunctionName "NETWORK" -Action "RenewIP" -Status "SUCCESS"
        } catch {
            Escrever-Log -Mensagem "Falha ao renovar IP" -FunctionName "NETWORK" -Action "RenewIP" -Status "ERROR"
        }

        $reparoAplicado = $true
    } else {
        Escrever-Log -Mensagem "Internet saudavel - nenhum reparo necessario" -FunctionName "NETWORK" -Action "InternetHealthy" -Status "SUCCESS"
    }

    # Step 5 (100%): Check Wi-Fi driver version via WMI (Win32_PnPSignedDriver)
    Barra-Progresso (Get-Text "Step.Net.Wifi")
    $wifiInfo = Get-WifiDriverInfo

    # FIX (v1.3.0): evento final de resumo, com nome de acao proprio
    # (nao generico "DiagEnd") para servir de "Diagnostico executado"
    # na dashboard - um unico evento que marca claramente que o
    # diagnostico completo rodou, com o resultado geral resumido.
    $resumoStatus = if (-not $dnsOk) { "WARNING" } elseif ($pingRounded -gt 15) { "WARNING" } else { "SUCCESS" }
    $resumoMsg    = "Diagnostico de rede executado - " + $(if ($resumoStatus -eq "SUCCESS") { "sem problemas encontrados" } else { "problemas encontrados e reparo tentado" })
    Escrever-Log -Mensagem $resumoMsg -FunctionName "NETWORK" -Application "Diagnostico de Rede" -Action "DiagnosticoExecutado" -Status $resumoStatus

    Mostrar-Resultado-Rede -interface $interface -tipo $tipo -speed $speed -ipv4 $ipv4 `
        -pingRounded $pingRounded -dnsOk $dnsOk -reparoAplicado $reparoAplicado -wifiInfo $wifiInfo
}

# Wi-Fi driver minimum version baseline per Intel adapter model.
# Source: Intel driver release notes.
# To update: change the version string for the affected model.
# Format: "ModelSuffix" = "Major.Minor.Build.Revision"
$WifiDriverBaseline = @{
    "AX211"="24.20.0.0"; "AX210"="24.20.0.0"; "AX201"="24.20.0.0"
    "AX200"="24.20.0.0"; "9560"="23.60.0.0"
}

# Returns a hashtable with Wi-Fi adapter and driver info.
# Used internally by Diagnostico-Rede to populate the result window.
# PhysicalMediaType=9 filters to 802.11 Wi-Fi only (excludes USB gaming adapters).
function Get-WifiDriverInfo {
    $result = @{
        Found=$false; Modelo="N/A"; ModeloFull="N/A"; Fabricante="N/A"
        VersaoAtual="N/A"; VersaoMinima="N/A"; Desatualizado=$false
        Motivo = if ($Global:Language -eq "EN") { "Wi-Fi adapter not found (normal on desktops without Wi-Fi)" } else { "Adaptador Wi-Fi nao encontrado (normal em desktops sem Wi-Fi)" }
    }

    # Try multiple detection methods - PhysicalMediaType=9 only works for some Intel adapters
    # Method 1: PhysicalMediaType = 9 (native Wi-Fi - works for most Intel)
    $wifi = Get-NetAdapter | Where-Object {
        $_.Status -eq "Up" -and $_.PhysicalMediaType -eq 9 -and
        $_.InterfaceDescription -notmatch "Xbox|Razer|Logitech|Virtual|VPN|VMware|Hyper-V|TAP|Bluetooth"
    } | Select-Object -First 1

    # Method 2: Name or description contains Wi-Fi keywords (Realtek, MediaTek, Qualcomm, Broadcom)
    if (-not $wifi) {
        $wifi = Get-NetAdapter | Where-Object {
            $_.Status -eq "Up" -and
            ($_.InterfaceDescription -match "Wi-Fi|WiFi|Wireless|802\.11|WLAN|Realtek.*Wireless|MediaTek|Qualcomm.*Wi|Broadcom.*Wi|Intel.*Wi") -and
            $_.InterfaceDescription -notmatch "Xbox|Razer|Logitech|Virtual|VPN|VMware|Hyper-V|TAP|Bluetooth"
        } | Select-Object -First 1
    }

    # Method 3: Any adapter named "Wi-Fi" by Windows (common on laptops)
    if (-not $wifi) {
        $wifi = Get-NetAdapter | Where-Object {
            $_.Status -eq "Up" -and $_.Name -match "Wi-Fi|WiFi|Wireless|WLAN"
        } | Select-Object -First 1
    }

    if (!$wifi) { return $result }

    $driver = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq $wifi.PnPDeviceID }
    if (!$driver) {
        $result.Found=$true; $result.ModeloFull=$wifi.InterfaceDescription
        $result.Motivo = if ($Global:Language -eq "EN") { "Driver not found via WMI" } else { "Driver nao localizado via WMI" }
        return $result
    }
    $versaoAtual     = [version]$driver.DriverVersion
    $modeloDetectado = ($wifi.InterfaceDescription -replace ".*(AX\d+|9560).*",'$1')

    # If model wasn't detected from Intel pattern, use full description
    if ($modeloDetectado -eq $wifi.InterfaceDescription) {
        $modeloDetectado = "Unknown"
    }

    # For non-Intel adapters, skip baseline comparison (we don't have their baselines)
    # Just report the current driver version as informational
    if ($WifiDriverBaseline.ContainsKey($modeloDetectado)) {
        $versaoMinima  = [version]$WifiDriverBaseline[$modeloDetectado]
        $desatualizado = $versaoAtual -lt $versaoMinima
    } else {
        # Unknown model - report driver info but don't flag as outdated
        $versaoMinima  = [version]"0.0.0.0"
        $desatualizado = $false
    }
    $result.Found=$true; $result.Modelo=$modeloDetectado; $result.ModeloFull=$wifi.InterfaceDescription
    $result.Fabricante=$driver.Manufacturer; $result.VersaoAtual="$versaoAtual"
    $result.VersaoMinima=if ($versaoMinima -eq [version]"0.0.0.0") { "N/A" } else { "$versaoMinima" }
    $result.Desatualizado=$desatualizado

    # Resolve download URL based on manufacturer
    $fab = "$($driver.Manufacturer)"
    $driverUrl = $Global:WifiDriverURLs["Default"]
    foreach ($key in $Global:WifiDriverURLs.Keys) {
        if ($fab -match $key) { $driverUrl = $Global:WifiDriverURLs[$key]; break }
    }
    $result.DriverURL = $driverUrl

    $result.Motivo = if ($desatualizado) {
        if ($Global:Language -eq "EN") {"Outdated driver"} else {"Driver desatualizado"}
    } elseif ($versaoMinima -eq [version]"0.0.0.0") {
        if ($Global:Language -eq "EN") {"Driver OK (no baseline for this model)"} else {"Driver OK (sem baseline para este modelo)"}
    } else {
        if ($Global:Language -eq "EN") {"Driver up to date"} else {"Driver atualizado"}
    }
    Escrever-Log -Mensagem "WiFi: $modeloDetectado | Atual=$versaoAtual | Min=$($result.VersaoMinima) | Desatualizado=$desatualizado" -FunctionName "NETWORK" -Action "WifiDriverCheck" -Status $(if ($desatualizado) {"WARNING"} else {"SUCCESS"})
    return $result
}

$Global:IntelWifiDriverURL = "https://www.intel.com/content/www/us/en/download/19351/intel-wireless-bluetooth-for-windows-10-and-windows-11.html"

# Driver download URLs per manufacturer
# Used when Wi-Fi driver is detected as outdated
$Global:WifiDriverURLs = @{
    "Intel"    = "https://www.intel.com/content/www/us/en/download/19351/intel-wireless-bluetooth-for-windows-10-and-windows-11.html"
    "Realtek"  = "https://www.realtek.com/en/component/zoo/category/network-interface-controllers-10-100-1000m-gigabit-ethernet-pci-express-software"
    "Qualcomm" = "https://www.qualcomm.com/products/technology/wi-fi"
    "MediaTek" = "https://www.mediatek.com/products/broadbandWifi"
    "Broadcom" = "https://www.broadcom.com/support/download-search?pg=&pf=&pn=&pa=&po=&dk=wifi+driver&pl=&ll=&o="
    "Default"  = "https://support.microsoft.com/en-us/windows/update-drivers-manually-in-windows-ec62f46c-ff14-c91d-eead-d7126dc1f7b6"
}

function Abrir-Download-WifiDriver {
    $Global:UltimaFuncaoExecutada     = Get-Text "WifiDriverUpdateActionName"
    $Global:MensagemCustomizadaTicket = Get-Text "WifiDriverTicketMessage"
    $Global:ForcarAberturaTicket      = $true
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show((Get-Text "WifiDriverOutdatedMessage"),(Get-Text "WifiDriverTitle"),[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Warning) | Out-Null
    Start-Process $Global:IntelWifiDriverURL
}

function Verificar-DriverWifi {
    $info = Get-WifiDriverInfo
    if ($info.Desatualizado) { Abrir-Download-WifiDriver }
}

# =====================================================================
# RESULT WINDOW
# =====================================================================
# Opens a separate WPF result window after Diagnostico-Rede completes.
# All data is passed as parameters - no global state used.
# Color logic: green=good, yellow=warning (latency 15-50ms), red=critical (>50ms or failed).
function Mostrar-Resultado-Rede {
    param($interface, $tipo, $speed, $ipv4, $pingRounded, $dnsOk, $reparoAplicado, $wifiInfo)

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    # Calculate status colors and labels for each card in the result window
    $latColor  = if ($null -eq $pingRounded) {"#94A3B8"} elseif ($pingRounded -le 15) {"#3EA384"} elseif ($pingRounded -le 50) {"#F7C02D"} else {"#E05050"}
    $latStatus = if ($null -eq $pingRounded) { if ($Global:Language -eq "EN") {"No response"} else {"Sem resposta"} } elseif ($pingRounded -le 15) { if ($Global:Language -eq "EN") {"Excellent"} else {"Otimo"} } elseif ($pingRounded -le 50) { if ($Global:Language -eq "EN") {"Acceptable"} else {"Aceitavel"} } else { if ($Global:Language -eq "EN") {"High"} else {"Alta"} }
    $dnsColor  = if ($dnsOk) {"#3EA384"} else {"#E05050"}
    $dnsStatus = if ($dnsOk) {"OK"} else { if ($Global:Language -eq "EN") {"Failed"} else {"Falhou"} }
    $wifiColor = if (-not $wifiInfo.Found) {"#94A3B8"} elseif ($wifiInfo.Desatualizado) {"#E05050"} else {"#3EA384"}
    $wifiStatus= if (-not $wifiInfo.Found) { if ($Global:Language -eq "EN") {"Not found"} else {"Nao encontrado"} } elseif ($wifiInfo.Desatualizado) { if ($Global:Language -eq "EN") {"Outdated"} else {"Desatualizado"} } else { if ($Global:Language -eq "EN") {"Up to date"} else {"Atualizado"} }

    [xml]$RXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diagnostico de Rede" Width="544" Height="604"
        WindowStartupLocation="CenterScreen"
        Background="Transparent"
        WindowStyle="None"
        AllowsTransparency="True"
        ResizeMode="NoResize">
    <Border Margin="12">
        <Border CornerRadius="10" Background="#F0EDF2"
                BorderBrush="#2D1147" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="16" ShadowDepth="6"
                                  Direction="315" Color="#000000" Opacity="0.45"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="50"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="60"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="#6E277A" CornerRadius="10,10,0,0" x:Name="TitleBar">
                    <DockPanel Margin="16,0">
                        <Button x:Name="BtnClose" DockPanel.Dock="Right"
                                Content="&#x2715;" Width="32" Height="32"
                                Background="Transparent" Foreground="#E0C8E4"
                                BorderThickness="0" FontSize="13" Cursor="Hand"/>
                        <TextBlock x:Name="NetTitle" Text="Diagnostico de Rede" Foreground="White"
                                   FontFamily="Segoe UI Semibold" FontSize="14"
                                   VerticalAlignment="Center"/>
                    </DockPanel>
                </Border>

                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="16,12,16,0">
                    <StackPanel>
                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock x:Name="NetAdapterTitle" Text="Adaptador de Rede" Foreground="#3D1147"
                                           FontFamily="Segoe UI Semibold" FontSize="13" Margin="0,0,0,6"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="90"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <TextBlock Grid.Row="0" Grid.Column="0" x:Name="NetLblInterface" Text="Interface:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="0" Grid.Column="1" x:Name="TxtInterface" Text="" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="1" Grid.Column="0" x:Name="NetLblTipo" Text="Tipo:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="1" Grid.Column="1" x:Name="TxtTipo" Text="" Foreground="#3D1147" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2" TextWrapping="Wrap"/>
                                    <TextBlock Grid.Row="2" Grid.Column="0" x:Name="NetLblSpeed" Text="Velocidade:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="2" Grid.Column="1" x:Name="TxtSpeed" Text="" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="3" Grid.Column="0" Text="IP:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="3" Grid.Column="1" x:Name="TxtIP" Text="" Foreground="#3D1147" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                </Grid>
                            </StackPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <DockPanel>
                                <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="16,0,0,0" MinWidth="70">
                                    <TextBlock x:Name="TxtLatVal" Text="--" FontFamily="Segoe UI Black" FontSize="28" HorizontalAlignment="Center"/>
                                    <TextBlock Text="ms" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Center"/>
                                </StackPanel>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock x:Name="NetLblLatency" Text="Latencia (ping 8.8.8.8)" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13"/>
                                    <TextBlock x:Name="TxtLatStatus" Text="" FontFamily="Segoe UI Semibold" FontSize="15" Margin="0,4,0,4"/>
                                    <TextBlock x:Name="NetLblMaxLatency" Text="Maximo recomendado: 15 ms" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="11"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <DockPanel>
                                <TextBlock x:Name="TxtDnsIcon" Text="+" DockPanel.Dock="Right"
                                           FontSize="28" FontFamily="Segoe UI Black"
                                           VerticalAlignment="Center" Margin="16,0,0,0"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock x:Name="NetLblDNS" Text="Resolucao DNS" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13"/>
                                    <TextBlock x:Name="TxtDnsStatus" Text="" FontFamily="Segoe UI Semibold" FontSize="15" Margin="0,4,0,4"/>
                                    <TextBlock x:Name="NetLblDNSTest" Text="Teste: resolucao de google.com" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="11"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>

                        <Border x:Name="CardReparo" Background="#FFF8E7" CornerRadius="10"
                                Padding="16,12" Margin="0,0,0,10" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock x:Name="NetLblRepair" Text="Reparo Automatico Aplicado" Foreground="#F7C02D"
                                           FontFamily="Segoe UI Semibold" FontSize="13" Margin="0,0,0,4"/>
                                <TextBlock x:Name="NetLblRepairDetail" Text="DNS cache limpo e IP renovado." Foreground="#6B5878"
                                           FontFamily="Segoe UI" FontSize="12" TextWrapping="Wrap"/>
                            </StackPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,4">
                            <StackPanel>
                                <DockPanel Margin="0,0,0,8">
                                    <TextBlock x:Name="TxtWifiStatus" Text="" DockPanel.Dock="Right"
                                               FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="NetWifi" Text="Driver Wi-Fi" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13"/>
                                </DockPanel>
                                <Grid x:Name="GridWifiDetail">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="110"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <TextBlock Grid.Row="0" Grid.Column="0" x:Name="NetLblModelo" Text="Modelo:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="0" Grid.Column="1" x:Name="TxtWifiModelo" Text="" Foreground="#3D1147" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2" TextWrapping="Wrap"/>
                                    <TextBlock Grid.Row="1" Grid.Column="0" x:Name="NetLblFab" Text="Fabricante:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="1" Grid.Column="1" x:Name="TxtWifiFab" Text="" Foreground="#3D1147" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="2" Grid.Column="0" x:Name="NetLblVersao" Text="Versao atual:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="2" Grid.Column="1" x:Name="TxtWifiVersao" Text="" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="3" Grid.Column="0" x:Name="NetLblMinima" Text="Versao minima:" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                    <TextBlock Grid.Row="3" Grid.Column="1" x:Name="TxtWifiMinima" Text="" Foreground="#3D1147" FontFamily="Segoe UI" FontSize="12" Margin="0,2,0,2"/>
                                </Grid>
                                <TextBlock x:Name="TxtWifiNone" Text="" Foreground="#94A3B8"
                                           FontFamily="Segoe UI" FontSize="12" Visibility="Collapsed"/>
                                <Button x:Name="BtnDownloadWifi"
                                        Content="Abrir pagina de download (Intel oficial)"
                                        Margin="0,12,0,0" Height="34" Background="#E05050" Foreground="White"
                                        BorderThickness="0" FontFamily="Segoe UI Semibold" FontSize="12"
                                        Cursor="Hand" Visibility="Collapsed"/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <Border Grid.Row="2" Padding="16,0">
                    <Button x:Name="BtnNetClose" Content="Fechar" Height="38"
                            Background="#6E277A" Foreground="White" BorderThickness="0"
                            FontFamily="Segoe UI Semibold" FontSize="13" Cursor="Hand"/>
                </Border>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    # Load the XAML and create the WPF window instance
    $rdr = [System.Xml.XmlNodeReader]::new($RXAML)
    $rw  = [Windows.Markup.XamlReader]::Load($rdr)

    # Apply language to result window
    if ($Global:Language -eq "EN") {
        try { $rw.FindName("NetTitle").Text           = "Network Diagnostic" }          catch {}
        try { $rw.FindName("NetAdapterTitle").Text    = "Network Adapter" }             catch {}
        try { $rw.FindName("NetLblInterface").Text    = "Interface:" }                  catch {}
        try { $rw.FindName("NetLblTipo").Text         = "Type:" }                       catch {}
        try { $rw.FindName("NetLblSpeed").Text        = "Speed:" }                      catch {}
        try { $rw.FindName("NetLblLatency").Text      = "Latency (ping 8.8.8.8)" }      catch {}
        try { $rw.FindName("NetLblMaxLatency").Text   = "Recommended max: 15 ms" }      catch {}
        try { $rw.FindName("NetLblDNS").Text          = "DNS Resolution" }              catch {}
        try { $rw.FindName("NetLblDNSTest").Text      = "Test: google.com resolution" } catch {}
        try { $rw.FindName("NetLblRepair").Text       = "Auto Repair Applied" }         catch {}
        try { $rw.FindName("NetLblRepairDetail").Text = "DNS cache cleared and IP renewed." } catch {}
        try { $rw.FindName("NetWifi").Text            = "Wi-Fi Driver" }                catch {}
        try { $rw.FindName("NetLblModelo").Text       = "Model:" }                      catch {}
        try { $rw.FindName("NetLblFab").Text          = "Manufacturer:" }               catch {}
        try { $rw.FindName("NetLblVersao").Text       = "Current version:" }            catch {}
        try { $rw.FindName("NetLblMinima").Text       = "Minimum version:" }            catch {}
        try { $rw.FindName("BtnDownloadWifi").Content  = "Open download page (Intel official)" } catch {}
        try { $rw.FindName("BtnNetClose").Content     = "Close" }                       catch {}
    }

    # Flat template for buttons in this window (no WPF hover chrome)
    $ft = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)
    # Apply flat + hover to BtnNetClose (purple -> 2 tones lighter)
    $btnOk = $rw.FindName("BtnNetClose")
    if ($btnOk) {
        $btnOk.Template = $ft
        $btnOk.Tag = "#6E277A|#8E3A9A"
        $btnOk.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
        $btnOk.Add_MouseLeave({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })
    }
    $btnCl = $rw.FindName("BtnClose")
    if ($btnCl) {
        $btnCl.Template = $ft
        $btnCl.Tag = "Transparent|#5A2468"
        $btnCl.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
        $btnCl.Add_MouseLeave({ param($s,$e) $s.Background=[Windows.Media.Brushes]::Transparent })
    }

    $rw.FindName("TitleBar").Add_MouseLeftButtonDown({ param($s,$e) $rw.DragMove() })
    $rw.FindName("BtnClose").Add_Click({ $rw.Close() })

    $rw.FindName("TxtInterface").Text = $interface
    $rw.FindName("TxtTipo").Text      = $tipo
    $rw.FindName("TxtSpeed").Text     = $speed
    $rw.FindName("TxtIP").Text        = if ($ipv4) { $ipv4 } else { "N/A" }

    $rw.FindName("TxtLatVal").Text               = if ($pingRounded) { "$pingRounded" } else { "--" }
    $rw.FindName("TxtLatVal").Foreground         = [Windows.Media.BrushConverter]::new().ConvertFromString($latColor)
    $rw.FindName("TxtLatStatus").Text            = $latStatus
    $rw.FindName("TxtLatStatus").Foreground      = [Windows.Media.BrushConverter]::new().ConvertFromString($latColor)

    $rw.FindName("TxtDnsIcon").Text              = if ($dnsOk) { "+" } else { "x" }
    $rw.FindName("TxtDnsIcon").Foreground        = [Windows.Media.BrushConverter]::new().ConvertFromString($dnsColor)
    $rw.FindName("TxtDnsStatus").Text            = $dnsStatus
    $rw.FindName("TxtDnsStatus").Foreground      = [Windows.Media.BrushConverter]::new().ConvertFromString($dnsColor)

    if ($reparoAplicado) { $rw.FindName("CardReparo").Visibility = "Visible" }

    $rw.FindName("TxtWifiStatus").Text           = $wifiStatus
    $rw.FindName("TxtWifiStatus").Foreground     = [Windows.Media.BrushConverter]::new().ConvertFromString($wifiColor)

    if ($wifiInfo.Found -and $wifiInfo.VersaoAtual -ne "N/A") {
        $rw.FindName("TxtWifiModelo").Text  = if ($wifiInfo.Modelo -ne "N/A") { "$($wifiInfo.Modelo) - $($wifiInfo.ModeloFull)" } else { $wifiInfo.ModeloFull }
        $rw.FindName("TxtWifiFab").Text     = $wifiInfo.Fabricante
        $rw.FindName("TxtWifiVersao").Text  = $wifiInfo.VersaoAtual
        $rw.FindName("TxtWifiVersao").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($wifiColor)
        $rw.FindName("TxtWifiMinima").Text  = $wifiInfo.VersaoMinima
        if ($wifiInfo.Desatualizado) {
            $rw.FindName("BtnDownloadWifi").Visibility = "Visible"
            $driverURL = $wifiInfo.DriverURL
            $rw.FindName("BtnDownloadWifi").Add_Click({ Start-Process $driverURL })
        }
    } else {
        $rw.FindName("GridWifiDetail").Visibility = "Collapsed"
        $rw.FindName("TxtWifiNone").Text          = $wifiInfo.Motivo
        $rw.FindName("TxtWifiNone").Visibility    = "Visible"
    }

    $rw.FindName("BtnNetClose").Add_Click({
        $rw.Close()
        Perguntar-Resolvido
    })

    $rw.ShowDialog() | Out-Null
}

# ==============================================================
# IP / DNS VERIFICATION
# ==============================================================
# Detects the primary active adapter (one with a gateway),
# reads IP assignment type (DHCP vs Static) and DNS servers,
# then shows a clean result window.
#
# DHCP vs Static detection:
#   PrefixOrigin = "Dhcp"   → IP atribuído automaticamente
#   PrefixOrigin = "Manual" → IP fixo configurado manualmente
#
# DNS detection:
#   Get-DnsClientServerAddress returns the configured servers.
#   Empty list = inherited from DHCP / not configured.
# ==============================================================
function Verificar-IP-DNS {
    $Global:UltimaFuncaoExecutada = "IP/DNS"
    Escrever-Log -Mensagem "=== INICIO VERIFICACAO IP/DNS ===" -FunctionName "NETWORK" -Action "DiagStart" -Status "INFO"

    Barra-Progresso (Get-Text "Step.IPDNS.Collect")

    # Find primary adapter: Up + has a default gateway (main connection)
    $primaryAdapter = $null
    foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq "Up" })) {
        $cfg = Get-NetIPConfiguration -InterfaceAlias $a.Name -ErrorAction SilentlyContinue
        if ($cfg.IPv4DefaultGateway) { $primaryAdapter = $a; break }
    }
    # Fallback: any Up adapter
    if (-not $primaryAdapter) {
        $primaryAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    }
    if (-not $primaryAdapter) {
        WPF-Log "ERRO: Nenhum adaptador ativo." -Color "#E05050"
        return
    }

    $iface = $primaryAdapter.Name

    # IP address and assignment type
    $netIP        = Get-NetIPAddress -InterfaceAlias $iface -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $ipv4         = $netIP.IPAddress
    $prefixOrigin = $netIP.PrefixOrigin   # Dhcp | Manual | WellKnown
    $isStatic     = $prefixOrigin -eq "Manual"

    # DNS servers
    $dnsServers = @((Get-DnsClientServerAddress -InterfaceAlias $iface -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)

    Barra-Progresso (Get-Text "Step.IPDNS.Done")

    Escrever-Log -Mensagem "Interface=$iface | IP=$ipv4 | Tipo=$prefixOrigin | DNS=$($dnsServers -join ', ')" -FunctionName "NETWORK" -Action "IPDNSCheck" -Status "INFO"
    Escrever-Log -Mensagem "=== FIM VERIFICACAO IP/DNS ===" -FunctionName "NETWORK" -Action "DiagEnd" -Status "INFO"

    Mostrar-Resultado-IP-DNS -iface $iface -ipv4 $ipv4 -isStatic $isStatic -dnsServers $dnsServers
}

function Mostrar-Resultado-IP-DNS {
    param(
        [string]$iface,
        [string]$ipv4,
        [bool]$isStatic,
        [string[]]$dnsServers
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $isEN = $Global:Language -eq "EN"

    # Labels
    $lblTitle     = if ($isEN) { "IP and DNS Status" }          else { "Status de IP e DNS" }
    $lblInterface = if ($isEN) { "Interface:" }                  else { "Interface:" }
    $lblIP        = if ($isEN) { "Current IP:" }                 else { "IP Atual:" }
    $lblType      = if ($isEN) { "Assignment:" }                 else { "Atribuicao:" }
    $lblDNS       = if ($isEN) { "DNS Servers:" }                else { "Servidores DNS:" }
    $lblClose     = if ($isEN) { "Close" }                       else { "Fechar" }

    $typeLabel = if ($isStatic) {
        if ($isEN) { "STATIC (manually configured)" } else { "FIXO (configurado manualmente)" }
    } else {
        if ($isEN) { "AUTOMATIC (DHCP)" } else { "AUTOMATICO (DHCP)" }
    }
    $typeColor = if ($isStatic) { "#F7A020" } else { "#3EA384" }

    $dnsLabel = if ($dnsServers -and $dnsServers.Count -gt 0) {
        $dnsServers -join "`n"
    } else {
        if ($isEN) { "Automatic (via DHCP)" } else { "Automatico (via DHCP)" }
    }

    [xml]$IXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IP/DNS" Width="460" Height="340"
        WindowStartupLocation="CenterScreen"
        Background="Transparent" WindowStyle="None"
        AllowsTransparency="True" ResizeMode="NoResize" Topmost="True">
    <Border Margin="12">
        <Border CornerRadius="10" Background="#F0EDF2" BorderBrush="#2D1147" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="16" ShadowDepth="6" Direction="315" Color="#000000" Opacity="0.45"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="50"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="60"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="#6E277A" CornerRadius="10,10,0,0" x:Name="TitleBar">
                    <DockPanel Margin="16,0">
                        <Button x:Name="BtnClose" DockPanel.Dock="Right"
                                Content="&#x2715;" Width="32" Height="32"
                                Background="Transparent" Foreground="#E0C8E4"
                                BorderThickness="0" FontSize="13" Cursor="Hand"/>
                        <TextBlock x:Name="WinTitle" Text="" Foreground="White"
                                   FontFamily="Segoe UI Semibold" FontSize="14"
                                   VerticalAlignment="Center"/>
                    </DockPanel>
                </Border>

                <StackPanel Grid.Row="1" Margin="16,12,16,0">

                    <!-- IP Card -->
                    <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="110"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Grid.Column="0" x:Name="LblInterface"
                                       Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2"/>
                            <TextBlock Grid.Row="0" Grid.Column="1" x:Name="TxtInterface"
                                       Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="12" Margin="0,2"/>
                            <TextBlock Grid.Row="1" Grid.Column="0" x:Name="LblIP"
                                       Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2"/>
                            <TextBlock Grid.Row="1" Grid.Column="1" x:Name="TxtIP"
                                       Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="14" Margin="0,2"/>
                            <TextBlock Grid.Row="2" Grid.Column="0" x:Name="LblType"
                                       Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2"/>
                            <TextBlock Grid.Row="2" Grid.Column="1" x:Name="TxtType"
                                       FontFamily="Segoe UI Semibold" FontSize="12" Margin="0,2"/>
                        </Grid>
                    </Border>

                    <!-- DNS Card -->
                    <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="110"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" x:Name="LblDNS"
                                       Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="12" Margin="0,2"/>
                            <TextBlock Grid.Column="1" x:Name="TxtDNS"
                                       Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="12"
                                       Margin="0,2" TextWrapping="Wrap"/>
                        </Grid>
                    </Border>

                </StackPanel>

                <Border Grid.Row="2" Padding="16,0">
                    <Button x:Name="BtnClose2" Content="" Height="38"
                            Background="#6E277A" Foreground="White" BorderThickness="0"
                            FontFamily="Segoe UI Semibold" FontSize="13" Cursor="Hand"/>
                </Border>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    $rdr = [System.Xml.XmlNodeReader]::new($IXAML)
    $iw  = [Windows.Markup.XamlReader]::Load($rdr)

    $ft = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)

    # Fill data
    $iw.FindName("WinTitle").Text       = $lblTitle
    $iw.FindName("LblInterface").Text   = $lblInterface
    $iw.FindName("TxtInterface").Text   = $iface
    $iw.FindName("LblIP").Text          = $lblIP
    $iw.FindName("TxtIP").Text          = if ($ipv4) { $ipv4 } else { "N/A" }
    $iw.FindName("LblType").Text        = $lblType
    $iw.FindName("TxtType").Text        = $typeLabel
    $iw.FindName("TxtType").Foreground  = [Windows.Media.BrushConverter]::new().ConvertFromString($typeColor)
    $iw.FindName("LblDNS").Text         = $lblDNS
    $iw.FindName("TxtDNS").Text         = $dnsLabel
    $iw.FindName("BtnClose2").Content   = $lblClose

    # Button templates and hover
    $btnOk = $iw.FindName("BtnClose2")
    $btnOk.Template = $ft
    $btnOk.Tag = "#6E277A|#8E3A9A"
    $btnOk.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
    $btnOk.Add_MouseLeave({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })

    $btnX = $iw.FindName("BtnClose")
    $btnX.Template = $ft
    $btnX.Add_Click({ $iw.Close() })
    $btnOk.Add_Click({ $iw.Close() })

    $iw.FindName("TitleBar").Add_MouseLeftButtonDown({ param($s,$e) $iw.DragMove() })

    $iw.ShowDialog() | Out-Null
}

Export-ModuleMember -Function Verificar-DriverWifi, Abrir-Download-WifiDriver, Diagnostico-Rede, Get-WifiDriverInfo, Mostrar-Resultado-Rede, Verificar-IP-DNS
