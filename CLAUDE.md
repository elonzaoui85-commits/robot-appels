# Robot appels

Robot d'appels vocaux et de SMS via Twilio (PowerShell + interface HTML locale), utilisé sur un Mac et sur un PC Windows.

## Règles importantes

- **Ce dépôt est public et sert de mise à jour automatique.** Tout ce qui est poussé sur `main` est installé
  automatiquement sur les deux ordinateurs (`mise_a_jour.ps1`) : au lancement du robot, puis toutes les
  30 minutes pendant qu'il tourne (redémarrage automatique quand aucun appel/SMS n'est en cours).
  Ne pousser sur `main` que du code testé et fonctionnel.
- **Jamais de secret ni de donnée client ici** : pas de clé Twilio, de clé IA, de mot de passe, de numéro
  de téléphone réel, de liste de clients ni de résultats. `config.json` n'est qu'un modèle : la mise à jour
  ne remplace jamais le `config.json`, `campagne.json` ni le dossier `resultats` des ordinateurs.
- **Garder la compatibilité Windows (PowerShell 5.1) et Mac (PowerShell 7)** : utiliser `$IsMacOS` pour les
  différences, `Join-Path` imbriqués (pas de chemins avec `\`), et des fichiers `.ps1` en UTF-8 avec BOM.
- Les modifications se font ici (dans ce dépôt), pas directement dans les fichiers d'un ordinateur :
  la mise à jour suivante écraserait une modification locale.

## Fichiers

- `application.ps1` : serveur local (http://localhost:8787) + ouverture de la fenêtre ; lance la mise à jour au démarrage.
- `interface/index.html` : l'interface (et l'assistant IA intégré).
- `moteur_campagne.ps1` : déroulement des campagnes 24 h/24.
- `robot_fonctions.ps1` : fonctions communes (Twilio, liste de clients, message).
- `mise_a_jour.ps1` : mise à jour automatique depuis ce dépôt.
- `configurer.ps1` + `Lancer Robot appels.command` : premier lancement et lanceur Mac.
- `mac/` : fabrication de l'application Mac (`mac/creer-app.sh`).
- `robot_appel.ps1` : version en ligne de commande.
