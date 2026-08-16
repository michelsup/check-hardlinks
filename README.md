# check_hardlinks.sh

![CI](https://github.com/michelsup/check-hardlinks/actions/workflows/ci.yml/badge.svg)

Script Bash de dédoublonnage et de gestion des hardlinks entre **qBittorrent** et vos bibliothèques **Radarr / Sonarr**.

Il analyse chaque torrent, vérifie s'il est réellement hardlinké vers la bibliothèque média, le classe automatiquement via des **tags qBittorrent**, peut **réparer** les torrents orphelins (recréer le hardlink manquant), et repère les **fichiers de la bibliothèque** qui n'appartiennent à aucun torrent connu.

## Sommaire

- [Fonctionnement en un coup d'œil](#fonctionnement-en-un-coup-dœil)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Configuration](#configuration)
- [Utilisation](#utilisation)
- [Les 10 phases](#les-10-phases)
- [Tags appliqués](#tags-appliqués)
- [Caches](#caches)
- [Sécurité](#sécurité)
- [Dépannage](#dépannage)

## Fonctionnement en un coup d'œil

Pour chaque torrent qBittorrent, le script détermine s'il est :

| Tag | Signification |
|---|---|
| `linked` | **Tous** les fichiers du torrent sont hardlinkés vers la bibliothèque (via Radarr/Sonarr ou détection directe) |
| `partial` | **Certains** fichiers sont liés, d'autres non (ex. un pack de saison où seuls quelques épisodes ont été importés) |
| `cross-linked` | Tous les fichiers sont liés à la bibliothèque **et** présents dans le dossier de cross-seed |
| `no-media` | Le torrent ne contient aucun fichier vidéo (pas concerné par la dédup) |
| `orphan` | Aucun fichier n'est lié — c'est une copie non dédupliquée pure |
| `à effacer` | Orphelin ayant déjà seedé plus longtemps que le minimum exigé par son tracker : candidat à la suppression |

Si `AUTO_REPAIR=true`, le script tente de **réparer** les torrents `orphan`/`partial` en cherchant un fichier identique (même taille + même hash) dans la bibliothèque et en le hardlinkant à la place de la copie orpheline — sans jamais supprimer un fichier avant que son remplaçant ne soit prêt (opération atomique).

## Prérequis

- **bash** ≥ 4.3 (tableaux associatifs)
- **curl**
- **python3** (parsing JSON des réponses API)
- Un outil de hachage : `xxh128sum` ou `xxh64sum` (recommandés, package `xxhash`) ou `md5sum` (fallback)
- Accès réseau aux instances qBittorrent et, si utilisé, à Radarr/Sonarr
- Les torrents et la bibliothèque doivent être sur le **même système de fichiers** (condition nécessaire pour un hardlink)

## Installation

```
check-hardlinks/
├── check_hardlinks.sh          # le script
├── .gitignore
└── cleanup/
    ├── config.conf.example     # modèle de configuration (versionné)
    ├── config.conf             # votre configuration réelle (jamais versionnée)
    ├── tracker_secrets.conf    # généré automatiquement (durées de seed par tracker)
    └── *.txt                   # caches générés automatiquement
```

```bash
chmod +x check_hardlinks.sh
cp cleanup/config.conf.example cleanup/config.conf
# éditez cleanup/config.conf avec vos instances qBittorrent, vos chemins, etc.
```

## Configuration

Toute la configuration vit dans `cleanup/config.conf` (fichier `bash` sourcé au démarrage, copié depuis `cleanup/config.conf.example`). Il contient des mots de passe et des clés API en clair : le script restreint automatiquement ses permissions à `600` au premier lancement, et il est exclu du dépôt par `.gitignore` — **ne le publiez jamais**.

Le détail de chaque réglage est commenté directement dans [`cleanup/config.conf.example`](cleanup/config.conf.example) ; résumé :

| Section | Variables | Rôle |
|---|---|---|
| 1. Instances qBittorrent | `INSTANCES`, `QBIT_*_URL/USER/PASS` | Une entrée par instance qBittorrent à surveiller |
| 2. Tags | `TAG_*`, `DELETE_TAGS` | Noms des tags appliqués/nettoyés dans qBittorrent |
| 3. Médias | `MEDIA_DIRS`, `CROSS_SEED_DIR` | Chemins **hôte** de la bibliothèque et du dossier de cross-seed |
| 4. Traduction de chemins | `PATH_MAP` | Correspondance chemin conteneur → chemin hôte |
| 5. Radarr/Sonarr | `ARR_CONFIG` | `"app\|URL\|clé_API"` par instance qBittorrent |
| 6. Réparation | `AUTO_REPAIR`, `CHOWN_FILES`, `CHOWN_USER` | Active la réparation automatique par hardlink |
| 7. Normalisation | `STOPWORDS` | Mots ignorés lors du matching par nom de fichier |
| 8. Cache Arr | `ARR_CACHE_DURATION` | Durée de validité (secondes) du cache des inodes Arr |
| — | `TORRENT_STATUS_TTL` | Durée de validité (secondes) d'un statut de torrent mis en cache — défaut 86400 (24 h) |
| 9. Orphelins de disque | `SCAN_DISK_ORPHANS`, `DISK_ORPHAN_LOG`, `DISK_ORPHAN_PATHS_FILE`, `DISK_ORPHAN_MIN_SIZE`, `DISK_ORPHAN_EXTENSIONS` | Phase 7 : fichiers de bibliothèque non référencés |

### Durée minimale de seed par tracker

`cleanup/tracker_secrets.conf` associe chaque domaine de tracker à une durée minimale de seed (en heures) avant qu'un torrent orphelin ne soit marqué « à effacer ». Il est peuplé automatiquement :

- **Interactif** : le script demande la valeur la première fois qu'il rencontre un nouveau tracker.
- **Non-interactif** (cron) : une valeur conservatrice (`999999` h, jamais atteinte) est utilisée par défaut tant que vous n'avez pas renseigné le tracker manuellement.

Format du fichier (généré/édité automatiquement, `chmod 600`) :

```
tracker.example.org=72
tracker.autre.net=168
```

## Utilisation

```bash
./check_hardlinks.sh                          # run normal (utilise les caches)
./check_hardlinks.sh --use-no-cache            # ignore tous les caches, ré-analyse tout depuis zéro
./check_hardlinks.sh --dry-run                 # simulation complète, aucune écriture réelle
./check_hardlinks.sh --full-hash               # Phase 5 : exige un hash complet, pas seulement échantillonné
./check_hardlinks.sh --debug 2> debug.log      # journal de diagnostic détaillé sur stderr
./check_hardlinks.sh --help                    # aide
```

- `--use-no-cache` force un nouveau scan complet (hash, inodes, statut des torrents, inodes Arr) sans supprimer les caches existants — ils sont réécrits normalement en fin d'exécution pour les prochains runs.
- `--dry-run` exécute toute l'analyse et la classification normalement, mais **aucune écriture réelle** n'a lieu : ni hardlink/chown sur le filesystem, ni tag ajouté/retiré dans qBittorrent. Force `AUTO_REPAIR=true` le temps du run pour prévisualiser les réparations qui seraient tentées (sans jamais les appliquer). Recommandé pour un premier run sur une nouvelle configuration.
- `--full-hash` : par défaut, un candidat dont le hash rapide (échantillonné) correspond à l'orphelin est considéré comme une correspondance et hardlinké directement — le plus rapide. Avec `--full-hash`, une confirmation par hash complet est exigée avant tout hardlink, comme avant l'optimisation ; plus lent sur de gros fichiers, mais élimine le risque (infinitésimal mais non nul) qu'un hash rapide identique corresponde à des fichiers réellement différents. Sans effet sur les petits fichiers (déjà vérifiés en entier dans les deux cas).
- `--debug` affiche sur stderr (préfixé `🐛 [DEBUG]`, n'affecte jamais la sortie normale sur stdout) : chaque requête API qBittorrent/Radarr/Sonarr avec son code HTTP, les traductions `PATH_MAP` appliquées, le diagnostic complet de chaque tentative de hardlink (device, inode, permissions), et les hashs comparés lors de la réparation (Phase 5). Combinable avec `--dry-run` pour investiguer un problème sans rien modifier.

## Les 10 phases

| # | Phase | Rôle |
|---|---|---|
| 0 | Récupération des torrents | Liste tous les torrents qBittorrent (cache `TORRENT_CACHE_DURATION`) |
| 1 | Inodes Radarr/Sonarr | Indexe tous les fichiers connus des Arr par inode |
| 2 | Marquage linked/partial | Compare les fichiers de chaque torrent aux inodes Arr — **tous** liés → `linked`, **certains** → `partial` |
| 3 | Analyse des inodes | Pour les torrents non résolus en Phase 2 : détecte média/cross-seed par inode réel |
| 4 | Classification finale | Statut définitif : `linked` / `cross-linked` / `no-media` / `orphan` |
| 5 | Réparation | Si `AUTO_REPAIR=true` : hardlink des fichiers manquants des torrents `orphan`/`partial`, **uniquement vers des fichiers revendiqués par Radarr/Sonarr** |
| 6 | Vérification durée de seed | Pour les torrents restés 100% orphelins : bascule en `à effacer` si le minimum du tracker est atteint |
| 7 | Orphelins de disque | Si `SCAN_DISK_ORPHANS=true` : fichiers de la bibliothèque que **l'API Radarr/Sonarr ne revendique pas** et qui ne sont liés à aucun torrent connu. Ignorée si l'API n'a rien renvoyé (impossible de trancher) |
| 8 | Nettoyage des tags | Retire tous les anciens tags de gestion avant réapplication |
| 9 | Application des tags | Applique les tags calculés à ce run |

Un torrent `orphan` ou `partial` réparé en Phase 5 devient `linked` s'il est entièrement corrigé, ou reste `partial` si seulement une partie de ses fichiers a pu être réparée. Un torrent `partial` n'est **jamais** proposé à la suppression (Phase 6) : il contient de vrais fichiers non dupliqués ailleurs.

### Ce qui compte comme « déjà dans la bibliothèque »

Le script raisonne par **inode** : deux chemins qui partagent un inode sont le même contenu physique — c'est la définition d'un hardlink. Il distingue deux ensembles, et cette distinction est volontaire :

| Provenance | Origine | Sert à la détection (Phases 2-4) | Sert de cible de réparation (Phase 5) |
|---|---|---|---|
| `api` | Fichier revendiqué par Radarr/Sonarr | ✅ | ✅ |
| `scan` | Fichier présent dans `MEDIA_DIRS` mais inconnu des \*arr | ✅ | ❌ |

**Pourquoi l'union pour la détection** : « ce torrent est-il déjà dédoublonné ? » est un fait du système de fichiers, indépendant de ce que Radarr sait. C'est aussi un garde-fou : si une API est momentanément injoignable, s'en tenir à `api` ferait basculer *tous* les torrents en `orphan`, et la Phase 6 pourrait alors les promouvoir en masse en « à effacer ».

**Pourquoi `api` seul pour la réparation** : un fichier présent dans la bibliothèque mais inconnu des \*arr est précisément ce que la Phase 7 signale comme orphelin de disque à nettoyer. Y hardlinker un torrent donnerait un gain illusoire — le jour où ce fichier est supprimé, le torrent redevient une copie isolée et repasse `orphan` — tout en le faisant apparaître `linked`, ce qui masquerait le fait que l'import Arr n'a jamais eu lieu.

**Sens du hardlink** : c'est le fichier **du torrent** qui est remplacé par un lien vers le fichier de la bibliothèque, jamais l'inverse — le fichier géré par Radarr/Sonarr n'est jamais touché. Note : qBittorrent gardant le fichier ouvert, l'espace disque n'est réellement libéré qu'après un recheck ou un redémarrage de qBittorrent.

**Index de réparation** : les candidats sont cherchés dans un index `taille → fichiers` construit une seule fois en Phase 1, en se greffant sur le parcours de `MEDIA_DIRS` déjà effectué. Auparavant chaque fichier orphelin déclenchait un parcours complet de *chacun* des `MEDIA_DIRS` : pour 200 orphelins et 5 répertoires, un millier de parcours intégraux de la bibliothèque.

**Performance de la Phase 5** : par défaut, deux fichiers de même taille sont comparés par hash rapide par échantillonnage (début/milieu/fin, ~3 Mo au lieu de tout le fichier vidéo) — un candidat qui correspond est hardlinké directement, sans hash complet. Utilisez `--full-hash` pour exiger en plus une confirmation par hash complet avant chaque hardlink (plus lent, plus rigoureux).

**Performance des parcours de fichiers** : parcourir un dossier torrent ou la bibliothèque avec `find` puis lire l'inode de chaque fichier avec un `stat` externe coûte un fork+exec par fichier — sur une grosse bibliothèque, ça representait des milliers de processus juste pour lire des métadonnées. Ces parcours (Phases 2 à 5, scan de la bibliothèque, indexation Radarr/Sonarr) passent maintenant par un seul processus Python par appel (`os.walk` + `os.lstat`), qui renvoie directement inode/taille/chemin.

**Mémoïsation des parcours** : le répertoire d'un même torrent était parcouru jusqu'à quatre fois par run (Phases 2, 3, 4 et 5). Le résultat est désormais mémoïsé pour la durée du run, puis invalidé après la Phase 5 (qui change les inodes en créant des hardlinks). Le mémo est écrit dans `TMPDIR`, résolu de préférence sur un tmpfs (`/dev/shm`) : ces fichiers éphémères restent donc en RAM plutôt que d'être infligés au pool de stockage. Définir `TMPDIR` explicitement force un autre emplacement.

**Performance du chargement du cache torrents** : la traduction de chemin (`translate_path`, Docker → hôte via `PATH_MAP`) refaisait un tri complet des préfixes (`awk`+`sort`+`cut`, donc 3 process externes) à **chaque appel**, alors qu'elle est appelée une fois par torrent au chargement du cache. Sur une grosse liste de torrents, ça pouvait à lui seul représenter l'essentiel du temps de démarrage. Le tri est maintenant calculé une seule fois et mis en cache, `PATH_MAP` ne changeant jamais en cours de run.

### Exploiter les orphelins de disque depuis un autre script

La Phase 7 produit deux fichiers distincts :

| Fichier | Destinataire | Format |
|---|---|---|
| `DISK_ORPHAN_LOG` | lecture humaine | en-tête daté, puis `inode<TAB>taille<TAB>chemin` |
| `DISK_ORPHAN_PATHS_FILE` | script annexe | un chemin absolu par ligne, rien d'autre |

La liste des chemins est triée (donc comparable au `diff` d'un run à l'autre) et basculée par `mv` en fin de phase : un script qui la lit pendant un scan ne verra jamais de liste partielle.

**Contrat à respecter si votre script supprime des fichiers :**

| État du fichier | Signification | Action attendue |
|---|---|---|
| présent, non vide | ces chemins sont orphelins | traiter |
| présent, vide | aucun orphelin | ne rien faire |
| **absent** | la Phase 7 n'a pas pu conclure (API Arr injoignable) ou n'a pas tourné | **s'abstenir** — ne jamais réutiliser une liste précédente |

Le fichier est volontairement vidé quand il n'y a plus d'orphelin, et supprimé quand la phase abandonne : dans les deux cas, il ne doit jamais rester une liste périmée sur laquelle un script agirait à tort.

```bash
while IFS= read -r f; do
    echo "à traiter : $f"
done < cleanup/disk_orphans_paths.txt
```

Limite : un chemin contenant un retour à la ligne ne peut pas être représenté dans ce format (inexistant en pratique pour des fichiers média).

## Tags appliqués

Les tags sont entièrement nettoyés puis réappliqués à chaque run (Phases 8-9), donc toujours à jour par rapport au dernier scan. Personnalisables via `TAG_*` dans `config.conf`.

## Caches

Stockés dans `cleanup/*.txt`, ils évitent de tout recalculer à chaque run :

| Fichier | Contenu |
|---|---|
| `hash_cache.txt` | Hash de chaque fichier (invalidé si la taille change) |
| `inode_status.txt` | Statut média/cross-seed de chaque inode |
| `torrent_status.txt` | Dernier statut connu de chaque torrent (durée `TORRENT_STATUS_TTL`, purgé des torrents supprimés de qBittorrent) |
| `torrent_list.txt` | Liste des torrents qBittorrent (durée `TORRENT_CACHE_DURATION`) |
| `arr_inodes.txt` | Inodes de la bibliothèque et leur provenance — `api` (revendiqué par Radarr/Sonarr) ou `scan` (simplement présent dans `MEDIA_DIRS`). Durée `ARR_CACHE_DURATION` |

Tous les caches sont sauvegardés automatiquement en cas d'interruption (Ctrl+C) et à la fin d'un run normal. Utilisez `--use-no-cache` pour forcer une réanalyse complète sans les supprimer.

## Sécurité

- `config.conf` (mots de passe qBittorrent, clés API Radarr/Sonarr) et `tracker_secrets.conf` sont automatiquement passés en permissions `600` (lecture propriétaire uniquement).
- Mots de passe et clés API sont transmis à `curl` via sa configuration (`-K -`, lue sur stdin) plutôt qu'en argument de ligne de commande, pour ne jamais apparaître en clair dans `ps aux` le temps d'un appel.
- Les réparations utilisent un hardlink **atomique** : le fichier orphelin n'est jamais supprimé avant que son remplaçant soit prêt et vérifié — en cas d'échec ou d'interruption, aucune perte de données.
- Un verrou (`cleanup/check_hardlinks.lock`) empêche deux exécutions simultanées de se marcher dessus (tags, hardlinks, caches) ; une seconde instance lancée pendant qu'une autre tourne s'arrête immédiatement avec une erreur explicite.
- `AUTO_REPAIR=true` et `SCAN_DISK_ORPHANS=true` déclenchent des opérations réelles sur le système de fichiers et sur vos instances qBittorrent (tags, hardlinks). Utilisez `--dry-run` pour un premier run qui montre tout ce qui serait fait sans rien modifier.

## Dépannage

- **« X: unbound variable »** : généralement un tableau associatif de `config.conf` mal formé ou absent (`MEDIA_DIRS`, `PATH_MAP`, `ARR_CONFIG`, `STOPWORDS` doivent être définis, même vides).
- **Torrent classé « orphan » alors qu'il est bien lié** : vérifiez `PATH_MAP` (traduction chemin conteneur → hôte) et que les torrents/la bibliothèque sont bien sur le même filesystem (nécessaire pour un hardlink).
- **La Phase 5 ne répare presque rien** : normal si beaucoup d'orphelins ont déjà dépassé la durée de seed minimale de leur tracker — ils passent directement par la Phase 6, après une tentative de réparation en Phase 5.
- **Un tag ne se retire jamais** : vérifiez qu'il figure bien dans `DELETE_TAGS`.
- **« Une autre instance tourne déjà »** : un run précédent a été interrompu brutalement (`kill -9`) sans libérer le verrou correctement ne devrait pas arriver (le verrou est un descripteur de fichier, relâché automatiquement à la fin du processus) ; si ça persiste, supprimez `cleanup/check_hardlinks.lock`.

## Licence

[MIT](LICENSE)
- Pour investiguer n'importe lequel de ces cas, lancez avec `--dry-run --debug 2> debug.log` : classification et diagnostic complets, sans aucune écriture.
