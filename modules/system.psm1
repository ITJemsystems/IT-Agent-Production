# ==============================================================
# system.psm1 - PC Diagnostic and Cache Cleanup
# ==============================================================
# WHAT THIS MODULE DOES:
#   Provides two user-facing functions and their result windows:
#
#   Diagnostico-PC  (action 13):
#     6-step diagnostic that collects system metrics and shows
#     a WPF result window with health score, CPU/RAM/disk bars,
#     and uptime. Optionally offers a restart if uptime > 24h.
#
#   Limpar-PC (action 5):
#     5-step cache cleanup that removes Windows temp files,
#     browser cache (Chrome and Edge), and empties the recycle bin.
#     Asks user whether to close running apps first (Deep vs Safe mode).
#     Shows a WPF result window with space freed and mode used.
#
# DIAGNOSTIC STEPS (match ActionSteps "13" in ui.psm1):
#   Step 1 (17%) - OS and machine info (COMPUTERNAME, Windows version)
#   Step 2 (34%) - CPU usage via Win32_Processor (works on Win11)
#   Step 3 (51%) - RAM total/used/free via Win32_OperatingSystem
#   Step 4 (68%) - Disk C: usage via Get-PSDrive
#   Step 5 (85%) - Health score calculation (0-100 based on thresholds)
#   Step 6 (100%)- Uptime check, offer restart if > 24 hours
#
# CLEANUP STEPS (match ActionSteps "5" in ui.psm1):
#   Step 1 (20%) - Measure cache size before cleanup
#   Step 2 (40%) - Close browser/app processes (Deep mode only)
#   Step 3 (60%) - Delete temp files (%TEMP%, INetCache, Explorer)
#   Step 4 (80%) - Clear browser cache (Chrome, Edge Default profiles)
#   Step 5 (100%)- Empty recycle bin
#
# HEALTH SCORE THRESHOLDS:
#   Starts at 100, deductions apply:
#   CPU > 80%     -> -20 points
#   RAM free < 2GB -> -20 points
#   Disk free < 10GB -> -30 points
#   80-100 = BOM (green), 50-79 = ATENCAO (yellow), 0-49 = CRITICO (red)
#
# RESULT WINDOWS:
#   Both functions open a separate WPF window (same style as
#   network.psm1 result window) with dark purple border + shadow.
# ==============================================================

function Diagnostico-PC {
    $Global:UltimaFuncaoExecutada = Get-Text "System.DiagnosticFunctionName"

    # Step 1 (17%): Collect basic system info
    Barra-Progresso (Get-Text "Step.Diag.SysInfo")
    $pc        = $env:COMPUTERNAME
    $os        = (Get-CimInstance Win32_OperatingSystem).Caption
    $osVersion = (Get-CimInstance Win32_OperatingSystem).Version
    Escrever-Log -Mensagem "PC=$pc | OS=$os | Version=$osVersion" -FunctionName "SYSTEM" -Application "PC Diagnostic" -Action "CollectSystemInfo" -Status "INFO"

    # Step 2 (34%): Read CPU usage
    # Note: Get-Counter is avoided because it fails on Windows 11 when
    # performance counters are disabled. Win32_Processor.LoadPercentage
    # works reliably without admin rights on all Windows versions.
    Barra-Progresso (Get-Text "Step.Diag.CPU")
    $cpuName  = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $cpuLoad  = Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average
    $cpuUsage = [math]::Round($cpuLoad.Average, 2)
    Escrever-Log -Mensagem "CPU=$cpuUsage% | Nome=$cpuName" -FunctionName "SYSTEM" -Application "PC Diagnostic" -Action "CPUCheck" -Status "INFO"

    # Step 3 (51%): Read RAM usage
    # FreePhysicalMemory is in KB, convert to GB for display
    Barra-Progresso (Get-Text "Step.Diag.RAM")
    $ramTotal = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1GB, 1)
    $os_mem   = Get-CimInstance Win32_OperatingSystem
    $ramLivre = [math]::Round($os_mem.FreePhysicalMemory / 1MB, 1)
    $ramUso   = [math]::Round($ramTotal - $ramLivre, 1)
    $ramPct   = [math]::Round(($ramUso / $ramTotal) * 100, 0)
    Escrever-Log -Mensagem "RAM Total=$ramTotal GB | Used=$ramUso GB | Free=$ramLivre GB" -FunctionName "SYSTEM" -Application "PC Diagnostic" -Action "RAMCheck" -Status "INFO"

    # Step 4 (68%): Read disk C: usage via PowerShell drive provider
    Barra-Progresso (Get-Text "Step.Diag.Disk")
    $disk        = Get-PSDrive C
    $diskTotal   = [math]::Round(($disk.Used + $disk.Free) / 1GB, 1)
    $diskFreeGB  = [math]::Round($disk.Free / 1GB, 1)
    $diskUsedGB  = [math]::Round($disk.Used / 1GB, 1)
    $diskPct     = [math]::Round(($diskUsedGB / $diskTotal) * 100, 0)
    Escrever-Log -Mensagem "Disco Total=$diskTotal GB | Used=$diskUsedGB GB | Free=$diskFreeGB GB" -FunctionName "SYSTEM" -Application "PC Diagnostic" -Action "DiskCheck" -Status "INFO"

    # Step 5 (85%): Calculate health score based on thresholds
    # Score starts at 100 and gets deductions for bad metrics
    Barra-Progresso (Get-Text "Step.Diag.Health")
    $score = 100
    if ($cpuUsage   -gt 80) { $score -= 20 }
    if ($ramLivre   -lt 2)  { $score -= 20 }
    if ($diskFreeGB -lt 10) { $score -= 30 }
    if ($score -ge 80)     { $healthLabel = Get-Text "System.StatusGood";     $healthColor = "#3EA384" }
    elseif ($score -ge 50) { $healthLabel = Get-Text "System.StatusWarning";  $healthColor = "#F7C02D" }
    else                   { $healthLabel = Get-Text "System.StatusCritical"; $healthColor = "#E05050" }
    Escrever-Log -Mensagem "HealthScore=$score | Status=$healthLabel" -FunctionName "SYSTEM" -Application "PC Diagnostic" -Action "HealthScore" -Status "INFO"

    # Step 6 (100%): Check system uptime
    # If PC has been on for 24+ hours, offer a scheduled restart
    Barra-Progresso (Get-Text "Step.Diag.Uptime")
    $bootTime   = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $uptime     = New-TimeSpan -Start $bootTime -End (Get-Date)
    $dias       = $uptime.Days
    $horas      = $uptime.Hours
    $uptimeText = "$dias $(Get-Text 'System.Days') $horas $(Get-Text 'System.Hours')"
    $uptimeWarn = $uptime.TotalHours -ge 24
    Escrever-Log -Mensagem "Uptime=$dias days $horas hours" -FunctionName "SYSTEM" -Application "PC Diagnostic" -Action "UptimeCheck" -Status "INFO"

    WPF-Log "Score: $score/100 | CPU: $cpuUsage% | RAM: $ramUso/$ramTotal GB | Disco: $diskUsedGB/$diskTotal GB"

    Mostrar-Resultado-Diagnostico -pc $pc -os $os -cpuName $cpuName -cpuUsage $cpuUsage `
        -ramTotal $ramTotal -ramUso $ramUso -ramLivre $ramLivre -ramPct $ramPct `
        -diskTotal $diskTotal -diskUsedGB $diskUsedGB -diskFreeGB $diskFreeGB -diskPct $diskPct `
        -score $score -healthLabel $healthLabel -healthColor $healthColor `
        -uptimeText $uptimeText -uptimeWarn $uptimeWarn -dias $dias -horas $horas
}

