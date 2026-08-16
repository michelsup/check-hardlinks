# check_hardlinks.sh

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
| 9. Orphelins de disque | `SCAN_DISK_ORPHANS`, `DISK_ORPHAN_LOG`, `DISK_ORPHAN_MIN_SIZE`, `DISK_ORPHAN_EXTENSIONS` | Phase 7 : fichiers de bibliothèque non référencés |

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
./check_hardlinks.sh                 # run normal (utilise les caches)
./check_hardlinks.sh --use-no-cache   # ignore tous les caches, ré-analyse tout depuis zéro
./check_hardlinks.sh --help           # aide
```

`--use-no-cache` force un nouveau scan complet (hash, inodes, statut des torrents, inodes Arr) sans supprimer les caches existants — ils sont réécrits normalement en fin d'exécution pour les prochains runs.

## Les 10 phases

| # | Phase | Rôle |
|---|---|---|
| 0 | Récupération des torrents | Liste tous les torrents qBittorrent (cache `TORRENT_CACHE_DURATION`) |
| 1 | Inodes Radarr/Sonarr | Indexe tous les fichiers connus des Arr par inode |
| 2 | Marquage linked/partial | Compare les fichiers de chaque torrent aux inodes Arr — **tous** liés → `linked`, **certains** → `partial` |
| 3 | Analyse des inodes | Pour les torrents non résolus en Phase 2 : détecte média/cross-seed par inode réel |
| 4 | Classification finale | Statut définitif : `linked` / `cross-linked` / `no-media` / `orphan` |
| 5 | Réparation | Si `AUTO_REPAIR=true` : hardlink des fichiers manquants des torrents `orphan`/`partial` |
| 6 | Vérification durée de seed | Pour les torrents restés 100% orphelins : bascule en `à effacer` si le minimum du tracker est atteint |
| 7 | Orphelins de disque | Si `SCAN_DISK_ORPHANS=true` : fichiers de la bibliothèque ni gérés par les Arr, ni liés à un torrent connu |
| 8 | Nettoyage des tags | Retire tous les anciens tags de gestion avant réapplication |
| 9 | Application des tags | Applique les tags calculés à ce run |

Un torrent `orphan` ou `partial` réparé en Phase 5 devient `linked` s'il est entièrement corrigé, ou reste `partial` si seulement une partie de ses fichiers a pu être réparée. Un torrent `partial` n'est **jamais** proposé à la suppression (Phase 6) : il contient de vrais fichiers non dupliqués ailleurs.

## Tags appliqués

Les tags sont entièrement nettoyés puis réappliqués à chaque run (Phases 8-9), donc toujours à jour par rapport au dernier scan. Personnalisables via `TAG_*` dans `config.conf`.

## Caches

Stockés dans `cleanup/*.txt`, ils évitent de tout recalculer à chaque run :

| Fichier | Contenu |
|---|---|
| `hash_cache.txt` | Hash de chaque fichier (invalidé si la taille change) |
| `inode_status.txt` | Statut média/cross-seed de chaque inode |
| `torrent_status.txt` | Dernier statut connu de chaque torrent |
| `torrent_list.txt` | Liste des torrents qBittorrent (durée `TORRENT_CACHE_DURATION`) |
| `arr_inodes.txt` | Inodes connus de Radarr/Sonarr (durée `ARR_CACHE_DURATION`) |

Tous les caches sont sauvegardés automatiquement en cas d'interruption (Ctrl+C) et à la fin d'un run normal. Utilisez `--use-no-cache` pour forcer une réanalyse complète sans les supprimer.

## Sécurité

- `config.conf` (mots de passe qBittorrent, clés API Radarr/Sonarr) et `tracker_secrets.conf` sont automatiquement passés en permissions `600` (lecture propriétaire uniquement).
- Les réparations utilisent un hardlink **atomique** : le fichier orphelin n'est jamais supprimé avant que son remplaçant soit prêt et vérifié — en cas d'échec ou d'interruption, aucune perte de données.
- `AUTO_REPAIR=true` et `SCAN_DISK_ORPHANS=true` déclenchent des opérations réelles sur le système de fichiers et sur vos instances qBittorrent (tags, hardlinks). Testez avec `AUTO_REPAIR=false` si vous voulez d'abord valider la classification sans rien modifier.

## Dépannage

- **« X: unbound variable »** : généralement un tableau associatif de `config.conf` mal formé ou absent (`MEDIA_DIRS`, `PATH_MAP`, `ARR_CONFIG`, `STOPWORDS` doivent être définis, même vides).
- **Torrent classé « orphan » alors qu'il est bien lié** : vérifiez `PATH_MAP` (traduction chemin conteneur → hôte) et que les torrents/la bibliothèque sont bien sur le même filesystem (nécessaire pour un hardlink).
- **La Phase 5 ne répare presque rien** : normal si beaucoup d'orphelins ont déjà dépassé la durée de seed minimale de leur tracker — ils passent directement par la Phase 6, après une tentative de réparation en Phase 5.
- **Un tag ne se retire jamais** : vérifiez qu'il figure bien dans `DELETE_TAGS`.
