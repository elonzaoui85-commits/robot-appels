# Robot appels

## Sur Mac

1. Range le dossier **Robot appels** sur ton Bureau.
2. La première fois seulement, ouvre l'app **Terminal** (cmd + espace, tape « Terminal », Entrée), colle cette ligne puis appuie sur Entrée :
   ```
   xattr -dr com.apple.quarantine ~/Desktop/"Robot appels"; chmod +x ~/Desktop/"Robot appels/Lancer Robot appels.command"; open ~/Desktop/"Robot appels/Lancer Robot appels.command"
   ```
   (Elle retire le blocage « fichier téléchargé d'Internet » du Mac et lance le robot.)
3. Les fois suivantes : double-clic sur **Lancer Robot appels.command**.

Au premier lancement, le robot installe **PowerShell** (gratuit, Microsoft) : suis l'installateur, puis relance. Il demande ensuite ton **Account SID**, ton **Auth Token** et ton **numéro Twilio**, les vérifie et les garde sur ce Mac.

Laisse la fenêtre du Terminal ouverte (réduite dans le Dock si tu veux) : tant qu'elle est ouverte, le robot tourne. Le Mac reste éveillé pendant une campagne, mais **ne ferme pas le capot**.

### Application Mac (icône sur le Bureau)

`./mac/creer-app.sh` fabrique **Robot appels.app**. Un double-clic ouvre le robot dans le Terminal.
Ses données (config.json, campagne, résultats) sont dans `~/Library/Application Support/Robot appels` : elles sont conservées quand on remplace l'application par une nouvelle version. À la première ouverture, l'application reprend les réglages de l'ancien dossier `~/Desktop/Robot appels` s'il existe.

## Ouvrir l'application (Windows)

Double-clique sur le raccourci **Robot appels** du Bureau : une fenêtre s'ouvre (elle fonctionne uniquement sur cet ordinateur).

- À la première ouverture, choisis un **mot de passe**. Il sera demandé à chaque ouverture.
- Le bouton en haut à droite (flèche) **verrouille** l'application.

## Utilisation

1. **Ta liste de clients** : glisse ton fichier Excel ou CSV (colonne **Téléphone** obligatoire, **Prénom** / **Nom** conseillés).
2. **Le message vocal** : écris ton message ; les boutons `+ Prénom`, `+ Nom`, etc. insèrent des variables remplacées pour chaque client. L'aperçu montre ce que le client entendra.
   - **Appel test** : appelle ton portable pour écouter.
   - **Améliorer avec l'IA** : l'assistant réécrit ton message.
3. **La campagne** : **Lancer les appels**. Le tableau se colore au fur et à mesure ; **Mettre en pause** puis **Reprendre** quand tu veux.
   - En dehors des horaires, le robot attend tout seul : laisse la fenêtre ouverte.
4. **Résultats** : ouvre le dossier des résultats (fichiers Excel/CSV).

**Réglages** (roue dentée) : jours et horaires, voix (Léa ou Rémi), répétition du message, dépôt sur répondeur, pause entre deux appels.

## Assistant IA

Panneau de droite. Pour l'activer : compte sur console.anthropic.com, un peu de crédit, **API Keys → Create Key → Copy**, puis bouton **J'ai copié ma clé**. La clé est enregistrée uniquement sur cet ordinateur.

## Sécurité

**Ne partage jamais ce dossier** : `config.json` contient les clés du compte Twilio et de l'assistant IA.

Mot de passe oublié : ouvre `config.json` avec le Bloc-notes, supprime le bloc `"acces": { ... }` (et la virgule qui le précède), enregistre, puis rouvre l'application.

## Fichiers

- `application.ps1` : l'application (serveur local + fenêtre).
- `interface/index.html` : l'interface.
- `robot_fonctions.ps1` : fonctions communes (Twilio, liste, message).
- `robot_appel.ps1` : version en ligne de commande (`-Fichier liste.csv [-Test]`).
- `Lancer Robot appels.command` : lanceur Mac (double-clic).
- `configurer.ps1` : demande et vérifie les identifiants Twilio au premier lancement (Mac).
