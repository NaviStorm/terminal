# mTerm

mTerm est un terminal natif pour macOS 14.6 ou ultérieur. L’interface est écrite en Objective-C avec AppKit et le moteur de terminal en Rust. Chaque volet possède son propre shell, son pseudo-terminal (PTY) et son historique. Le rendu limite la taille de l’image de texte à la zone occupée pour réduire la consommation mémoire des volets peu remplis.

## Compiler et lancer en développement

Installez Xcode et une chaîne Rust avec Cargo pour l’architecture de votre Mac. Python 3 sert aux scripts de vérification. Clonez le dépôt avec son historique Git pour que le numéro de build, calculé par `git rev-list --count HEAD`, corresponde à celui du projet.

```sh
git clone https://github.com/NaviStorm/terminal.git
cd terminal
open mTerm.xcodeproj
```

Dans Xcode, sélectionnez le schéma **mTerm**, la destination **My Mac**, puis lancez avec **⌘R**. La cible utilise la signature automatique du projet. Pour une compilation locale sur un autre Mac, adaptez la signature de la cible **mTerm** dans **Signing & Capabilities** pour les configurations Debug et Release.

À chaque build, la phase **Compiler le moteur Rust** appelle Cargo avec `--locked`. Cargo réutilise les dépendances et les artefacts à jour. Xcode lie ensuite la bibliothèque statique `libmterm_engine.a` à l’exécutable AppKit. Une modification du moteur est donc prise en compte au prochain **⌘R**. [Script de compilation Rust](scripts/build-engine.sh)

## Installer la Release

Depuis la racine du dépôt, avec un accès en écriture à `/Applications` :

```sh
./scripts/build_release_mac.sh && open /Applications/mTerm.app
```

Le script compile en Release dans `DerivedData/` avec une identité **Developer ID Application** de l’équipe configurée. Le certificat et sa clé privée doivent être disponibles dans le trousseau. Le script vérifie la signature avant de remplacer la version installée. Dans Xcode, Debug et Release utilisent la signature automatique. [Script d’installation](scripts/build_release_mac.sh)

## Architecture

| Composant | Responsabilité |
| --- | --- |
| [Moteur Rust](Engine/src/lib.rs) | Interprète la sortie du PTY avec la bibliothèque `vt100`, maintient la grille et l’historique, traite les recherches et prépare les réponses aux requêtes du terminal. |
| [Interface C](mTerm/Engine.h) | Expose le moteur à Objective-C. Chaque `mt_new` est associé à un `mt_free`. Les octets de cellule fournis par `mt_cell` restent valides jusqu’à la prochaine mutation du parseur. |
| [Vue de terminal](mTerm/TerminalView.m) | Lance le shell avec `forkpty`, transmet sa sortie à `mt_feed` et dessine les cellules. Gère aussi le clavier, la souris, la sélection et le presse-papiers. |
| [Fenêtres et sessions](mTerm/main.m) | Gère les onglets AppKit, les volets scindés, le focus, les menus et la fermeture des sessions. |
| [Profils](mTerm/ColorProfiles.m) et [réglages](mTerm/ColorSettings.m) | Gèrent les palettes, l’import de fichiers `.itermcolors`, l’opacité du fond et les préférences générales. |

## Fonctionnalités à essayer

- **Volets et onglets** — Scindez une session avec **⌘D** ou **⇧⌘D**, passez au volet voisin avec **⌘⌥ + flèche** et agrandissez le volet actif avec **⇧⌘Entrée**. Une seconde pression restaure la disposition.
- **Texte et fichiers** — La sélection copie le texte dans le presse-papiers. Un double-clic sélectionne un mot, un triple-clic une ligne. Déposez un fichier du Finder pour insérer son chemin dans la commande.
- **Recherche et historique** — **⌘F** recherche dans la session. **Réglages → Général** fixe le nombre de lignes conservées par nouvelle session, avec une valeur initiale de 1 000.
- **Profils et fenêtres** — Les profils règlent les couleurs du texte, du curseur et de la sélection, ainsi que l’opacité du fond. La taille de police et la géométrie de la fenêtre sont mémorisées.

## Vérifier une modification

**Moteur Rust.** Depuis la racine du dépôt, lancez les tests de la grille, de l’historique, de la recherche et des séquences de terminal.

```sh
cargo test --locked --manifest-path Engine/Cargo.toml
```

**Échanges avec le shell.** Dans un volet **mTerm** ouvert à la racine du dépôt, exécutez la commande suivante. Le script interroge le terminal actif via `/dev/tty` et affiche son identité, son état, la position du curseur et les dimensions de la grille.

```sh
python3 scripts/test_terminal.py
```

**Empreinte mémoire.** Une fois la Release installée, lancez le script ci-dessous et gardez sa fenêtre de test au premier plan. Il ouvre une copie temporaire de mTerm, passe de un à cinq volets puis revient à un, et mesure séparément mTerm et les shells `zsh`. Par défaut, il utilise le profil de l’application mesurée. L’option `--profil "Nom du profil"` permet de reproduire une mesure avec un autre profil enregistré.

```sh
./scripts/test_ram.py
```

## Assistance et licence

Pour poser une question, signaler un problème ou proposer une amélioration, consultez [CONTACT.md](CONTACT.md).

© 2026 Andreu-Ascensio Thierry. [Licence GPLv3](LICENSE) · [Traduction française](LICENSE.fr)
