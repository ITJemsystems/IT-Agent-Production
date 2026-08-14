# =====================================================================
# ui.psm1 - PHASE 1 v5
#
# CRITICAL FIX: Module functions now run in a background Runspace.
# UI thread stays free to process Dispatcher updates from Barra-Progresso.
# This is why progress was always 0% - same thread = no UI updates.
#
# ARCHITECTURE:
#   - Launch-MainWindow runs on UI thread (WPF requirement)
#   - Run Action creates a Runspace with all loaded modules
#   - Module function runs in Runspace (background thread)
#   - Barra-Progresso uses Dispatcher.BeginInvoke to update UI from bg thread
#   - UI thread processes updates while background thread works
#   - Runspace signals completion via $Global:RunspaceJob
# =====================================================================

# ==============================================================
# ui.psm1 - Main WPF window, progress animation, dialogs
# ==============================================================
# WHAT THIS MODULE DOES:
#   This is the heart of the application. It builds and runs the
#   entire WPF interface, handles all user interactions, and
#   coordinates with the other modules.
#
# KEY FUNCTIONS:
#   Launch-MainWindow   - Creates and shows the main WPF window.
#                         This is a blocking call - returns only
#                         when the user closes the app.
#   Build-ActionSteps   - Defines the progress bar step targets
#                         (% and label) for each action number.
#                         Must be called after language is set.
#   Barra-Progresso     - Called by module functions during execution.
#                         Animates the donut to the next defined step.
#   Update-Donut        - Renders a specific % on the donut arc.
#   WPF-Log             - Appends a message to the in-app log panel.
#   WPF-SetStatus       - Updates the status dot and text (bottom left).
#   Perguntar-Resolvido - Shows the "was it resolved?" dialog after
#                         an action completes.
#   Abrir-Ticket-Email  - Opens Outlook Web compose directly in the
#                         default browser, pre-filled (v1.1.5 - works
#                         regardless of Classic vs New Outlook).
#
# ARCHITECTURE - WHY FUNCTIONS RUN ON THE UI THREAD:
#   WPF requires that all UI updates happen on the UI thread.
#   PowerShell Runspace attempts failed because modules could not
#   be reliably shared across runspace boundaries.
#   Current solution: module functions run on the UI thread, and
#   Barra-Progresso uses Dispatcher.Invoke(Render priority) to
#   force WPF to flush each animation frame before continuing.
#   This makes the progress bar update in real-time while the
#   function executes. See Barra-Progresso for details.
#
# CLOSURE LIMITATION WORKAROUND:
#   PowerShell scriptblocks passed to Dispatcher.BeginInvoke and
#   event handlers (Add_Click, Add_MouseEnter) do NOT automatically
#   capture variables from the outer scope. Workaround used:
#   - $Global:_VarName for UI update values (DonutPct, LogMessage)
#   - $btn.Tag = "value1|value2" for hover colors (split on "|")
#   - $script:_VarName for timer/closure state
#
# ACTION NUMBERING (must match apps.psm1 and Build-ActionSteps):
#   1=Teams  2=Outlook  3=Drive  4=Slack  5=Cleanup
#   6=Zoom   7=OneDrive 8=Chrome 9=Webex  10=WhatsApp  11=Dropbox
#   12=Network Diagnose  13=PC Diagnostic
#
# COLOR PALETTE:
#   Sidebar bg:    #3D1147    Title bar:  #6E277A
#   Hover purple:  #8E3A9A    Hover side: #5A2468
#   Accent cyan:   #2DF7B9    Green ok:   #3EA384
#   Warning amber: #F7C02D    Error red:  #E05050
#   Content bg:    #F0EDF2    Cards:      #FFFFFF
# ==============================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global hashtable holding references to all named WPF controls.
# Populated in Launch-MainWindow after XamlReader loads the window.
# Used by Barra-Progresso, WPF-Log, WPF-SetStatus to update the UI
# from module functions running on the same thread.
$Global:WPF = @{
    Window        = $null
    LogPanel      = $null
    LogScroll     = $null
    DonutArc      = $null
    DonutPct      = $null
    DonutLabel    = $null
    StepText      = $null
    ContentTitle  = $null
    ContentSub    = $null
    StatusDot     = $null
    StatusText    = $null
    BtnRun        = $null
    MainView      = $null
    LogView       = $null
}

# Tracks current progress state across Barra-Progresso calls:
#   ProgressCurrent = last % reached (used as animation start point)
#   CurrentStep     = index into the ActionSteps array for current action
#   SelectedAction  = the Tag value of the last sidebar button clicked
$Global:ProgressCurrent = 0
$Global:CurrentStep     = 0
$Global:SelectedAction  = $null

# =====================================================================
# DONUT GEOMETRY
# =====================================================================
# Generates an SVG arc path string for the donut progress ring.
# The arc starts at the top (12 o clock = 100,20) and draws clockwise.
# Grid is 200x200, center=100,100, radius=80, stroke=16.
# Special cases: 0% and 100% use near-identical start/end points
# to avoid SVG degenerate arc rendering artifacts.
function Get-DonutPath {
    param([double]$Percent)
    # Grid is 200x200. Center=100,100. Radius=80. Start at top (12 o'clock) = 100,20.
    if ($Percent -le 0)   { return "M 100,20 A 80,80 0 0 1 100,20.001" }
    if ($Percent -ge 100) { return "M 100,20 A 80,80 0 1 1 99.999,20" }
    $angle   = $Percent / 100.0 * 360.0
    $radians = ($angle - 90) * [Math]::PI / 180.0
    $x = 100 + 80 * [Math]::Cos($radians)
    $y = 100 + 80 * [Math]::Sin($radians)
    $large = if ($angle -gt 180) { 1 } else { 0 }
    return "M 100,20 A 80,80 0 $large 1 $x,$y"
}

