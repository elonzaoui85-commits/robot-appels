# Assistant IA gratuit avec Google Gemini (clé gratuite sur https://aistudio.google.com/apikey).
# L'interface parle le même "format de conversation" qu'avec Claude : ce fichier traduit dans les deux sens,
# pour que la fenêtre et ses outils fonctionnent à l'identique.

$script:urlGemini = 'https://generativelanguage.googleapis.com/v1beta'

function Erreur-Gemini($err) {
    $code = 0
    try { $code = [int]$err.Exception.Response.StatusCode } catch {}
    $detail = Message-Erreur $err
    if ($code -eq 429) { return "Limite gratuite de Google atteinte pour le moment : réessaie dans une minute (ou demain si le quota du jour est épuisé)." }
    if (Est-Sature $err) { return "Les serveurs gratuits de Google sont saturés en ce moment : réessaie dans quelques minutes." }
    if ($detail -match 'API key not valid|API_KEY_INVALID') { return "Clé Google refusée : recopie la clé depuis aistudio.google.com/apikey." }
    if ($code -eq 0) { return "Impossible de joindre l'assistant IA : vérifie la connexion Internet." }
    return "Assistant IA indisponible : $detail"
}

# Erreur passagère (modèle saturé, délai dépassé, connexion coupée) ou modèle retiré : on essaie un autre modèle.
function Est-Sature($err) {
    $code = 0
    try { $code = [int]$err.Exception.Response.StatusCode } catch {}
    $detail = "$(Message-Erreur $err) $($err.Exception.Message)"
    return ($code -in 500, 503, 504) -or ($detail -match 'high demand|overloaded|UNAVAILABLE|timed out|délai|connexion sous-jacente|connection was closed')
}
function Est-Retire($err) { (Message-Erreur $err) -match 'no longer available|not found|is not supported' }

# Modèles Gemini "flash" disponibles pour cette clé, du plus récent au plus ancien (gardés en mémoire).
$script:modelesGemini = @{}
function Modeles-Gemini([string]$cle) {
    if ($script:modelesGemini.ContainsKey($cle)) { return , $script:modelesGemini[$cle] }
    try { $r = Invoke-RestMethod -Uri "$script:urlGemini/models?pageSize=200" -Headers @{ 'x-goog-api-key' = $cle } -TimeoutSec 30 }
    catch { throw (Erreur-Gemini $_) }
    $candidats = @($r.models | Where-Object {
        $_.supportedGenerationMethods -contains 'generateContent' -and $_.name -match '^models/gemini-[\d.]+-flash$'
    })
    if (-not $candidats.Count) {
        $candidats = @($r.models | Where-Object {
            $_.supportedGenerationMethods -contains 'generateContent' -and $_.name -match 'gemini' -and $_.name -match 'flash' -and $_.name -notmatch 'lite|image|tts|live|audio|exp|thinking'
        })
    }
    if (-not $candidats.Count) { throw "Aucun modèle Gemini gratuit n'est disponible pour cette clé." }
    $liste = @($candidats | Sort-Object { $v = [regex]::Match($_.name, 'gemini-([\d.]+)').Groups[1].Value; try { [version]($v + $(if ($v -notmatch '\.') { '.0' })) } catch { [version]'0.0' } } -Descending |
        ForEach-Object { $_.name -replace '^models/', '' })
    $script:modelesGemini[$cle] = $liste
    return , $liste
}

