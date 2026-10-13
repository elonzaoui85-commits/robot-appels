# Fonctions communes au script (robot_appel.ps1) et à l'application (Robot appels.ps1).

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Normaliser-Texte([string]$s) {
    if ($null -eq $s) { return '' }
    (($s.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '').ToLower() -replace '[^a-z0-9]', '')
}

function Normaliser-Numero([string]$n) {
    if (-not $n) { return $null }
    $n = $n -replace '[^\d+]', ''
    if ($n.StartsWith('00')) { $n = '+' + $n.Substring(2) }
    elseif ($n -match '^0\d{9}$') { $n = '+33' + $n.Substring(1) }
    elseif ($n -match '^[1-9]\d{8}$') { $n = '+33' + $n }   # Excel a supprimé le 0 du début
    if ($n -match '^\+\d{8,15}$') { return $n }
    return $null
}

function Echapper-Xml([string]$s) { [Security.SecurityElement]::Escape($s) }

function Lire-Config([string]$dossier) {
    Get-Content (Join-Path $dossier 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Enregistrer-Config([string]$dossier, $cfg) {
    [IO.File]::WriteAllText((Join-Path $dossier 'config.json'), ($cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function Lire-Clients([string]$chemin) {
    if ($chemin -match '\.xlsx?$') {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("clients_" + [guid]::NewGuid() + ".csv")
        try {
            $excel = New-Object -ComObject Excel.Application
            $excel.DisplayAlerts = $false
            $wb = $excel.Workbooks.Open((Resolve-Path $chemin).Path)
            $wb.SaveAs($tmp, 62)   # 62 = CSV UTF-8
            $wb.Close($false)
            $excel.Quit()
        } catch {
            throw "Impossible d'ouvrir le fichier Excel (Excel est-il installe ?). Dans Excel : Fichier > Enregistrer sous > CSV, puis choisis le fichier .csv."
        }
        $chemin = $tmp
    }

    $octets = [IO.File]::ReadAllBytes((Resolve-Path $chemin).Path)
    try { $texte = (New-Object Text.UTF8Encoding($false, $true)).GetString($octets) }
    catch { $texte = [Text.Encoding]::GetEncoding(1252).GetString($octets) }   # CSV Excel "classique" (ANSI)
    $texte = $texte.TrimStart([char]0xFEFF)

    $lignes = $texte -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    $entete = $lignes[0]
    $sep = if ($entete.Split(';').Count -ge $entete.Split(',').Count) { ';' } else { ',' }
    return $lignes | ConvertFrom-Csv -Delimiter $sep
}

function Premiere-Valeur($valeurs, [string[]]$noms) {
    foreach ($n in $noms) { if ($valeurs.ContainsKey($n) -and $valeurs[$n].Trim()) { return $valeurs[$n].Trim() } }
    return ''
}

# Transforme une ligne du fichier en client : prénom, nom, numéro brut et normalisé, toutes les colonnes.
function Infos-Client($ligne) {
    $valeurs = @{}
    foreach ($p in $ligne.PSObject.Properties) { $valeurs[(Normaliser-Texte $p.Name)] = [string]$p.Value }
    $prenom = Premiere-Valeur $valeurs 'prenom', 'firstname'
    $nom = Premiere-Valeur $valeurs 'nom', 'lastname', 'name', 'client'
    $valeurs['prenom'] = $prenom
    $valeurs['nom'] = $nom
    $brut = Premiere-Valeur $valeurs 'telephone', 'tel', 'numero', 'phone', 'mobile', 'portable', 'numerodetelephone'
    return @{ Prenom = $prenom; Nom = $nom; Brut = $brut; Numero = (Normaliser-Numero $brut); Valeurs = $valeurs }
}

function Personnaliser([string]$modele, $valeurs) {
    $texte = $modele
    foreach ($m in [regex]::Matches($modele, '\{([^}]+)\}')) {
        $cle = Normaliser-Texte $m.Groups[1].Value
        $texte = $texte.Replace($m.Value, $(if ($valeurs.ContainsKey($cle)) { $valeurs[$cle] } else { '' }))
    }
    return ($texte -replace '\s+', ' ').Trim()
}

function Construire-Twiml($cfg, [string]$message) {
    $texte = Echapper-Xml $message
    if ($cfg.vitesse -and [int]$cfg.vitesse -ne 100) { $texte = "<prosody rate=`"$([int]$cfg.vitesse)%`">$texte</prosody>" }
    $voix = "<Say language=`"fr-FR`" voice=`"$($cfg.voix)`">$texte</Say>"
    if ($cfg.audio_url) { $voix = "<Play>$(Echapper-Xml $cfg.audio_url)</Play>" }
    # Pas de pause au début : le robot parle dès que la personne décroche.
    $twiml = "<Response>$voix"
    if ($cfg.repeter_message) { $twiml += "<Pause length=`"1`"/>$voix" }
    return $twiml + '</Response>'
}

$joursFr = @{ dimanche = 0; lundi = 1; mardi = 2; mercredi = 3; jeudi = 4; vendredi = 5; samedi = 6 }

function Dans-Horaires($cfg) {
    $maintenant = Get-Date
    $jours = @($cfg.horaires.jours | ForEach-Object { $joursFr[(Normaliser-Texte $_)] })
    if ($jours -notcontains [int]$maintenant.DayOfWeek) { return $false }
    $heure = $maintenant.ToString('HH:mm')
    return ($heure -ge $cfg.horaires.debut -and $heure -lt $cfg.horaires.fin)
}

function Appel-Twilio($cfg, [string]$methode, [string]$url, $corps) {
    $sid = $cfg.twilio.account_sid
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${sid}:$($cfg.twilio.auth_token)"))
    $params = @{ Method = $methode; Uri = "https://api.twilio.com/2010-04-01/Accounts/$sid/$url"; Headers = @{ Authorization = $auth } }
    if ($corps) {
        $params.Body = ($corps.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))" }) -join '&'
        $params.ContentType = 'application/x-www-form-urlencoded'
    }
    try { return Invoke-RestMethod @params }
    catch {
        $detail = $_.ErrorDetails.Message
        try { $detail = ($detail | ConvertFrom-Json).message } catch {}
        if (-not $detail) { $detail = $_.Exception.Message }
        throw "Twilio : $detail"
    }
}

function Lancer-Appel($cfg, [string]$numero, [string]$twiml) {
    $corps = [ordered]@{ To = $numero; From = $cfg.twilio.numero; Twiml = $twiml; Timeout = $cfg.sonnerie_secondes }
    # La détection de répondeur fait attendre 4 à 8 s avant que le robot parle : seulement si l'option est activée.
    if ($cfg.laisser_message_repondeur) { $corps.MachineDetection = 'DetectMessageEnd' }
    return Appel-Twilio $cfg 'Post' 'Calls.json' $corps
}

function Lire-Appel($cfg, [string]$sidAppel) { Appel-Twilio $cfg 'Get' "Calls/$sidAppel.json" $null }

function Appel-Termine($appel) { $appel.status -notin 'queued', 'initiated', 'ringing', 'in-progress' }

# ---------- SMS ----------
# L'expéditeur est un nom (11 caractères max, ex. "CABINET") : le client ne peut pas répondre au SMS.
function Expediteur-Sms($cfg) { if ($cfg.expediteur_sms) { [string]$cfg.expediteur_sms } else { 'INFO' } }

function Envoyer-Sms($cfg, [string]$numero, [string]$texte) {
    Appel-Twilio $cfg 'Post' 'Messages.json' ([ordered]@{ To = $numero; From = (Expediteur-Sms $cfg); Body = $texte })
}

function Lire-Sms($cfg, [string]$sidSms) { Appel-Twilio $cfg 'Get' "Messages/$sidSms.json" $null }

function Sms-Termine($sms) { $sms.status -in 'delivered', 'read', 'undelivered', 'failed', 'canceled' }

function Resultat-Sms($sms) {
    switch ($sms.status) {
        'delivered' { 'SMS recu' }
        'read' { 'SMS recu' }
        'undelivered' { 'SMS non distribue' }
        'failed' { 'Echec SMS' }
        'canceled' { 'Echec SMS' }
        default { 'SMS envoye' }
    }
}

$statutsFr = @{
    'completed' = 'Appel abouti'; 'busy' = 'Occupe'; 'no-answer' = 'Pas de reponse'
    'failed' = 'Echec'; 'canceled' = 'Annule'
}

function Resultat-Appel($appel) {
    if ($appel.answered_by -like 'machine*') { return 'Message laisse sur repondeur' }
    if ($statutsFr.ContainsKey($appel.status)) { return $statutsFr[$appel.status] }
    return $appel.status
}

function Nouveau-FichierResultats([string]$dossier, [switch]$Test) {
    $d = Join-Path $dossier 'resultats'
    New-Item -ItemType Directory -Force $d | Out-Null
    Join-Path $d ("resultats_{0}{1}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HH\hmm'), $(if ($Test) { '_TEST' } else { '' }))
}

# Avec BOM pour qu'Excel (Windows et Mac) affiche bien les accents ; PowerShell 7 (Mac) l'appelle utf8BOM.
$encodageCsv = if ($PSVersionTable.PSEdition -eq 'Core') { 'utf8BOM' } else { 'UTF8' }

function Ajouter-Resultat([string]$fichier, $client, [string]$resultat, [string]$reponduPar, $duree, [string]$detail) {
    [pscustomobject][ordered]@{
        'Date' = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; 'Prenom' = $client.Prenom; 'Nom' = $client.Nom; 'Telephone' = $client.Brut
        'Resultat' = $resultat; 'Repondu par' = $reponduPar; 'Duree (s)' = $duree; 'Detail' = $detail
    } | Export-Csv $fichier -Append -Delimiter ';' -Encoding $encodageCsv -NoTypeInformation
}