# Updates the donut arc to show a specific percentage.
# Called by Barra-Progresso during animation ticks.
# Uses BeginInvoke (async, Background priority) for non-blocking updates.
# Colors: 0%=gray track, 1-99%=purple arc, 100%=green success.
function Update-Donut {
    param([int]$Percent, [string]$Label = "")
    if ($null -eq $Global:WPF.DonutArc) { return }
    # Store in Global - only safe way to pass values into BeginInvoke closures
    $Global:_DonutPct = $Percent
    $Global:_DonutLbl = $Label
    $Global:WPF.Window.Dispatcher.BeginInvoke([action]{
        $pct  = $Global:_DonutPct
        $lbl  = $Global:_DonutLbl
        $path = Get-DonutPath -Percent $pct
        $Global:WPF.DonutArc.Data = [Windows.Media.Geometry]::Parse($path)
        $Global:WPF.DonutPct.Text = "$pct%"
        if (-not [string]::IsNullOrEmpty($lbl)) {
            $Global:WPF.DonutLabel.Text = $lbl
            $Global:WPF.StepText.Text   = $lbl
        }
        if ($pct -eq 0)       { $arcColor = "#D8D0DC"; $pctColor = "#3D1147" }
        elseif ($pct -ge 100) { $arcColor = "#3EA384"; $pctColor = "#3EA384" }
        else                  { $arcColor = "#6E277A"; $pctColor = "#3D1147" }
        $Global:WPF.DonutArc.Stroke     = [Windows.Media.BrushConverter]::new().ConvertFromString($arcColor)
        $Global:WPF.DonutPct.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($pctColor)
    }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

# Smooth animation: slides from current to target in ~2 seconds
# Must be called from background thread only
function Animate-DonutTo {
    param([int]$Target, [string]$Label = "")
    $from  = $Global:ProgressCurrent
    $to    = $Target
    $ticks = 60
    $lbl   = $Label
    for ($i = 1; $i -le $ticks; $i++) {
        $val = $from + ($to - $from) * ($i / $ticks)
        $pct = [int][math]::Round($val)
        Update-Donut -Percent $pct -Label $lbl
        Start-Sleep -Milliseconds 33
    }
    $Global:ProgressCurrent = $to
}

# =====================================================================
# ANIMATE-DONUT-ADMIN
# =====================================================================
# Versao ISOLADA da animacao do donut, para uso exclusivo das acoes
# do Modo Admin (Executar-SFC, Executar-SyncEntraID, etc).
#
# POR QUE NAO REUSAR Barra-Progresso/Animate-DonutTo DIRETO:
#   Ambas leem/escrevem $Global:SelectedAction, $Global:ActionSteps,
#   $Global:CurrentStep e $Global:ProgressCurrent - variaveis que
#   pertencem exclusivamente ao fluxo normal (clique em "Executar"
#   com uma acao do sidebar padrao). Os botoes do Modo Admin sao
#   conectados direto (Add_Click -> Executar-X), sem passar por esse
#   fluxo - $Global:SelectedAction pode estar vazio ou ainda apontando
#   para a ULTIMA acao normal executada antes de entrar no Modo Admin.
#   Usar Barra-Progresso ali animaria para um alvo errado (ou nenhum).
#
#   Esta funcao NAO le nem escreve nenhuma dessas variaveis globais -
#   recebe -De/-Para/-Label explicitamente. Zero risco de interferir
#   no fluxo normal, e o fluxo normal tambem nunca chama esta funcao.
#
# COMO FUNCIONA (mesma tecnica ja usada em Barra-Progresso):
#   Dispatcher.Invoke com prioridade Render, chamado repetidamente com
#   pequenos Start-Sleep entre cada tick. Mesmo estando na UI thread,
#   Invoke forca o WPF a processar a fila de renderizacao a cada
#   iteracao - e isso que faz a janela continuar respondendo (em vez
#   de "Nao Responde") durante uma espera longa como a do Sync Entra ID.
# =====================================================================
function Animate-DonutAdmin {
    param(
        [int]$De,
        [int]$Para,
        [string]$Label = "",
        [int]$DuracaoMs = 1000
    )
    if ($null -eq $Global:WPF.DonutArc) { return }   # seguranca: UI ainda nao existe

    $ticks = [Math]::Max(5, [int]($DuracaoMs / 30))
    for ($i = 1; $i -le $ticks; $i++) {
        $pct = [int]($De + ($Para - $De) * ($i / $ticks))
        $Global:_DonutPct = $pct
        $Global:_DonutLbl = $Label
        $Global:WPF.Window.Dispatcher.Invoke([action]{
            $p    = $Global:_DonutPct
            $l    = $Global:_DonutLbl
            $path = Get-DonutPath -Percent $p
            $Global:WPF.DonutArc.Data = [Windows.Media.Geometry]::Parse($path)
            $Global:WPF.DonutPct.Text = "$p%"
            if (-not [string]::IsNullOrEmpty($l)) {
                $Global:WPF.DonutLabel.Text = $l
                $Global:WPF.StepText.Text   = $l
            }
            if ($p -eq 0)       { $arc = "#D8D0DC"; $pctc = "#3D1147" }
            elseif ($p -ge 100) { $arc = "#3EA384"; $pctc = "#3EA384" }
            else                { $arc = "#6E277A"; $pctc = "#3D1147" }
            $Global:WPF.DonutArc.Stroke     = [Windows.Media.BrushConverter]::new().ConvertFromString($arc)
            $Global:WPF.DonutPct.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($pctc)
        }, [Windows.Threading.DispatcherPriority]::Render) | Out-Null
        Start-Sleep -Milliseconds 30
    }
}
# =====================================================================
# Defines progress step targets for each action.
# Each entry is an array of [targetPercent, labelText] pairs.
# Barra-Progresso advances through these in order on each call.
# Must be called AFTER language is set (Get-Text needs $Global:Language).
# App actions (1-11) share a 3-step template: close/wait/start.
# System actions (5, 12, 13) have more steps matching their complexity.
function Build-ActionSteps {
    # 3-step template for all app restarts (Close / Wait / Start)
    $app = @(@(33,(Get-Text "Step.App.Close")),@(66,(Get-Text "Step.Waiting")),@(100,(Get-Text "Step.App.Start")))
    $Global:ActionSteps = @{
        "1"  = $app; "2"  = $app; "3"  = $app; "4"  = $app
        "6"  = $app; "7"  = $app; "8"  = $app; "9"  = $app
        "10" = $app; "11" = $app; "15" = $app; "16" = $app; "18" = $app
        "5" = @(
            @(20, (Get-Text "Step.Clean.Scan")),
            @(40, (Get-Text "Step.Clean.Apps")),
            @(60, (Get-Text "Step.Clean.Temp")),
            @(80, (Get-Text "Step.Clean.Browser")),
            @(100,(Get-Text "Step.Clean.Recycle"))
        )
        "12" = @(
            @(20, (Get-Text "Step.Net.Interface")),
            @(40, (Get-Text "Step.Net.Latency")),
            @(60, (Get-Text "Step.Net.DNS")),
            @(80, (Get-Text "Step.Net.Repair")),
            @(100,(Get-Text "Step.Net.Wifi"))
        )
        "13" = @(
            @(17, (Get-Text "Step.Diag.SysInfo")),
            @(34, (Get-Text "Step.Diag.CPU")),
            @(51, (Get-Text "Step.Diag.RAM")),
            @(68, (Get-Text "Step.Diag.Disk")),
            @(85, (Get-Text "Step.Diag.Health")),
            @(100,(Get-Text "Step.Diag.Uptime"))
        )
        "14" = @(
            @(20, (Get-Text "Step.Reg.Scan")),
            @(40, (Get-Text "Step.Reg.MRU")),
            @(60, (Get-Text "Step.Reg.Orphan")),
            @(80, (Get-Text "Step.Reg.Temp")),
            @(100,(Get-Text "Step.Reg.Done"))
        )
        "17" = @(
            @(50,  (Get-Text "Step.IPDNS.Collect")),
            @(100, (Get-Text "Step.IPDNS.Done"))
        )
    }
}

# =====================================================================
# XAML
# =====================================================================
[xml]$XAML = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
    Title="IT Support Agent"
    Width="940" Height="640"
    MinWidth="820" MinHeight="520"
    WindowStartupLocation="CenterScreen"
    Background="Transparent"
    WindowStyle="None"
    AllowsTransparency="True"
    ResizeMode="CanResizeWithGrip">
    <shell:WindowChrome.WindowChrome>
        <shell:WindowChrome ResizeBorderThickness="6" CaptionHeight="0"
                            CornerRadius="0" GlassFrameThickness="0"
                            UseAeroCaptionButtons="False"/>
    </shell:WindowChrome.WindowChrome>
    <Border CornerRadius="12" Background="#F0EDF2" ClipToBounds="True">
        <Border.Effect>
            <DropShadowEffect BlurRadius="28" ShadowDepth="0" Color="#000000" Opacity="0.3"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="44"/>
                <RowDefinition Height="4"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="38"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Background="#6E277A" CornerRadius="12,12,0,0" x:Name="TitleBar">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
                        <Image x:Name="TitleLogo" Width="22" Height="22"
                               Margin="0,0,8,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                        <TextBlock x:Name="TitleText" Text="Agent IT" Foreground="#FFFFFF"
                                   FontFamily="Segoe UI Semibold" FontSize="13" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="0,0,8,0">
                        <Button x:Name="BtnMinimize" Content="&#x2212;" Width="34" Height="34"
                                Background="Transparent" Foreground="#E0C8E4" BorderThickness="0" FontSize="16" Cursor="Hand"/>
                        <Button x:Name="BtnClose" Content="&#x2715;" Width="34" Height="34"
                                Background="Transparent" Foreground="#E0C8E4" BorderThickness="0" FontSize="13" Cursor="Hand"/>
                    </StackPanel>
                </Grid>
            </Border>

            <Rectangle Grid.Row="1">
                <Rectangle.Fill>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#6E277A" Offset="0"/>
                        <GradientStop Color="#2DF7B9" Offset="0.5"/>
                        <GradientStop Color="#3EA384" Offset="1"/>
                    </LinearGradientBrush>
                </Rectangle.Fill>
            </Rectangle>

            <Grid Grid.Row="2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="210" MinWidth="210" MaxWidth="210"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- ============================================================
                     SIDEBAR - Left navigation panel
                     Background #2A0B38 (deeper than main window #3D1147)
                     Buttons use a custom template with a 3px cyan left accent
                     bar when selected, and a pill-style rounded background on hover.
                     Section headers use the cyan accent color at 9px.
                     ============================================================ -->
                <Border Grid.Column="0" Background="#2A0B38">
                    <DockPanel LastChildFill="True">

                        <!-- App logo / brand block at the top -->
                        <Border DockPanel.Dock="Top" Padding="20,18,16,14">
                            <StackPanel>
                                <TextBlock Text="SUPPORT" Foreground="#FFFFFF"
                                           FontFamily="Segoe UI Black" FontSize="18"/>
                                <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                                    <Border Width="20" Height="2" Background="#2DF7B9" Margin="0,0,6,0" VerticalAlignment="Center"/>
                                    <TextBlock Text="AGENT" Foreground="#2DF7B9"
                                               FontFamily="Segoe UI Light" FontSize="10" VerticalAlignment="Center"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <!-- Thin separator below brand -->
                        <Rectangle DockPanel.Dock="Top" Height="1" Margin="0,0,0,6">
                            <Rectangle.Fill>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                    <GradientStop Color="#2DF7B9" Offset="0"/>
                                    <GradientStop Color="#3D1147" Offset="1"/>
                                </LinearGradientBrush>
                            </Rectangle.Fill>
                        </Rectangle>

                        <!-- Bottom: Exit button -->
                        <Border DockPanel.Dock="Bottom" Padding="0,4,0,10">
                            <Button x:Name="BtnExit" Background="Transparent" Foreground="#F7C02D"
                                    BorderThickness="0" Padding="20,10" HorizontalContentAlignment="Left"
                                    Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Tag="0" Margin="0,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#x2715;" Foreground="#F7C02D" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="BtnExitText" Text="Sair" Foreground="#F7C02D" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                </StackPanel>
                            </Button>
                        </Border>

                        <!-- Thin separator above exit -->
                        <Rectangle DockPanel.Dock="Bottom" Height="1" Fill="#3D1147" Margin="16,0"/>

                        <!-- Mode Admin button -->
                        <Border DockPanel.Dock="Bottom" Padding="0,2,0,2">
                            <Button x:Name="BtnModeAdmin" Background="Transparent" Foreground="#94A3B8"
                                    BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                    Cursor="Hand" FontFamily="Segoe UI" FontSize="11" Margin="0,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#x1F512;" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="BtnModeAdminText" Text="Mode Admin" Foreground="#94A3B8"
                                               FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center"/>
                                </StackPanel>
                            </Button>
                        </Border>

                        <!-- View Log toggle button -->
                        <Border DockPanel.Dock="Bottom" Padding="0,2,0,2">
                            <Button x:Name="BtnToggleLog" Background="Transparent" Foreground="#7B6B8A"
                                    BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                    Cursor="Hand" FontFamily="Segoe UI" FontSize="11" Margin="0,0">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#x2261;" Foreground="#7B6B8A" FontSize="14" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="BtnToggleLogText" Text="Ver Log" Foreground="#7B6B8A" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center"/>
                                </StackPanel>
                            </Button>
                        </Border>

                        <!-- Scrollable menu items -->
                        <!-- Custom scrollbar: thin, rounded, dark purple to match sidebar theme -->
                        <ScrollViewer HorizontalScrollBarVisibility="Disabled"
                                      VerticalScrollBarVisibility="Auto">
                            <ScrollViewer.Resources>
                                <Style TargetType="ScrollBar">
                                    <Setter Property="Width" Value="6"/>
                                    <Setter Property="Background" Value="Transparent"/>
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="ScrollBar">
                                                <Grid Background="Transparent" Width="4">
                                                    <Border Background="#1A0830" CornerRadius="2" Margin="0"/>
                                                    <Track x:Name="PART_Track" IsDirectionReversed="True">
                                                        <Track.Thumb>
                                                            <Thumb>
                                                                <Thumb.Template>
                                                                    <ControlTemplate TargetType="Thumb">
                                                                        <Border Background="#6E277A" CornerRadius="2"
                                                                                Opacity="0.8"/>
                                                                    </ControlTemplate>
                                                                </Thumb.Template>
                                                            </Thumb>
                                                        </Track.Thumb>
                                                    </Track>
                                                </Grid>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                </Style>
                            </ScrollViewer.Resources>
                            <StackPanel Margin="0,4,0,8">

                                <!-- COMUNICACAO section -->
                                <TextBlock x:Name="SectionComm" Text="COMUNICACAO"
                                           Foreground="#2DF7B9" FontFamily="Segoe UI"
                                           FontSize="9" FontWeight="Bold"
                                           Margin="20,10,0,4" Opacity="0.8"/>

                                <Button x:Name="BtnOutlook"  Tag="2"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x2709;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnOutlookText" Grid.Column="1" Text="Outlook" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnTeams"  Tag="1"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25A6;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnTeamsText" Grid.Column="1" Text="Microsoft Teams" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnWhatsApp"  Tag="10" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25CF;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnWhatsAppText" Grid.Column="1" Text="WhatsApp" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnZoom"  Tag="6"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25CB;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnZoomText" Grid.Column="1" Text="Zoom" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <!-- [WEBEX] Descomente para reativar o botão Cisco Webex
                                <Button x:Name="BtnWebex"    Tag="9"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock Text="&#x25C6;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock Text="Cisco Webex" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                                -->
                                <Button x:Name="Btn8x8Work"  Tag="15" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x260F;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="Btn8x8WorkText" Grid.Column="1" Text="8x8 Work" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnAnyDesk"  Tag="16" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x1F4BB;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnAnyDeskText" Grid.Column="1" Text="AnyDesk" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnSlack"  Tag="4"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x23;&#x23;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnSlackText" Grid.Column="1" Text="Slack" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnClickUp"  Tag="18" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x2611;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnClickUpText" Grid.Column="1" Text="ClickUp" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>

                                <!-- Divider -->
                                <Rectangle Height="1" Fill="#3D1147" Margin="16,8,16,0"/>

                                <!-- PRODUTIVIDADE section -->
                                <TextBlock x:Name="SectionProd" Text="PRODUTIVIDADE"
                                           Foreground="#2DF7B9" FontFamily="Segoe UI"
                                           FontSize="9" FontWeight="Bold"
                                           Margin="20,10,0,4" Opacity="0.8"/>

                                <Button x:Name="BtnOneDrive"  Tag="7"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x2601;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnOneDriveText" Grid.Column="1" Text="OneDrive" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnDrive"  Tag="3"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25B3;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnDriveText" Grid.Column="1" Text="Google Drive" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnChrome"  Tag="8"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25D4;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnChromeText" Grid.Column="1" Text="Google Chrome" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnDropbox"  Tag="11" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25A1;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnDropboxText" Grid.Column="1" Text="Dropbox" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>

                                <!-- Divider -->
                                <Rectangle Height="1" Fill="#3D1147" Margin="16,8,16,0"/>

                                <!-- SISTEMA section -->
                                <TextBlock x:Name="SectionSys" Text="SISTEMA"
                                           Foreground="#2DF7B9" FontFamily="Segoe UI"
                                           FontSize="9" FontWeight="Bold"
                                           Margin="20,10,0,4" Opacity="0.8"/>

                                <Button x:Name="BtnClean"  Tag="5"  Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x2605;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnCleanText" Grid.Column="1" Text="Limpeza de Cache" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnNetwork"  Tag="12" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25C9;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnNetworkText" Grid.Column="1" Text="Diag. de Rede" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnDiag"  Tag="13" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x25A3;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnDiagText" Grid.Column="1" Text="Diag. do PC" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnRegistry"  Tag="14" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x2699;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnRegistryText" Grid.Column="1" Text="Otimizar Registro" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>
                                <Button x:Name="BtnIPDNS"  Tag="17" Background="Transparent" Foreground="#C4AACC" BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left" Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                    <Grid HorizontalAlignment="Left">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="24"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="&#x1F310;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0.7"/>
                                        <TextBlock x:Name="BtnIPDNSText" Grid.Column="1" Text="Status IP/DNS" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                    </Grid>
                                </Button>

                                <!-- ADMIN SECTION — visible only in elevated mode ($Global:AdminMode) -->
                                <StackPanel x:Name="AdminSection" Visibility="Collapsed">
                                    <TextBlock x:Name="SectionAdmin" Text="ADMIN"
                                               Foreground="#E05050" FontFamily="Segoe UI"
                                               FontSize="9" FontWeight="Bold"
                                               Margin="20,14,0,4" Opacity="0.9"/>
                                    <Button x:Name="BtnSFC" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x1F6E1;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="SFC /scannow" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnDISM" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x1F527;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="DISM /RestoreHealth" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnFlushDNS" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x1F504;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="Flush DNS" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnSpooler" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x1F5A8;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="Print Spooler" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>

                                    <!-- Separador fino antes do grupo de diagnostico/gestao -->
                                    <Rectangle Height="1" Fill="#3D1147" Margin="20,6"/>

                                    <Button x:Name="BtnEventos" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x26A0;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="Eventos Criticos" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnBateria" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x1F50B;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="Relatorio de Bateria" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnDiscoSMART" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x1F4BE;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="Saude do Disco" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnSyncEntra" Background="Transparent" Foreground="#C4AACC"
                                            BorderThickness="0" Padding="20,9" HorizontalContentAlignment="Left"
                                            Cursor="Hand" FontFamily="Segoe UI" FontSize="12" Margin="0,1">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock Text="&#x2601;" FontSize="11" Margin="0,0,10,0" VerticalAlignment="Center" Opacity="0.7"/>
                                            <TextBlock Text="Sync Entra ID" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                </StackPanel>

                            </StackPanel>
                        </ScrollViewer>
                    </DockPanel>
                </Border>

                <Grid Grid.Column="1" Background="#F0EDF2">
                    <!-- MAIN VIEW -->
                    <Grid x:Name="MainView">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0" Padding="24,16,24,14" Background="#E8E0EC">
                            <StackPanel>
                                <TextBlock x:Name="ContentTitle" Text="Welcome" Foreground="#3D1147"
                                           FontFamily="Segoe UI Semibold" FontSize="20"/>
                                <TextBlock x:Name="ContentSubtitle" Text="Select an option from the sidebar."
                                           Foreground="#6B5878" FontFamily="Segoe UI" FontSize="13"
                                           Margin="0,4,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                        </Border>

                        <Grid Grid.Row="1">
                            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                                <!-- Donut circle: track ring + arc + percentage only in center -->
                                <!-- Shadow removed: no DropShadowEffect on this element -->
                                <!-- DonutLabel removed from inside - text shows only below via StepText -->
                                <!-- Donut: 200x200 canvas. All coordinates in 200x200 space.
                                     Center=100,100. Radius=80. Track stroke=16.
                                     Path uses Stretch=None + explicit 200x200 so WPF
                                     does NOT rescale or reposition the geometry. -->
                                <Grid Width="200" Height="200" Margin="0,0,0,16">

                                    <!-- Track ring drawn as a Canvas-aligned Path, not Ellipse,
                                         so both track and arc share the same coordinate space -->
                                    <Path Stroke="#E2DCE8" StrokeThickness="16" Fill="Transparent"
                                          Width="200" Height="200"
                                          Stretch="None"
                                          HorizontalAlignment="Left"
                                          VerticalAlignment="Top"
                                          Data="M 100,20 A 80,80 0 1 1 99.999,20"/>

                                    <!-- Progress arc: same coordinate space, same origin -->
                                    <Path x:Name="DonutArc"
                                          Stroke="#E2DCE8" StrokeThickness="16" Fill="Transparent"
                                          Width="200" Height="200"
                                          Stretch="None"
                                          HorizontalAlignment="Left"
                                          VerticalAlignment="Top"
                                          StrokeStartLineCap="Round"
                                          StrokeEndLineCap="Round"
                                          Data="M 100,20 A 80,80 0 0 1 100,20.001"/>

                                    <!-- Percentage text centered in the 200x200 grid -->
                                    <TextBlock x:Name="DonutPct"
                                               Text="0%"
                                               Foreground="#3D1147"
                                               FontFamily="Segoe UI Black"
                                               FontSize="32"
                                               HorizontalAlignment="Center"
                                               VerticalAlignment="Center"/>

                                    <!-- Hidden - kept for code compatibility -->
                                    <TextBlock x:Name="DonutLabel" Text="" Visibility="Collapsed"/>
                                </Grid>
                                <!-- Step text: only shown below the circle -->
                                <TextBlock x:Name="StepText"
                                           Text=""
                                           Foreground="#6B5878"
                                           FontFamily="Segoe UI"
                                           FontSize="13"
                                           HorizontalAlignment="Center"
                                           TextWrapping="Wrap"
                                           MaxWidth="420"
                                           TextAlignment="Center"
                                           Margin="0,0,0,8"/>
                            </StackPanel>
                        </Grid>

                        <Border Grid.Row="2" Padding="20,10,20,14" Background="#F0EDF2">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
                                    <Ellipse x:Name="StatusDot" Width="9" Height="9" Fill="#3EA384" Margin="0,0,8,0"/>
                                    <TextBlock x:Name="StatusText" Text="Idle" Foreground="#6B5878"
                                               FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Center"/>
                                </StackPanel>
                                <Rectangle Grid.Column="1"/>
                                <Button x:Name="BtnClearLog" Grid.Column="2" Content="Clear Log"
                                        Width="96" Height="36" Background="#D8D0DC" Foreground="#3D1147"
                                        BorderThickness="0" FontFamily="Segoe UI" FontSize="13" Cursor="Hand" Margin="0,0,8,0"/>
                                <Button x:Name="BtnRun" Grid.Column="3" Content="Run Action"
                                        Width="130" Height="36" Background="#B0A0B8" Foreground="#3D1147"
                                        BorderThickness="0" FontFamily="Segoe UI Semibold" FontSize="13"
                                        Cursor="Hand" IsEnabled="False"/>
                            </Grid>
                        </Border>
                    </Grid>

                    <!-- LOG VIEW -->
                    <Grid x:Name="LogView" Visibility="Collapsed">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Padding="24,14,24,12" Background="#E8E0EC">
                            <DockPanel>
                                <Button x:Name="BtnBackToMain" Content="Back" Width="70" Height="30"
                                        Background="#6E277A" Foreground="White" BorderThickness="0"
                                        FontFamily="Segoe UI" FontSize="12" Cursor="Hand" DockPanel.Dock="Right"/>
                                <TextBlock Text="Execution Log" Foreground="#3D1147"
                                           FontFamily="Segoe UI Semibold" FontSize="18" VerticalAlignment="Center"/>
                            </DockPanel>
                        </Border>
                        <Border Grid.Row="1" Background="#FFFFFF" Margin="20,12,20,20" CornerRadius="10" Padding="16">
                            <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                <TextBlock x:Name="LogOutput" Foreground="#3D1147"
                                           FontFamily="Cascadia Code, Consolas, Courier New"
                                           FontSize="12" TextWrapping="Wrap" LineHeight="22" Text="Ready."/>
                            </ScrollViewer>
                        </Border>
                    </Grid>
                </Grid>
            </Grid>

            <Border Grid.Row="3" Background="#3D1147" CornerRadius="0,0,12,12" Padding="16,0">
                <DockPanel>
                    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                        <Ellipse Width="7" Height="7" Fill="#2DF7B9" Margin="0,0,6,0"/>
                        <TextBlock x:Name="StatusBarUser"    Foreground="#E0C8E4" FontFamily="Segoe UI Semibold" FontSize="11" VerticalAlignment="Center"/>
                        <TextBlock Text="  |  "              Foreground="#5A2468" FontSize="11" VerticalAlignment="Center"/>
                        <TextBlock x:Name="StatusBarMachine" Foreground="#2DF7B9" FontFamily="Segoe UI Semibold" FontSize="11" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Foreground="#5A2468" FontFamily="Segoe UI" FontSize="11" VerticalAlignment="Center" Text="IT Support Agent v3.0"/>
                </DockPanel>
            </Border>
        </Grid>
    </Border>
</Window>
"@

# =====================================================================
# LAUNCH-MAINWINDOW
# =====================================================================
function Launch-MainWindow {

    try {
        $reader = [System.Xml.XmlNodeReader]::new($XAML)
        $window = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        [System.Windows.MessageBox]::Show("XAML Load Error:`n$_","Startup Error")
        return
    }

    $Global:WPF.Window       = $window
    $Global:WPF.LogPanel     = $window.FindName("LogOutput")

    # Load logo image for title bar
    $logoPath = Join-Path $Global:AssetsPath "logo_title.png"
    if (Test-Path $logoPath) {
        $logoImg = [Windows.Media.Imaging.BitmapImage]::new()
        $logoImg.BeginInit()
        $logoImg.UriSource = [Uri]::new($logoPath)
        $logoImg.EndInit()
        $window.FindName("TitleLogo").Source = $logoImg
    }
    $Global:WPF.LogScroll    = $window.FindName("LogScroll")
    $Global:WPF.DonutArc     = $window.FindName("DonutArc")
    $Global:WPF.DonutPct     = $window.FindName("DonutPct")
    $Global:WPF.DonutLabel   = $window.FindName("DonutLabel")
    $Global:WPF.StepText     = $window.FindName("StepText")
    $Global:WPF.ContentTitle = $window.FindName("ContentTitle")
    $Global:WPF.ContentSub   = $window.FindName("ContentSubtitle")
    $Global:WPF.StatusDot    = $window.FindName("StatusDot")
    $Global:WPF.StatusText   = $window.FindName("StatusText")
    $Global:WPF.BtnRun       = $window.FindName("BtnRun")
    $Global:WPF.MainView     = $window.FindName("MainView")

    # ==============================================================
    # INDICADOR VISUAL DE AMBIENTE (STAGING)
    # --------------------------------------------------------------
    # $Global:Environment e definido em main.ps1 - "PRODUCTION" ou
    # "STAGING" (unica diferenca de codigo entre as duas builds do
    # .exe). Se for STAGING, muda a cor da barra de titulo e o texto
    # "Agent IT" para deixar visualmente impossivel confundir com a
    # producao - importante porque acoes de restart/diagnostico tem
    # efeito real na maquina, e um tecnico nao pode achar que esta
    # testando quando na verdade esta na versao real.
    # ==============================================================
    if ($Global:Environment -eq "STAGING") {
        $titleBar = $window.FindName("TitleBar")
        if ($titleBar) {
            $titleBar.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#B45309")
        }
        $titleText = $window.FindName("TitleText")
        if ($titleText) {
            $titleText.Text = "Agent IT - STAGING"
        }
    }
    $Global:WPF.LogView      = $window.FindName("LogView")

    $Global:SelectedAction  = $null
    $Global:ProgressCurrent = 0
    $Global:CurrentStep     = 0

    # Force Run button readable in disabled state
    $Global:WPF.BtnRun.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#B0A0B8")
    $Global:WPF.BtnRun.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#3D1147")

    Build-ActionSteps

    $actionTitles = @{
        "1"=Get-Text "UI.Title.1";  "2"=Get-Text "UI.Title.2";  "3"=Get-Text "UI.Title.3"
        "4"=Get-Text "UI.Title.4";  "5"=Get-Text "UI.Title.5";  "6"=Get-Text "UI.Title.6"
        "7"=Get-Text "UI.Title.7";  "8"=Get-Text "UI.Title.8";  "9"=Get-Text "UI.Title.9"
        "10"=Get-Text "UI.Title.10"; "11"=Get-Text "UI.Title.11"
        "12"=Get-Text "UI.Title.12"; "13"=Get-Text "UI.Title.13"
        "14"=Get-Text "UI.Title.14"; "15"=Get-Text "UI.Title.15"; "16"=Get-Text "UI.Title.16"; "17"=Get-Text "UI.Title.17"; "18"=Get-Text "UI.Title.18"
    }
    $actionDescriptions = @{
        "1"=Get-Text "UI.Desc.1";  "2"=Get-Text "UI.Desc.2";  "3"=Get-Text "UI.Desc.3"
        "4"=Get-Text "UI.Desc.4";  "5"=Get-Text "UI.Desc.5";  "6"=Get-Text "UI.Desc.6"
        "7"=Get-Text "UI.Desc.7";  "8"=Get-Text "UI.Desc.8";  "9"=Get-Text "UI.Desc.9"
        "10"=Get-Text "UI.Desc.10"; "11"=Get-Text "UI.Desc.11"
        "12"=Get-Text "UI.Desc.12"; "13"=Get-Text "UI.Desc.13"
        "14"=Get-Text "UI.Desc.14"; "15"=Get-Text "UI.Desc.15"; "16"=Get-Text "UI.Desc.16"; "17"=Get-Text "UI.Desc.17"; "18"=Get-Text "UI.Desc.18"
    }

    # Title bar drag
    $window.FindName("TitleBar").Add_MouseLeftButtonDown({ param($s,$e) $window.DragMove() })
    $window.FindName("BtnMinimize").Add_Click({ $window.WindowState = "Minimized" })
    $window.FindName("BtnClose").Add_Click({
        Escrever-Log -Mensagem "App closed" -FunctionName "UI" -Action "AppClose" -Status "INFO"
        $window.Close()
    })

    # Log view toggle
    $window.FindName("BtnToggleLog").Add_Click({
        $Global:WPF.MainView.Visibility = "Collapsed"
        $Global:WPF.LogView.Visibility  = "Visible"
    })
    $window.FindName("BtnBackToMain").Add_Click({
        $Global:WPF.LogView.Visibility  = "Collapsed"
        $Global:WPF.MainView.Visibility = "Visible"
    })

    # ----------------------------------------------------------------
    # Flat button template - no WPF hover chrome
    # Applied to ALL buttons that need custom hover colors
    # ----------------------------------------------------------------
    # Sidebar button template: pill-style with rounded corners (8px)
    # A 3px left accent bar is revealed by the Border's left padding shrinking on selection
    $flatTemplate = [Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Background="{TemplateBinding Background}"
            CornerRadius="8" Padding="{TemplateBinding Padding}"
            Margin="8,0,8,0">
        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                          VerticalAlignment="Center"/>
    </Border>
</ControlTemplate>
"@)

    # Set-ButtonHover: applies flat WPF template + mouse hover color changes.
    # Colors are stored in the button's Tag property as "Normal|Hover" string
    # because PowerShell event handler closures cannot capture outer scope
    # variables - only the sender object ($s) is reliably accessible.
    # The Tag is split on "|" inside each event handler to get the two colors.
    # Helper: hover via Tag "Normal|Hover" - only way to pass values into PS closures
    function Set-ButtonHover {
        param($btn, [string]$NC, [string]$HC)
        if ($null -eq $btn) { return }
        $btn.Template = $flatTemplate
        $btn.Tag = "$NC|$HC"
        $btn.Add_MouseEnter({
            param($s,$e)
            $c = ($s.Tag -split "\|")
            if ($c[1] -eq "Transparent") { $s.Background = [Windows.Media.Brushes]::Transparent }
            elseif (-not [string]::IsNullOrEmpty($c[1])) { $s.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) }
        })
        $btn.Add_MouseLeave({
            param($s,$e)
            $c = ($s.Tag -split "\|")
            if ($c[0] -eq "Transparent") { $s.Background = [Windows.Media.Brushes]::Transparent }
            elseif (-not [string]::IsNullOrEmpty($c[0])) { $s.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) }
        })
    }

    # Apply to main window action buttons
    Set-ButtonHover -btn $window.FindName("BtnRun")       -NC "#6E277A"    -HC "#8E3A9A"
    Set-ButtonHover -btn $window.FindName("BtnClearLog")  -NC "#D8D0DC"    -HC "#E8E0EC"
    Set-ButtonHover -btn $window.FindName("BtnToggleLog") -NC "Transparent" -HC "#3D1147"
    Set-ButtonHover -btn $window.FindName("BtnExit")      -NC "Transparent" -HC "#3D1147"

    # [WEBEX] "BtnWebex" removido temporariamente - reativar ao descomentar o botão no XAML acima
    $sidebarButtons = @("BtnOutlook","BtnTeams","BtnWhatsApp","BtnZoom","Btn8x8Work","BtnAnyDesk","BtnSlack","BtnClickUp","BtnOneDrive","BtnDrive","BtnChrome","BtnDropbox","BtnClean","BtnNetwork","BtnDiag","BtnRegistry","BtnIPDNS")

    foreach ($btnName in $sidebarButtons) {
        $btn = $window.FindName($btnName)
        if ($null -eq $btn) { continue }
        $btn.Template = $flatTemplate

        $btn.Add_MouseEnter({
            param($sender,$e)
            if ($sender.Tag -ne $Global:SelectedAction) {
                $sender.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#3D1147")
                $sender.Foreground = [Windows.Media.Brushes]::White
            }
        })
        $btn.Add_MouseLeave({
            param($sender,$e)
            if ($sender.Tag -ne $Global:SelectedAction) {
                $sender.Background = [Windows.Media.Brushes]::Transparent
                $sender.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#C4AACC")
                $sender.FontWeight = "Normal"
            }
        })
        $btn.Add_Click({
            param($sender,$e)
            $tag = $sender.Tag
            $Global:SelectedAction = $tag
            foreach ($b in $sidebarButtons) {
                $wb = $window.FindName($b)
                if ($null -ne $wb) {
                    $wb.Background = [Windows.Media.Brushes]::Transparent
                    $wb.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#C4AACC")
                    $wb.FontWeight = "Normal"
                }
            }
            $sender.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#5A1F6E")
            $sender.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#2DF7B9")
            $sender.FontWeight = "SemiBold"

            $Global:WPF.ContentTitle.Text = $actionTitles[$tag]
            $Global:WPF.ContentSub.Text   = $actionDescriptions[$tag]
            $Global:WPF.BtnRun.IsEnabled  = $true
            $Global:WPF.BtnRun.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#6E277A")
            $Global:WPF.BtnRun.Foreground = [Windows.Media.Brushes]::White
            $Global:WPF.StepText.Text     = $actionDescriptions[$tag]

            Update-Donut -Percent 0 -Label (Get-Text "UI.StatusIdle")
            WPF-Log "$(Get-Text 'UI.Selected'): $($actionTitles[$tag])" -Color "#6E277A"
        })
    }

    $window.FindName("BtnExit").Add_Click({
        Escrever-Log -Mensagem "App closed" -FunctionName "UI" -Action "AppClose" -Status "INFO"
        $window.Close()
        [Environment]::Exit(0)
    })

    # ==================================================================
    # MODE ADMIN BUTTON
    # Closes current window and relaunches EXE elevated via UAC.
    # If user cancels UAC prompt, current window stays open (try/catch).
    # ==================================================================
    $window.FindName("BtnModeAdmin").Add_Click({
        try {
            $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($exe -like "*powershell*" -or $exe -like "*pwsh*") {
                $exe = Join-Path "C:\ProgramData\IT Support Agent" "AgentIT.exe"
            }
            Start-Process $exe -ArgumentList "--admin" -Verb RunAs -ErrorAction Stop
            $window.Close()
            [Environment]::Exit(0)
        } catch {
            # User cancelled UAC or insufficient rights — stay in current window
            Escrever-Log -Mensagem "Admin mode cancelled or UAC denied" -FunctionName "UI" -Action "AdminModeCancelled" -Status "WARNING"
        }
    })

    # ==================================================================
    # ADMIN MODE ACTIVATION
    # When $Global:AdminMode is true (--admin arg + verified elevation):
    #   - Hide all standard menu sections and buttons
    #   - Show admin section with SFC / DISM / FlushDNS
    #   - Hide the Mode Admin button (already elevated)
    #   - Wire admin action buttons directly (no BtnRun flow)
    # ==================================================================
    if ($Global:AdminMode) {
        # Hide all standard menu items
        @("BtnOutlook","BtnTeams","BtnWhatsApp","BtnZoom","Btn8x8Work","BtnAnyDesk",
          "BtnSlack","BtnOneDrive","BtnDrive","BtnChrome","BtnDropbox",
          "BtnClean","BtnNetwork","BtnDiag","BtnRegistry","BtnIPDNS") | ForEach-Object {
            $b = $window.FindName($_)
            if ($b) { $b.Visibility = "Collapsed" }
        }
        # Hide standard section headers
        @("SectionComm","SectionProd","SectionSys") | ForEach-Object {
            $el = $window.FindName($_)
            if ($el) { $el.Visibility = "Collapsed" }
        }
        # Show admin section
        $window.FindName("AdminSection").Visibility = "Visible"

        # Hide Mode Admin button (already elevated, no need to elevate again)
        $window.FindName("BtnModeAdmin").Visibility = "Collapsed"

        # Show admin indicator in content area
        $window.FindName("ContentTitle").Text    = if ($Global:Language -eq "EN") { "Admin Mode" } else { "Modo Admin" }
        $window.FindName("ContentSubtitle").Text = if ($Global:Language -eq "EN") {
            "Running with elevated privileges. Select an admin action from the sidebar."
        } else {
            "Executando com privilegios elevados. Selecione uma acao admin no menu lateral."
        }

        # Wire admin action buttons directly — they open their own output windows
        $window.FindName("BtnSFC").Add_Click({
            Set-ButtonHover -btn $window.FindName("BtnSFC") -NC "Transparent" -HC "#3D1147"
            Executar-SFC
        })
        $window.FindName("BtnDISM").Add_Click({
            Executar-DISM
        })
        $window.FindName("BtnFlushDNS").Add_Click({
            Executar-FlushDNS
        })
        $window.FindName("BtnSpooler").Add_Click({
            Executar-PrintSpooler
        })
        $window.FindName("BtnEventos").Add_Click({
            Executar-EventosCriticos
        })
        $window.FindName("BtnBateria").Add_Click({
            Executar-RelatorioBateria
        })
        $window.FindName("BtnDiscoSMART").Add_Click({
            Executar-SaudeDisco
        })
        $window.FindName("BtnSyncEntra").Add_Click({
            Executar-SyncEntraID
        })

        # Hover effects for admin buttons
        Set-ButtonHover -btn $window.FindName("BtnSFC")        -NC "Transparent" -HC "#3D1147"
        Set-ButtonHover -btn $window.FindName("BtnDISM")       -NC "Transparent" -HC "#3D1147"
        Set-ButtonHover -btn $window.FindName("BtnFlushDNS")   -NC "Transparent" -HC "#3D1147"
        Set-ButtonHover -btn $window.FindName("BtnSpooler")    -NC "Transparent" -HC "#3D1147"
        Set-ButtonHover -btn $window.FindName("BtnEventos")    -NC "Transparent" -HC "#3D1147"
        Set-ButtonHover -btn $window.FindName("BtnBateria")    -NC "Transparent" -HC "#3D1147"
        Set-ButtonHover -btn $window.FindName("BtnDiscoSMART") -NC "Transparent" -HC "#3D1147"
        Set-ButtonHover -btn $window.FindName("BtnSyncEntra")  -NC "Transparent" -HC "#3D1147"

        Escrever-Log -Mensagem "Admin mode activated" -FunctionName "UI" -Action "AdminModeStart" -Status "INFO"
    }

    $window.FindName("BtnClearLog").Add_Click({
        $Global:WPF.LogPanel.Text = "Ready."
        WPF-Log (Get-Text "UI.LogCleared") -Color "#6B5878"
    })

    # ==================================================================
    # RUN ACTION - uses background Runspace so UI thread stays free
    # ==================================================================
    $Global:WPF.BtnRun.Add_Click({
        if (-not $Global:SelectedAction) { return }
        $action = $Global:SelectedAction

        # Disable UI controls during run
        $Global:WPF.BtnRun.IsEnabled  = $false
        $Global:WPF.BtnRun.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#B0A0B8")
        $Global:WPF.BtnRun.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#3D1147")
        WPF-SetStatus -Text (Get-Text "UI.StatusRunning") -Color "#F7C02D"

        # Reset progress
        $Global:ProgressCurrent = 0
        $Global:CurrentStep     = 0
        Update-Donut -Percent 0 -Label (Get-Text "UI.StatusRunning")
        WPF-Log "--- $(Get-Text 'UI.LogStarting'): $($actionTitles[$action]) ---" -Color "#6E277A"

        # ------------------------------------------------------------------
        # RUN ACTION - Execute the selected module function
        # ------------------------------------------------------------------
        # Functions run on the UI thread. Barra-Progresso uses
        # Dispatcher.Invoke(Render) to force frame renders between steps.
        # After the function returns, we animate the remaining progress
        # to 100% (in case the function finished before the last step),
        # then show the resolution dialog for app restart actions.
        # Actions 5, 12, 13 handle their own dialogs internally.
        # ------------------------------------------------------------------
        # Run module function directly on the UI thread.
        # Barra-Progresso calls Dispatcher.Invoke(Render priority) which
        # forces the WPF render pipeline to flush between each step,
        # making the donut update visible while the function runs.
        # This is simpler and more reliable than Runspace in PowerShell WPF.
        # ------------------------------------------------------------------
        $script:_action = $action
        try {
            switch ($action) {
                "1"  { Escrever-Log "Usuario executou: Teams";    Reiniciar-Teams      }
                "2"  { Escrever-Log "Usuario executou: Outlook";  Reiniciar-Outlook    }
                "3"  { Escrever-Log "Usuario executou: Drive";    Reiniciar-GoogleDrive }
                "4"  { Escrever-Log "Usuario executou: Slack";    Reiniciar-Slack      }
                "5"  { Escrever-Log "Usuario executou: Cleanup";  Limpar-PC            }
                "6"  { Escrever-Log "Usuario executou: Zoom";     Reiniciar-Zoom       }
                "7"  { Escrever-Log "Usuario executou: OneDrive"; Reiniciar-OneDrive   }
                "8"  { Escrever-Log "Usuario executou: Chrome";   Reiniciar-Chrome     }
                # [WEBEX] "9"  { Escrever-Log "Usuario executou: Webex";    Reiniciar-Webex      }
                "15" { Escrever-Log "Usuario executou: 8x8 Work"; Reiniciar-8x8Work    }
                "16" { Escrever-Log "Usuario executou: AnyDesk";  Reiniciar-AnyDesk    }
                "17" { Escrever-Log "Usuario executou: IP/DNS";   Verificar-IP-DNS     }
                "10" { Escrever-Log "Usuario executou: WhatsApp"; Reiniciar-WhatsApp   }
                "11" { Escrever-Log "Usuario executou: Dropbox";  Reiniciar-Dropbox    }
                "12" { Escrever-Log "Usuario executou: Network";  Diagnostico-Rede     }
                "13" { Escrever-Log "Usuario executou: Diag PC";  Diagnostico-PC       }
                "14" { Escrever-Log "Usuario executou: Registry"; Otimizar-Registro    }
                "18" { Escrever-Log "Usuario executou: ClickUp";  Reiniciar-ClickUp    }
            }

            # Animate remaining progress to 100%
            $from = $Global:ProgressCurrent
            for ($i = 1; $i -le 30; $i++) {
                $pct = [int]($from + (100 - $from) * ($i / 30))
                $Global:_DonutPct = $pct
                $Global:_DonutLbl = "Completing..."
                $Global:WPF.Window.Dispatcher.Invoke([action]{
                    $p    = $Global:_DonutPct
                    $path = Get-DonutPath -Percent $p
                    $Global:WPF.DonutArc.Data     = [Windows.Media.Geometry]::Parse($path)
                    $Global:WPF.DonutPct.Text     = "$p%"
                    $Global:WPF.DonutLabel.Text   = $Global:_DonutLbl
                    $Global:WPF.StepText.Text     = $Global:_DonutLbl
                    $Global:WPF.DonutArc.Stroke   = [Windows.Media.BrushConverter]::new().ConvertFromString("#6E277A")
                    $Global:WPF.DonutPct.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#3D1147")
                }, [Windows.Threading.DispatcherPriority]::Render)
                Start-Sleep -Milliseconds 20
            }

            # Final: 100% green
            $Global:_DonutPct = 100
            $Global:_DonutLbl = "Done"
            $Global:WPF.Window.Dispatcher.Invoke([action]{
                $path = Get-DonutPath -Percent 100
                $Global:WPF.DonutArc.Data       = [Windows.Media.Geometry]::Parse($path)
                $Global:WPF.DonutPct.Text       = "100%"
                $Global:WPF.DonutLabel.Text     = "Done"
                $Global:WPF.StepText.Text       = "Done"
                $Global:WPF.DonutArc.Stroke     = [Windows.Media.BrushConverter]::new().ConvertFromString("#3EA384")
                $Global:WPF.DonutPct.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#3EA384")
                $Global:WPF.StatusDot.Fill      = [Windows.Media.BrushConverter]::new().ConvertFromString("#3EA384")
                $Global:WPF.StatusText.Text     = "Done"
            }, [Windows.Threading.DispatcherPriority]::Render)

            # Only show Done log for app restart actions
            # Actions 5, 12, 13, 14 have their own result windows
            if ($script:_action -notin @("5","12","13","14","17")) {
                WPF-Log "--- Done ---" -Color "#3EA384"
                Perguntar-Resolvido
            }

        } catch {
            WPF-Log "ERROR: $_" -Color "#E05050"
            $Global:WPF.Window.Dispatcher.Invoke([action]{
                $Global:WPF.StatusDot.Fill  = [Windows.Media.BrushConverter]::new().ConvertFromString("#E05050")
                $Global:WPF.StatusText.Text = "Error"
            }, [Windows.Threading.DispatcherPriority]::Render)
            Escrever-Log -Mensagem "UI Error: $_" -FunctionName "UI" -Action "RunError" -Status "ERROR"
        } finally {
            Start-Sleep -Milliseconds 1500
            $Global:ProgressCurrent = 0
            $Global:CurrentStep     = 0
            $Global:_DonutPct = 0
            $Global:_DonutLbl = "Idle"
            $Global:WPF.Window.Dispatcher.Invoke([action]{
                $path = Get-DonutPath -Percent 0
                $Global:WPF.DonutArc.Data       = [Windows.Media.Geometry]::Parse($path)
                $Global:WPF.DonutPct.Text       = "0%"
                $Global:WPF.DonutLabel.Text     = "Idle"
                $Global:WPF.StepText.Text       = ""
                $Global:WPF.DonutArc.Stroke     = [Windows.Media.BrushConverter]::new().ConvertFromString("#D8D0DC")
                $Global:WPF.DonutPct.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#3D1147")
                $Global:WPF.StatusDot.Fill      = [Windows.Media.BrushConverter]::new().ConvertFromString("#3EA384")
                $Global:WPF.StatusText.Text     = "Idle"
                # FIX: antes reativava o botao Executar incondicionalmente.
                # Agora, se Reset-SidebarSelection ja limpou a selecao (fluxo
                # do Perguntar-Resolvido), o botao continua desabilitado/cinza
                # ate uma nova acao ser escolhida - mesmo estado da tela inicial.
                if ($Global:SelectedAction) {
                    $Global:WPF.BtnRun.IsEnabled    = $true
                    $Global:WPF.BtnRun.Background   = [Windows.Media.BrushConverter]::new().ConvertFromString("#6E277A")
                    $Global:WPF.BtnRun.Foreground   = [Windows.Media.Brushes]::White
                } else {
                    $Global:WPF.BtnRun.IsEnabled    = $false
                    $Global:WPF.BtnRun.Background   = [Windows.Media.BrushConverter]::new().ConvertFromString("#B0A0B8")
                    $Global:WPF.BtnRun.Foreground   = [Windows.Media.BrushConverter]::new().ConvertFromString("#3D1147")
                }
            }, [Windows.Threading.DispatcherPriority]::Render)
        }
    })

    # Set all labels from language
    $window.FindName("StatusBarUser").Text    = $env:USERNAME
    $window.FindName("StatusBarMachine").Text = $env:COMPUTERNAME
    $window.FindName("SectionComm").Text      = Get-Text "UI.SectionComm"
    $window.FindName("SectionProd").Text      = Get-Text "UI.SectionProd"
    $window.FindName("SectionSys").Text       = Get-Text "UI.SectionSys"
    $window.FindName("BtnOutlookText").Text     = Get-Text "UI.Menu.2"
    $window.FindName("BtnTeamsText").Text       = Get-Text "UI.Menu.1"
    $window.FindName("BtnWhatsAppText").Text    = Get-Text "UI.Menu.10"
    $window.FindName("BtnZoomText").Text        = Get-Text "UI.Menu.6"
    # [WEBEX] $window.FindName("BtnWebexText").Text       = Get-Text "UI.Menu.9"
    $window.FindName("Btn8x8WorkText").Text     = Get-Text "UI.Menu.15"
    $window.FindName("BtnAnyDeskText").Text     = Get-Text "UI.Menu.16"
    $window.FindName("BtnIPDNSText").Text       = Get-Text "UI.Menu.17"
    $window.FindName("BtnSlackText").Text       = Get-Text "UI.Menu.4"
    $window.FindName("BtnClickUpText").Text     = Get-Text "UI.Menu.18"
    $window.FindName("BtnOneDriveText").Text    = Get-Text "UI.Menu.7"
    $window.FindName("BtnDriveText").Text       = Get-Text "UI.Menu.3"
    $window.FindName("BtnChromeText").Text      = Get-Text "UI.Menu.8"
    $window.FindName("BtnDropboxText").Text     = Get-Text "UI.Menu.11"
    $window.FindName("BtnCleanText").Text       = Get-Text "UI.Menu.5"
    $window.FindName("BtnNetworkText").Text     = Get-Text "UI.Menu.12"
    $window.FindName("BtnDiagText").Text        = Get-Text "UI.Menu.13"
    $window.FindName("BtnRegistryText").Text    = Get-Text "UI.Menu.14"
    $window.FindName("BtnExit").Content       = "  " + (Get-Text "UI.Exit")
    $window.FindName("BtnRun").Content        = Get-Text "UI.BtnRun"
    $window.FindName("BtnClearLog").Content   = Get-Text "UI.BtnClear"
    $window.FindName("BtnToggleLog").Content  = "  " + (Get-Text "UI.BtnViewLog")
    $window.FindName("ContentTitle").Text     = Get-Text "UI.Welcome"
    $window.FindName("ContentSubtitle").Text  = Get-Text "UI.WelcomeSub"
    $window.FindName("LogOutput").Text        = Get-Text "UI.LogReady"
    $window.FindName("DonutLabel").Text       = Get-Text "UI.StatusIdle"
    $window.FindName("StatusText").Text       = Get-Text "UI.StatusIdle"

    $window.ShowDialog() | Out-Null
}

# =====================================================================
# WPF HELPERS
# =====================================================================
# Appends a timestamped message to the in-app execution log panel.
# The log is visible when the user clicks "Ver Log" in the sidebar.
# Uses Dispatcher.BeginInvoke (async) so it doesn't block execution.
# IMPORTANT: $Message is stored in $Global:_LogMessage before the
# BeginInvoke call because PowerShell closures don't capture outer
# scope variables automatically.
function WPF-Log {
    param([string]$Message, [string]$Color = "#3D1147")
    if ($null -eq $Global:WPF.LogPanel) { Write-Host $Message; return }
    # Store message in Global so BeginInvoke closure can access it
    $Global:_LogMessage = $Message
    $Global:WPF.Window.Dispatcher.BeginInvoke([action]{
        $ts      = Get-Date -Format "HH:mm:ss"
        $msg     = $Global:_LogMessage
        $current = $Global:WPF.LogPanel.Text
        $Global:WPF.LogPanel.Text = if ($current -eq "Ready." -or $current -eq "Pronto.") {
            "[$ts] $msg"
        } else {
            "$current`n[$ts] $msg"
        }
        $Global:WPF.LogScroll.ScrollToEnd()
    }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

function WPF-ProgressUpdate { param([int]$Value, [string]$Message="") Update-Donut -Percent $Value -Label $Message }
function WPF-ProgressShow   { param([string]$Message="",[int]$Value=0) Update-Donut -Percent $Value -Label $Message }
function WPF-ProgressHide   { Update-Donut -Percent 0 -Label (Get-Text "UI.StatusIdle") }

# Updates the status dot color and status text in the bottom-left
# of the main window (e.g. "Running..." in amber, "Done" in green).
# Color string stored in Global before BeginInvoke for same reason
# as WPF-Log - closure variable capture limitation.
function WPF-SetStatus {
    param([string]$Text="Idle",[string]$Color="#3EA384")
    if ($null -eq $Global:WPF.StatusDot) { return }
    if ([string]::IsNullOrEmpty($Color)) { $Color = "#3EA384" }
    if ([string]::IsNullOrEmpty($Text))  { $Text  = "Idle" }
    # Store in Global so the BeginInvoke closure can read them
    # (PowerShell closures don't capture local vars unless GetNewClosure() is used,
    #  but GetNewClosure is not always available. Global is the safest approach.)
    $Global:_StatusColor = $Color
    $Global:_StatusText  = $Text
    $Global:WPF.Window.Dispatcher.BeginInvoke([action]{
        if (-not [string]::IsNullOrEmpty($Global:_StatusColor)) {
            $Global:WPF.StatusDot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($Global:_StatusColor)
        }
        $Global:WPF.StatusText.Text = $Global:_StatusText
    }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

# ==============================================================
# BARRA-PROGRESSO - Progress bar advancement
# ==============================================================
# Called once per logical step from module functions (apps, network,
# system). Each call animates the donut from its current position
# to the next target % defined in ActionSteps.
#
# HOW IT WORKS ON THE UI THREAD:
#   Module functions run on the WPF UI thread. When Barra-Progresso
#   calls Dispatcher.Invoke with Render priority, WPF is forced to
#   flush the render pipeline (draw the frame) before returning.
#   This makes each animation tick visible to the user while the
#   module function continues executing its next operation.
#
#   Each step animates over 40 ticks x 30ms = ~1.2 seconds,
#   giving a smooth visual transition between steps.
#
# FALLBACK:
#   If $Global:WPF.Window is null (no WPF window open), falls back
#   to a simple WinForms progress popup for testing from console.
# ==============================================================
function Barra-Progresso {
    param([string]$Mensagem)

    if ($null -ne $Global:WPF.Window) {

        # Log step message to panel
        # Skip for result-window actions (5,12,13,14) to avoid duplicate info
        $skipLogActions = @("5","12","13","14")
        if ($Global:SelectedAction -notin $skipLogActions) {
            $Global:_LogMessage = $Mensagem
            $Global:WPF.Window.Dispatcher.Invoke([action]{
                $ts      = Get-Date -Format "HH:mm:ss"
                $msg     = $Global:_LogMessage
                $current = $Global:WPF.LogPanel.Text
                $Global:WPF.LogPanel.Text = if ($current -eq "Ready." -or $current -eq "Pronto.") {
                    "[$ts] $msg"
                } else {
                    "$current`n[$ts] $msg"
                }
                $Global:WPF.LogScroll.ScrollToEnd()
            }, [Windows.Threading.DispatcherPriority]::Render)
        }

        # Advance to next defined step and animate smoothly
        $steps = $Global:ActionSteps[$Global:SelectedAction]
        if ($steps -and $Global:CurrentStep -lt $steps.Count) {
            $target = $steps[$Global:CurrentStep][0]
            $lbl    = $steps[$Global:CurrentStep][1]
            $Global:CurrentStep++

            $from = $Global:ProgressCurrent
            $to   = $target

            # Smooth animation: 40 ticks of 30ms = 1.2 seconds per step
            for ($i = 1; $i -le 40; $i++) {
                $pct = [int]($from + ($to - $from) * ($i / 40))
                $Global:_DonutPct = $pct
                $Global:_DonutLbl = $lbl
                $Global:WPF.Window.Dispatcher.Invoke([action]{
                    $p    = $Global:_DonutPct
                    $l    = $Global:_DonutLbl
                    $path = Get-DonutPath -Percent $p
                    $Global:WPF.DonutArc.Data     = [Windows.Media.Geometry]::Parse($path)
                    $Global:WPF.DonutPct.Text     = "$p%"
                    $Global:WPF.DonutLabel.Text   = $l
                    $Global:WPF.StepText.Text     = $l
                    if ($p -eq 0)       { $arc = "#D8D0DC"; $pctc = "#3D1147" }
                    elseif ($p -ge 100) { $arc = "#3EA384"; $pctc = "#3EA384" }
                    else                { $arc = "#6E277A"; $pctc = "#3D1147" }
                    $Global:WPF.DonutArc.Stroke     = [Windows.Media.BrushConverter]::new().ConvertFromString($arc)
                    $Global:WPF.DonutPct.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($pctc)
                }, [Windows.Threading.DispatcherPriority]::Render)
                Start-Sleep -Milliseconds 30
            }
            $Global:ProgressCurrent = $to
        }
    } else {
        # Fallback WinForms popup
        $form           = New-Object System.Windows.Forms.Form
        $form.Text      = "IT Support Agent"
        $form.Width     = 500
        $form.Height    = 130
        $form.StartPosition = "CenterScreen"
        $form.BackColor = [System.Drawing.Color]::FromArgb(61,17,71)
        $lbl            = New-Object System.Windows.Forms.Label
        $lbl.Text       = $Mensagem
        $lbl.ForeColor  = [System.Drawing.Color]::White
        $lbl.Font       = "Segoe UI, 10"
        $lbl.AutoSize   = $true
        $lbl.Location   = "20,10"
        $form.Controls.Add($lbl)
        $bar            = New-Object System.Windows.Forms.ProgressBar
        $bar.Width      = 440
        $bar.Location   = "20,40"
        $form.Controls.Add($bar)
        $form.Show()
        1..100 | ForEach-Object { $bar.Value = $_; Start-Sleep -Milliseconds 20; [System.Windows.Forms.Application]::DoEvents() }
        $form.Close()
    }
}

# ==============================================================
# PERGUNTAR-RESOLVIDO - Post-action resolution dialog
# ==============================================================
# Shown after an action completes. Asks the user if the problem
# was resolved.
#
#   "Resolvido"     -> Logs RESOLVED, returns to main window
#   "Nao resolvido" -> Logs NOT_RESOLVED, calls Abrir-Ticket-Email
#
# SPECIAL CASE: $Global:ForcarAberturaTicket
#   Set by Abrir-Download-WifiDriver when a driver update is needed.
#   When true, skips the yes/no dialog and shows only a single
#   "Open Ticket" button, forcing the user to open a support ticket.
#
# WHICH ACTIONS CALL THIS:
#   Called by ui.psm1 Run Action for actions 1-4, 6-11 (app restarts).
#   Actions 5, 12, 13 call it themselves from their result windows
#   (BtnOk click handler) so it is excluded from the ui.psm1 call.
# ==============================================================
# ==============================================================
# RESET-SIDEBAR-SELECTION
# --------------------------------------------------------------
# Limpa a selecao visual do sidebar e volta o painel de conteudo
# para a tela inicial de "Bem-vindo" - usada pelo Perguntar-Resolvido
# depois que o usuario da o feedback (Resolvido ou Nao Resolvido),
# para a tela nao ficar "presa" mostrando a ultima acao executada.
#
# A lista de nomes de botoes e a MESMA usada em Launch-MainWindow -
# duplicada aqui porque aquela e uma variavel local aquela funcao.
# Se um botao novo for adicionado ao sidebar, adicione o nome dele
# aqui tambem (mesmo passo que ja e descrito no cabecalho do apps.psm1
# para "adicionar um app novo").
# ==============================================================
function Reset-SidebarSelection {
    if ($null -eq $Global:WPF.Window) { return }

    $sidebarButtons = @("BtnOutlook","BtnTeams","BtnWhatsApp","BtnZoom","Btn8x8Work","BtnAnyDesk","BtnSlack","BtnClickUp","BtnOneDrive","BtnDrive","BtnChrome","BtnDropbox","BtnClean","BtnNetwork","BtnDiag","BtnRegistry","BtnIPDNS")

    foreach ($btnName in $sidebarButtons) {
        $btn = $Global:WPF.Window.FindName($btnName)
        if ($null -ne $btn) {
            $btn.Background = [Windows.Media.Brushes]::Transparent
            $btn.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#C4AACC")
            $btn.FontWeight = "Normal"
        }
    }

    $Global:SelectedAction = $null
    $Global:WPF.ContentTitle.Text = Get-Text "UI.Welcome"
    $Global:WPF.ContentSub.Text   = Get-Text "UI.WelcomeSub"
    $Global:WPF.BtnRun.IsEnabled  = $false
    $Global:WPF.BtnRun.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#B0A0B8")
    $Global:WPF.BtnRun.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString("#3D1147")
}

function Perguntar-Resolvido {

    if ($Global:ForcarAberturaTicket) {
        [xml]$dXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IT Support Agent" Width="460" Height="210"
        WindowStartupLocation="CenterScreen" Background="#E8E0EC"
        WindowStyle="ToolWindow" ResizeMode="NoResize" Topmost="True">
    <StackPanel Margin="24">
        <TextBlock x:Name="TitleLbl" Text="" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="15" Margin="0,0,0,10"/>
        <TextBlock x:Name="BodyLbl"  Text="" Foreground="#6B5878" FontFamily="Segoe UI" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,20"/>
        <Button x:Name="BtnOk" Content="" Background="#6E277A" Foreground="White"
                BorderThickness="0" Padding="20,10" MinWidth="140" Height="38"
                FontFamily="Segoe UI Semibold" FontSize="13" HorizontalAlignment="Center" Cursor="Hand"/>
    </StackPanel>
</Window>
"@
        $dr = [System.Xml.XmlNodeReader]::new($dXAML)
        $dw = [Windows.Markup.XamlReader]::Load($dr)
        $dw.FindName("TitleLbl").Text = Get-Text "DriverTitulo"
        $dw.FindName("BodyLbl").Text  = Get-Text "DriverTexto"
        $dw.FindName("BtnOk").Content = Get-Text "BtnAbrirTicket"
        $dw.FindName("BtnOk").Add_Click({ $dw.Close() })
        $dw.ShowDialog() | Out-Null
        $Global:ForcarAberturaTicket = $null
        Abrir-Ticket-Email
        return
    }

    $script:resolveResult = "Resolvido"

    [xml]$rXAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="IT Support Agent" Width="460" Height="230"
        WindowStartupLocation="CenterScreen" Background="#E8E0EC"
        WindowStyle="ToolWindow" ResizeMode="NoResize" Topmost="True">
    <StackPanel Margin="24">
        <TextBlock x:Name="TitleLbl" Text="" Foreground="#3D1147" FontFamily="Segoe UI Semibold" FontSize="15" Margin="0,0,0,8"/>
        <TextBlock x:Name="BodyLbl"  Text="" Foreground="#6B5878" FontFamily="Segoe UI" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,24"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <Button x:Name="BtnYes" Content="" Background="#3EA384" Foreground="White"
                    BorderThickness="0" Padding="20,10" MinWidth="130" Height="38"
                    FontFamily="Segoe UI Semibold" FontSize="13" Cursor="Hand" Margin="0,0,12,0"/>
            <Button x:Name="BtnNo"  Content="" Background="#6E277A" Foreground="White"
                    BorderThickness="0" Padding="20,10" MinWidth="160" Height="38"
                    FontFamily="Segoe UI Semibold" FontSize="13" Cursor="Hand"/>
        </StackPanel>
    </StackPanel>
</Window>
"@
    $rdr = [System.Xml.XmlNodeReader]::new($rXAML)
    $rw  = [Windows.Markup.XamlReader]::Load($rdr)
    $rw.FindName("TitleLbl").Text  = Get-Text "UI.DialogDoneTitle"
    $rw.FindName("BodyLbl").Text   = Get-Text "UI.DialogDoneText"
    $rw.FindName("BtnYes").Content = Get-Text "BtnResolvido"
    $rw.FindName("BtnNo").Content  = Get-Text "BtnNaoResolvido"
    # Hover: 2 tones lighter, text stays white
    $btnYes = $rw.FindName("BtnYes")
    $btnNo  = $rw.FindName("BtnNo")
    $btnYes.Tag = "#3EA384|#52BF9E"
    $btnNo.Tag  = "#6E277A|#8E3A9A"
    $btnYes.Add_MouseEnter({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
    $btnYes.Add_MouseLeave({ param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })
    $btnNo.Add_MouseEnter({  param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[1]) })
    $btnNo.Add_MouseLeave({  param($s,$e) $c=$s.Tag -split "\|"; $s.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($c[0]) })
    $rw.FindName("BtnYes").Add_Click({ $script:resolveResult = "Resolvido";    $rw.Close() })
    $rw.FindName("BtnNo").Add_Click({  $script:resolveResult = "NaoResolvido"; $rw.Close() })
    $rw.ShowDialog() | Out-Null

    if ($script:resolveResult -eq "Resolvido") {
        Escrever-Log -Mensagem "Resolved" -FunctionName "USER_FEEDBACK" -Action "Feedback" -Status "RESOLVED" -Application $Global:UltimaFuncaoExecutada
        WPF-Log (Get-Text "UI.LogResolved") -Color "#3EA384"
    } else {
        Escrever-Log -Mensagem "Not resolved" -FunctionName "USER_FEEDBACK" -Action "Feedback" -Status "NOT_RESOLVED" -Application $Global:UltimaFuncaoExecutada
        WPF-Log (Get-Text "UI.LogTicket") -Color "#F7C02D"
        Abrir-Ticket-Email
    }

    # FIX: depois do feedback (resolvido ou nao), a tela voltava para
    # o "Bem-vindo" so na proxima vez que o app abrisse - ficava presa
    # mostrando a ultima acao executada. Agora reseta pra tela inicial
    # nos dois casos, exigindo nova selecao antes de rodar outra acao.
    Reset-SidebarSelection
}

# =====================================================================
# MOSTRAR-LOGO
# =====================================================================
# Shows the splash screen logo (assets/logo.png) for 2 seconds
# before the main WPF window opens. Called from main.ps1.
# If the logo file does not exist, this function returns silently.
function Mostrar-Logo {
    # Splash screen shown for 2 seconds before the main window opens.
    # Uses WinForms because WPF is not yet initialized at this point.
    # Logo centered in a dark purple borderless window.
    $LogoPath = Join-Path $Global:AssetsPath "logo.png"
    if (-not (Test-Path $LogoPath)) { return }

    $form                  = New-Object System.Windows.Forms.Form
    $form.Text             = "Agent IT"
    $form.Width            = 320
    $form.Height           = 320
    $form.StartPosition    = "CenterScreen"
    $form.BackColor        = [System.Drawing.Color]::FromArgb(26, 10, 46)
    $form.FormBorderStyle  = "None"
    $form.TopMost          = $true

    # Logo centered
    $pb            = New-Object System.Windows.Forms.PictureBox
    $pb.Image      = [System.Drawing.Image]::FromFile($LogoPath)
    $pb.SizeMode   = "Zoom"
    $pb.Width      = 180
    $pb.Height     = 180
    $pb.Left       = ($form.Width  - $pb.Width)  / 2
    $pb.Top        = ($form.Height - $pb.Height) / 2 - 16
    $form.Controls.Add($pb)

    # App name label below logo
    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = "Agent IT"
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(45, 247, 185)
    $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $lbl.AutoSize  = $true
    $lbl.Left      = ($form.Width - 90) / 2
    $lbl.Top       = $pb.Bottom + 12
    $form.Controls.Add($lbl)

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep 2
    $form.Close()
}

# ==============================================================
# ABRIR-TICKET-EMAIL - Support ticket email composer
# ==============================================================
# FIX (v1.1.5): trocado de novo. A versao anterior abria o Outlook
# DESKTOP via linha de comando (/c ipm.note), mas isso so encontra e
# abre o Outlook CLASSICO - em maquinas com "novo Outlook" (New Outlook,
# o app baseado em web/loja), o ticket abria no app errado (Classico),
# nao no que o usuario realmente usa.
#
# Agora abre direto o Outlook WEB (compose), que funciona igual pra
# qualquer configuracao (Classic, New Outlook, ou so navegador) porque
# nao depende de nenhum executavel instalado - so abre uma URL no
# navegador padrao, com todos os campos ja preenchidos.
#
# IDIOMA: assunto e corpo continuam respeitando $Global:Language -
# se o usuario escolheu Ingles na tela inicial, o email sai em ingles.
#
# DESTINATARIO:
#   $Global:EmailDestino - fixo em firedesk@jemsystems.com.
# ==============================================================
$Global:EmailDestino = "firedesk@jemsystems.com"

function Abrir-Ticket-Email {
    $Usuario         = $env:USERNAME
    $Maquina         = $env:COMPUTERNAME
    $FuncaoExecutada = $Global:UltimaFuncaoExecutada
    if (-not $FuncaoExecutada) { $FuncaoExecutada = "Funcao nao identificada" }

    $isEN = $Global:Language -eq "EN"

    $assunto = if ($isEN) {
        "IT Support - Unresolved issue: $FuncaoExecutada"
    } else {
        "Suporte TI - Problema nao resolvido: $FuncaoExecutada"
    }
    $corpo = if ($isEN) {
        "Hello IT team,`n`nI ran the action: $FuncaoExecutada, but it was not resolved. Could you please help me?`n`nMachine info:`nPC Name: $Maquina`nUser: $Usuario`n`nThank you."
    } else {
        "Ola time de TI,`n`nExecutei a acao: $FuncaoExecutada, mas nao foi resolvido. Por favor, poderia me ajudar?`n`nDados da maquina:`nNome do PC: $Maquina`nUsuario: $Usuario`n`nObrigado(a)."
    }

    $subjectEnc = [System.Uri]::EscapeDataString($assunto)
    $bodyEnc    = [System.Uri]::EscapeDataString($corpo)
    $toEnc      = [System.Uri]::EscapeDataString($Global:EmailDestino)
    $url        = "https://outlook.office.com/mail/deeplink/compose?to=$toEnc&subject=$subjectEnc&body=$bodyEnc"

    try {
        Start-Process $url -ErrorAction Stop
        $idiomaLog = if ($isEN) { "EN" } else { "PT" }
        Escrever-Log -Mensagem "Ticket | Outlook Web compose aberto (idioma=$idiomaLog)" -FunctionName "TICKET" -Action "OpenTicket" -Status "SUCCESS"
    } catch {
        $err = $_.ToString()
        Add-Type -AssemblyName System.Windows.Forms
        $errMsg = if ($isEN) {
            "Could not open Outlook Web automatically.`n`nPlease send an email manually to:`n$($Global:EmailDestino)`n`nSubject: $assunto`n`n$corpo"
        } else {
            "Nao foi possivel abrir o Outlook Web automaticamente.`n`nPor favor, envie um email manualmente para:`n$($Global:EmailDestino)`n`nAssunto: $assunto`n`n$corpo"
        }
        [System.Windows.Forms.MessageBox]::Show($errMsg, "Ticket de Suporte", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Escrever-Log -Mensagem "Ticket | Erro ao abrir Outlook Web: $err" -FunctionName "TICKET" -Action "OpenTicketError" -Status "ERROR"
    }
}
# =====================================================================
# LEGACY STUBS
# =====================================================================
function Menu-Principal { return $null }
function Voltar-Menu    { return }

Export-ModuleMember -Function `
    Launch-MainWindow, Mostrar-Logo, Barra-Progresso, `
    Perguntar-Resolvido, Abrir-Ticket-Email, `
    WPF-Log, WPF-ProgressShow, WPF-ProgressUpdate, `
    WPF-ProgressHide, WPF-SetStatus, Update-Donut, `
    Build-ActionSteps, Menu-Principal, Voltar-Menu, Animate-DonutAdmin, Reset-SidebarSelection
