# Mise à jour automatique : au lancement, récupère la dernière version du robot sur GitHub
# (dépôt public elonzaoui85-commits/Robot-appels, branche main).
# Ne touche jamais aux données de cet ordinateur : config.json (clés, mot de passe), campagne.json, resultats.
# Sans Internet ou en cas de problème, le robot démarre simplement avec la version déjà installée.
# Renvoie $true si une nouvelle version vient d'être installée.

param([string]$Dossier = $PSScriptRoot)

$depot = 'elonzaoui85-commits/Robot-appels'
$garder = 'config.json', 'campagne.json', 'resultats', 'version.txt', '.git', '.gitignore', '.gitattributes'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $entetes = @{ 'User-Agent' = 'robot-appels' }
    $sha = (Invoke-RestMethod "https://api.github.com/repos/$depot/commits/main" -Headers $entetes -TimeoutSec 8).sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { return $false }
    $fichierVersion = Join-Path $Dossier 'version.txt'
    if ((Test-Path $fichierVersion) -and ([IO.File]::ReadAllText($fichierVersion).Trim() -eq $sha)) { return $false }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('robot_maj_' + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'maj.zip'
        Invoke-WebRequest -UseBasicParsing "https://codeload.github.com/$depot/zip/$sha" -Headers $entetes -OutFile $zip -TimeoutSec 60
        Expand-Archive $zip -DestinationPath (Join-Path $tmp 'x')
        $src = (Get-ChildItem (Join-Path $tmp 'x') -Directory | Select-Object -First 1).FullName
        if (-not $src -or -not (Test-Path (Join-Path $src 'application.ps1'))) { return $false }

        # Copie fichier par fichier, en sautant les données de l'ordinateur.
        foreach ($f in Get-ChildItem $src -Recurse -File -Force) {
            $relatif = $f.FullName.Substring($src.Length).TrimStart('\', '/')
            if (($relatif -split '[\\/]')[0] -in $garder) { continue }
            $cible = Join-Path $Dossier $relatif
            New-Item -ItemType Directory -Force (Split-Path $cible) | Out-Null
            Copy-Item $f.FullName $cible -Force
        }
        [IO.File]::WriteAllText($fichierVersion, $sha)
        Write-Host 'Robot mis a jour avec la derniere version.' -ForegroundColor Green
        return $true
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    return $false
}
