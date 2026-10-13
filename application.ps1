# Application "Robot appels" : petit serveur local (http://localhost:8787) + fenêtre Edge en mode application.
# L'interface est dans interface\index.html. Les clés (Twilio, IA) restent sur cet ordinateur, dans config.json.
# Se lance avec le raccourci "Robot appels" du Bureau (Windows) ou "Lancer Robot appels.command" (Mac). Avec -Arriere (démarrage de Windows), il tourne sans ouvrir de fenêtre.
# Le serveur reste actif 24 h/24 : fermer la fenêtre n'arrête pas les campagnes.
# Il vérifie aussi les mises à jour toutes les 30 minutes et redémarre tout seul sur la nouvelle version.

# -SansMaj : pas de vérification au démarrage (la version vient d'être installée).
# -Redemarrage et -Jetons : utilisés seulement quand le robot redémarre après une mise à jour (sessions conservées).
param([switch]$Arriere, [switch]$SansMaj, [switch]$Redemarrage, [string]$Jetons)

$ErrorActionPreference = 'Stop'
$dossier = $PSScriptRoot

# Mise à jour automatique depuis GitHub, puis relance de la nouvelle version dans la même fenêtre.
if (-not $SansMaj -and (Test-Path (Join-Path $dossier 'mise_a_jour.ps1'))) {
    if (& (Join-Path $dossier 'mise_a_jour.ps1') -Dossier $dossier) {
        & (Join-Path $dossier 'application.ps1') -Arriere:$Arriere -SansMaj
        exit
    }
}
. (Join-Path $dossier 'robot_fonctions.ps1')

$port = 8787
$adresse = "http://localhost:$port/"
$modeleIA = 'claude-opus-5-5'

$surMac = [bool]$IsMacOS