# Opens the PC Diagnostic result window after all 6 steps complete.
# Receives all collected metrics as parameters.
# Bar widths are calculated as percentage of 454px (card inner width).
function Mostrar-Resultado-Diagnostico {
    param(
        $pc, $os, $cpuName, $cpuUsage,
        $ramTotal, $ramUso, $ramLivre, $ramPct,
        $diskTotal, $diskUsedGB, $diskFreeGB, $diskPct,
        $score, $healthLabel, $healthColor,
        $uptimeText, $uptimeWarn, $dias, $horas
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $cpuColor  = if ($cpuUsage  -gt 80) {"#E05050"} elseif ($cpuUsage  -gt 50) {"#F7C02D"} else {"#3EA384"}
    $ramColor  = if ($ramPct    -gt 85) {"#E05050"} elseif ($ramPct    -gt 65) {"#F7C02D"} else {"#3EA384"}
    $diskColor = if ($diskFreeGB -lt 10) {"#E05050"} elseif ($diskPct  -gt 80) {"#F7C02D"} else {"#3EA384"}
    $upColor   = if ($uptimeWarn) {"#F7C02D"} else {"#3EA384"}

    [xml]$RXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diagnostico do PC" Width="544" Height="624"
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
                        <TextBlock x:Name="DiagTitle" Text="Diagnostico do PC" Foreground="White"
                                   FontFamily="Segoe UI Semibold" FontSize="14"
                                   VerticalAlignment="Center"/>
                    </DockPanel>
                </Border>

                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="16,12,16,0">
                    <StackPanel>
                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <StackPanel>
                                <TextBlock x:Name="TxtPC" Text="" Foreground="#3D1147"
                                           FontFamily="Segoe UI Semibold" FontSize="14"/>
                                <TextBlock x:Name="TxtOS" Text="" Foreground="#6B5878"
                                           FontFamily="Segoe UI" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <DockPanel>
                                <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="12,0,0,0">
                                    <TextBlock x:Name="TxtScore" Text="100" FontFamily="Segoe UI Black" FontSize="36" HorizontalAlignment="Center"/>
                                    <TextBlock Text="/ 100" Foreground="#94A3B8" FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Center"/>
                                </StackPanel>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock x:Name="DiagHealthLabel" Text="PC Health Score" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13"/>
                                    <TextBlock x:Name="TxtHealth" Text="" FontFamily="Segoe UI Semibold" FontSize="20" Margin="0,4,0,0"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <StackPanel>
                                <DockPanel Margin="0,0,0,6">
                                    <TextBlock x:Name="TxtCpuPct" Text="" DockPanel.Dock="Right" FontFamily="Segoe UI Black" FontSize="18"/>
                                    <TextBlock x:Name="DiagCPULabel" Text="CPU" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
                                </DockPanel>
                                <TextBlock x:Name="TxtCpuName" Text="" Foreground="#6B5878" FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,8" TextWrapping="Wrap"/>
                                <Border Background="#E8E0EC" CornerRadius="4" Height="8">
                                    <Border x:Name="BarCpu" Background="#3EA384" CornerRadius="4" HorizontalAlignment="Left" Width="0" Height="8"/>
                                </Border>
                            </StackPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <StackPanel>
                                <DockPanel Margin="0,0,0,6">
                                    <TextBlock x:Name="TxtRamPct" Text="" DockPanel.Dock="Right" FontFamily="Segoe UI Black" FontSize="18"/>
                                    <TextBlock x:Name="DiagRAMLabel" Text="RAM" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
                                </DockPanel>
                                <TextBlock x:Name="TxtRamDetail" Text="" Foreground="#6B5878" FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,8"/>
                                <Border Background="#E8E0EC" CornerRadius="4" Height="8">
                                    <Border x:Name="BarRam" Background="#3EA384" CornerRadius="4" HorizontalAlignment="Left" Width="0" Height="8"/>
                                </Border>
                            </StackPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                            <StackPanel>
                                <DockPanel Margin="0,0,0,6">
                                    <TextBlock x:Name="TxtDiskPct" Text="" DockPanel.Dock="Right" FontFamily="Segoe UI Black" FontSize="18"/>
                                    <TextBlock x:Name="DiagDiskLabel" Text="Disco C:" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
                                </DockPanel>
                                <TextBlock x:Name="TxtDiskDetail" Text="" Foreground="#6B5878" FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,8"/>
                                <Border Background="#E8E0EC" CornerRadius="4" Height="8">
                                    <Border x:Name="BarDisk" Background="#3EA384" CornerRadius="4" HorizontalAlignment="Left" Width="0" Height="8"/>
                                </Border>
                            </StackPanel>
                        </Border>

                        <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,4">
                            <DockPanel>
                                <TextBlock Text="&#x23F0;" DockPanel.Dock="Right" FontSize="22" VerticalAlignment="Center" Margin="12,0,0,0"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock x:Name="DiagUptimeLabel" Text="Tempo de Atividade" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13"/>
                                    <TextBlock x:Name="TxtUptime" Text="" FontFamily="Segoe UI" FontSize="13" Margin="0,4,0,0"/>
                                    <TextBlock x:Name="TxtUptimeWarn" Text="" Foreground="#F7C02D"
                                               FontFamily="Segoe UI" FontSize="11" Margin="0,2,0,0"
                                               Visibility="Collapsed" TextWrapping="Wrap"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <Border Grid.Row="2" Padding="16,0">
                    <Button x:Name="BtnDiagClose" Content="Fechar" Height="38"
                            Background="#6E277A" Foreground="White" BorderThickness="0"
                            FontFamily="Segoe UI Semibold" FontSize="13" Cursor="Hand"/>
                </Border>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    $rdr = [System.Xml.XmlNodeReader]::new($RXAML)
    $rw  = [Windows.Markup.XamlReader]::Load($rdr)

    # Apply language translations BEFORE populating data
    if ($Global:Language -eq "EN") {
        try { $rw.FindName("DiagTitle").Text       = "PC Diagnostic" }       catch {}
        try { $rw.FindName("DiagHealthLabel").Text = "PC Health Score" }     catch {}
        try { $rw.FindName("DiagCPULabel").Text    = "CPU" }                 catch {}
        try { $rw.FindName("DiagRAMLabel").Text    = "RAM" }                 catch {}
        try { $rw.FindName("DiagDiskLabel").Text   = "Disk C:" }             catch {}
        try { $rw.FindName("DiagUptimeLabel").Text = "Activity Time" }       catch {}
        try { $rw.FindName("BtnDiagClose").Content = "Close" }               catch {}
    }

    # Flat template for buttons in this window (no WPF hover chrome)
    $ft = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)
    # Apply flat + hover to BtnOk (purple -> 2 tones lighter)
    $btnOk = $rw.FindName("BtnDiagClose")
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

    $rw.FindName("TxtPC").Text     = $pc
    $rw.FindName("TxtOS").Text     = $os
    $rw.FindName("TxtScore").Text  = "$score"
    $rw.FindName("TxtScore").Foreground  = [Windows.Media.BrushConverter]::new().ConvertFromString($healthColor)
    $rw.FindName("TxtHealth").Text       = $healthLabel
    $rw.FindName("TxtHealth").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($healthColor)

    $barWidth = 454
    $rw.FindName("TxtCpuPct").Text       = "$cpuUsage%"
    $rw.FindName("TxtCpuPct").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($cpuColor)
    $rw.FindName("TxtCpuName").Text      = $cpuName
    $rw.FindName("BarCpu").Background    = [Windows.Media.BrushConverter]::new().ConvertFromString($cpuColor)
    $rw.FindName("BarCpu").Width         = [math]::Max(4, [math]::Round($barWidth * $cpuUsage / 100))

    $rw.FindName("TxtRamPct").Text       = "$ramPct%"
    $rw.FindName("TxtRamPct").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($ramColor)
    $rw.FindName("TxtRamDetail").Text    = if ($Global:Language -eq "EN") { "In use: $ramUso GB  |  Free: $ramLivre GB  |  Total: $ramTotal GB" } else { "Em uso: $ramUso GB  |  Livre: $ramLivre GB  |  Total: $ramTotal GB" }
    $rw.FindName("BarRam").Background    = [Windows.Media.BrushConverter]::new().ConvertFromString($ramColor)
    $rw.FindName("BarRam").Width         = [math]::Max(4, [math]::Round($barWidth * $ramPct / 100))

    $rw.FindName("TxtDiskPct").Text      = "$diskPct%"
    $rw.FindName("TxtDiskPct").Foreground= [Windows.Media.BrushConverter]::new().ConvertFromString($diskColor)
    $rw.FindName("TxtDiskDetail").Text   = if ($Global:Language -eq "EN") { "In use: $diskUsedGB GB  |  Free: $diskFreeGB GB  |  Total: $diskTotal GB" } else { "Em uso: $diskUsedGB GB  |  Livre: $diskFreeGB GB  |  Total: $diskTotal GB" }
    $rw.FindName("BarDisk").Background   = [Windows.Media.BrushConverter]::new().ConvertFromString($diskColor)
    $rw.FindName("BarDisk").Width        = [math]::Max(4, [math]::Round($barWidth * $diskPct / 100))

    $rw.FindName("TxtUptime").Text       = $uptimeText
    $rw.FindName("TxtUptime").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($upColor)
    if ($uptimeWarn) {
        $rw.FindName("TxtUptimeWarn").Text       = if ($Global:Language -eq "EN") { "Restart recommended. PC has been on for more than 24 hours." } else { "Reinicio recomendado. PC ligado ha mais de 24 horas." }
        $rw.FindName("TxtUptimeWarn").Visibility = "Visible"
    }

    $rw.FindName("BtnDiagClose").Add_Click({
        $rw.Close()
        if ($uptimeWarn) {
            Add-Type -AssemblyName PresentationFramework
            $msg  = "$(Get-Text 'System.UptimeRestartQuestion') $dias $(Get-Text 'System.Days') $horas $(Get-Text 'System.Hours')`n`n$(Get-Text 'System.RestartNow')"
            $resp = [System.Windows.MessageBox]::Show($msg,(Get-Text "System.RestartWindowTitle"),"YesNo","Warning")
            if ($resp -eq "Yes") {
                [System.Windows.MessageBox]::Show((Get-Text "System.RestartCountdown"),(Get-Text "System.RestartScheduledTitle"),"OK","Warning") | Out-Null
                & "$env:SystemRoot\System32\shutdown.exe" /r /t 40 /c "Reinicio recomendado pelo diagnostico."
            }
        }
        Perguntar-Resolvido
    })

    $rw.ShowDialog() | Out-Null
}

