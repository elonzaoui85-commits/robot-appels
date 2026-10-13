# Première configuration : demande les identifiants Twilio s'ils ne sont pas encore dans config.json, puis les vérifie.
# Lancé automatiquement par "Lancer Robot appels.command" (Mac). Les clés restent sur cet ordinateur.

$ErrorActionPreference = 'Stop'
$dossier = $PSScriptRoot
. (Join-Path $dossier 'robot_fonctions.ps1')

$cfg = Lire-Config $dossier
if ($cfg.twilio.account_sid -match '^AC[0-9a-f]{32}$' -and $cfg.twilio.auth_token -and $cfg.twilio.auth_token -ne 'XXXX' -and (Normaliser-Numero $cfg.twilio.numero)) { exit 0 }

Write-Host ''
Write-Host 'Premiere ouverture : il faut relier le robot a ton compte Twilio.' -ForegroundColor Cyan
Write-Host 'Tu trouves ces informations sur https://console.twilio.com (page d''accueil, cadre "Account Info").'
Write-Host 'Pour coller : cmd + V, puis Entree.'
Write-Host ''

for ($essai = 1; $true; $essai++) {
    while ($true) {
        $sid = (Read-Host 'Account SID (commence par AC)').Trim()
        if ($sid -match '^AC[0-9a-fA-F]{32}$') { break }
        Write-Host '  -> Ce n''est pas un Account SID valide (AC suivi de 32 caracteres). Recommence.' -ForegroundColor Red
    }
    while ($true) {
        $token = (Read-Host 'Auth Token').Trim()
        if ($token -match '^[0-9a-fA-F]{32}$') { break }
        Write-Host '  -> L''Auth Token fait 32 caracteres (icone copier a cote de l''Auth Token dans Twilio). Recommence.' -ForegroundColor Red
    }
    while ($true) {
        $numero = Normaliser-Numero (Read-Host 'Ton numero Twilio (ex. +33 1 23 45 67 89)')
        if ($numero) { break }
        Write-Host '  -> Numero invalide. Recommence.' -ForegroundColor Red
    }

    $cfg.twilio.account_sid = $sid
    $cfg.twilio.auth_token = $token
    $cfg.twilio.numero = $numero

    Write-Host ''
    Write-Host 'Verification aupres de Twilio...'
    try {
        # Lecture du compte lui-même (GET /Accounts/AC....json) : la vérification la plus simple des identifiants.
        $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${sid}:$token"))
        try { $compte = Invoke-RestMethod -Method Get -Uri "https://api.twilio.com/2010-04-01/Accounts/$sid.json" -Headers @{ Authorization = $auth } }
        catch {
            $detail = $_.ErrorDetails.Message
            try { $detail = ($detail | ConvertFrom-Json).message } catch {}
            if (-not $detail) { $detail = $_.Exception.Message }
            throw "Twilio : $detail"
        }
        Write-Host ("  -> OK, compte relie ({0}, statut : {1})." -f $compte.friendly_name, $compte.status) -ForegroundColor Green
        break
    } catch {
        Write-Host "  -> $($_.Exception.Message)" -ForegroundColor Red
        if ($essai -ge 3) {
            Write-Host '     Rien n''a ete enregistre. Envoie une capture de ce message a Claude (en cachant l''Auth Token).' -ForegroundColor Red
            exit 1
        }
        Write-Host '     Recopie l''Account SID et l''Auth Token avec les icones "copier" de Twilio, et recommence :' -ForegroundColor Yellow
        Write-Host ''
    }
}

Enregistrer-Config $dossier $cfg
Write-Host '  -> Identifiants enregistres sur ce Mac (config.json).' -ForegroundColor Green
