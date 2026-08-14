# ==============================================================
# logging.psm1 - Structured log writer
# ==============================================================
# WHAT THIS MODULE DOES:
#   Provides Escrever-Log, the single logging function used by
#   ALL other modules. Every action the user takes is recorded
#   locally to a dated .txt file on the machine.
#
# LOCAL LOG LOCATION:
#   C:\IT Support Agent\Logs\Log_YYYY-MM-DD.txt
#
# DASHBOARD INTEGRATION (comentado - ativar na empresa):
#   O bloco marcado com [DASHBOARD] envia eventos para o Supabase
#   da empresa para visualizacao no painel administrativo.
#   Para ativar:
#     1. Crie o projeto no Supabase da empresa
#     2. Crie a Edge Function "log-event"
#     3. Preencha SUPABASE_URL_LOG e SUPABASE_ANON_LOG abaixo
#     4. Descomente o bloco [DASHBOARD] no final desta funcao
#
# UTF-8 FIX (v1.1.1):
#   Windows usernames with accented characters (e.g. "Usuario")
#   were being stored as garbled text because PS5 uses system
#   codepage (CP1252 on PT-BR). Fix: explicit UTF-8 conversion.
# ==============================================================

# ==============================================================
# ENCODING SETUP
# ==============================================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding  = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

# ==============================================================
# [DASHBOARD] CONFIGURAR: Supabase da empresa
# --------------------------------------------------------------
# Descomente e preencha quando migrar para a empresa.
# Supabase Dashboard -> Project Settings -> API -> Project URL
# Supabase Dashboard -> Project Settings -> API -> anon/public key
#
# FIX (v1.2.0): payload reestruturado para os filtros da dashboard
# (aplicacao, tipo de evento, data, usuario, status, detalhes).
# Antes o "action" enviado era um texto combinado ("App - Acao");
# agora "application" e "action" vao em campos separados, e
# "function_name" (APPLICATIONS/ADMIN/NETWORK/SYSTEM/USER_FEEDBACK/
# TICKET) vira o "tipo de evento" que a dashboard filtra. O campo
# "environment" (production/staging) vem de $Global:Environment,
# definido no main.ps1 - reflete o mesmo texto usado la.
# ==============================================================
$Global:SUPABASE_URL_LOG  = "https://sluhfuoazyykrhhgestg.supabase.co/functions/v1/log-event"
$Global:SUPABASE_ANON_LOG = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNsdWhmdW9henl5a3JoaGdlc3RnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY3MzE4OTgsImV4cCI6MjEwMjMwNzg5OH0.TmUVK4zf9_d-DGXAnl141zopV9ZvoVUwYeqtqN64xPg"

# ==============================================================
# HELPER: Normalize-StringUTF8
# ==============================================================
# Ensures a string is properly encoded as UTF-8.
# Fixes accented characters on PT-BR Windows (CP1252 -> UTF-8).
# ==============================================================
function Normalize-StringUTF8 {
    param([string]$InputString)
    if ([string]::IsNullOrEmpty($InputString)) { return $InputString }
    try {
        $ansiBytes = [System.Text.Encoding]::Default.GetBytes($InputString)
        return [System.Text.Encoding]::UTF8.GetString($ansiBytes)
    } catch {
        return $InputString
    }
}

