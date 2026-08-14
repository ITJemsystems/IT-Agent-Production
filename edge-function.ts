// ==============================================================
// Edge Function: get-modules
// Supabase Edge Function - retorna versao atual e URLs dos modulos
// ==============================================================
// CONFIGURAR antes de fazer deploy:
//   1. Crie o repositorio privado no GitHub da empresa
//   2. Gere um Personal Access Token (PAT) com permissao "repo"
//      GitHub -> Settings -> Developer settings -> Personal access tokens
//   3. Adicione o PAT como secret no Supabase:
//      Supabase Dashboard -> Edge Functions -> Secrets -> Add secret
//      Nome: GITHUB_TOKEN
//      Valor: ghp_xxxxxxxxxxxxxxxxxxxx
//   4. Atualize GITHUB_REPO_BASE abaixo com o repo da empresa
//   5. Atualize CURRENT_VERSION com a versao atual dos modulos
//
// DEPLOY:
//   supabase functions deploy get-modules
// ==============================================================

// ==============================================================
// !! CONFIGURAR: Repositorio GitHub da empresa !!
// Formato: https://api.github.com/repos/EMPRESA/REPOSITORIO/contents/modules
// ==============================================================
const GITHUB_REPO_BASE = "https://api.github.com/repos/EMPRESA/REPOSITORIO/contents/modules"

// ==============================================================
// !! CONFIGURAR: Versao atual dos modulos !!
// Atualize este valor toda vez que subir uma nova versao dos modulos
// para o GitHub. O EXE compara com o version.txt local e baixa
// os modulos novamente se a versao for diferente.
// ==============================================================
const CURRENT_VERSION = "1.0.0"

// Lista de modulos que o EXE deve baixar (ordem importa)
const MODULE_NAMES = [
  "language.psm1",
  "logging.psm1",
  "apps.psm1",
  "network.psm1",
  "system.psm1",
  "ui.psm1",
]

Deno.serve(async (_req) => {
  // Retrieve GitHub PAT from Supabase secrets (never hardcoded)
  const githubToken = Deno.env.get("GITHUB_TOKEN")

  if (!githubToken) {
    return Response.json(
      { error: "GitHub token not configured" },
      { status: 500 }
    )
  }

  // Build signed GitHub API URLs for each module.
  // The token is embedded in the URL so the PowerShell client
  // knows which token to use when calling the GitHub API.
  // The client extracts the token and sends it as an Authorization
  // header, then calls the clean URL without the token parameter.
  const moduleUrls: Record<string, string> = {}
  for (const mod of MODULE_NAMES) {
    moduleUrls[mod] = `${GITHUB_REPO_BASE}/${mod}?ref=main&token=${githubToken}`
  }

  return Response.json({
    version:     CURRENT_VERSION,
    module_urls: moduleUrls,
  })

  // ==============================================================
  // [DASHBOARD] LOG DE EVENTOS - Ativar quando migrar para empresa
  // --------------------------------------------------------------
  // Descomente este bloco para registrar qual maquina/usuario
  // fez o check de atualizacao. Util para rastrear adocao.
  // Requer tabela "update_checks" no Supabase da empresa.
  // ==============================================================
  /*
  const { computername, username } = await _req.json().catch(() => ({}))

  if (computername) {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    )
    await supabase.from("update_checks").insert({
      computername,
      username,
      version_served: CURRENT_VERSION,
      checked_at:     new Date().toISOString(),
    }).then(() => {})
  }
  */
})