# ==============================================================
# LIMPAR-PC - Cache cleanup function
# Safe to run without admin rights.
# All paths target user-space temp folders only.
# Does NOT touch: documents, downloads, browser profile data,
# passwords, cookies, or any user-created files.
# ==============================================================
function Limpar-PC {
    $Global:UltimaFuncaoExecutada = Get-Text "System.CleanFunctionName"
    $inicio = Get-Date
    # ==============================================================
    # DEEP/SOFT CLEAN DIALOG - Custom WPF style matching app design
    # Replaces the old plain Windows MessageBox
    # ==============================================================
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $dlgTitle    = if ($Global:Language -eq "EN") { "Cache Cleanup" }                                                     else { "Limpeza de Cache" }
    $dlgQuestion = if ($Global:Language -eq "EN") { "Close open apps before cleaning?" }                                  else { "Fechar apps abertos antes de limpar?" }
    $dlgDeepDesc = if ($Global:Language -eq "EN") { "Deep Clean: closes browsers and apps. More thorough." }             else { "Deep Clean: fecha navegadores e apps. Mais completo." }
    $dlgSafeDesc = if ($Global:Language -eq "EN") { "Safe Clean: only cleans unlocked files. Apps stay open." }          else { "Safe Clean: limpa apenas arquivos desbloqueados. Apps ficam abertos." }

    # ==============================================================
    # REVIT COLLABORATIONCACHE DETECTION
    # Scans for any version of Revit (2021/2022/2023/2024/2025...)
    # under %LOCALAPPDATA%\Autodesk\Revit\Autodesk Revit [version]\CollaborationCache
    # If found, appends a warning to the Deep Clean description.
    # These paths are only cleaned in Deep Clean mode.
    # ==============================================================
    $revitCachePaths = @()
    $revitBase       = Join-Path $env:LOCALAPPDATA "Autodesk\Revit"
    if (Test-Path $revitBase) {
        $revitCachePaths = Get-ChildItem $revitBase -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "^Autodesk Revit \d{4}" } |
            ForEach-Object { Join-Path $_.FullName "CollaborationCache" } |
            Where-Object { Test-Path $_ }
    }

    if ($revitCachePaths.Count -gt 0) {
        $versions = (Get-ChildItem $revitBase -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "^Autodesk Revit \d{4}" } |
            ForEach-Object { ($_.Name -replace "Autodesk Revit ", "") }) -join ", "

        $revitWarning = if ($Global:Language -eq "EN") {
            "`n`n`u{26A0} Revit $versions detected: CollaborationCache will be cleared. All locally downloaded project files will be removed and must be re-downloaded."
        } else {
            "`n`n`u{26A0} Revit $versions detectado: o CollaborationCache sera limpo. Todos os arquivos de projetos baixados localmente serao removidos e precisarao ser baixados novamente."
        }
        $dlgDeepDesc += $revitWarning
    }

    [xml]$dlgXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="420" Height="260" WindowStartupLocation="CenterScreen"
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
                    <RowDefinition Height="68"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="#6E277A" CornerRadius="10,10,0,0">
                    <TextBlock x:Name="DlgTitle" Text="" Foreground="White"
                               FontFamily="Segoe UI Semibold" FontSize="14"
                               VerticalAlignment="Center" Margin="16,0"/>
                </Border>
                <StackPanel Grid.Row="1" Margin="20,12,20,0">
                    <TextBlock x:Name="DlgQuestion" Text="" Foreground="#3D1147"
                               FontFamily="Segoe UI Semibold" FontSize="13" Margin="0,0,0,10"/>
                    <Border Background="#FFFFFF" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                        <TextBlock x:Name="DlgDeepDesc" Text="" Foreground="#6B5878"
                                   FontFamily="Segoe UI" FontSize="12" TextWrapping="Wrap"/>
                    </Border>
                    <Border Background="#FFFFFF" CornerRadius="8" Padding="12,10">
                        <TextBlock x:Name="DlgSafeDesc" Text="" Foreground="#6B5878"
                                   FontFamily="Segoe UI" FontSize="12" TextWrapping="Wrap"/>
                    </Border>
                </StackPanel>
                <Grid Grid.Row="2" Margin="16,0,16,16">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="8"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="BtnDeep" Grid.Column="0" Content="Deep Clean"
                            Height="38" Background="#6E277A" Foreground="White"
                            BorderThickness="0" FontFamily="Segoe UI Semibold"
                            FontSize="12" Cursor="Hand"/>
                    <Button x:Name="BtnSafe" Grid.Column="2" Content="Safe Clean"
                            Height="38" Background="#3EA384" Foreground="White"
                            BorderThickness="0" FontFamily="Segoe UI Semibold"
                            FontSize="12" Cursor="Hand"/>
                </Grid>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    $dlgRdr = [System.Xml.XmlNodeReader]::new($dlgXAML)
    $dlgWin = [Windows.Markup.XamlReader]::Load($dlgRdr)

    $dlgFt = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)

    # Fill text
    $dlgWin.FindName("DlgTitle").Text    = $dlgTitle
    $dlgWin.FindName("DlgQuestion").Text = $dlgQuestion
    $dlgWin.FindName("DlgDeepDesc").Text = $dlgDeepDesc
    $dlgWin.FindName("DlgSafeDesc").Text = $dlgSafeDesc

    # Apply templates and hover
    $btnD = $dlgWin.FindName("BtnDeep")
    $btnD.Template = $dlgFt
    $btnD.Tag = "#6E277A|#8E3A9A"
    $btnD.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
    $btnD.Add_MouseLeave({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })

    $btnS = $dlgWin.FindName("BtnSafe")
    $btnS.Template = $dlgFt
    $btnS.Tag = "#3EA384|#52BF9E"
    $btnS.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
    $btnS.Add_MouseLeave({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })

    # Choice result - mimics MessageBox "Yes"/"No" for compatibility
    $script:_cleanChoice = "No"
    $dlgWin.FindName("BtnDeep").Add_Click({ $script:_cleanChoice = "Yes"; $dlgWin.Close() })
    $dlgWin.FindName("BtnSafe").Add_Click({ $script:_cleanChoice = "No";  $dlgWin.Close() })
    $dlgWin.ShowDialog() | Out-Null
    $choice = $script:_cleanChoice
    $CMD    = "$env:SystemRoot\System32\cmd.exe"
    $paths  = @(
        $env:TEMP, "$env:LOCALAPPDATA\Temp",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "$env:LOCALAPPDATA\Microsoft\Windows\Explorer",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
    )

    # Deep Clean only: add Revit CollaborationCache paths found at startup
    # Safe Clean skips these — they may contain large project files the user
    # may still need, so only cleared when user explicitly chose Deep Clean
    # and was warned about it in the dialog above
    if ($choice -eq "Yes" -and $revitCachePaths.Count -gt 0) {
        $paths += $revitCachePaths
        WPF-Log "Revit CollaborationCache incluido na limpeza..." -Color "#F7C02D"
    }
    # Step 1 (20%): Measure total cache size before deletion (for result window)
    Barra-Progresso (Get-Text "Step.Clean.Scan")
    $sizeBefore = 0
    foreach ($path in $paths) { if (Test-Path $path) { try { $sizeBefore += (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch {} } }

    # Step 2 (40%): Deep mode closes apps that lock cache files
    # Safe mode skips this step and cleans only unlocked files
    Barra-Progresso (Get-Text "Step.Clean.Apps")
    if ($choice -eq "Yes") {
        WPF-Log (Get-Text "System.DeepCleanMode")
        foreach ($app in @("chrome","msedge","teams","outlook","onedrive")) { Get-Process $app -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    } else { WPF-Log (Get-Text "System.SafeCleanMode") }

    # Step 3 (60%): Delete all temp files
    # Uses both Remove-Item (PowerShell) and cmd del for thorough cleanup
    Barra-Progresso (Get-Text "Step.Clean.Temp")
    foreach ($path in $paths) {
        if (Test-Path $path) {
            try { Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            try { & $CMD /c "del /f /s /q `"$path\*`" >nul 2>&1" } catch {}
        }
    }
    try { & $CMD /c "del /f /s /q %windir%\Temp\* >nul 2>&1" } catch {}

    # Step 4 (80%): Browser cache already cleaned in Step 3 (paths included above)
    # This step logs completion and advances the progress bar
    Barra-Progresso (Get-Text "Step.Clean.Browser")
    # Step 5 (100%): Empty the recycle bin for all drives
    # -Force suppresses confirmation dialog
    Barra-Progresso (Get-Text "Step.Clean.Recycle")
    try { Clear-RecycleBin -Force -ErrorAction Stop } catch {}

    $sizeAfter = 0
    foreach ($path in $paths) { if (Test-Path $path) { try { $sizeAfter += (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch {} } }
    $freedGB  = [math]::Round(($sizeBefore - $sizeAfter) / 1GB, 2)
    $beforeGB = [math]::Round($sizeBefore / 1GB, 2)
    WPF-Log "Espaco liberado: $freedGB GB" -Color "#3EA384"
    # FIX (v1.3.0): -MetricValue/-MetricUnit tornam o "GB liberado" um
    # numero agregavel na dashboard (SUM), em vez de so texto dentro de
    # "details" que so dava para ler, nao para somar entre varias execucoes.
    Escrever-Log -Mensagem "Limpeza concluida | FreedSpace=$freedGB GB" -FunctionName "SYSTEM" -Application "PC Cleanup" -Action "CleanupFinished" -Status "SUCCESS" -MetricValue $freedGB -MetricUnit "GB"
    Mostrar-Resultado-Limpeza -FreedGB $freedGB -BeforeGB $beforeGB -Modo $(if ($choice -eq "Yes") {"Deep Clean"} else {"Safe Clean"})
}

# =====================================================================
# CLEANUP RESULT WINDOW
# =====================================================================
# Opens the cleanup result window after Limpar-PC completes.
# Shows space freed, mode used (Deep/Safe), and cache found before cleanup.
# BtnOk -> close window -> Perguntar-Resolvido
# BtnClose (X) -> close window only, no resolution dialog
function Mostrar-Resultado-Limpeza {
    param([double]$FreedGB, [double]$BeforeGB, [string]$Modo)

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $iconText   = if ($FreedGB -gt 0) { "OK" } else { "!" }
    $iconColor  = if ($FreedGB -gt 0) { "#3EA384" } else { "#F7C02D" }
    $freedText  = if ($FreedGB -gt 0) { if ($Global:Language -eq "EN") { "$FreedGB GB freed" } else { "$FreedGB GB liberados" } } else { if ($Global:Language -eq "EN") { "No space freed" } else { "Nenhum espaco liberado" } }
    $subText    = if ($FreedGB -gt 0) { if ($Global:Language -eq "EN") { "Cache and temporary files removed successfully." } else { "Cache e arquivos temporarios removidos com sucesso." } } else { if ($Global:Language -eq "EN") { "Temporary files were already clean." } else { "Os arquivos temporarios ja estavam limpos." } }

    [xml]$CXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Limpeza Concluida" Width="460" Height="320"
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
                        <TextBlock x:Name="CleanTitle" Text="Limpeza Concluida" Foreground="White"
                                   FontFamily="Segoe UI Semibold" FontSize="14"
                                   VerticalAlignment="Center"/>
                    </DockPanel>
                </Border>

                <StackPanel Grid.Row="1" VerticalAlignment="Center" Margin="24,0">

                    <!-- Icon + freed space -->
                    <Border Background="#FFFFFF" CornerRadius="10" Padding="20,16" Margin="0,0,0,12">
                        <DockPanel>
                            <Border DockPanel.Dock="Left" Width="56" Height="56"
                                    CornerRadius="28" Margin="0,0,16,0">
                                <Border.Background>
                                    <SolidColorBrush x:Name="IconBg" Color="#E8F5F0"/>
                                </Border.Background>
                                <TextBlock x:Name="TxtIcon" Text="OK"
                                           FontFamily="Segoe UI Black" FontSize="14"
                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <StackPanel VerticalAlignment="Center">
                                <TextBlock x:Name="TxtFreed" Text=""
                                           Foreground="#3D1147" FontFamily="Segoe UI Black"
                                           FontSize="16" TextWrapping="Wrap"/>
                                <TextBlock x:Name="TxtSub" Text=""
                                           Foreground="#6B5878" FontFamily="Segoe UI"
                                           FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- Mode and before size -->
                    <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0">
                                <TextBlock x:Name="CleanModeLabel" Text="Modo" Foreground="#94A3B8"
                                           FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,2"/>
                                <TextBlock x:Name="TxtModo" Text=""
                                           Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1">
                                <TextBlock x:Name="CleanFoundLabel" Text="Cache encontrado" Foreground="#94A3B8"
                                           FontFamily="Segoe UI" FontSize="11" Margin="0,0,0,2"/>
                                <TextBlock x:Name="TxtBefore" Text=""
                                           Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="13"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                </StackPanel>

                <Border Grid.Row="2" Padding="16,0">
                    <Button x:Name="BtnOk" Content="Fechar" Height="38"
                            Background="#6E277A" Foreground="White" BorderThickness="0"
                            FontFamily="Segoe UI Semibold" FontSize="13" Cursor="Hand"/>
                </Border>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    $rdr = [System.Xml.XmlNodeReader]::new($CXAML)
    $cw  = [Windows.Markup.XamlReader]::Load($rdr)

    # Apply language to Cleanup result window
    if ($Global:Language -eq "EN") {
        try { $cw.FindName("CleanTitle").Text      = "Cleanup Complete" }  catch {}
        try { $cw.FindName("CleanModeLabel").Text  = "Mode" }              catch {}
        try { $cw.FindName("CleanFoundLabel").Text = "Cache found" }       catch {}
        try { $cw.FindName("BtnOk").Content        = "Close" }             catch {}
    }

    $ft = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)

    $cw.FindName("TitleBar").Add_MouseLeftButtonDown({ param($s,$e) $cw.DragMove() })

    $btnOk = $cw.FindName("BtnOk")
    $btnOk.Template = $ft
    $btnOk.Tag = "#6E277A|#8E3A9A"
    $btnOk.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
    $btnOk.Add_MouseLeave({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })

    $btnCl = $cw.FindName("BtnClose")
    $btnCl.Template = $ft
    $btnCl.Tag = "Transparent|#5A2468"
    $btnCl.Add_MouseEnter({ param($s,$e) $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString("#5A2468") })
    $btnCl.Add_MouseLeave({ param($s,$e) $s.Background=[Windows.Media.Brushes]::Transparent })

    $cw.FindName("TxtIcon").Text       = $iconText
    $cw.FindName("TxtIcon").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($iconColor)
    $cw.FindName("TxtFreed").Text      = $freedText
    $cw.FindName("TxtFreed").Foreground= [Windows.Media.BrushConverter]::new().ConvertFromString($iconColor)
    $cw.FindName("TxtSub").Text        = $subText
    $cw.FindName("TxtModo").Text       = $Modo
    $cw.FindName("TxtBefore").Text     = "$BeforeGB GB"

    $cw.FindName("BtnClose").Add_Click({ $cw.Close() })
    $cw.FindName("BtnOk").Add_Click({
        $cw.Close()
        Perguntar-Resolvido
    })

    $cw.ShowDialog() | Out-Null
}



# ==============================================================
# OTIMIZAR-REGISTRO - HKCU Registry cleanup (action 14)
# ==============================================================
# WHAT THIS FUNCTION DOES:
#   Cleans 4 categories of safe-to-remove entries inside HKCU
#   (HKEY_CURRENT_USER) - no admin rights required, no system
#   entries are touched.
#
# STEP 1 (20%) - Scan: count entries before cleanup for result window
# STEP 2 (40%) - MRU lists: remove "recent files" entries left by
#   Office, Notepad, Paint, Windows Explorer and other apps.
#   These accumulate over time and slow down app startup menus.
# STEP 3 (60%) - Orphan keys: detect keys under HKCU\Software
#   whose parent app folder no longer exists in Program Files or
#   LocalAppData. Safe to remove - the app is gone.
# STEP 4 (80%) - Temp variables: remove user-scoped environment
#   variables whose value points to a path that no longer exists.
# STEP 5 (100%) - Show result window
#
# WHAT IS NEVER TOUCHED:
#   - HKLM (requires admin, system-wide)
#   - HKCU\Software\Microsoft\Windows (OS shell keys)
#   - HKCU\Software\Microsoft\Office (Office profile - complex)
#   - Any key whose parent path still exists on disk
#   - DLL references, COM/CLSID, file associations
#
# SAFETY APPROACH:
#   Before deleting any key, the function checks whether the
#   associated application path still exists. If there is any
#   doubt, the key is SKIPPED. False positives (wrongly deleting
#   a valid key) are worse than leaving orphan keys in place.
# ==============================================================
function Otimizar-Registro {
    # ==============================================================
    # SAFE REGISTRY CLEANUP - MRU lists only
    # Only touches well-known, safe-to-clear MRU keys under HKCU.
    # These keys store "recently opened files/folders" entries.
    # Windows rebuilds them automatically - removing them is safe.
    # No orphan key detection, no env vars, no HKLM - nothing risky.
    # ==============================================================

    $Global:UltimaFuncaoExecutada = "Otimizar Registro"
    Escrever-Log -Mensagem "=== INICIO LIMPEZA DE HISTORICO ===" -FunctionName "SYSTEM" -Action "Start" -Status "INFO"

    # ----------------------------------------------------------
    # All MRU paths are hardcoded (no dynamic discovery = no risk)
    # These are the same paths that CCleaner cleans without warning
    # ----------------------------------------------------------
    $mruPaths = @(
        # Files opened via standard Open/Save dialogs
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU",
        # Win+R Run dialog history
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU",
        # Address bar typed paths in Explorer
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths",
        # Recent documents list (not the Documents folder - just the shortcut list)
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs",
        # Recent folders in Explorer sidebar
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Map Network Drive MRU",
        # Find/search history in older Windows dialogs
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FindComputerMRU",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\PrnPortsMRU"
    )

    # ----------------------------------------------------------
    # Step 1 (20%): Count entries before cleanup
    # ----------------------------------------------------------
    Barra-Progresso (Get-Text "Step.Reg.Scan")

    $countBefore = 0
    foreach ($path in $mruPaths) {
        if (Test-Path $path) {
            try {
                $k = Get-Item $path -ErrorAction SilentlyContinue
                if ($k) { $countBefore += $k.GetValueNames().Count }
            } catch {}
        }
    }
    Escrever-Log -Mensagem "Scan: $countBefore entradas encontradas" -FunctionName "SYSTEM" -Action "ScanDone" -Status "INFO"

    # ----------------------------------------------------------
    # Step 2 (40%): Clear MRU values (not the keys themselves)
    # ----------------------------------------------------------
    Barra-Progresso (Get-Text "Step.Reg.MRU")

    $mruCleaned = 0
    foreach ($path in $mruPaths) {
        if (Test-Path $path) {
            try {
                $key = Get-Item $path -ErrorAction SilentlyContinue
                if ($key) {
                    # Remove each named value - the key itself stays intact
                    # Windows will repopulate it when you next use the dialog
                    $key.GetValueNames() | ForEach-Object {
                        Remove-ItemProperty -Path $path -Name $_ -ErrorAction SilentlyContinue
                        $mruCleaned++
                    }
                }
                # Individual path logged silently - summary sent at end of function
            } catch {
                # Skip logged silently
            }
        }
    }
    # ----------------------------------------------------------
    # Step 3 (60%): Clear pinned/recent items from taskbar jumplist
    # Stored as files in a known folder - safe to delete
    # ----------------------------------------------------------
    Barra-Progresso (Get-Text "Step.Reg.Orphan")

    $jumplistCleaned = 0
    $jumplistPaths = @(
        "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations",
        "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations"
    )
    foreach ($jpath in $jumplistPaths) {
        if (Test-Path $jpath) {
            try {
                $files = Get-ChildItem $jpath -File -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                    $jumplistCleaned++
                }
                # Individual jumplist logged silently - summary sent at end
            } catch {
                # Skip logged silently
            }
        }
    }
    # ----------------------------------------------------------
    # Step 4 (80%): Clear Windows Search history (user scope only)
    # ----------------------------------------------------------
    Barra-Progresso (Get-Text "Step.Reg.Temp")

    $searchCleaned = 0
    $searchPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery"
    if (Test-Path $searchPath) {
        try {
            $sk = Get-Item $searchPath -ErrorAction SilentlyContinue
            if ($sk) {
                $sk.GetValueNames() | Where-Object { $_ -ne "MRUListEx" } | ForEach-Object {
                    Remove-ItemProperty -Path $searchPath -Name $_ -ErrorAction SilentlyContinue
                    $searchCleaned++
                }
                # Reset MRUListEx to empty binary
                Set-ItemProperty -Path $searchPath -Name "MRUListEx" -Value ([byte[]](0xFF,0xFF,0xFF,0xFF)) -ErrorAction SilentlyContinue
            }
            Escrever-Log -Mensagem "Search history limpa: $searchCleaned termos" -FunctionName "SYSTEM" -Action "SearchCleaned" -Status "SUCCESS"
        } catch {
            # Search skip logged silently
        }
    }
    # ----------------------------------------------------------
    # Step 5 (100%): Show result window
    # ----------------------------------------------------------
    Barra-Progresso (Get-Text "Step.Reg.Done")

    $totalCleaned = $mruCleaned + $jumplistCleaned + $searchCleaned
    # FIX (v1.3.0): o evento final usava -Action "Done", que esta na
    # lista de ruido filtrada antes de chegar na dashboard (pensada
    # originalmente pra passos internos genericos de OUTRAS funcoes,
    # como Diagnostico-PC). Isso fazia o resumo da limpeza de registro
    # - com a contagem real de entradas limpas - nunca aparecer na
    # dashboard, mesmo ja estando calculado corretamente aqui.
    # Renomeado para "RegistryCleanupDone" (especifico, nao filtrado),
    # com -Application para agrupar bonito na dashboard, e -MetricValue
    # para o total virar um numero agregavel (SUM/AVG), nao so texto.
    Escrever-Log -Mensagem "Limpeza de registro concluida: $totalCleaned entradas removidas (MRU=$mruCleaned Jumplist=$jumplistCleaned Busca=$searchCleaned)" -FunctionName "SYSTEM" -Application "Otimizar Registro" -Action "RegistryCleanupDone" -Status "SUCCESS" -MetricValue $totalCleaned -MetricUnit "entradas"
    Mostrar-Resultado-Registro -MruCleaned $mruCleaned -OrphansCleaned $jumplistCleaned -EnvCleaned $searchCleaned -TotalBefore $countBefore
}

# ==============================================================
# RESULT WINDOW - Registry optimization summary
# ==============================================================
function Mostrar-Resultado-Registro {
    param(
        [int]$MruCleaned,
        [int]$OrphansCleaned,
        [int]$EnvCleaned,
        [int]$TotalBefore
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $totalCleaned = $MruCleaned + $OrphansCleaned + $EnvCleaned
    $iconText  = if ($totalCleaned -gt 0) { "OK" } else { "!" }
    $iconColor = if ($totalCleaned -gt 0) { "#3EA384" } else { "#F7C02D" }
    $headline  = if ($totalCleaned -gt 0) { if ($Global:Language -eq "EN") { "$totalCleaned entries removed" } else { "$totalCleaned entradas removidas" } } else { if ($Global:Language -eq "EN") { "History was already clean" } else { "Historico ja estava limpo" } }

    [xml]$RXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Otimizar Registro" Width="460" Height="400"
        WindowStartupLocation="CenterScreen"
        Background="Transparent" WindowStyle="None"
        AllowsTransparency="True" ResizeMode="NoResize">
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
                        <TextBlock x:Name="RegTitle" Text="Otimizacao de Registro" Foreground="White"
                                   FontFamily="Segoe UI Semibold" FontSize="14"
                                   VerticalAlignment="Center"/>
                    </DockPanel>
                </Border>

                <StackPanel Grid.Row="1" Margin="20,12,20,0">

                    <!-- Result hero card -->
                    <Border Background="#FFFFFF" CornerRadius="10" Padding="16,14" Margin="0,0,0,10">
                        <DockPanel>
                            <Border DockPanel.Dock="Left" Width="52" Height="52"
                                    CornerRadius="26" Margin="0,0,14,0" Background="#E8F5F0">
                                <TextBlock x:Name="TxtIcon" Text="OK"
                                           FontFamily="Segoe UI Black" FontSize="13"
                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <StackPanel VerticalAlignment="Center">
                                <TextBlock x:Name="TxtHeadline" Text=""
                                           Foreground="#3D1147" FontFamily="Segoe UI Black" FontSize="18"/>
                                <TextBlock x:Name="RegSubtitle" Text="entradas limpas no registro HKCU"
                                           Foreground="#6B5878" FontFamily="Segoe UI" FontSize="12" Margin="0,3,0,0"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- Detail cards -->
                    <Border Background="#FFFFFF" CornerRadius="10" Padding="16,12" Margin="0,0,0,10">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" HorizontalAlignment="Center">
                                <TextBlock x:Name="TxtMRU" Text="0"
                                           FontFamily="Segoe UI Black" FontSize="26"
                                           Foreground="#6E277A" HorizontalAlignment="Center"/>
                                <TextBlock Text="MRU" Foreground="#94A3B8"
                                           FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="RegLblMRU" Text="listas de recentes" Foreground="#6B5878"
                                           FontFamily="Segoe UI" FontSize="10" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" HorizontalAlignment="Center">
                                <TextBlock x:Name="TxtOrphans" Text="0"
                                           FontFamily="Segoe UI Black" FontSize="26"
                                           Foreground="#6E277A" HorizontalAlignment="Center"/>
                                <TextBlock Text="Jumplist" Foreground="#94A3B8"
                                           FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="RegLblJump" Text="itens recentes" Foreground="#6B5878"
                                           FontFamily="Segoe UI" FontSize="10" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"/>
                            </StackPanel>
                            <StackPanel Grid.Column="2" HorizontalAlignment="Center">
                                <TextBlock x:Name="TxtEnv" Text="0"
                                           FontFamily="Segoe UI Black" FontSize="26"
                                           Foreground="#6E277A" HorizontalAlignment="Center"/>
                                <TextBlock Text="Pesquisa" Foreground="#94A3B8"
                                           FontFamily="Segoe UI" FontSize="11" HorizontalAlignment="Center"/>
                                <TextBlock x:Name="RegLblSearch" Text="termos buscados" Foreground="#6B5878"
                                           FontFamily="Segoe UI" FontSize="10" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <!-- Info note -->
                    <Border Background="#F0EDF2" CornerRadius="8" Padding="14,10" Margin="0,0,0,0">
                        <TextBlock x:Name="RegNote" Text="Apenas historico de uso foi removido: arquivos recentes, pesquisas e jumplists. Nenhum dado, app ou configuracao foi afetado."
                                   Foreground="#6B5878" FontFamily="Segoe UI" FontSize="11"
                                   TextWrapping="Wrap"/>
                    </Border>

                </StackPanel>

                <Border Grid.Row="2" Padding="16,0">
                    <Button x:Name="BtnRegOk" Content="Fechar" Height="38"
                            Background="#6E277A" Foreground="White" BorderThickness="0"
                            FontFamily="Segoe UI Semibold" FontSize="13" Cursor="Hand"/>
                </Border>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    $rdr = [System.Xml.XmlNodeReader]::new($RXAML)
    $rw  = [Windows.Markup.XamlReader]::Load($rdr)

    # Apply language to Registry result window
    if ($Global:Language -eq "EN") {
        try { $rw.FindName("RegTitle").Text    = "Registry Optimization" }                                                                  catch {}
        try { $rw.FindName("RegSubtitle").Text = "entries cleaned from HKCU registry" }                                                    catch {}
        try { $rw.FindName("RegNote").Text     = "Only usage history was removed: recent files, searches and jumplists. No data, app or configuration was affected." } catch {}
        try { $rw.FindName("RegLblMRU").Text   = "recent lists" }                                                                           catch {}
        try { $rw.FindName("RegLblJump").Text  = "recent items" }                                                                           catch {}
        try { $rw.FindName("RegLblSearch").Text= "search terms" }                                                                           catch {}
        try { $rw.FindName("BtnRegOk").Content = "Close" }                                                                                  catch {}
    }

    $ft = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)

    $rw.FindName("TitleBar").Add_MouseLeftButtonDown({ param($s,$e) $rw.DragMove() })

    $btnOk = $rw.FindName("BtnRegOk")
    $btnOk.Template = $ft
    $btnOk.Tag = "#6E277A|#8E3A9A"
    $btnOk.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
    $btnOk.Add_MouseLeave({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })

    $btnCl = $rw.FindName("BtnClose")
    $btnCl.Template = $ft
    $btnCl.Tag = "Transparent|#5A2468"
    $btnCl.Add_MouseEnter({ param($s,$e) $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString("#5A2468") })
    $btnCl.Add_MouseLeave({ param($s,$e) $s.Background=[Windows.Media.Brushes]::Transparent })

    # Fill data
    $rw.FindName("TxtIcon").Text       = $iconText
    $rw.FindName("TxtIcon").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($iconColor)
    $rw.FindName("TxtHeadline").Text   = $headline
    $rw.FindName("TxtHeadline").Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($iconColor)
    $rw.FindName("TxtMRU").Text        = "$MruCleaned"
    $rw.FindName("TxtOrphans").Text    = "$OrphansCleaned"
    $rw.FindName("TxtEnv").Text        = "$EnvCleaned"

    $rw.FindName("BtnClose").Add_Click({ $rw.Close() })
    $rw.FindName("BtnRegOk").Add_Click({
        $rw.Close()
        Perguntar-Resolvido
    })

    $rw.ShowDialog() | Out-Null
}

# ==============================================================
# ADMIN MODE — Elevated actions (SFC, DISM, Flush DNS)
# ==============================================================
# These functions require admin elevation and are only accessible
# when the app is relaunched via RunAs (--admin argument).
#
# REAL-TIME OUTPUT ARCHITECTURE:
#   Each function opens a dedicated WPF output window.
#   The command runs in a separate PowerShell Runspace.
#   Output is streamed line-by-line to the WPF TextBox via
#   Dispatcher.BeginInvoke — the only safe way to update WPF
#   controls from a background thread.
#   A synchronized hashtable bridges the two threads.
# ==============================================================
# ==============================================================
# ADMIN HELPER — Confirmation dialog (WPF, same style as app)
# Returns $true (SIM) or $false (NAO)
# ==============================================================
function Confirmar-Acao-Admin {
    param(
        [string]$Titulo,
        [string]$Mensagem
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $isEN = $Global:Language -eq "EN"

    [xml]$CXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="440" Height="230" WindowStartupLocation="CenterScreen"
        Background="Transparent" WindowStyle="None"
        AllowsTransparency="True" ResizeMode="NoResize" Topmost="True">
    <Border Margin="10">
        <Border CornerRadius="10" Background="#F0EDF2" BorderBrush="#2D1147" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="14" ShadowDepth="5" Direction="315" Color="#000000" Opacity="0.4"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="46"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="58"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="#6E277A" CornerRadius="10,10,0,0" x:Name="TitleBar">
                    <DockPanel Margin="16,0">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock Text="&#x1F512; " Foreground="#2DF7B9" FontSize="12" VerticalAlignment="Center"/>
                            <TextBlock x:Name="WinTitle" Text="" Foreground="White"
                                       FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
                        </StackPanel>
                    </DockPanel>
                </Border>

                <Border Grid.Row="1" Padding="20,14">
                    <TextBlock x:Name="WinMsg" Text="" Foreground="#3D1147"
                               FontFamily="Segoe UI" FontSize="12.5"
                               TextWrapping="Wrap" VerticalAlignment="Center"/>
                </Border>

                <Border Grid.Row="2" Background="#E8E0EC" CornerRadius="0,0,10,10" Padding="16,0">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"
                                VerticalAlignment="Center">
                        <Button x:Name="BtnNao" Width="90" Height="34" Margin="0,0,10,0"
                                Background="#C4AACC" Foreground="#3D1147" BorderThickness="0"
                                FontFamily="Segoe UI Semibold" FontSize="12" Cursor="Hand"/>
                        <Button x:Name="BtnSim" Width="90" Height="34"
                                Background="#3EA384" Foreground="White" BorderThickness="0"
                                FontFamily="Segoe UI Semibold" FontSize="12" Cursor="Hand"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    $rdr = [System.Xml.XmlNodeReader]::new($CXAML)
    $cw  = [Windows.Markup.XamlReader]::Load($rdr)

    $cw.FindName("WinTitle").Text = $Titulo
    $cw.FindName("WinMsg").Text   = $Mensagem
    $cw.FindName("BtnSim").Content = if ($isEN) { "Yes" } else { "Sim" }
    $cw.FindName("BtnNao").Content = if ($isEN) { "No"  } else { "Nao" }

    $ft = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)
    $cw.FindName("BtnSim").Template = $ft
    $cw.FindName("BtnNao").Template = $ft

    $cw.FindName("TitleBar").Add_MouseLeftButtonDown({ param($s,$e) $cw.DragMove() })

    $script:_adminConfirm = $false
    $cw.FindName("BtnSim").Add_Click({ $script:_adminConfirm = $true;  $cw.Close() })
    $cw.FindName("BtnNao").Add_Click({ $script:_adminConfirm = $false; $cw.Close() })

    $cw.ShowDialog() | Out-Null
    return $script:_adminConfirm
}

# ==============================================================
# MOSTRAR-INFO-ADMIN
# --------------------------------------------------------------
# Janela de resultado no MESMO estilo visual do resto do app
# (mesma moldura/titlebar/cores de Confirmar-Acao-Admin), com uma
# area de texto ROLAVEL para caber listas maiores (ex.: eventos).
#
# Usada pelos diagnosticos rapidos do Modo Admin (Eventos Criticos,
# Relatorio de Bateria, Saude do Disco) para mostrar o resultado
# DENTRO do proprio Agent IT - sem abrir Notepad, navegador ou
# qualquer outro programa externo.
#
# Parametros:
#   -Titulo      texto da barra de titulo
#   -Corpo       texto a exibir (pode ter varias linhas)
#   -FonteTexto  "Segoe UI" (padrao, texto normal) ou "Consolas"
#                (monoespacado, melhor para listas alinhadas)
#   -Severidade  "Info" (verde/ciano) | "Warning" (amarelo) | "Error" (vermelho)
#                so muda a cor do indicador ao lado do titulo
# ==============================================================
function Mostrar-Info-Admin {
    param(
        [string]$Titulo,
        [string]$Corpo,
        [string]$FonteTexto = "Segoe UI",
        [ValidateSet("Info","Warning","Error")]
        [string]$Severidade = "Info"
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $corIndicador = switch ($Severidade) {
        "Warning" { "#F7C02D" }
        "Error"   { "#E05050" }
        default   { "#2DF7B9" }
    }
    $isEN = $Global:Language -eq "EN"

    [xml]$iXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" Height="520" WindowStartupLocation="CenterScreen"
        Background="Transparent" WindowStyle="None"
        AllowsTransparency="True" ResizeMode="NoResize" Topmost="True">
    <Border Margin="10">
        <Border CornerRadius="10" Background="#F0EDF2" BorderBrush="#2D1147" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="16" ShadowDepth="6" Direction="315" Color="#000000" Opacity="0.45"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="46"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="58"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="#6E277A" CornerRadius="10,10,0,0" x:Name="TitleBar">
                    <DockPanel Margin="16,0">
                        <TextBlock x:Name="DotIcon" Text="&#x25CF;" Foreground="$corIndicador" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <TextBlock x:Name="WinTitle" Text="" Foreground="White"
                                   FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
                    </DockPanel>
                </Border>

                <Border Grid.Row="1" Background="White" CornerRadius="6" Margin="10,10,10,4">
                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="16,12">
                        <TextBlock x:Name="WinBody" Text="" Foreground="#3D1147"
                                   FontFamily="Segoe UI" FontSize="12.5" TextWrapping="Wrap"/>
                    </ScrollViewer>
                </Border>

                <Border Grid.Row="2" Background="#E8E0EC" CornerRadius="0,0,10,10" Padding="16,0">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="BtnFechar" Width="100" Height="34"
                                Background="#6E277A" Foreground="White" BorderThickness="0"
                                FontFamily="Segoe UI Semibold" FontSize="12" Cursor="Hand"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>
    </Border>
</Window>
"@

    $rdr = [System.Xml.XmlNodeReader]::new($iXAML)
    $iw  = [Windows.Markup.XamlReader]::Load($rdr)

    $iw.FindName("WinTitle").Text = $Titulo
    $body = $iw.FindName("WinBody")
    $body.Text = $Corpo
    # Conversao explicita (mesmo padrao usado para cores/Brush no resto do app)
    # em vez de atribuicao direta de string - evita depender de conversao
    # implicita do PowerShell para o tipo FontFamily do WPF.
    $body.FontFamily = [Windows.Media.FontFamilyConverter]::new().ConvertFromString($FonteTexto)

    $iw.FindName("BtnFechar").Content = if ($isEN) { "Close" } else { "Fechar" }

    $ft = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}" CornerRadius="6">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)
    $iw.FindName("BtnFechar").Template = $ft

    $iw.FindName("TitleBar").Add_MouseLeftButtonDown({ param($s,$e) $iw.DragMove() })
    $iw.FindName("BtnFechar").Add_Click({ $iw.Close() })

    $iw.ShowDialog() | Out-Null
}

function Executar-SFC {
    # ==============================================================
    # FIX (v1.1.2): "sfc is not recognized as a cmdlet"
    # --------------------------------------------------------------
    # SINTOMA REPORTADO:
    #   Ao clicar em SFC no Modo Admin, a janela que abria mostrava
    #   "sfc is not recognized as the name of a cmdlet..." — essa e a
    #   mensagem de erro do POWERSHELL, nao do cmd.exe (que responderia
    #   "is not recognized as an internal or external command"). Ou seja,
    #   a janela que abria NAO era o Prompt de Comando esperado.
    #
    # CAUSA RAIZ:
    #   Start-Process "cmd.exe" (nome sem caminho) deixa a resolucao do
    #   executavel por conta da busca padrao do Windows. Em algumas
    #   maquinas ha algo mais cedo na ordem de busca/PATH do usuario
    #   (App Execution Aliases em %LOCALAPPDATA%\Microsoft\WindowsApps,
    #   terminal de terceiros, politica de ambiente customizada, etc.)
    #   que responde por esse nome antes do cmd.exe real do System32 —
    #   e o que acabou abrindo foi outro interpretador (PowerShell).
    #
    # CORRECAO:
    #   1. Resolver cmd.exe E sfc.exe pelo caminho absoluto via
    #      $env:SystemRoot\System32 — nunca depende de PATH/alias.
    #   2. Validar que ambos existem antes de tentar abrir (evita
    #      janela confusa se algo estiver corrompido/bloqueado).
    #   3. ArgumentList como array (nao string unica) — evita qualquer
    #      ambiguidade de parsing dos argumentos.
    #   4. Try/catch com MessageBox de erro claro em vez de falha muda.
    # ==============================================================
    $isEN = $Global:Language -eq "EN"

    $msg = if ($isEN) {
        "An elevated CMD window will open and run:`n`n  sfc /scannow`n`nThis may take 10-30 minutes. Continue?"
    } else {
        "Uma janela CMD elevada sera aberta e ira executar:`n`n  sfc /scannow`n`nIsso pode levar 10 a 30 minutos. Deseja continuar?"
    }

    if (-not (Confirmar-Acao-Admin -Titulo "SFC - System File Checker" -Mensagem $msg)) { return }

    Escrever-Log -Mensagem "Admin | SFC iniciado via CMD" -FunctionName "ADMIN" -Action "SFCStart" -Status "INFO"

    Add-Type -AssemblyName System.Windows.Forms

    # Caminhos absolutos - nunca depende do PATH do usuario
    $cmdExe = Join-Path $env:SystemRoot "System32\cmd.exe"
    $sfcExe = Join-Path $env:SystemRoot "System32\sfc.exe"

    if (-not (Test-Path $cmdExe) -or -not (Test-Path $sfcExe)) {
        $errMsg = if ($isEN) {
            "Could not locate cmd.exe or sfc.exe at:`n$cmdExe`n$sfcExe`n`nThis usually indicates a corrupted Windows installation or a restricted/locked-down environment."
        } else {
            "Nao foi possivel localizar cmd.exe ou sfc.exe em:`n$cmdExe`n$sfcExe`n`nIsso geralmente indica uma instalacao do Windows corrompida ou um ambiente restrito/bloqueado."
        }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "SFC", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | SFC abortado - cmd.exe ou sfc.exe nao encontrado ($cmdExe | $sfcExe)" -FunctionName "ADMIN" -Action "SFCPathMissing" -Status "ERROR"
        return
    }

    try {
        # /k mantem a janela aberta apos o comando terminar, para o usuario ver o resultado.
        # sfc.exe tambem e chamado pelo caminho completo (entre aspas) dentro do argumento do cmd.
        Start-Process -FilePath $cmdExe -ArgumentList @("/k", "`"$sfcExe`" /scannow") -ErrorAction Stop
        Escrever-Log -Mensagem "Admin | Janela CMD aberta com sucesso ($cmdExe)" -FunctionName "ADMIN" -Action "SFCLaunched" -Status "SUCCESS"
    } catch {
        $err = $_.ToString()
        $errMsg = if ($isEN) { "Failed to open the CMD window:`n`n$err" } else { "Falha ao abrir a janela CMD:`n`n$err" }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "SFC", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | SFC erro ao abrir CMD: $err" -FunctionName "ADMIN" -Action "SFCLaunchError" -Status "ERROR"
    }
}

function Executar-DISM {
    # ==============================================================
    # FIX (v1.1.2): mesmo problema do Executar-SFC acima (ver comentario
    # detalhado la). DISM tinha exatamente o mesmo padrao de risco -
    # Start-Process "cmd.exe" sem caminho absoluto - por isso recebeu
    # a mesma correcao preventivamente, mesmo sem o bug ter sido
    # reportado especificamente aqui.
    # ==============================================================
    $isEN = $Global:Language -eq "EN"

    $msg = if ($isEN) {
        "An elevated CMD window will open and run:`n`n  DISM /Online /Cleanup-Image /RestoreHealth`n`nRequires internet. May take 15-30 minutes. Continue?"
    } else {
        "Uma janela CMD elevada sera aberta e ira executar:`n`n  DISM /Online /Cleanup-Image /RestoreHealth`n`nRequer internet. Pode levar 15 a 30 minutos. Deseja continuar?"
    }

    if (-not (Confirmar-Acao-Admin -Titulo "DISM - Windows Image Repair" -Mensagem $msg)) { return }

    Escrever-Log -Mensagem "Admin | DISM iniciado via CMD" -FunctionName "ADMIN" -Action "DISMStart" -Status "INFO"

    Add-Type -AssemblyName System.Windows.Forms

    # Caminhos absolutos - nunca depende do PATH do usuario
    $cmdExe  = Join-Path $env:SystemRoot "System32\cmd.exe"
    $dismExe = Join-Path $env:SystemRoot "System32\Dism.exe"

    if (-not (Test-Path $cmdExe) -or -not (Test-Path $dismExe)) {
        $errMsg = if ($isEN) {
            "Could not locate cmd.exe or Dism.exe at:`n$cmdExe`n$dismExe`n`nThis usually indicates a corrupted Windows installation or a restricted/locked-down environment."
        } else {
            "Nao foi possivel localizar cmd.exe ou Dism.exe em:`n$cmdExe`n$dismExe`n`nIsso geralmente indica uma instalacao do Windows corrompida ou um ambiente restrito/bloqueado."
        }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "DISM", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | DISM abortado - cmd.exe ou Dism.exe nao encontrado ($cmdExe | $dismExe)" -FunctionName "ADMIN" -Action "DISMPathMissing" -Status "ERROR"
        return
    }

    try {
        Start-Process -FilePath $cmdExe -ArgumentList @("/k", "`"$dismExe`" /Online /Cleanup-Image /RestoreHealth") -ErrorAction Stop
        Escrever-Log -Mensagem "Admin | Janela CMD aberta com sucesso ($cmdExe)" -FunctionName "ADMIN" -Action "DISMLaunched" -Status "SUCCESS"
    } catch {
        $err = $_.ToString()
        $errMsg = if ($isEN) { "Failed to open the CMD window:`n`n$err" } else { "Falha ao abrir a janela CMD:`n`n$err" }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "DISM", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | DISM erro ao abrir CMD: $err" -FunctionName "ADMIN" -Action "DISMLaunchError" -Status "ERROR"
    }
}

function Executar-FlushDNS {
    Escrever-Log -Mensagem "Admin | FlushDNS iniciado" -FunctionName "ADMIN" -Action "FlushDNSStart" -Status "INFO"

    Add-Type -AssemblyName System.Windows.Forms
    $isEN = $Global:Language -eq "EN"

    # Capture ipconfig output using the system OEM codepage (850 on PT-BR)
    # to correctly decode accented characters from the console
    #
    # FIX (v1.1.2): caminho absoluto em vez de "ipconfig.exe" puro -
    # mesma classe de risco de resolucao via PATH corrigida no
    # Executar-SFC e Executar-DISM (ver comentario detalhado la).
    $ipconfigExe = Join-Path $env:SystemRoot "System32\ipconfig.exe"
    $psi = [System.Diagnostics.ProcessStartInfo]::new($ipconfigExe, "/flushdns")
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(
        [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    )

    $proc   = [System.Diagnostics.Process]::Start($psi)
    $output = $proc.StandardOutput.ReadToEnd().Trim()
    $proc.WaitForExit()

    $success = $output -match "conclu|success|flushed"
    $icon    = if ($success) {
        [System.Windows.Forms.MessageBoxIcon]::Information
    } else {
        [System.Windows.Forms.MessageBoxIcon]::Warning
    }

    $title = "Flush DNS"
    $msg   = if ($isEN) { "Result:`n`n$output" } else { "Resultado:`n`n$output" }

    [System.Windows.Forms.MessageBox]::Show(
        $msg, $title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    ) | Out-Null

    Escrever-Log -Mensagem "Admin | FlushDNS concluido" -FunctionName "ADMIN" -Action "FlushDNSEnd" -Status "INFO"
}
function Executar-PrintSpooler {
    # ==============================================================
    # PRINT SPOOLER RESTART
    # Stops the Print Spooler service, clears the spool queue,
    # then restarts the service. Fixes stuck print jobs and
    # printer errors without requiring a reboot.
    # Requires admin elevation — called from Mode Admin only.
    # ==============================================================
    $isEN = $Global:Language -eq "EN"
    Escrever-Log -Mensagem "Admin | Print Spooler restart iniciado" -FunctionName "ADMIN" -Action "SpoolerStart" -Status "INFO"

    Add-Type -AssemblyName System.Windows.Forms

    try {
        # Step 1: Stop service
        Stop-Service -Name "Spooler" -Force -ErrorAction Stop

        # Step 2: Clear spool queue (stuck jobs)
        $spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
        if (Test-Path $spoolPath) {
            Get-ChildItem $spoolPath -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }

        # Step 3: Restart service
        Start-Service -Name "Spooler" -ErrorAction Stop

        $msg = if ($isEN) {
            "Print Spooler restarted successfully.`n`nThe print queue has been cleared.`nPrinters should now be available."
        } else {
            "Servico Print Spooler reiniciado com sucesso.`n`nA fila de impressao foi limpa.`nAs impressoras devem estar disponiveis novamente."
        }

        [System.Windows.Forms.MessageBox]::Show(
            $msg, "Print Spooler",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        Escrever-Log -Mensagem "Admin | Print Spooler reiniciado com sucesso" -FunctionName "ADMIN" -Action "SpoolerEnd" -Status "SUCCESS"

    } catch {
        $err = $_.ToString()
        $msg = if ($isEN) {
            "Error restarting Print Spooler:`n`n$err"
        } else {
            "Erro ao reiniciar o Print Spooler:`n`n$err"
        }
        [System.Windows.Forms.MessageBox]::Show(
            $msg, "Print Spooler",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null

        Escrever-Log -Mensagem "Admin | Print Spooler erro: $err" -FunctionName "ADMIN" -Action "SpoolerError" -Status "ERROR"
    }
}

function Executar-EventosCriticos {
    # ==============================================================
    # EVENTOS CRITICOS DO WINDOWS (Event Viewer)
    # --------------------------------------------------------------
    # Le os ultimos eventos de nivel Critico (1) e Erro (2) dos logs
    # System e Application e mostra o resultado DENTRO do proprio
    # Agent IT via Mostrar-Info-Admin (fonte Consolas p/ alinhamento).
    # Nao grava arquivo nem abre nenhum programa externo.
    # Puramente leitura - nao precisa de Confirmar-Acao-Admin.
    # ==============================================================
    $isEN = $Global:Language -eq "EN"
    Escrever-Log -Mensagem "Admin | Consulta de eventos criticos iniciada" -FunctionName "ADMIN" -Action "EventLogStart" -Status "INFO"

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = "System","Application"
            Level   = 1,2   # 1=Critical, 2=Error (Warning=3 fica de fora, e muito ruido)
        } -MaxEvents 30 -ErrorAction Stop

        if (-not $events -or $events.Count -eq 0) {
            $corpoVazio = if ($isEN) { "No Critical or Error events found in the System/Application logs." } else { "Nenhum evento Critico ou de Erro encontrado nos logs System/Application." }
            Mostrar-Info-Admin -Titulo "Event Viewer" -Corpo $corpoVazio -Severidade "Info"
            Escrever-Log -Mensagem "Admin | Nenhum evento critico/erro encontrado" -FunctionName "ADMIN" -Action "EventLogEmpty" -Status "INFO"
            return
        }

        $temCritico = ($events | Where-Object { $_.Level -eq 1 }).Count -gt 0

        $linhas = foreach ($ev in $events) {
            $nivel = switch ($ev.Level) { 1 {"CRITICAL"} 2 {"ERROR"} default {"LEVEL$($ev.Level)"} }
            # Pega so a primeira linha da mensagem e limita o tamanho - mensagem completa pode ter paragrafos inteiros
            $msgResumo = ($ev.Message -split "`n")[0]
            if ($msgResumo.Length -gt 160) { $msgResumo = $msgResumo.Substring(0,160) + "..." }
            "[$($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] [$nivel] [$($ev.LogName)] Fonte=$($ev.ProviderName) ID=$($ev.Id)`n    $msgResumo"
        }

        $header = if ($isEN) {
            "Last $($events.Count) Critical/Error events - $($env:COMPUTERNAME) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n$('-'*68)`n`n"
        } else {
            "Ultimos $($events.Count) eventos Critico/Erro - $($env:COMPUTERNAME) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n$('-'*68)`n`n"
        }

        $corpo = $header + ($linhas -join "`n`n")

        Mostrar-Info-Admin -Titulo "Event Viewer" -Corpo $corpo -FonteTexto "Consolas" `
            -Severidade $(if ($temCritico) { "Error" } else { "Warning" })

        Escrever-Log -Mensagem "Admin | $($events.Count) eventos exibidos na tela" -FunctionName "ADMIN" -Action "EventLogShown" -Status "SUCCESS"

    } catch {
        $err = $_.ToString()
        Add-Type -AssemblyName System.Windows.Forms
        $errMsg = if ($isEN) { "Failed to read the Event Log:`n`n$err" } else { "Falha ao ler o Event Log:`n`n$err" }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "Event Viewer", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | Erro ao ler Event Log: $err" -FunctionName "ADMIN" -Action "EventLogError" -Status "ERROR"
    }
}

function Executar-RelatorioBateria {
    # ==============================================================
    # SAUDE DA BATERIA (leitura direta via WMI - sem powercfg/HTML)
    # --------------------------------------------------------------
    # ANTES: gerava o relatorio HTML nativo (powercfg /batteryreport)
    # e abria no navegador padrao. Trocado por leitura direta via WMI
    # para: (1) nao abrir nenhum programa externo, (2) mostrar so o
    # que importa para uma analise rapida, sem navegar por um relatorio
    # HTML inteiro cheio de tabelas de historico de uso.
    #
    # FONTES DE DADOS:
    #   Win32_Battery              -> carga atual (%) e status
    #   root\wmi BatteryStaticData -> capacidade de fabrica (design)
    #   root\wmi BatteryFullChargedCapacity -> capacidade atual maxima
    #   Saude (%) = capacidade atual maxima / capacidade de fabrica
    #   Esses dados de capacidade dependem do driver ACPI do fabricante;
    #   se nao existirem, mostramos so carga+status (com aviso claro).
    # Puramente leitura - nao precisa de Confirmar-Acao-Admin.
    # ==============================================================
    $isEN = $Global:Language -eq "EN"

    $bateria = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if (-not $bateria) {
        $corpoSemBateria = if ($isEN) { "No battery detected on this machine (normal on desktops)." } else { "Nenhuma bateria detectada nesta maquina (normal em desktops)." }
        Mostrar-Info-Admin -Titulo "Battery Health" -Corpo $corpoSemBateria -Severidade "Info"
        Escrever-Log -Mensagem "Admin | Saude da bateria ignorada - sem bateria detectada" -FunctionName "ADMIN" -Action "BatteryHealthSkipped" -Status "INFO"
        return
    }

    Escrever-Log -Mensagem "Admin | Verificacao de saude da bateria iniciada" -FunctionName "ADMIN" -Action "BatteryHealthStart" -Status "INFO"

    try {
        # Mapa dos codigos de status da Win32_Battery (documentacao Microsoft)
        $statusMap = @{
            1="Discharging"; 2="On A/C"; 3="Fully Charged"; 4="Low"; 5="Critical"
            6="Charging"; 7="Charging and High"; 8="Charging and Low"
            9="Charging and Critical"; 10="Undefined"; 11="Partially Charged"
        }
        $statusMapPT = @{
            1="Descarregando"; 2="Na tomada (AC)"; 3="Totalmente carregada"; 4="Baixa"; 5="Critica"
            6="Carregando"; 7="Carregando (alta)"; 8="Carregando (baixa)"
            9="Carregando (critica)"; 10="Indefinido"; 11="Parcialmente carregada"
        }
        $statusTxt = if ($isEN) { $statusMap[[int]$bateria.BatteryStatus] } else { $statusMapPT[[int]$bateria.BatteryStatus] }
        if (-not $statusTxt) { $statusTxt = "$($bateria.BatteryStatus)" }

        $cargaPct = $bateria.EstimatedChargeRemaining

        # Capacidade de fabrica x capacidade atual maxima - nem todo driver expoe isso
        $designed   = (Get-CimInstance -Namespace "root\wmi" -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
        $fullCharge = (Get-CimInstance -Namespace "root\wmi" -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity

        $saudePct   = $null
        if ($designed -and $fullCharge -and $designed -gt 0) {
            $saudePct = [math]::Round(($fullCharge / $designed) * 100, 0)
        }

        $linhas = @()
        $linhas += if ($isEN) { "Battery: $($bateria.Name)" }        else { "Bateria: $($bateria.Name)" }
        $linhas += if ($isEN) { "Current charge: $cargaPct%" }       else { "Carga atual: $cargaPct%" }
        $linhas += if ($isEN) { "Status: $statusTxt" }               else { "Status: $statusTxt" }
        $linhas += ""

        $severidade = "Info"
        if ($null -ne $saudePct) {
            $linhas += if ($isEN) { "Estimated battery health: $saudePct%" } else { "Saude estimada da bateria: $saudePct%" }
            $linhas += if ($isEN) { "  (Full charge capacity $fullCharge mWh / Design capacity $designed mWh)" } else { "  (Capacidade atual maxima $fullCharge mWh / Capacidade de fabrica $designed mWh)" }

            if ($saudePct -lt 50)      { $severidade = "Error" }
            elseif ($saudePct -lt 80)  { $severidade = "Warning" }
            else                       { $severidade = "Info" }
        } else {
            $linhas += if ($isEN) {
                "Battery health percentage is not available from this device's driver (design/full-charge capacity not exposed)."
            } else {
                "O percentual de saude nao esta disponivel no driver deste dispositivo (capacidade de fabrica/atual nao exposta)."
            }
        }

        $corpo = ($linhas -join "`n")

        Mostrar-Info-Admin -Titulo "Battery Health" -Corpo $corpo -Severidade $severidade

        Escrever-Log -Mensagem "Admin | Saude da bateria: Carga=$cargaPct% Status=$statusTxt Saude=$saudePct%" -FunctionName "ADMIN" -Action "BatteryHealthDone" -Status "SUCCESS"

    } catch {
        $err = $_.ToString()
        Add-Type -AssemblyName System.Windows.Forms
        $errMsg = if ($isEN) { "Failed to read battery info:`n`n$err" } else { "Falha ao ler informacoes da bateria:`n`n$err" }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "Battery Health", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | Erro na saude da bateria: $err" -FunctionName "ADMIN" -Action "BatteryHealthError" -Status "ERROR"
    }
}

function Executar-SaudeDisco {
    # ==============================================================
    # SAUDE DO DISCO (S.M.A.R.T. via modulo Storage)
    # --------------------------------------------------------------
    # Usa Get-PhysicalDisk (modulo Storage, nativo no Windows 10/11)
    # que agrega os dados S.M.A.R.T. do driver de armazenamento em
    # um status simples: Healthy / Warning / Unhealthy. Funciona para
    # discos SATA, NVMe e USB reconhecidos pelo Windows.
    # Mostra o resultado via Mostrar-Info-Admin (mesma janela usada
    # pelos outros 2 diagnosticos) - nao abre nada externo.
    # Puramente leitura - nao precisa de Confirmar-Acao-Admin.
    # ==============================================================
    $isEN = $Global:Language -eq "EN"
    Escrever-Log -Mensagem "Admin | Verificacao de saude do disco iniciada" -FunctionName "ADMIN" -Action "DiskHealthStart" -Status "INFO"

    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop

        if (-not $disks -or $disks.Count -eq 0) {
            $corpoVazio = if ($isEN) { "No physical disks detected via Get-PhysicalDisk." } else { "Nenhum disco fisico detectado via Get-PhysicalDisk." }
            Mostrar-Info-Admin -Titulo "Disk Health" -Corpo $corpoVazio -Severidade "Warning"
            Escrever-Log -Mensagem "Admin | Nenhum disco fisico detectado" -FunctionName "ADMIN" -Action "DiskHealthEmpty" -Status "WARNING"
            return
        }

        $algumProblema = $false
        $linhas = foreach ($d in $disks) {
            $tamanhoGB = [math]::Round($d.Size / 1GB, 0)
            $status    = "$($d.HealthStatus)"
            if ($status -ne "Healthy") { $algumProblema = $true }
            $statusTxt = if ($isEN) { $status } else {
                switch ($status) { "Healthy" {"Saudavel"} "Warning" {"Atencao"} "Unhealthy" {"Critico"} default { $status } }
            }
            $labelStatus = if ($isEN) { "Status" } else { "Status" }
            $labelOper   = if ($isEN) { "Operational" } else { "Operacional" }
            "- $($d.FriendlyName)  [$($d.MediaType), $tamanhoGB GB]`n    ${labelStatus}: $statusTxt   |   ${labelOper}: $($d.OperationalStatus)"
        }

        $titulo = if ($isEN) { "Disk Health (S.M.A.R.T.)" } else { "Saude do Disco (S.M.A.R.T.)" }
        $corpo  = ($linhas -join "`n`n")
        $severidade = if ($algumProblema) { "Warning" } else { "Info" }

        Mostrar-Info-Admin -Titulo $titulo -Corpo $corpo -Severidade $severidade

        Escrever-Log -Mensagem "Admin | Saude do disco verificada: $($disks.Count) disco(s), problema=$algumProblema" -FunctionName "ADMIN" -Action "DiskHealthDone" -Status $(if ($algumProblema) {"WARNING"} else {"SUCCESS"})

    } catch {
        $err = $_.ToString()
        Add-Type -AssemblyName System.Windows.Forms
        $errMsg = if ($isEN) {
            "Failed to check disk health:`n`n$err`n`nGet-PhysicalDisk requires the Storage module (built into Windows 10/11)."
        } else {
            "Falha ao verificar a saude do disco:`n`n$err`n`nGet-PhysicalDisk requer o modulo Storage (nativo no Windows 10/11)."
        }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "Disk Health", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | Erro na verificacao de disco: $err" -FunctionName "ADMIN" -Action "DiskHealthError" -Status "ERROR"
    }
}

function Executar-SyncEntraID {
    # ==============================================================
    # SYNC ENTRA ID / INTUNE
    # --------------------------------------------------------------
    # Reinicia o servico "Intune Management Extension" (IME), agente
    # responsavel por aplicar politicas, scripts e apps do Intune na
    # maquina. Reiniciar o servico forca o agente a reprocessar as
    # politicas pendentes na proxima sincronizacao, sem esperar o
    # ciclo automatico (que pode levar horas).
    #
    # NOTA TECNICA: isso reinicia o cliente de gerenciamento do Intune,
    # nao um "sync" do Entra ID em si (que e identidade/login, feito
    # via dsregcmd) - mas e o termo usado no dia a dia de suporte, e o
    # efeito pratico esperado (novas politicas/apps chegarem) e o mesmo.
    #
    # Sequencia (conforme solicitado):
    #   1. Stop-Service -Force
    #   2. Aguarda 5 segundos
    #   3. Start-Service
    #   4. Aguarda 10 segundos
    #   5. Conclui
    #
    # Usa cmdlets nativos do PowerShell (Stop-Service/Start-Service),
    # sem abrir CMD/executavel externo - evita por completo a classe
    # de bug corrigida em Executar-SFC/DISM (resolucao via PATH).
    #
    # FIX (v1.1.3): janela parecia "travada" durante os 15s de espera.
    # --------------------------------------------------------------
    # CAUSA: os dois Start-Sleep (5s + 10s) bloqueavam a UI thread sem
    # NENHUMA atualizacao de tela no meio - o WPF nunca tinha chance de
    # repintar a janela, que fica com aparencia de congelada (podendo
    # o Windows ate marcar como "Nao Responde").
    # CORRECAO: troca dos Start-Sleep por Animate-DonutAdmin, que quebra
    # a mesma espera em ticks de 30ms com Dispatcher.Invoke(Render) no
    # meio - a duracao total da espera NAO muda, so passa a mostrar o
    # donut girando e o status "Executando..." durante os 15s, dando a
    # confirmacao visual de que a solicitacao esta em andamento.
    # Essa animacao (Animate-DonutAdmin, em ui.psm1) e isolada do fluxo
    # normal - nao le/escreve $Global:SelectedAction/ActionSteps/etc.
    # ==============================================================
    $isEN    = $Global:Language -eq "EN"
    $svcName = "IntuneManagementExtension"

    Add-Type -AssemblyName System.Windows.Forms

    $msg = if ($isEN) {
        "This will restart the Intune Management Extension service:`n`n  1. Stop service (forced)`n  2. Wait 5 seconds`n  3. Start service`n  4. Wait 10 seconds`n`nThis may briefly interrupt an in-progress Intune sync. Continue?"
    } else {
        "Isso vai reiniciar o servico Intune Management Extension:`n`n  1. Parar o servico (forcado)`n  2. Aguardar 5 segundos`n  3. Iniciar o servico`n  4. Aguardar 10 segundos`n`nIsso pode interromper brevemente uma sincronizacao do Intune em andamento. Deseja continuar?"
    }

    if (-not (Confirmar-Acao-Admin -Titulo "Sync Entra ID" -Mensagem $msg)) { return }

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $naoEncontrado = if ($isEN) {
            "Service '$svcName' was not found on this machine.`nThis device may not be enrolled in Intune."
        } else {
            "O servico '$svcName' nao foi encontrado nesta maquina.`nEste dispositivo pode nao estar cadastrado no Intune."
        }
        [System.Windows.Forms.MessageBox]::Show($naoEncontrado, "Sync Entra ID", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Escrever-Log -Mensagem "Admin | Sync Entra ID abortado - servico $svcName nao encontrado" -FunctionName "ADMIN" -Action "EntraSyncServiceMissing" -Status "WARNING"
        return
    }

    Escrever-Log -Mensagem "Admin | Sync Entra ID iniciado (servico $svcName)" -FunctionName "ADMIN" -Action "EntraSyncStart" -Status "INFO"
    WPF-SetStatus -Text (Get-Text "UI.StatusRunning") -Color "#F7C02D"

    try {
        $lblParando = if ($isEN) { "Stopping service..." } else { "Parando servico..." }
        Update-Donut -Percent 0 -Label $lblParando

        Stop-Service -Name $svcName -Force -ErrorAction Stop
        Escrever-Log -Mensagem "Admin | $svcName parado, aguardando 5s" -FunctionName "ADMIN" -Action "EntraSyncStopped" -Status "INFO"

        $lblEspera1 = if ($isEN) { "Waiting (5s)..." } else { "Aguardando (5s)..." }
        Animate-DonutAdmin -De 0 -Para 40 -Label $lblEspera1 -DuracaoMs 5000

        Start-Service -Name $svcName -ErrorAction Stop
        Escrever-Log -Mensagem "Admin | $svcName iniciado, aguardando 10s" -FunctionName "ADMIN" -Action "EntraSyncStarted" -Status "INFO"

        $lblEspera2 = if ($isEN) { "Waiting (10s)..." } else { "Aguardando (10s)..." }
        Animate-DonutAdmin -De 40 -Para 95 -Label $lblEspera2 -DuracaoMs 10000

        Animate-DonutAdmin -De 95 -Para 100 -Label (Get-Text "UI.StatusDone") -DuracaoMs 400
        WPF-SetStatus -Text (Get-Text "UI.StatusDone") -Color "#3EA384"

        $sucesso = if ($isEN) {
            "Intune Management Extension restarted successfully.`nThe agent will process pending policies/apps in the background."
        } else {
            "Intune Management Extension reiniciado com sucesso.`nO agente vai processar politicas/apps pendentes em segundo plano."
        }
        [System.Windows.Forms.MessageBox]::Show($sucesso, "Sync Entra ID", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        Escrever-Log -Mensagem "Admin | Sync Entra ID concluido com sucesso" -FunctionName "ADMIN" -Action "EntraSyncDone" -Status "SUCCESS"

        # Volta o donut e o status para o estado de espera - mesmo estado
        # inicial visto na tela antes de qualquer acao ser executada.
        WPF-ProgressHide
        WPF-SetStatus -Text (Get-Text "UI.StatusIdle") -Color "#3EA384"

    } catch {
        $err = $_.ToString()
        WPF-SetStatus -Text "Error" -Color "#E05050"
        $errMsg = if ($isEN) { "Failed to restart the Intune service:`n`n$err" } else { "Falha ao reiniciar o servico do Intune:`n`n$err" }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "Sync Entra ID", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Escrever-Log -Mensagem "Admin | Erro no Sync Entra ID: $err" -FunctionName "ADMIN" -Action "EntraSyncError" -Status "ERROR"
        WPF-ProgressHide
    }
}

Export-ModuleMember -Function Diagnostico-PC, Limpar-PC, Mostrar-Resultado-Diagnostico, Mostrar-Resultado-Limpeza, Otimizar-Registro, Mostrar-Resultado-Registro, Executar-SFC, Executar-DISM, Executar-FlushDNS, Confirmar-Acao-Admin, Executar-PrintSpooler, Executar-EventosCriticos, Executar-RelatorioBateria, Executar-SaudeDisco, Executar-SyncEntraID, Mostrar-Info-Admin