function Ouvrir-Fenetre {
    if ($surMac) {
        # Edge ou Chrome en mode application (fenêtre sans barre d'adresse), sinon le navigateur par défaut.
        $nav = @('/Applications/Microsoft Edge.app', '/Applications/Google Chrome.app') | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($nav) {
            $profil = Join-Path $HOME 'Library/Application Support/RobotAppels/navigateur'
            & open -na $nav --args "--app=$adresse" "--user-data-dir=$profil" '--window-size=1480,920' '--no-first-run'
        } else {
            & open $adresse
        }
        return
    }
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($edge) {
        $profil = Join-Path $env:LOCALAPPDATA 'RobotAppels\navigateur'
        Start-Process $edge -ArgumentList "--app=$adresse", "--user-data-dir=`"$profil`"", '--window-size=1480,920',
            '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', '--no-first-run'
    } else {
        Start-Process $adresse
    }
}

# ---------- Mot de passe et sessions ----------

function Hacher-MotDePasse([string]$mdp, [string]$sel) {
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($mdp, [Convert]::FromBase64String($sel), 100000)
    [Convert]::ToBase64String($kdf.GetBytes(32))
}

function Aleatoire([int]$n) {
    $octets = New-Object byte[] $n
    (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($octets)
    [Convert]::ToBase64String($octets)
}

function Definir([string]$nom, $valeur) {
    $script:cfg | Add-Member -NotePropertyName $nom -NotePropertyValue $valeur -Force
}

$script:sessions = @{}
foreach ($j in ([string]$Jetons).Split(',')) { if ($j) { $script:sessions[$j] = $true } }

function Session-Valide($req) {
    $c = $req.Cookies['session']
    return ($c -and $script:sessions.ContainsKey($c.Value))
}

function Nouvelle-Session {
    $jeton = (Aleatoire 32) -replace '[+/=]', ''
    $script:sessions[$jeton] = $true
    return "session=$jeton; Path=/; HttpOnly; SameSite=Strict"
}

# ---------- HTTP ----------

function Repondre($ctx, [int]$code, $obj, [string]$cookie) {
    $json = if ($null -eq $obj) { '{}' } else { $obj | ConvertTo-Json -Depth 8 -Compress }
    $octets = [Text.Encoding]::UTF8.GetBytes($json)
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = 'application/json; charset=utf-8'
    $r.Headers['Cache-Control'] = 'no-store'
    if ($cookie) { $r.Headers.Add('Set-Cookie', $cookie) }
    $r.ContentLength64 = $octets.Length
    $r.OutputStream.Write($octets, 0, $octets.Length)
    $r.OutputStream.Close()
}

function Repondre-Brut($ctx, [string]$json) {
    $octets = [Text.Encoding]::UTF8.GetBytes($json)
    $r = $ctx.Response
    $r.StatusCode = 200
    $r.ContentType = 'application/json; charset=utf-8'
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = $octets.Length
    $r.OutputStream.Write($octets, 0, $octets.Length)
    $r.OutputStream.Close()
}

function Envoyer-Page($ctx) {
    $octets = [IO.File]::ReadAllBytes((Join-Path (Join-Path $dossier 'interface') 'index.html'))
    $r = $ctx.Response
    $r.ContentType = 'text/html; charset=utf-8'
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = $octets.Length
    $r.OutputStream.Write($octets, 0, $octets.Length)
    $r.OutputStream.Close()
}

function Message-Erreur($err) {
    $detail = $err.ErrorDetails.Message
    if (-not $detail) {
        # Avec Invoke-WebRequest, le message d'erreur du serveur est dans le corps de la réponse.
        try { $s = $err.Exception.Response.GetResponseStream(); $s.Position = 0; $detail = (New-Object IO.StreamReader($s)).ReadToEnd() } catch {}
    }
    if ($detail) { try { $j = $detail | ConvertFrom-Json -ErrorAction Stop; if ($j.error.message) { $detail = $j.error.message } elseif ($j.message) { $detail = $j.message } } catch {} }
    if (-not $detail) { $detail = $err.Exception.Message }
    return $detail
}

# ---------- Assistant IA ----------
# L'assistant pilote l'application avec des "outils" exécutés par la fenêtre (interface\index.html).
# Le serveur ne fait que relayer la conversation vers Claude, avec la clé qui reste sur cet ordinateur.

$consignesIA = @'
Tu es l'assistant IA intégré à "Robot appels", une application qui contacte automatiquement une liste de clients : appel avec message vocal (voix de synthèse française), SMS, ou appel puis SMS si le client ne répond pas. L'utilisateur n'est pas technicien : réponds en français simple, chaleureux et bref.

Tu pilotes l'application grâce à tes outils : lire l'état, lister/ajouter/supprimer des clients, remettre des clients à rappeler, modifier le message vocal et le texte SMS, changer le mode (appel, sms, appel_puis_sms), choisir la cadence (un par un, ou tous en même temps), programmer une date et heure de départ, modifier les réglages (horaires ou 24 h/24, voix, vitesse, répétition, répondeur, pause, expéditeur SMS, numéros de test, nombre de contacts par numéro et délai entre deux rappels), lancer ou mettre en pause la campagne, faire un test, ouvrir les résultats. Tu peux aussi chercher sur Internet quand c'est utile.
Le robot tourne 24 h/24 en arrière-plan sur l'ordinateur : une campagne lancée ou programmée continue même si la fenêtre est fermée, tant que l'ordinateur reste allumé et connecté à Internet.
Tu agis à la place de l'utilisateur, de bout en bout :
- Quand il demande quelque chose, enchaîne toi-même toutes les étapes avec tes outils, sans lui demander de cliquer ni de valider chaque étape. Exemple : "appelle dix fois de suite ces numéros et prépare-leur un bon message" = ajouter_clients (remplacer_liste si ce sont de nouveaux numéros), modifier_messages avec un message que tu rédiges, modifier_reglages (nombre_appels 10, delai_rappel_minutes 0), choisir_mode appel, choisir_cadence, programmer "maintenant" (ou l'heure demandée), puis lancer_campagne. Ensuite résume en quelques lignes ce que tu as fait.
- Ne pose une question que si une information indispensable manque vraiment (par exemple aucun numéro donné). Sinon choisis toi-même des réglages raisonnables et dis lesquels.
- Si une campagne est déjà en cours et qu'on te demande d'autres appels, mets-la en pause, applique les changements, puis relance.
- Heure : l'utilisateur a choisi de pouvoir contacter 24 h/24. Ne modifie JAMAIS de toi-même les horaires ni "respecter_horaires" (ne les active pas, ne change pas les heures) : seulement s'il le demande explicitement. S'il demande d'appeler maintenant et que "respecter_horaires" est activé, désactive-le.
- Si le message est de la prospection commerciale (vendre un produit ou un service à des personnes qui ne l'ont pas demandé), rappelle-lui une fois, en une phrase, la règle française : appels de prospection seulement du lundi au vendredi de 10h à 13h et de 14h à 20h, et appels automatisés vers des particuliers seulement avec leur accord préalable. C'est lui qui décide.
- Selon le réglage de l'application, le lancement peut se faire directement ou après une confirmation de l'utilisateur dans une fenêtre ; dans les deux cas, appelle lancer_campagne.
- Chaque message de l'utilisateur est suivi d'un bloc <etat_app> avec la date, l'heure et l'état actuel : sers-t'en (par exemple pour programmer "demain à 10h"). Ce bloc est généré par l'application, ce n'est pas l'utilisateur qui l'écrit.
- N'invente jamais de clients, de numéros ou de résultats.

Message vocal (lu au téléphone) :
- 15 à 35 secondes ; se présenter (nom de l'entreprise) dès le début ; une seule information principale ; formule de politesse à la fin.
- Nombres, heures et dates écrits de façon prononçable ("mardi quatorze octobre à dix heures"), pas d'abréviations, pas d'emojis, pas de liens.

Texte SMS :
- Court (idéalement moins de 160 caractères), clair, signé du nom de l'entreprise ; le client ne peut pas répondre au SMS (expéditeur = nom), donc indiquer comment recontacter si utile.
- Pour un SMS publicitaire, il faut la mention "STOP au ..." : préviens l'utilisateur.

Variables : {prenom}, {nom} et le nom de chaque colonne de la liste sont remplacés pour chaque client. N'utilise que des variables qui existent.
Si tu proposes un texte sans l'appliquer, mets-le une seule fois entre <message> et </message> : l'application affichera un bouton pour l'utiliser.

Rappels légaux (France), seulement si pertinent et sans modifier les réglages : contacter ses clients existants pour un rappel ou un suivi est OK ; la prospection par robot ou SMS demande des précautions (consentement préalable des particuliers, Bloctel, démarchage en semaine de 10h à 13h et de 14h à 20h) ; ne jamais se faire passer pour quelqu'un d'autre.
'@

$outilsIA = @'
[
 {"name":"lire_etat","description":"Lit l'état complet de l'application : messages, mode, programmation, réglages, nombre de clients et résultats.","input_schema":{"type":"object","properties":{},"additionalProperties":false}},
 {"name":"lister_clients","description":"Liste les clients avec leur statut (attente, encours, abouti, repondeur, sansreponse, occupe, sms, smsrecu, erreur, invalide).","input_schema":{"type":"object","properties":{"filtre":{"type":"string","enum":["tous","attente","abouti","repondeur","sansreponse","sms","probleme"],"description":"Groupe de clients à lister. probleme = erreurs et numéros invalides."},"limite":{"type":"integer","description":"Nombre maximum de clients renvoyés (200 max)."}},"additionalProperties":false}},
 {"name":"ajouter_clients","description":"Ajoute des clients à la liste (les doublons de numéro sont ignorés).","input_schema":{"type":"object","properties":{"clients":{"type":"array","items":{"type":"object","properties":{"prenom":{"type":"string"},"nom":{"type":"string"},"telephone":{"type":"string"},"autres":{"type":"object","description":"Colonnes supplémentaires, ex. {\"Date RDV\": \"mardi 14 octobre\"}","additionalProperties":{"type":"string"}}},"required":["telephone"],"additionalProperties":false}},"remplacer_liste":{"type":"boolean","description":"true = vider la liste actuelle et ne garder que ces clients (nouvelle campagne). false par défaut = ajouter à la liste."}},"required":["clients"],"additionalProperties":false}},
 {"name":"supprimer_clients","description":"Retire des clients de la liste à partir de leurs numéros de téléphone.","input_schema":{"type":"object","properties":{"telephones":{"type":"array","items":{"type":"string"}}},"required":["telephones"],"additionalProperties":false}},
 {"name":"remettre_a_appeler","description":"Remet des clients déjà traités dans la file d'attente pour les recontacter.","input_schema":{"type":"object","properties":{"groupe":{"type":"string","enum":["sansreponse","repondeur","probleme","sms","tous_traites"]}},"required":["groupe"],"additionalProperties":false}},
 {"name":"modifier_messages","description":"Remplace le message vocal (lu au téléphone) et/ou le texte SMS.","input_schema":{"type":"object","properties":{"message_vocal":{"type":"string"},"texte_sms":{"type":"string"}},"additionalProperties":false}},
 {"name":"choisir_mode","description":"Choisit comment contacter les clients.","input_schema":{"type":"object","properties":{"mode":{"type":"string","enum":["appel","sms","appel_puis_sms"],"description":"appel_puis_sms = SMS envoyé seulement si l'appel n'aboutit pas."}},"required":["mode"],"additionalProperties":false}},
 {"name":"choisir_cadence","description":"Choisit si les clients sont contactés un par un, ou tous en même temps (environ un nouveau contact par seconde, sans limite de nombre).","input_schema":{"type":"object","properties":{"tous_en_meme_temps":{"type":"boolean"}},"required":["tous_en_meme_temps"],"additionalProperties":false}},
 {"name":"programmer","description":"Programme l'heure de départ de la campagne, ou l'annule pour partir tout de suite.","input_schema":{"type":"object","properties":{"date_heure":{"type":"string","description":"Date et heure locales au format AAAA-MM-JJTHH:MM, ou \"maintenant\" pour annuler la programmation."}},"required":["date_heure"],"additionalProperties":false}},
 {"name":"modifier_reglages","description":"Modifie les réglages. Ne fournir que ce qui change.","input_schema":{"type":"object","properties":{"respecter_horaires":{"type":"boolean","description":"false = appeler à n'importe quelle heure."},"jours":{"type":"array","items":{"type":"string","enum":["lundi","mardi","mercredi","jeudi","vendredi","samedi","dimanche"]}},"debut":{"type":"string","description":"HH:MM"},"fin":{"type":"string","description":"HH:MM"},"voix":{"type":"string","enum":["Polly.Lea-Neural","Polly.Remi-Neural"],"description":"Lea = femme, Remi = homme."},"vitesse":{"type":"integer","description":"Vitesse de la voix en %, de 70 à 130 (100 = normale)."},"repeter":{"type":"boolean"},"repondeur":{"type":"boolean","description":"Détecter les répondeurs et attendre le bip pour y laisser le message. Attention : ajoute 4 à 8 secondes de silence avant que le robot parle quand une personne décroche. false = le robot parle immédiatement."},"nombre_appels":{"type":"integer","description":"Nombre de fois que chaque numéro est contacté (1 à 50)."},"rappels_apres_decroche":{"type":"integer","description":"Nombre de rappels d'une personne qui a déjà décroché : 0, 1 ou 2 au maximum (au-delà ce serait du harcèlement, l'application le refuse)."},"delai_apres_decroche":{"type":"integer","description":"Minutes avant de rappeler une personne qui a décroché (5 minimum)."},"delai_rappel_minutes":{"type":"integer","description":"Minutes d'attente avant de recontacter le même numéro (0 = tout de suite)."},"pause":{"type":"integer","description":"Secondes entre deux contacts (2 à 120)."},"expediteur_sms":{"type":"string","description":"Nom affiché pour les SMS : 11 caractères max, lettres/chiffres/espaces, au moins une lettre."},"numeros_test":{"type":"array","items":{"type":"string"},"description":"Liste complète des numéros qui reçoivent les appels et SMS de test (sans limite). Remplace la liste actuelle."}},"additionalProperties":false}},
 {"name":"lancer_campagne","description":"Lance (ou reprend) la campagne avec le mode et la programmation actuels. L'utilisateur doit confirmer dans une fenêtre.","input_schema":{"type":"object","properties":{},"additionalProperties":false}},
 {"name":"mettre_en_pause","description":"Met la campagne en pause après le contact en cours.","input_schema":{"type":"object","properties":{},"additionalProperties":false}},
 {"name":"faire_un_test","description":"Envoie un appel test ou un SMS test à tous les numéros de test (après confirmation de l'utilisateur).","input_schema":{"type":"object","properties":{"type":{"type":"string","enum":["appel","sms"]}},"required":["type"],"additionalProperties":false}},
 {"name":"ouvrir_resultats","description":"Ouvre le dossier des fichiers de résultats sur l'ordinateur.","input_schema":{"type":"object","properties":{},"additionalProperties":false}},
 {"type":"web_search_20260209","name":"web_search","max_uses":3}
]
'@

function Envoyer-IA([string]$cle, [string]$json) {
    $entetes = @{ 'x-api-key' = $cle; 'anthropic-version' = '2023-06-01'; 'anthropic-beta' = 'server-side-fallback-2026-07-01' }
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://api.anthropic.com/v1/messages' -Headers $entetes `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 300
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        $detail = Message-Erreur $_
        if ($code -eq 401) { throw "Cle refusee par Anthropic : verifie que tu as copie la cle en entier, ou cree une nouvelle cle." }
        if ($detail -match 'credit balance') { throw "Ton compte Anthropic n'a plus de credit : ajoute du credit dans Facturation sur console.anthropic.com." }
        if ($code -eq 0) { throw "Impossible de joindre l'assistant IA : verifie la connexion Internet." }
        throw "Assistant IA indisponible : $detail"
    }
    return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

function Tester-CleIA([string]$cle) {
    [void](Envoyer-IA $cle ('{"model":"' + $modeleIA + '","max_tokens":50,"output_config":{"effort":"low"},"fallbacks":"default","messages":[{"role":"user","content":"Reponds seulement : ok"}]}'))
}

# La conversation (tableau "messages" au format de l'API) est transmise telle quelle, sans être retouchée.
function Requete-IA([string]$messagesJson) {
    '{"model":"' + $modeleIA + '","max_tokens":16000,"output_config":{"effort":"high"},"fallbacks":"default",' +
        '"system":' + (ConvertTo-Json $consignesIA -Compress) + ',"tools":' + $outilsIA + ',"messages":' + $messagesJson + '}'
}

# Assistant gratuit (Google Gemini), utilisé dès qu'une clé Google est enregistrée.
. (Join-Path $dossier 'ia_gemini.ps1')

# ---------- Routes ----------

function Traiter($ctx) {
    $req = $ctx.Request
    $chemin = $req.Url.AbsolutePath
    $methode = $req.HttpMethod
    $script:dernierSignal = Get-Date

    # Seule la fenêtre de l'application (sur cet ordinateur) peut parler au serveur.
    if ($req.Headers['Host'] -notin "localhost:$port", "127.0.0.1:$port") { Repondre $ctx 403 @{ erreur = 'Interdit' }; return }
    $origine = $req.Headers['Origin']
    if ($origine -and $origine -notin "http://localhost:$port", "http://127.0.0.1:$port") { Repondre $ctx 403 @{ erreur = 'Interdit' }; return }

    if ($methode -eq 'GET' -and $chemin -in '/', '/index.html') { Envoyer-Page $ctx; return }

    $corps = $null
    $brut = ''
    if ($methode -eq 'POST') {
        $brut = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
        if ($brut -and $chemin -ne '/api/ia') { $corps = $brut | ConvertFrom-Json }
    }
    $configure = [bool]($script:cfg.acces -and $script:cfg.acces.hash)

    switch ($chemin) {
        '/api/etat' { Repondre $ctx 200 @{ configure = $configure; connecte = (Session-Valide $req) }; return }
        '/api/creer-mdp' {
            if ($configure) { Repondre $ctx 400 @{ erreur = 'Un mot de passe existe deja.' }; return }
            $mdp = [string]$corps.mdp
            if ($mdp.Length -lt 4) { Repondre $ctx 400 @{ erreur = 'Le mot de passe doit faire au moins 4 caracteres.' }; return }
            $sel = Aleatoire 16
            Definir 'acces' ([pscustomobject]@{ sel = $sel; hash = (Hacher-MotDePasse $mdp $sel) })
            Enregistrer-Config $dossier $script:cfg
            Repondre $ctx 200 @{ ok = $true } (Nouvelle-Session)
            return
        }
        '/api/connexion' {
            if ($configure -and (Hacher-MotDePasse ([string]$corps.mdp) $script:cfg.acces.sel) -eq $script:cfg.acces.hash) {
                Repondre $ctx 200 @{ ok = $true } (Nouvelle-Session)
            } else {
                Start-Sleep -Milliseconds 800
                Repondre $ctx 401 @{ erreur = 'Mot de passe incorrect.' }
            }
            return
        }
        '/api/ping' { Repondre $ctx 200 @{ ok = $true }; return }
    }

    if (-not (Session-Valide $req)) { Repondre $ctx 401 @{ erreur = 'Non connecte' }; return }

    switch ($chemin) {
        '/api/deconnexion' {
            $script:sessions.Remove($req.Cookies['session'].Value)
            Repondre $ctx 200 @{ ok = $true } 'session=; Path=/; Max-Age=0'
        }
        '/api/compte' {
            $credit = $null; $devise = ''
            try { $b = Appel-Twilio $script:cfg 'Get' 'Balance.json' $null; $credit = [double]$b.balance; $devise = $b.currency } catch {}
            $c = $script:cfg
            Repondre $ctx 200 @{
                numero = $c.twilio.numero; message = $c.message; voix = $c.voix
                repeter = [bool]$c.repeter_message; repondeur = [bool]$c.laisser_message_repondeur
                pause = $c.pause_entre_appels_secondes; sonnerie = $c.sonnerie_secondes
                horaires = @{ jours = @($c.horaires.jours); debut = $c.horaires.debut; fin = $c.horaires.fin }
                respecterHoraires = ($c.respecter_horaires -ne $false)
                vitesse = $(if ($c.vitesse) { [int]$c.vitesse } else { 100 })
                smsTexte = [string]$c.sms_texte; expediteur = (Expediteur-Sms $c)
                mode = $(if ($c.mode) { [string]$c.mode } else { 'appel' })
                numerosTest = @(Numeros-Test $c)
                nombreAppels = $(if ($c.nombre_appels) { [int]$c.nombre_appels } else { 1 })
                rappelsApresDecroche = [math]::Max(0, [math]::Min(2, [int]$c.rappels_apres_decroche))
                delaiApresDecroche = $(if ($null -ne $c.delai_apres_decroche) { [math]::Max(5, [int]$c.delai_apres_decroche) } else { 5 })
                delaiRappel = [int]$c.delai_rappel_minutes
                iaAutonome = ($c.ia_autonome -ne $false)
                demarrageAuto = ((-not $surMac) -and (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'Robot appels (24h).lnk')))
                mac = $surMac
                credit = $credit; devise = $devise; iaActive = [bool]($c.ia_cle_gemini -or $c.ia_cle)
                iaFournisseur = $(if ($c.ia_cle_gemini) { 'gemini' } elseif ($c.ia_cle) { 'claude' } else { '' })
            }
        }
        '/api/reglages' {
            if ($null -ne $corps.message) { $script:cfg.message = ([string]$corps.message).Trim() }
            if ($corps.voix -in 'Polly.Lea-Neural', 'Polly.Remi-Neural') { $script:cfg.voix = $corps.voix }
            if ($null -ne $corps.repeter) { $script:cfg.repeter_message = [bool]$corps.repeter }
            if ($null -ne $corps.repondeur) { $script:cfg.laisser_message_repondeur = [bool]$corps.repondeur }
            if ($null -ne $corps.pause) { $script:cfg.pause_entre_appels_secondes = [math]::Max(2, [math]::Min(120, [int]$corps.pause)) }
            if ($null -ne $corps.sms_texte) { Definir 'sms_texte' ([string]$corps.sms_texte).Trim() }
            if ($corps.mode -in 'appel', 'sms', 'appel_puis_sms') { Definir 'mode' ([string]$corps.mode) }
            if ($null -ne $corps.respecter_horaires) { Definir 'respecter_horaires' ([bool]$corps.respecter_horaires) }
            if ($null -ne $corps.vitesse) { Definir 'vitesse' ([math]::Max(70, [math]::Min(130, [int]$corps.vitesse))) }
            if ($null -ne $corps.ia_autonome) { Definir 'ia_autonome' ([bool]$corps.ia_autonome) }
            if ($null -ne $corps.nombre_appels) { Definir 'nombre_appels' ([math]::Max(1, [math]::Min(50, [int]$corps.nombre_appels))) }
            if ($null -ne $corps.rappels_apres_decroche) { Definir 'rappels_apres_decroche' ([math]::Max(0, [math]::Min(2, [int]$corps.rappels_apres_decroche))) }
            if ($null -ne $corps.delai_apres_decroche) { Definir 'delai_apres_decroche' ([math]::Max(5, [math]::Min(10080, [int]$corps.delai_apres_decroche))) }
            if ($null -ne $corps.delai_rappel_minutes) { Definir 'delai_rappel_minutes' ([math]::Max(0, [math]::Min(10080, [int]$corps.delai_rappel_minutes))) }
            if ($null -ne $corps.numeros_test) {
                $liste = @(@($corps.numeros_test) | ForEach-Object { Normaliser-Numero ([string]$_) } | Where-Object { $_ } | Select-Object -Unique)
                Definir 'numeros_test' $liste
            }
            if ($null -ne $corps.expediteur) {
                $exp = ([string]$corps.expediteur).Trim()
                if ($exp -notmatch '^(?=.*[A-Za-z])[A-Za-z0-9 ]{1,11}$') { Repondre $ctx 400 @{ erreur = "Nom d'expediteur SMS invalide : 11 caracteres max, lettres et chiffres sans accent, au moins une lettre." }; return }
                Definir 'expediteur_sms' $exp
            }
            if ($corps.horaires) {
                $jours = @($corps.horaires.jours | Where-Object { $joursFr.ContainsKey((Normaliser-Texte $_)) })
                if ($corps.horaires.debut -match '^\d\d:\d\d$' -and $corps.horaires.fin -match '^\d\d:\d\d$' -and $jours.Count -gt 0) {
                    $script:cfg.horaires = [pscustomobject]@{ jours = $jours; debut = $corps.horaires.debut; fin = $corps.horaires.fin }
                }
            }
            Enregistrer-Config $dossier $script:cfg
            Repondre $ctx 200 @{ ok = $true }
        }
        '/api/appel' {
            if ($methode -eq 'POST') {
                $numero = Normaliser-Numero ([string]$corps.numero)
                $message = ([string]$corps.message).Trim()
                if (-not $numero) { Repondre $ctx 400 @{ erreur = 'Numero invalide' }; return }
                if (-not $message -or $message.Length -gt 1500) { Repondre $ctx 400 @{ erreur = 'Message vide ou trop long' }; return }
                try { $a = Lancer-Appel $script:cfg $numero (Construire-Twiml $script:cfg $message) }
                catch { Repondre $ctx 502 @{ erreur = $_.Exception.Message }; return }
                Repondre $ctx 200 @{ sid = $a.sid }
            } else {
                $sid = [string]$req.QueryString['sid']
                if ($sid -notmatch '^CA[0-9a-f]{32}$') { Repondre $ctx 400 @{ erreur = 'Identifiant d''appel invalide' }; return }
                try { $a = Lire-Appel $script:cfg $sid } catch { Repondre $ctx 502 @{ erreur = $_.Exception.Message }; return }
                Repondre $ctx 200 @{ termine = (Appel-Termine $a); statut = $a.status; resultat = (Resultat-Appel $a); reponduPar = $a.answered_by; duree = $a.duration }
            }
        }
        '/api/resultat' {
            $campagne = [string]$corps.campagne
            if ($campagne -notmatch '^[0-9_h-]{8,30}$') { Repondre $ctx 400 @{ erreur = 'Campagne invalide' }; return }
            $d = Join-Path $dossier 'resultats'
            New-Item -ItemType Directory -Force $d | Out-Null
            $client = @{ Prenom = [string]$corps.prenom; Nom = [string]$corps.nom; Brut = [string]$corps.telephone }
            Ajouter-Resultat (Join-Path $d "resultats_$campagne.csv") $client ([string]$corps.resultat) ([string]$corps.reponduPar) $corps.duree ([string]$corps.detail)
            Repondre $ctx 200 @{ ok = $true }
        }
        '/api/test' {
            $message = ([string]$corps.message).Trim()
            if (-not $message) { Repondre $ctx 400 @{ erreur = 'Message vide' }; return }
            $envoyes = @(); $erreurs = @()
            foreach ($n in (Numeros-Test $script:cfg)) {
                try {
                    [void](Appel-Twilio $script:cfg 'Post' 'Calls.json' ([ordered]@{
                        To = $n; From = $script:cfg.twilio.numero; Twiml = (Construire-Twiml $script:cfg $message); Timeout = 25 }))
                    $envoyes += $n
                } catch { $erreurs += "$n : $($_.Exception.Message)" }
            }
            if (-not $envoyes.Count) { Repondre $ctx 502 @{ erreur = ($erreurs -join ' ; ') }; return }
            Repondre $ctx 200 @{ ok = $true; numeros = $envoyes; erreurs = $erreurs }
        }
        '/api/campagne' {
            if ([string]$req.QueryString['v'] -eq [string]$script:campVersion) { Repondre $ctx 200 @{ inchange = $true; version = $script:campVersion }; return }
            Repondre $ctx 200 (Vue-Campagne)
        }
        '/api/campagne/liste' {
            try { Repondre $ctx 200 (Ajouter-Clients $corps.clients ([bool]$corps.remplacer) ([string]$corps.source) $corps.colonnes) }
            catch { Repondre $ctx 400 @{ erreur = $_.Exception.Message } }
        }
        '/api/campagne/supprimer' { Repondre $ctx 200 (Supprimer-Clients $corps.numeros $corps.bruts) }
        '/api/campagne/remettre' { Repondre $ctx 200 (Remettre-Clients ([string]$corps.groupe)) }
        '/api/campagne/lancer' {
            try { Lancer-Campagne $corps; Repondre $ctx 200 @{ ok = $true; etat = $script:camp.etat } }
            catch { Repondre $ctx 400 @{ erreur = $_.Exception.Message } }
        }
        '/api/campagne/pause' { Pause-Campagne; Repondre $ctx 200 @{ ok = $true } }
        '/api/demarrage' {
            if ($surMac) { Repondre $ctx 400 @{ erreur = 'Le demarrage automatique n''existe que sur Windows.' }; return }
            $lien = Join-Path ([Environment]::GetFolderPath('Startup')) 'Robot appels (24h).lnk'
            if ($methode -eq 'POST') {
                if ($corps.actif) {
                    $ws = New-Object -ComObject WScript.Shell
                    $l = $ws.CreateShortcut($lien)
                    $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                    $l.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dossier\application.ps1`" -Arriere"
                    $l.WorkingDirectory = $dossier
                    $l.Save()
                } elseif (Test-Path $lien) { Remove-Item $lien -Confirm:$false }
            }
            Repondre $ctx 200 @{ actif = (Test-Path $lien) }
        }
        '/api/ouvrir-resultats' {
            $d = Join-Path $dossier 'resultats'
            New-Item -ItemType Directory -Force $d | Out-Null
            if ($surMac) { & open $d } else { Invoke-Item $d }
            Repondre $ctx 200 @{ ok = $true }
        }
        '/api/cle-ia' {
            # La clé est collée dans la case de l'application ; à défaut, on la prend dans le presse-papiers.
            $cle = ([string]$corps.cle).Trim()
            if (-not $cle) { try { $cle = ([string](Get-Clipboard -Raw)).Trim() } catch {} }
            # Espaces et caractères invisibles parfois copiés avec la clé.
            $cle = $cle -replace '[\s\u200B-\u200D\uFEFF]', ''
            # Clés Google : ancien format AIza…, nouveau format AQ.… (vérifiées ensuite auprès de Google).
            if ($cle -match '^(AIza|AQ\.?)\S{20,}$') {
                # Clé gratuite Google Gemini
                try { $modele = Tester-CleGemini $cle } catch { Repondre $ctx 400 @{ erreur = $_.Exception.Message }; return }
                Definir 'ia_cle_gemini' $cle
                Definir 'ia_modele_gemini' $modele
                Enregistrer-Config $dossier $script:cfg
                if (-not $corps.cle) { try { Set-Clipboard -Value ' ' } catch {} }
                Repondre $ctx 200 @{ ok = $true; fournisseur = 'gemini'; modele = $modele }
                return
            }
            if ($cle -notmatch '^sk-ant-[A-Za-z0-9_\-]{20,}$') {
                Repondre $ctx 400 @{ erreur = "Ce n'est pas une cle valide : une cle Google gratuite commence par AIza ou AQ. (aistudio.google.com/apikey), une cle Claude par sk-ant-." }
                return
            }
            try { Tester-CleIA $cle } catch { Repondre $ctx 400 @{ erreur = $_.Exception.Message }; return }
            Definir 'ia_cle' $cle
            Enregistrer-Config $dossier $script:cfg
            if (-not $corps.cle) { try { Set-Clipboard -Value ' ' } catch {} }
            Repondre $ctx 200 @{ ok = $true }
        }
        '/api/sms' {
            if ($methode -eq 'POST') {
                $numero = Normaliser-Numero ([string]$corps.numero)
                $texteSms = ([string]$corps.texte).Trim()
                if (-not $numero) { Repondre $ctx 400 @{ erreur = 'Numero invalide' }; return }
                if (-not $texteSms -or $texteSms.Length -gt 1000) { Repondre $ctx 400 @{ erreur = 'Texte SMS vide ou trop long' }; return }
                try { $m = Envoyer-Sms $script:cfg $numero $texteSms } catch { Repondre $ctx 502 @{ erreur = $_.Exception.Message }; return }
                Repondre $ctx 200 @{ sid = $m.sid }
            } else {
                $sid = [string]$req.QueryString['sid']
                if ($sid -notmatch '^(SM|MM)[0-9a-f]{32}$') { Repondre $ctx 400 @{ erreur = 'Identifiant de SMS invalide' }; return }
                try { $m = Lire-Sms $script:cfg $sid } catch { Repondre $ctx 502 @{ erreur = $_.Exception.Message }; return }
                Repondre $ctx 200 @{ termine = (Sms-Termine $m); statut = $m.status; resultat = (Resultat-Sms $m); erreur = [string]$m.error_message }
            }
        }
        '/api/sms-test' {
            $texteSms = ([string]$corps.texte).Trim()
            if (-not $texteSms) { Repondre $ctx 400 @{ erreur = 'Texte SMS vide' }; return }
            $envoyes = @(); $erreurs = @()
            foreach ($n in (Numeros-Test $script:cfg)) {
                try { [void](Envoyer-Sms $script:cfg $n $texteSms); $envoyes += $n } catch { $erreurs += "$n : $($_.Exception.Message)" }
            }
            if (-not $envoyes.Count) { Repondre $ctx 502 @{ erreur = ($erreurs -join ' ; ') }; return }
            Repondre $ctx 200 @{ ok = $true; numeros = $envoyes; erreurs = $erreurs }
        }
        '/api/ia' {
            if (-not ($script:cfg.ia_cle_gemini -or $script:cfg.ia_cle)) { Repondre $ctx 400 @{ erreur = "L'assistant IA n'est pas encore active." }; return }
            if (-not $brut -or -not $brut.TrimStart().StartsWith('[') -or $brut.Length -gt 3000000) { Repondre $ctx 400 @{ erreur = 'Conversation invalide' }; return }
            try {
                if ($script:cfg.ia_cle_gemini) { Repondre-Brut $ctx (Demander-Gemini $brut) }
                else { Repondre-Brut $ctx (Envoyer-IA $script:cfg.ia_cle (Requete-IA $brut)) }
            }
            catch { Repondre $ctx 502 @{ erreur = $_.Exception.Message } }
        }
        '/api/quitter' {
            if ($script:camp.etat -in 'encours', 'programmee' -and -not $corps.forcer) { Repondre $ctx 400 @{ erreur = 'Une campagne est en cours ou programmee : mets-la en pause avant d''arreter le robot.' }; return }
            $script:quitter = $true
            Repondre $ctx 200 @{ ok = $true }
        }
        default { Repondre $ctx 404 @{ erreur = 'Introuvable' } }
    }
}

function Numeros-Test($cfg) {
    $liste = @($cfg.numeros_test | ForEach-Object { Normaliser-Numero ([string]$_) } | Where-Object { $_ })
    if ($liste.Count) { return $liste }
    return @($cfg.twilio.numero)
}

# ---------- Démarrage ----------

$script:cfg = Lire-Config $dossier
# Une clé « XXXX » vient d'une copie nettoyée de config.json : ce n'est pas une vraie clé.
foreach ($k in 'ia_cle', 'ia_cle_gemini') { if ($script:cfg.$k -eq 'XXXX') { $script:cfg.$k = '' } }
$script:quitter = $false
$script:dernierSignal = Get-Date
. (Join-Path $dossier 'moteur_campagne.ps1')
$script:camp = Charger-Campagne

# Après une mise à jour, on réessaie quelques secondes le temps que l'ancienne version libère le port.
for ($essai = 1; ; $essai++) {
    $ecoute = New-Object Net.HttpListener
    $ecoute.Prefixes.Add($adresse)
    try { $ecoute.Start(); break }
    catch {
        if (-not $Redemarrage -or $essai -ge 20) {
            # Le robot tourne déjà (autre fenêtre ou arrière-plan) : on rouvre juste sa fenêtre.
            Write-Host 'Le robot tourne deja (dans une autre fenetre ou en arriere-plan) : sa fenetre est rouverte.' -ForegroundColor Yellow
            Write-Host 'Pour utiliser une nouvelle version, arrete-le d''abord (bouton Arreter, ou ferme son autre fenetre du Terminal).' -ForegroundColor Yellow
            if (-not $Arriere) { Ouvrir-Fenetre }
            exit
        }
        Start-Sleep -Milliseconds 500
    }
}

if (-not $Arriere) { Ouvrir-Fenetre }

# Le serveur tourne en continu : il répond à la fenêtre et fait avancer la campagne environ une fois par seconde.
$tache = $ecoute.GetContextAsync()
$dernierTour = Get-Date
$derniereVerifMaj = Get-Date
$intervalleMajMinutes = 30
$script:redemarrer = $false
while (-not $script:quitter) {
    if ($tache.Wait(1000)) {
        $ctx = $tache.Result
        $tache = $ecoute.GetContextAsync()
        try { Traiter $ctx }
        catch { try { Repondre $ctx 500 @{ erreur = $_.Exception.Message } } catch {} }
    }
    if (((Get-Date) - $dernierTour).TotalMilliseconds -ge 900) {
        $dernierTour = Get-Date
        try { Avancer-Campagne } catch {}
        try { Sauver-Campagne; Gerer-Veille } catch {}
    }
    # Mise à jour sans fermer le robot : seulement quand aucun appel ou SMS n'est en cours.
    if (((Get-Date) - $derniereVerifMaj).TotalMinutes -ge $intervalleMajMinutes -and
        -not @($script:camp.clients | Where-Object { $_.statut -eq 'encours' }).Count) {
        $derniereVerifMaj = Get-Date
        if (& (Join-Path $dossier 'mise_a_jour.ps1') -Dossier $dossier) { $script:redemarrer = $true; break }
    }
}
try { Sauver-Campagne -Forcer } catch {}
try { Liberer-Veille } catch {}
$ecoute.Close()

if ($script:redemarrer) {
    # La campagne est enregistrée dans campagne.json : la nouvelle version la reprend là où elle en était.
    Write-Host 'Nouvelle version installee : le robot redemarre...' -ForegroundColor Green
    & (Join-Path $dossier 'application.ps1') -Arriere -SansMaj -Redemarrage -Jetons ($script:sessions.Keys -join ',')
}