function Escrever-Log {
    param(
        [string]$Mensagem,        # Human-readable description of what happened
        [string]$FunctionName,    # Module/category (e.g. "APPLICATIONS", "SYSTEM")
        [string]$Action,          # Specific action code (e.g. "Opened", "Closed")
        [string]$Status = "INFO", # INFO | SUCCESS | WARNING | ERROR | FAIL | EXECUTED
        [string]$Details,         # Optional extra key=value pairs for debugging
        [string]$Application      # App name (e.g. "Microsoft Teams")
    )

    # Create local log directory if needed
    $pastaLog = "C:\IT Support Agent\Logs"
    if (!(Test-Path $pastaLog)) {
        New-Item -ItemType Directory -Path $pastaLog | Out-Null
    }

    $arquivoLog   = "$pastaLog\Log_$(Get-Date -Format yyyy-MM-dd).txt"
    $dataHora     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $ComputerName = $env:COMPUTERNAME
    $UserName     = $env:USERNAME

    # Resolve function name
    $funcao = if ($FunctionName)                    { $FunctionName }
              elseif ($Global:UltimaFuncaoExecutada) { $Global:UltimaFuncaoExecutada }
              else                                  { "Sem funcao definida" }

    # FIX (v1.2.0): quando -Action era informado, esta linha usava $Details
    # (parametro que NENHUMA chamada em todo o projeto preenche) em vez de
    # $Mensagem (onde o texto descritivo de verdade sempre foi passado -
    # ex: "8x8 Work | 3 processo(s) encerrado(s) | caminho para reabrir: X").
    # Resultado: essa mensagem nunca era gravada no log local quando havia
    # Action. Corrigido para sempre incluir $Mensagem; $Details continua
    # disponivel como extra opcional, anexado se algum dia for usado.
    if ($Action) {
        $appTag     = if ($Application) { "[APP:$Application]" } else { "" }
        $extraDetails = if ($Details) { " $Details" } else { "" }
        $linhaLog   = "[$dataHora] [PC:$ComputerName] [User:$UserName] [$funcao] $appTag [Action:$Action] [Status:$Status] $Mensagem$extraDetails"
    } else {
        $linhaLog = "[$dataHora] [PC:$ComputerName] [User:$UserName] [$funcao] $Mensagem"
    }

    # Write to local log file with explicit UTF-8 encoding
    Add-Content -Path $arquivoLog -Value $linhaLog -Encoding UTF8

    # ==============================================================
    # [DASHBOARD] ENVIO REMOTO - Supabase da empresa
    # --------------------------------------------------------------
    # Descomente este bloco inteiro quando migrar para a empresa.
    # Requer: $Global:SUPABASE_URL_LOG e $Global:SUPABASE_ANON_LOG
    # configurados acima.
    #
    # O bloco envia apenas acoes significativas do usuario (com $Action)
    # para a tabela de eventos no Supabase da empresa.
    # Mensagens internas (sem $Action) ficam apenas no log local.
    #
    # FIX (v1.2.0): payload agora envia campos SEPARADOS em vez de um
    # texto combinado - isso e o que permite a dashboard filtrar por
    # aplicacao, tipo de evento (function_name) e status de forma
    # independente, em vez de precisar quebrar uma string.
    #   environment    -> "production" ou "staging" ($Global:Environment,
    #                     definido no main.ps1)
    #   function_name  -> categoria/"tipo de evento" (APPLICATIONS,
    #                     ADMIN, NETWORK, SYSTEM, USER_FEEDBACK, TICKET)
    #   application    -> nome do app (Microsoft Teams, 8x8 Work, etc.)
    #                     ou null para acoes que nao sao de um app
    #                     especifico (diagnosticos, admin)
    #   action         -> o codigo especifico (RestartStart, Opened,
    #                     Feedback, SFCStart, etc.)
    #   status         -> INFO/SUCCESS/WARNING/ERROR/RESOLVED/NOT_RESOLVED
    #   details        -> o texto legivel ($Mensagem) para o usuario ver
    #                     "o que aconteceu" sem precisar decifrar codigos
    # ==============================================================
    # ==============================================================
    # ATIVADO (v1.2.1): credenciais reais preenchidas acima.
    # Seguro deixar ativo mesmo antes do deploy da Edge Function
    # "log-event" - a chamada tem timeout de 3s e ignora qualquer
    # erro em silencio (o log local sempre continua sendo a fonte
    # de verdade). Ate o deploy acontecer, essas chamadas so falham
    # sem nenhum efeito colateral.
    # ==============================================================
    if ($Action -and $Global:SUPABASE_URL_LOG -and $Global:SUPABASE_ANON_LOG) {

        # Skip internal step markers that would flood the events table
        $skipActions = @(
            "DiagStart","DiagEnd","ScanDone","PathSearch",
            "Start","Done","MRUSkip","JumplistSkip","SearchSkip",
            "CollectSystemInfo","CPUCheck","RAMCheck","DiskCheck",
            "UptimeCheck","WifiDriverCheck","HealthScoreCalculated",
            "EntraSyncStopped","EntraSyncStarted"
        )

        if ($Action -notin $skipActions) {
            try {
                $usernameClean     = Normalize-StringUTF8 -InputString $UserName
                $computernameClean = Normalize-StringUTF8 -InputString $ComputerName
                $funcaoClean       = Normalize-StringUTF8 -InputString $funcao
                $applicationClean  = if ($Application) { Normalize-StringUTF8 -InputString $Application } else { $null }
                $mensagemClean     = Normalize-StringUTF8 -InputString $Mensagem

                # "production" e o padrao de seguranca: se $Global:Environment
                # nao estiver definido por algum motivo, nunca marca um evento
                # como staging por engano.
                $ambiente = if ($Global:Environment -eq "STAGING") { "staging" } else { "production" }

                $bodyObject = @{
                    environment   = $ambiente
                    computername = $computernameClean
                    username     = $usernameClean
                    function_name = $funcaoClean
                    application  = $applicationClean
                    action       = $Action
                    status       = $Status
                    details      = $mensagemClean
                }

                $jsonString = $bodyObject | ConvertTo-Json -Compress
                $utf8Bytes  = [System.Text.Encoding]::UTF8.GetBytes($jsonString)

                # FIX (v1.2.2): Edge Functions do Supabase exigem "Authorization:
                # Bearer" (verificacao de JWT do proprio portao de entrada) -
                # "apikey" sozinho retorna 401 Unauthorized. A anon key ja e
                # um JWT valido (role=anon), serve para os dois cabecalhos.
                $null = Invoke-RestMethod `
                    -Uri         $Global:SUPABASE_URL_LOG `
                    -Method      Post `
                    -Body        $utf8Bytes `
                    -ContentType "application/json; charset=utf-8" `
                    -Headers     @{ "apikey" = $Global:SUPABASE_ANON_LOG; "Authorization" = "Bearer $($Global:SUPABASE_ANON_LOG)" } `
                    -TimeoutSec  3 `
                    -ErrorAction SilentlyContinue

            } catch {
                # Silently ignore - local log is always the source of truth
            }
        }
    }
}

Export-ModuleMember -Function Escrever-Log
