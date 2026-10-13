# Robot d'appels en ligne de commande : appelle chaque client d'une liste (CSV ou Excel) et lui lit un message vocal.
# Utilisation :
#   .\robot_appel.ps1 -Fichier clients.csv          -> appelle les clients du fichier
#   .\robot_appel.ps1 -Fichier clients.csv -Test    -> simulation, aucun appel passé
# Pour l'application avec fenêtre, utiliser "Robot appels.ps1".

param(
    [Parameter(Mandatory)][string]$Fichier,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$dossier = $PSScriptRoot
. (Join-Path $dossier 'robot_fonctions.ps1')

$cfg = Lire-Config $dossier

if (-not $Test -and ($cfg.twilio.account_sid -notmatch '^AC[0-9a-f]{32}$' -or -not $cfg.twilio.auth_token -or -not $cfg.twilio.numero)) {
    Write-Host "Configure d'abord tes identifiants Twilio dans config.json (voir LISEZ-MOI.md)." -ForegroundColor Red
    exit 1
}

$clients = @(Lire-Clients $Fichier | ForEach-Object { Infos-Client $_ })
Write-Host ("{0} client(s) trouve(s) dans {1}" -f $clients.Count, (Split-Path $Fichier -Leaf)) -ForegroundColor Cyan
if ($Test) { Write-Host 'MODE TEST : aucun appel ne sera passe.' -ForegroundColor Yellow }

$fichierResultats = Nouveau-FichierResultats $dossier -Test:$Test

$i = 0
foreach ($client in $clients) {
    $i++
    Write-Host ("[{0}/{1}] {2} {3} {4}" -f $i, $clients.Count, $client.Prenom, $client.Nom, $client.Brut) -NoNewline

    if (-not $client.Numero) {
        Ajouter-Resultat $fichierResultats $client 'Numero invalide' '' '' ''
        Write-Host '  -> numero invalide, ignore' -ForegroundColor Red
        continue
    }

    $message = Personnaliser $cfg.message $client.Valeurs
    if ($Test) {
        Ajouter-Resultat $fichierResultats $client 'Simulation' '' '' $message
        Write-Host "  -> $($client.Numero)" -ForegroundColor Green
        Write-Host "     Message : $message" -ForegroundColor DarkGray
        continue
    }

    if (-not (Dans-Horaires $cfg)) {
        Write-Host ''
        Write-Host ("En dehors des horaires d'appel ({0}, {1}-{2}). Le robot attend..." -f ($cfg.horaires.jours -join ', '), $cfg.horaires.debut, $cfg.horaires.fin) -ForegroundColor Yellow
        while (-not (Dans-Horaires $cfg)) { Start-Sleep -Seconds 60 }
    }

    try {
        $appel = Lancer-Appel $cfg $client.Numero (Construire-Twiml $cfg $message)
        $debut = Get-Date
        do {
            Start-Sleep -Seconds 5
            $appel = Lire-Appel $cfg $appel.sid
        } while (-not (Appel-Termine $appel) -and ((Get-Date) - $debut).TotalMinutes -lt 15)

        $resultat = Resultat-Appel $appel
        Ajouter-Resultat $fichierResultats $client $resultat $appel.answered_by $appel.duration $appel.sid
        Write-Host "  -> $resultat" -ForegroundColor Green
    } catch {
        Ajouter-Resultat $fichierResultats $client 'Erreur' '' '' $_.Exception.Message
        Write-Host "  -> ERREUR : $($_.Exception.Message)" -ForegroundColor Red
    }

    if ($i -lt $clients.Count) { Start-Sleep -Seconds $cfg.pause_entre_appels_secondes }
}

Write-Host ''
Write-Host "Termine. Resultats enregistres dans : $fichierResultats" -ForegroundColor Cyan