function Choisir-ModeleGemini([string]$cle) {
    try { $r = Invoke-RestMethod -Uri "$script:urlGemini/models?pageSize=200" -Headers @{ 'x-goog-api-key' = $cle } -TimeoutSec 30 }
    catch { throw (Erreur-Gemini $_) }
    $candidats = @($r.models | Where-Object {
        $_.supportedGenerationMethods -contains 'generateContent' -and $_.name -match '^models/gemini-[\d.]+-flash$'
    })
    if (-not $candidats.Count) {
        $candidats = @($r.models | Where-Object {
            $_.supportedGenerationMethods -contains 'generateContent' -and $_.name -match 'gemini' -and $_.name -match 'flash' -and $_.name -notmatch 'lite|image|tts|live|audio|exp|thinking'
        })
    }
    if (-not $candidats.Count) { throw "Aucun modèle Gemini gratuit n'est disponible pour cette clé." }
    $meilleur = $candidats | Sort-Object { $v = [regex]::Match($_.name, 'gemini-([\d.]+)').Groups[1].Value; try { [version]($v + $(if ($v -notmatch '\.') { '.0' })) } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    return $meilleur.name -replace '^models/', ''
}

# Schéma d'outil (format JSON Schema) -> format accepté par Gemini.
function Schema-Gemini($s) {
    $h = [ordered]@{}
    if ($s.type) { $h.type = ([string]$s.type).ToUpper() }
    if ($s.description) { $h.description = [string]$s.description }
    if ($s.enum) { $h.enum = @($s.enum) }
    if ($s.items) { $h.items = Schema-Gemini $s.items }
    if ($s.properties) {
        $props = [ordered]@{}
        foreach ($p in $s.properties.PSObject.Properties) {
            # Gemini n'accepte pas les objets sans propriétés fixes (ex. "autres") : on les ignore.
            if ($p.Value.type -eq 'object' -and -not $p.Value.properties) { continue }
            $props[$p.Name] = Schema-Gemini $p.Value
        }
        $h.properties = $props
        $requis = @(@($s.required) | Where-Object { $_ -and $props.Contains([string]$_) })
        if ($requis.Count) { $h.required = $requis }
    }
    return $h
}

function Outils-Gemini([string]$outilsJson) {
    $declarations = New-Object System.Collections.ArrayList
    foreach ($o in ($outilsJson | ConvertFrom-Json)) {
        if ($o.type) { continue }   # outils propres à Claude (recherche Internet)
        $d = [ordered]@{ name = $o.name; description = $o.description }
        if ($o.input_schema.properties -and @($o.input_schema.properties.PSObject.Properties).Count) { $d.parameters = Schema-Gemini $o.input_schema }
        [void]$declarations.Add($d)
    }
    return , @(@{ functionDeclarations = $declarations })
}

# Conversation au format de l'interface (rôles user/assistant, blocs text/tool_use/tool_result) -> format Gemini.
function Contenus-Gemini($messages) {
    $noms = @{}
    $contenus = New-Object System.Collections.ArrayList
    foreach ($m in @($messages)) {
        $parts = New-Object System.Collections.ArrayList
        $blocs = $(if ($m.content -is [string]) { @([pscustomobject]@{ type = 'text'; text = $m.content }) } else { @($m.content) })
        foreach ($b in $blocs) {
            switch ($b.type) {
                'text' {
                    if ($b._gemini) { [void]$parts.Add($b._gemini) }
                    elseif ($b.text) { [void]$parts.Add(@{ text = [string]$b.text }) }
                }
                'tool_use' {
                    $noms[[string]$b.id] = [string]$b.name
                    if ($b._gemini) { [void]$parts.Add($b._gemini) }
                    else { [void]$parts.Add(@{ functionCall = @{ name = $b.name; args = $(if ($b.input) { $b.input } else { @{} }) } }) }
                }
                'tool_result' {
                    $contenu = [string]$b.content
                    $reponse = @{ resultat = $contenu }
                    if ($b.is_error) { $reponse = @{ erreur = $contenu } }
                    [void]$parts.Add(@{ functionResponse = @{ name = $noms[[string]$b.tool_use_id]; response = $reponse } })
                }
            }
        }
        if ($parts.Count) { [void]$contenus.Add(@{ role = $(if ($m.role -eq 'assistant') { 'model' } else { 'user' }); parts = $parts }) }
    }
    return , $contenus
}

# Réponse Gemini -> réponse au format de l'interface ({ content: [...], stop_reason }).
function Reponse-Depuis-Gemini($rep) {
    $cand = @($rep.candidates)[0]
    $blocs = New-Object System.Collections.ArrayList
    $outil = $false
    foreach ($p in @($cand.content.parts)) {
        if ($null -eq $p) { continue }
        if ($p.functionCall) {
            $outil = $true
            $arguments = $p.functionCall.args
            if ($null -eq $arguments -or -not @($arguments.PSObject.Properties).Count) { $arguments = @{} }
            [void]$blocs.Add(@{ type = 'tool_use'; id = 'g' + [guid]::NewGuid().ToString('N').Substring(0, 12); name = $p.functionCall.name; input = $arguments; _gemini = $p })
        } elseif ($p.text -and -not $p.thought) {
            [void]$blocs.Add(@{ type = 'text'; text = [string]$p.text; _gemini = $p })
        }
    }
    $fin = [string]$cand.finishReason
    $raison = $(if ($outil) { 'tool_use' } elseif ($fin -in 'SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII') { 'refusal' } elseif ($fin -eq 'MAX_TOKENS') { 'max_tokens' } else { 'end_turn' })
    if (-not $blocs.Count -and $raison -eq 'end_turn' -and $rep.promptFeedback.blockReason) { $raison = 'refusal' }
    return @{ content = $blocs; stop_reason = $raison }
}

function Demander-Gemini([string]$messagesJson) {
    $cle = [string]$script:cfg.ia_cle_gemini
    # Le dernier modèle qui a marché d'abord, puis les autres du plus récent au plus ancien.
    $prefere = [string]$script:cfg.ia_modele_gemini
    $liste = Modeles-Gemini $cle
    $modeles = @(@($prefere) + $liste | Where-Object { $_ } | Select-Object -Unique)

    $consignes = $consignesIA + "`n`nNote : la recherche sur Internet n'est pas disponible avec cet assistant gratuit."
    $requete = [ordered]@{
        systemInstruction = @{ parts = @(@{ text = $consignes }) }
        contents          = Contenus-Gemini ($messagesJson | ConvertFrom-Json)
        tools             = Outils-Gemini $outilsIA
        generationConfig  = @{ temperature = 0.4; maxOutputTokens = 8192 }
    }
    $corps = [Text.Encoding]::UTF8.GetBytes(($requete | ConvertTo-Json -Depth 40 -Compress))
    $retires = @{}
    # Deux tours : si tous les modèles sont saturés, on patiente quelques secondes et on réessaie.
    for ($tour = 1; $tour -le 2; $tour++) {
        if ($tour -gt 1) { Start-Sleep -Seconds 5 }
        foreach ($modele in $modeles) {
            if ($retires.ContainsKey($modele)) { continue }
            try {
                $r = Invoke-WebRequest -UseBasicParsing -DisableKeepAlive -Method Post -Uri "$script:urlGemini/models/${modele}:generateContent" -Headers @{ 'x-goog-api-key' = $cle } `
                    -ContentType 'application/json; charset=utf-8' -Body $corps -TimeoutSec 90
            } catch {
                if (Est-Retire $_) { $retires[$modele] = $true; continue }
                if (Est-Sature $_) { continue }
                throw (Erreur-Gemini $_)
            }
            if ($modele -ne $prefere) { Definir 'ia_modele_gemini' $modele; Enregistrer-Config $dossier $script:cfg }
            $rep = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
            return ((Reponse-Depuis-Gemini $rep) | ConvertTo-Json -Depth 40 -Compress)
        }
    }
    throw "Les serveurs gratuits de Google sont saturés en ce moment (tous les modèles Gemini sont occupés). Ce n'est pas un problème du robot : réessaie dans quelques minutes."
}

# Clé valide = Google accepte de lister les modèles (même si les modèles sont saturés à cet instant).
function Tester-CleGemini([string]$cle) {
    $liste = Modeles-Gemini $cle
    return $liste[0]
}
