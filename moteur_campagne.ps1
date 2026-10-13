# Moteur de campagne : tourne dans le serveur de l'application, même fenêtre fermée (24 h/24).
# La campagne (liste, statuts, programmation) est enregistrée dans campagne.json : elle reprend après un redémarrage.

$script:fichierCampagne = Join-Path $dossier 'campagne.json'
$script:campVersion = 1
$script:campSale = $false
$script:campSauvee = Get-Date

function En-Table($objet) {
    $h = @{}
    if ($null -eq $objet) { return $h }
    if ($objet -is [hashtable]) { foreach ($k in $objet.Keys) { $h[$k] = $objet[$k] }; return $h }
    foreach ($p in $objet.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Nouvelle-Campagne {
    @{ id = ''; etat = 'vide'; mode = 'appel'; simultane = $false; programmation = $null; attente = $null
       message = ''; sms = ''; source = ''; colonnes = @(); clients = (New-Object System.Collections.ArrayList); prochain = $null }
}

function Charger-Campagne {
    $c = Nouvelle-Campagne
    if (Test-Path $script:fichierCampagne) {
        try {
            $j = Get-Content $script:fichierCampagne -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($p.Name -ne 'clients') { $c[$p.Name] = $p.Value } }
            $c.colonnes = @($j.colonnes)
            foreach ($cl in @($j.clients)) {
                if ($null -eq $cl) { continue }
                $h = En-Table $cl
                $h.valeurs = En-Table $cl.valeurs
                [void]$c.clients.Add($h)
            }
        } catch {}
    }
    return $c
}

function Marquer-Campagne { $script:campVersion++; $script:campSale = $true }

function Sauver-Campagne([switch]$Forcer) {
    if (-not $script:campSale) { return }
    if (-not $Forcer -and ((Get-Date) - $script:campSauvee).TotalSeconds -lt 2) { return }
    $json = $script:camp | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($script:fichierCampagne, $json, (New-Object Text.UTF8Encoding($false)))
    $script:campSale = $false
    $script:campSauvee = Get-Date
}

function Categorie-Appel([string]$resultat) {
    switch -Wildcard ($resultat) {
        'Appel abouti' { 'abouti' }
        'Message laisse*' { 'repondeur' }
        'Pas de reponse' { 'sansreponse' }
        'Occupe' { 'occupe' }
        default { 'erreur' }
    }
}

# ---------- Liste ----------

function Ajouter-Clients($clients, [bool]$remplacer, [string]$source, $colonnes) {
    $c = $script:camp
    if ($remplacer) {
        if ($c.etat -in 'encours', 'programmee') { throw 'Mets la campagne en pause avant de remplacer la liste.' }
        $c.clients = New-Object System.Collections.ArrayList
        $c.colonnes = @()
        $c.id = ''
        $c.etat = 'vide'
    }
    $deja = @{}
    foreach ($cl in $c.clients) { if ($cl.numero) { $deja[$cl.numero] = $true } }
    $ajoutes = 0; $doublons = 0; $invalides = 0
    foreach ($x in @($clients)) {
        if ($null -eq $x) { continue }
        $brut = [string]$x.brut
        $numero = Normaliser-Numero $brut
        if ($numero -and $deja.ContainsKey($numero)) { $doublons++; continue }
        if ($numero) { $deja[$numero] = $true } else { $invalides++ }
        $valeurs = En-Table $x.valeurs
        [void]$c.clients.Add(@{
            prenom = [string]$x.prenom; nom = [string]$x.nom; brut = $brut; numero = $numero; valeurs = $valeurs
            statut = $(if ($numero) { 'attente' } else { 'invalide' }); sms = $null; detail = ''; resultat = ''; tentatives = 0; apres = $null
        })
        $ajoutes++
    }
    foreach ($col in @($colonnes)) {
        if ($col -and -not (@($c.colonnes) | Where-Object { (Normaliser-Texte $_) -eq (Normaliser-Texte $col) })) { $c.colonnes = @($c.colonnes) + [string]$col }
    }
    if ($source) { $c.source = $(if ($remplacer -or -not $c.source) { $source } elseif ($c.source -like "*$source*") { $c.source } else { "$($c.source) + $source" }) }
    if ($c.etat -in 'vide', 'terminee' -and @($c.clients | Where-Object { $_.statut -eq 'attente' }).Count) { $c.etat = 'pret' }
    Marquer-Campagne
    return @{ ajoutes = $ajoutes - $invalides; invalides = $invalides; doublons = $doublons; total = $c.clients.Count }
}

# Retire des clients par numéro ; $bruts sert aux lignes sans numéro valide (retirées par leur texte d'origine).
function Supprimer-Clients($numeros, $bruts) {
    $cibles = @{}
    foreach ($n in @($numeros)) { $x = Normaliser-Numero ([string]$n); if ($x) { $cibles[$x] = $true } }
    $ciblesBrutes = @{}
    foreach ($b in @($bruts)) { if ($null -ne $b) { $ciblesBrutes[[string]$b] = $true } }
    $avant = $script:camp.clients.Count
    $garder = New-Object System.Collections.ArrayList
    foreach ($cl in $script:camp.clients) {
        $vise = ($cl.numero -and $cibles.ContainsKey($cl.numero)) -or (-not $cl.numero -and $ciblesBrutes.ContainsKey([string]$cl.brut))
        if (-not ($vise -and $cl.statut -ne 'encours')) { [void]$garder.Add($cl) }
    }
    $script:camp.clients = $garder
    Marquer-Campagne
    return @{ supprimes = $avant - $garder.Count; restants = $garder.Count }
}

function Groupe-Statut([string]$s) {
    if ($s -in 'erreur', 'invalide') { return 'probleme' }
    if ($s -eq 'occupe') { return 'sansreponse' }
    if ($s -eq 'smsrecu') { return 'sms' }
    return $s
}

function Remettre-Clients([string]$groupe) {
    $n = 0
    foreach ($cl in $script:camp.clients) {
        if (-not $cl.numero -or $cl.statut -in 'attente', 'encours') { continue }
        if ($groupe -eq 'tous_traites' -or (Groupe-Statut $cl.statut) -eq $groupe) {
            $cl.statut = 'attente'; $cl.sms = $null; $cl.detail = ''; $cl.resultat = ''; $cl.tentatives = 0; $cl.decroches = 0; $cl.apres = $null; $cl.dernierStatut = $null; $n++
        }
    }
    if ($n -and $script:camp.etat -in 'vide', 'terminee') { $script:camp.etat = 'pret' }
    Marquer-Campagne
    return @{ remis_a_contacter = $n }
}

# ---------- Lancement ----------

function Lancer-Campagne($corps) {
    $c = $script:camp
    if (-not @($c.clients | Where-Object { $_.statut -eq 'attente' }).Count) { throw 'Aucun client a contacter dans la liste.' }
    $mode = [string]$corps.mode
    if ($mode -notin 'appel', 'sms', 'appel_puis_sms') { throw 'Mode invalide.' }
    $message = ([string]$corps.message).Trim()
    $sms = ([string]$corps.sms).Trim()
    if ($mode -ne 'sms' -and -not $message) { throw 'Le message vocal est vide.' }
    if ($mode -ne 'appel' -and -not $sms) { throw 'Le texte SMS est vide.' }
    $prog = $null
    if ($corps.programmation) {
        $prog = [datetime]::Parse([string]$corps.programmation, [Globalization.CultureInfo]::InvariantCulture)
        if ($prog -lt (Get-Date).AddMinutes(-1)) { throw "L'heure programmee est deja passee." }
    }
    if (-not $c.id) { $c.id = (Get-Date).ToString('yyyy-MM-dd_HH\hmm') }
    $c.mode = $mode; $c.simultane = [bool]$corps.simultane; $c.message = $message; $c.sms = $sms
    $c.programmation = $(if ($prog) { $prog.ToString('s') } else { $null })
    $c.etat = $(if ($prog) { 'programmee' } else { 'encours' })
    $c.prochain = $null
    Marquer-Campagne
    Sauver-Campagne -Forcer
}

function Pause-Campagne {
    if ($script:camp.etat -in 'encours', 'programmee') { $script:camp.etat = 'pause'; $script:camp.programmation = $null; Marquer-Campagne; Sauver-Campagne -Forcer }
}

# ---------- Déroulement (appelé environ une fois par seconde) ----------

function Reglage-Rappels {
    $max = $(if ($script:cfg.nombre_appels) { [int]$script:cfg.nombre_appels } else { 1 })
    # Rappels d'une personne qui a déjà décroché : 2 au maximum, espacés d'au moins 5 min, pour ne pas harceler.
    $apres = [math]::Max(0, [math]::Min(2, [int]$script:cfg.rappels_apres_decroche))
    $delaiApres = $(if ($null -ne $script:cfg.delai_apres_decroche) { [math]::Max(5, [int]$script:cfg.delai_apres_decroche) } else { 5 })
    @{ max = [math]::Max(1, $max); delai = [int]$script:cfg.delai_rappel_minutes; apresDecroche = $apres; delaiApresDecroche = $delaiApres }
}

function Terminer-Contact($cl, [string]$statut, [string]$resultat) {
    $r = Reglage-Rappels
    $cl.tentatives = [int]$cl.tentatives + 1
    $cl.resultat = $resultat
    $cl.phase = $null
    $d = Join-Path $dossier 'resultats'
    New-Item -ItemType Directory -Force $d | Out-Null
    $client = @{ Prenom = $cl.prenom; Nom = $cl.nom; Brut = $cl.brut }
    $libelle = $(if ($r.max -gt 1) { "$resultat (contact $($cl.tentatives)/$($r.max))" } else { $resultat })
    try { Ajouter-Resultat (Join-Path $d "resultats_$($script:camp.id).csv") $client $libelle ([string]$cl.reponduPar) $cl.duree ([string]$cl.detail) } catch {}

    # Encore des contacts prévus pour ce numéro ?
    # - pas joint : on réessaie jusqu'au nombre d'appels prévu ;
    # - joint (a décroché) : seulement les quelques rappels autorisés après un décroché.
    $joint = $statut -in 'abouti', 'repondeur', 'sms', 'smsrecu'
    if ($joint) { $cl.decroches = [int]$cl.decroches + 1 }
    $encore = $statut -ne 'invalide' -and $cl.tentatives -lt $r.max -and (-not $joint -or $cl.decroches -le $r.apresDecroche)
    if ($encore) {
        $cl.dernierStatut = $statut
        $cl.statut = 'attente'
        $cl.apres = (Get-Date).AddMinutes($(if ($joint) { $r.delaiApresDecroche } else { $r.delai })).ToString('o')
    } else {
        $cl.statut = $statut
        $cl.apres = $null
    }
    $script:camp.prochain = (Get-Date).AddSeconds([int]$script:cfg.pause_entre_appels_secondes).ToString('o')
    Marquer-Campagne
}

function Disponible($cl, $maintenant) {
    $cl.statut -eq 'attente' -and $cl.numero -and (-not $cl.apres -or $maintenant -ge [datetime]$cl.apres)
}

function Demarrer-Contact($cl) {
    $c = $script:camp
    $cl.statut = 'encours'; $cl.sms = $null; $cl.detail = ''; $cl.erreursSuivi = 0
    $cl.debut = (Get-Date).ToString('o'); $cl.dernierSuivi = $cl.debut
    Marquer-Campagne
    try {
        if ($c.mode -eq 'sms') {
            $m = Envoyer-Sms $script:cfg $cl.numero (Personnaliser $c.sms $cl.valeurs)
            $cl.phase = 'sms'; $cl.sid = $m.sid
        } else {
            $a = Lancer-Appel $script:cfg $cl.numero (Construire-Twiml $script:cfg (Personnaliser $c.message $cl.valeurs))
            $cl.phase = 'appel'; $cl.sid = $a.sid
        }
        $cl.detail = $cl.sid
    } catch {
        $cl.detail = $_.Exception.Message
        Terminer-Contact $cl 'erreur' 'Erreur'
    }
}

function Suivre-Contact($cl) {
    $c = $script:camp
    $maintenant = Get-Date
    if ($cl.phase -eq 'appel') {
        $a = Lire-Appel $script:cfg $cl.sid
        if (-not (Appel-Termine $a) -and ($maintenant - [datetime]$cl.debut).TotalMinutes -lt 15) { return }
        $res = Resultat-Appel $a
        $cat = Categorie-Appel $res
        $cl.reponduPar = [string]$a.answered_by; $cl.duree = $a.duration
        if ($c.mode -eq 'appel_puis_sms' -and $cat -in 'sansreponse', 'occupe', 'erreur') {
            $cl.statutAppel = $cat; $cl.resultatAppel = $res
            try {
                $m = Envoyer-Sms $script:cfg $cl.numero (Personnaliser $c.sms $cl.valeurs)
                $cl.phase = 'relance'; $cl.sid = $m.sid; $cl.debut = $maintenant.ToString('o')
                $cl.detail = "$($cl.detail) | $($m.sid)"
                Marquer-Campagne
            } catch {
                $cl.sms = 'echec'; $cl.detail = "$($cl.detail) | $($_.Exception.Message)"
                Terminer-Contact $cl $cat "$res + Echec SMS"
            }
            return
        }
        Terminer-Contact $cl $cat $res
        return
    }
    # SMS seul ou SMS de relance après un appel sans réponse
    $m = Lire-Sms $script:cfg $cl.sid
    if (-not (Sms-Termine $m) -and ($maintenant - [datetime]$cl.debut).TotalSeconds -lt 45) { return }
    $r = Resultat-Sms $m
    if ($m.error_message) { $cl.detail = "$($cl.detail) $($m.error_message)" }
    $ok = $r -in 'SMS recu', 'SMS envoye'
    if ($cl.phase -eq 'relance') {
        $cl.sms = $(if ($ok) { 'envoye' } else { 'echec' })
        Terminer-Contact $cl $cl.statutAppel "$($cl.resultatAppel) + $r"
    } else {
        Terminer-Contact $cl $(if ($r -eq 'SMS recu') { 'smsrecu' } elseif ($ok) { 'sms' } else { 'erreur' }) $r
    }
}

function Avancer-Campagne {
    $c = $script:camp
    if ($c.etat -notin 'encours', 'programmee', 'pause') { return }
    $maintenant = Get-Date

    if ($c.etat -eq 'programmee' -and $c.programmation -and $maintenant -ge [datetime]$c.programmation) {
        $c.etat = 'encours'; $c.programmation = $null; Marquer-Campagne
    }

    # Suivi des contacts en cours (quelques lectures par tour pour garder l'application réactive).
    $lectures = 0
    foreach ($cl in @($c.clients | Where-Object { $_.statut -eq 'encours' })) {
        if ($lectures -ge 6) { break }
        if (-not $cl.phase) { $cl.statut = 'attente'; continue }   # contact interrompu (redémarrage) : on le refera
        if (($maintenant - [datetime]$cl.dernierSuivi).TotalSeconds -lt 4) { continue }
        $lectures++
        $cl.dernierSuivi = $maintenant.ToString('o')
        try { Suivre-Contact $cl }
        catch {
            $cl.erreursSuivi = [int]$cl.erreursSuivi + 1
            if ($cl.erreursSuivi -gt 20) { $cl.detail = $_.Exception.Message; Terminer-Contact $cl 'erreur' 'Erreur' }
        }
    }

    if ($c.etat -ne 'encours') { return }

    $attente = $null
    if ($script:cfg.respecter_horaires -ne $false -and -not (Dans-Horaires $script:cfg)) { $attente = 'horaires' }
    if ($c.attente -ne $attente) { $c.attente = $attente; Marquer-Campagne }
    if ($attente) { return }

    $actifs = @($c.clients | Where-Object { $_.statut -eq 'encours' }).Count
    $suivant = $null
    $enAttente = $false
    foreach ($cl in $c.clients) {
        if ($cl.statut -eq 'attente' -and $cl.numero) { $enAttente = $true; if (Disponible $cl $maintenant) { $suivant = $cl; break } }
    }
    if (-not $suivant) {
        # Plus personne à contacter (les rappels prévus plus tard gardent la campagne ouverte).
        if ($actifs -eq 0 -and -not $enAttente) { $c.etat = 'terminee'; $c.fin = $maintenant.ToString('o'); Marquer-Campagne; Sauver-Campagne -Forcer }
        return
    }
    if (-not $c.simultane) {
        # Un par un : on attend la fin du contact en cours et la pause choisie.
        # (Tous en même temps : aucune limite de nombre, un nouveau contact par tour, soit le rythme autorisé par Twilio.)
        if ($actifs -gt 0) { return }
        if ($c.prochain -and $maintenant -lt [datetime]$c.prochain) { return }
    }
    Demarrer-Contact $suivant
}

# ---------- Empêcher la mise en veille pendant une campagne ----------

if (-not $IsMacOS -and -not ('RobotAppels.Veille' -as [type])) {   # déjà chargé si le robot a redémarré après une mise à jour
    Add-Type -Namespace RobotAppels -Name Veille -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
}
$script:eveilActif = $false
$script:cafeine = $null

function Gerer-Veille {
    $besoin = $script:camp.etat -in 'encours', 'programmee'
    if ($besoin -eq $script:eveilActif) { return }
    if ($IsMacOS) {
        # Mac : "caffeinate" garde l'ordinateur éveillé tant que la campagne tourne (il s'arrête tout seul avec le robot).
        if ($besoin) { $script:cafeine = Start-Process caffeinate -ArgumentList '-i', '-w', $PID -PassThru }
        else { Liberer-Veille }
    } else {
        # ES_CONTINUOUS (0x80000000) + ES_SYSTEM_REQUIRED (0x1) : l'ordinateur ne s'endort pas tant que la campagne tourne.
        [void][RobotAppels.Veille]::SetThreadExecutionState($(if ($besoin) { [uint32]2147483649 } else { [uint32]2147483648 }))
    }
    $script:eveilActif = $besoin
}

function Liberer-Veille {
    if ($IsMacOS) {
        if ($script:cafeine -and -not $script:cafeine.HasExited) { $script:cafeine.Kill() }
        $script:cafeine = $null
    } else {
        [void][RobotAppels.Veille]::SetThreadExecutionState([uint32]2147483648)
    }
}

# ---------- Vue pour l'interface ----------

function Vue-Campagne {
    $c = $script:camp
    $clients = New-Object System.Collections.ArrayList
    foreach ($cl in $c.clients) {
        [void]$clients.Add(@{ prenom = $cl.prenom; nom = $cl.nom; brut = $cl.brut; numero = $cl.numero; statut = $cl.statut; sms = $cl.sms; detail = [string]$cl.detail; valeurs = $cl.valeurs
            tentatives = [int]$cl.tentatives; dernierStatut = $cl.dernierStatut; apres = $cl.apres })
    }
    @{
        contactsParNumero = (Reglage-Rappels).max
        version = $script:campVersion; id = $c.id; etat = $c.etat; mode = $c.mode; simultane = [bool]$c.simultane
        programmation = $c.programmation; attente = $c.attente; source = $c.source; colonnes = @($c.colonnes)
        message = $c.message; sms = $c.sms; clients = $clients
    }
}
