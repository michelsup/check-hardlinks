#!/bin/bash
set -uo pipefail

# =============================================================================
# qBittorrent Dedupe & Hardlink Manager
# =============================================================================
# Ce script analyse les torrents qBittorrent, vérifie s'ils sont liés
# (hardlinks) aux bibliothèques Radarr/Sonarr, et classe automatiquement
# chaque torrent dans qBittorrent via des tags. Il peut aussi réparer les
# torrents orphelins (hardlink manuel) et repérer les fichiers de la
# bibliothèque qui n'appartiennent à aucun torrent connu.
#
# Déroulé (voir main(), en bas de fichier) :
#   Phase 0 — Récupération de la liste des torrents qBittorrent
#   Phase 1 — Récupération des inodes gérés par Radarr/Sonarr
#   Phase 2 — Marquage "linked" (tous les fichiers du torrent retrouvés chez
#             les Arr) ou "partial" (certains seulement, ex. pack de saison
#             où un épisode sur dix est déjà importé) par correspondance d'inode
#   Phase 3 — Analyse des inodes restants (média / cross-seed / inconnu)
#   Phase 4 — Classification finale (linked / cross-linked / no_media / orphan)
#   Phase 5 — Réparation automatique des orphelins ET des partiels
#             (si AUTO_REPAIR=true) — un torrent partiel entièrement réparé
#             devient "linked", partiellement réparé reste "partial"
#   Phase 6 — Vérification de la durée de seed minimale par tracker
#             (uniquement pour les torrents restés 100% orphelins)
#   Phase 7 — Scan des orphelins de disque (si SCAN_DISK_ORPHANS=true)
#   Phase 8 — Nettoyage des anciens tags qBittorrent
#   Phase 9 — Application des nouveaux tags
#
# Usage : voir print_usage() ci-dessous, ou `./check_hardlinks.sh --help`.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cleanup/config.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Fichier de configuration introuvable : $CONFIG_FILE"
    echo "   Copiez cleanup/config.conf.example vers $CONFIG_FILE puis éditez-le."
    exit 1
fi

# Le fichier contient des mots de passe et des clés API en clair :
# on restreint ses permissions pour qu'il ne soit lisible que par son propriétaire.
chmod 600 "$CONFIG_FILE" 2>/dev/null

# shellcheck source=cleanup/config.conf.example
# shellcheck disable=SC1091
source "$CONFIG_FILE"

# Valeurs par défaut pour toutes les variables de configuration (set -u safe)
INSTANCES=("${INSTANCES[@]}")
DELETE_TAGS=("${DELETE_TAGS[@]}")
TAG_LINKED="${TAG_LINKED:-linked}"
TAG_CROSS_LINKED="${TAG_CROSS_LINKED:-cross-linked}"
TAG_PARTIAL="${TAG_PARTIAL:-partial}"
TAG_NO_MEDIA="${TAG_NO_MEDIA:-no-media}"
TAG_ORPHAN="${TAG_ORPHAN:-orphan}"
TAG_DELETE="${TAG_DELETE:-delete-ready}"
CHOWN_FILES="${CHOWN_FILES:-false}"
CHOWN_USER="${CHOWN_USER:-}"
ARR_CACHE_DURATION="${ARR_CACHE_DURATION:-3600}"
AUTO_REPAIR="${AUTO_REPAIR:-false}"
SCAN_DISK_ORPHANS="${SCAN_DISK_ORPHANS:-false}"
DISK_ORPHAN_LOG="${DISK_ORPHAN_LOG:-${SCRIPT_DIR}/disk_orphans.log}"
DISK_ORPHAN_MIN_SIZE="${DISK_ORPHAN_MIN_SIZE:-0}"
CROSS_SEED_DIR="${CROSS_SEED_DIR:-}"

# Répertoire de travail temporaire. Tout ce qu'on y écrit est éphémère et
# reconstruit à chaque run (mémo de parcours, listes d'inodes intermédiaires,
# réponses Sonarr) : autant rester en RAM plutôt que d'infliger ces
# écritures au pool de stockage. On respecte TMPDIR s'il est explicitement
# défini par l'utilisateur, sinon on préfère /dev/shm — tmpfs garanti sous
# Linux — et on retombe sur /tmp (souvent déjà un tmpfs) en dernier recours.
if [ -n "${TMPDIR:-}" ]; then
    :
elif [ -d /dev/shm ] && [ -w /dev/shm ]; then
    TMPDIR=/dev/shm
else
    TMPDIR=/tmp
fi

# Durée de validité d'un statut de torrent mis en cache (secondes). Passé ce
# délai, le torrent est reclassifié de zéro.
# CORRECTION : le timestamp écrit dans torrent_status.txt était relu mais
# jamais comparé à quoi que ce soit — un statut « no_media », « orphan » ou
# « delete_ready » était donc définitif. Une seule classification erronée
# (ex. scan de fichiers vide à cause d'une défaillance ponctuelle) restait
# gravée pour toujours. 86400 = 24 h.
TORRENT_STATUS_TTL="${TORRENT_STATUS_TTL:-86400}"

# CORRECTION : "${X[@]:-}" sur un tableau absent produit UN élément vide, pas
# un tableau vide — "${#DISK_ORPHAN_EXTENSIONS[@]}" valait donc 1 et le test
# "-gt 0" passait à tort (le filtre était sauvé uniquement parce que la
# jointure d'un unique élément vide redonne une chaîne vide).
if declare -p DISK_ORPHAN_EXTENSIONS &>/dev/null; then
    DISK_ORPHAN_EXTENSIONS=("${DISK_ORPHAN_EXTENSIONS[@]}")
else
    DISK_ORPHAN_EXTENSIONS=()
fi

# -----------------------------------------------------------------------------
# VALIDATION DE LA CONFIGURATION
# -----------------------------------------------------------------------------
# CORRECTION : sous `set -u`, "${MEDIA_DIRS[@]}" sur un tableau totalement
# absent ne déclenche PAS d'erreur (contrairement à "${#X[@]}" sur un
# `declare -A` nu) — l'expansion est silencieusement vide. Un config.conf
# amputé de MEDIA_DIRS tournait donc jusqu'au bout en classant absolument
# tous les torrents en « orphelin », sans le moindre avertissement. On
# vérifie donc explicitement ce dont le script a besoin pour être correct.
config_errors=()

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    config_errors+=('INSTANCES est vide ou absent (ex: INSTANCES=("VPN" "DIRECT"))')
else
    for inst in "${INSTANCES[@]}"; do
        # qbit_vars() ne sait résoudre que ces deux noms : tout autre nom
        # échouerait plus tard à la connexion, sans message explicite.
        case "$inst" in
            VPN|DIRECT) ;;
            *) config_errors+=("INSTANCES contient \"$inst\" : seuls \"VPN\" et \"DIRECT\" sont gérés") ;;
        esac
        for suffix in URL USER PASS; do
            varname="QBIT_${inst}_${suffix}"
            [ -z "${!varname:-}" ] && config_errors+=("$varname non défini (requis par INSTANCES=\"$inst\")")
        done
    done
fi

if ! declare -p MEDIA_DIRS &>/dev/null || [ "${#MEDIA_DIRS[@]}" -eq 0 ]; then
    config_errors+=('MEDIA_DIRS est vide ou absent : sans bibliothèque de référence, tous les torrents seraient classés orphelins')
fi

declare -p PATH_MAP    &>/dev/null || config_errors+=('PATH_MAP absent (déclarez au moins "declare -A PATH_MAP" même vide)')
declare -p ARR_CONFIG  &>/dev/null || config_errors+=('ARR_CONFIG absent (déclarez au moins "declare -A ARR_CONFIG" même vide)')
declare -p STOPWORDS   &>/dev/null || STOPWORDS=()

[ "${#DELETE_TAGS[@]}" -eq 0 ] && \
    printf '⚠️  DELETE_TAGS est vide : les anciens tags ne seront pas nettoyés (Phase 8).\n' >&2

if [ "${#config_errors[@]}" -gt 0 ]; then
    printf '❌ Configuration invalide (%s) :\n' "$CONFIG_FILE" >&2
    for cfg_err in "${config_errors[@]}"; do
        printf '   • %s\n' "$cfg_err" >&2
    done
    printf '\n   Référez-vous à cleanup/config.conf.example.\n' >&2
    exit 1
fi
unset config_errors cfg_err inst suffix varname

CACHE_DIR="${SCRIPT_DIR}/cleanup"
mkdir -p "$CACHE_DIR"

# -----------------------------------------------------------------------------
# VARIABLES GLOBALES
# -----------------------------------------------------------------------------

# CORRECTION : tous les tableaux associatifs ci-dessous sont initialisés
# avec "=()" explicite, pas seulement "declare -A X". Un tableau associatif
# déclaré mais jamais affecté au moins une fois (même à vide) reste dans un
# état que bash considère "non lié" pour `${#X[@]}` sous `set -u` — même sur
# des versions récentes (bash 5.x), ce n'est pas un bug corrigé avec le temps,
# c'est le comportement voulu. Concrètement : avec --use-no-cache, les
# fonctions load_*() qui font normalement ce premier "X=()" ne sont jamais
# appelées, donc sans ce correctif `${#X[@]}` plantait en fin de run
# ("X: unbound variable") dès qu'un cache restait vide sur tout le run.

# Connexions qBittorrent
declare -A QBIT_COOKIES=()

# Caches disque
declare -A HASH_CACHE=()
declare -A INODE_STATUS_CACHE=()
# Chemin d'un fichier témoin par inode. CORRECTION : save_inode_cache_bulk
# écrivait un sample_path vide, alors que load_inode_cache rejette toute
# entrée sans fichier témoin existant — 100 % du cache d'inodes était donc
# jeté au rechargement suivant. On mémorise le témoin pour pouvoir le
# réécrire.
declare -A INODE_SAMPLE_PATH=()
declare -A TORRENT_CACHE=()

# Métadonnées torrents
declare -A TORRENT_NAMES=()
declare -A TORRENT_INSTANCE=()
declare -A TORRENT_SAVE_PATH=()
declare -A TORRENT_HOST_PATH=()
# Tracker et temps de seed déjà présents dans /torrents/info (Phase 0),
# utilisés en Phase 6 pour éviter un appel API séparé par torrent.
declare -A TORRENT_TRACKER=()
declare -A TORRENT_SEEDING_TIME=()

# Inodes présents dans la bibliothèque : union des fichiers réellement
# déclarés par l'API Radarr/Sonarr ET du scan direct de MEDIA_DIRS. C'est
# cette union qui répond à « ce fichier est-il dans la bibliothèque ? »
# (Phases 2 à 5).
declare -A ARR_MANAGED_INODES=()

# Provenance de chaque inode ci-dessus : "api" (Radarr/Sonarr le déclare
# explicitement) ou "scan" (simplement trouvé dans MEDIA_DIRS).
# CORRECTION : sans cette distinction, la Phase 7 était structurellement
# incapable de trouver quoi que ce soit. scan_media_dirs_for_inodes() injecte
# TOUS les fichiers média de MEDIA_DIRS dans ARR_MANAGED_INODES, et la
# Phase 7 se servait de ce même ensemble comme filtre « déjà connu » — donc
# tout fichier de la bibliothèque était connu par construction, y compris un
# vrai orphelin. Un orphelin de disque se définit par rapport aux fichiers
# que les Arr revendiquent (source "api"), pas par rapport à ce qui traîne
# sur le disque.
declare -A ARR_INODE_SOURCE=()

# Index « taille du fichier → candidats de réparation », construit une seule
# fois en Phase 1 par scan_media_dirs_for_inodes. Chaque ligne d'une entrée
# vaut "device<TAB>inode<TAB>chemin".
#
# Ne contient QUE les fichiers de provenance "api". Un fichier présent dans
# MEDIA_DIRS mais que Radarr/Sonarr ne revendiquent pas est précisément ce
# que la Phase 7 signale comme orphelin de disque : en faire une cible de
# hardlink donnerait un gain fictif (le torrent redeviendrait une copie
# isolée dès la suppression de ce fichier) tout en masquant le fait que
# l'import Arr n'a jamais eu lieu.
declare -A MEDIA_SIZE_INDEX=()
MEDIA_SIZE_INDEX_READY=false

# Inodes présents sous CROSS_SEED_DIR
declare -A CROSS_SEED_INODES=()

# Position des inodes (dans MEDIA_DIRS ou CROSS_SEED_DIR)
declare -A INODE_IN_MEDIA=()
declare -A INODE_IN_CROSS=()

# Batches de tags à appliquer par instance
declare -A TAG_BATCHES=()
# Garde d'unicité pour batch_add (clé "instance|tag|hash").
# CORRECTION : la Phase 2 classe un torrent puis l'écrit dans TORRENT_CACHE,
# et la Phase 4 relit ce cache tout juste écrit et refait un batch_add — le
# même hash se retrouvait donc deux fois dans le lot. La Phase 9 dédoublonne
# avec `sort -u`, mais la Phase 5 itère la chaîne brute : chaque torrent
# partiel était réparé deux fois, gonflant repaired_count et orphan_count.
declare -A BATCH_SEEN=()

# Initialisation des batches pour éviter les variables unbound
for inst in "${INSTANCES[@]}"; do
    for t in "$TAG_LINKED" "$TAG_CROSS_LINKED" "$TAG_PARTIAL" \
             "$TAG_NO_MEDIA" "$TAG_ORPHAN" "$TAG_DELETE"; do
        TAG_BATCHES["${inst}|${t}"]=""
    done
done

# Fichiers de cache
HASH_CMD=""
HASH_CACHE_FILE="${CACHE_DIR}/hash_cache.txt"
HASH_JOURNAL_FILE="${CACHE_DIR}/hash_journal.txt"
INODE_CACHE_FILE="${CACHE_DIR}/inode_status.txt"
TORRENT_CACHE_FILE="${CACHE_DIR}/torrent_status.txt"
ARR_INODES_FILE="${CACHE_DIR}/arr_inodes.txt"
# Un arr_inodes.txt écrit par une version antérieure n'a pas la colonne de
# provenance : impossible d'y distinguer "api" de "scan". On force alors une
# réinterrogation de l'API plutôt que de deviner (deviner "scan" ferait
# remonter toute la bibliothèque en orphelins de disque au premier run).
ARR_CACHE_LEGACY=false

# Seuils
HASH_MERGE_THRESHOLD=50
HASH_CACHE_DIRTY=0
TORRENT_CACHE_DURATION="${TORRENT_CACHE_DURATION:-3600}"

# Fichiers temporaires globaux (nettoyés par trap)
ALL_FILES_TMP=""
UNCACHED_TMP=""

# -----------------------------------------------------------------------------
# OPTIONS DE LIGNE DE COMMANDE
# -----------------------------------------------------------------------------
NO_CACHE=false
DRY_RUN=false
DEBUG=false
FULL_HASH=false

print_usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [OPTIONS]

Options :
  --use-no-cache   Ignore tous les caches sur disque (hash, inodes, statut
                    des torrents, inodes Arr, liste qBittorrent) et force
                    une analyse complète depuis zéro. Les caches sont tout
                    de même réécrits en fin d'exécution pour les prochains runs.
  --dry-run        Simulation : toute l'analyse et la classification
                    s'exécutent normalement, mais aucune écriture réelle
                    n'est effectuée — ni hardlink/chown sur le filesystem,
                    ni tag ajouté/retiré dans qBittorrent. Force AUTO_REPAIR
                    à true le temps du run pour prévisualiser les réparations
                    qui seraient tentées, sans jamais les appliquer.
  --full-hash      Phase 5 (réparation) : exige une confirmation par hash
                    complet avant de créer un hardlink, en plus du hash
                    rapide (échantillonné) utilisé par défaut. Plus lent sur
                    de gros fichiers, mais élimine le risque — infinitésimal
                    mais non nul — qu'un hash rapide identique corresponde à
                    des fichiers réellement différents. Sans effet sur les
                    petits fichiers (déjà vérifiés en entier dans les deux cas).
  --debug          Affiche des informations de diagnostic détaillées sur
                    stderr (préfixées "🐛 [DEBUG]") : requêtes API qBittorrent/
                    Arr avec code HTTP, traduction de chemins, diagnostic complet
                    de chaque tentative de hardlink, hashs comparés en Phase 5.
                    N'affecte pas la sortie normale (stdout) du script — pratique
                    pour rediriger : ./check_hardlinks.sh --debug 2> debug.log
  -h, --help       Affiche cette aide et quitte.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --use-no-cache) NO_CACHE=true ;;
        --dry-run) DRY_RUN=true ;;
        --full-hash) FULL_HASH=true ;;
        --debug) DEBUG=true ;;
        -h|--help) print_usage; exit 0 ;;
        *)
            printf '❌ Option inconnue : %s\n\n' "$arg" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

# Log de diagnostic (silencieux sauf --debug), toujours sur stderr pour ne
# jamais polluer la sortie normale ni les valeurs retournées par les
# fonctions qui impriment leur résultat sur stdout (ex. translate_path).
debug_log() {
    $DEBUG && printf '   🐛 [DEBUG] %s\n' "$*" >&2
    return 0
}

if $NO_CACHE; then
    TORRENT_CACHE_DURATION=0
    ARR_CACHE_DURATION=0
fi

# En dry-run, on force AUTO_REPAIR pour que le script exécute (en simulation)
# toute la logique de réparation et montre ce qui serait fait.
if $DRY_RUN; then
    AUTO_REPAIR=true
fi

# -----------------------------------------------------------------------------
# VERROU (empêche deux exécutions simultanées)
# -----------------------------------------------------------------------------
# Deux runs en parallèle (cron qui se chevauche, lancement manuel pendant un
# cron, etc.) peuvent se marcher dessus sur les caches, les tags qBittorrent
# et les réparations par hardlink. On prend un verrou non bloquant : si une
# autre instance tourne déjà, on quitte immédiatement plutôt que d'attendre
# ou de risquer une exécution concurrente.
if ! command -v flock &>/dev/null; then
    echo "❌ flock requis (paquet util-linux)."
    exit 1
fi
LOCK_FILE="${CACHE_DIR}/check_hardlinks.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "❌ Une autre instance de check_hardlinks.sh tourne déjà (verrou : $LOCK_FILE)."
    echo "   Si vous êtes certain qu'aucune autre instance ne tourne, supprimez ce fichier."
    exit 1
fi

# -----------------------------------------------------------------------------
# SIGNAL HANDLER
# -----------------------------------------------------------------------------
# CORRECTION : le trap EXIT et le trap SIGINT/SIGTERM/SIGHUP partageaient la
# même fonction, qui affichait TOUJOURS « Interruption » et forçait `exit 1`
# — y compris sur une fin de script normale et réussie. Résultat : impossible
# de distinguer un Ctrl+C d'une fin normale, et le code de sortie était
# toujours 1. On sépare maintenant les deux cas, avec un garde-fou pour
# n'exécuter la sauvegarde qu'une seule fois.
CLEANUP_DONE=false

# Sauvegarde groupée de tous les caches disque + nettoyage des fichiers
# temporaires. Appelée aussi bien en fin de run normale qu'en cas d'interruption.
# Appelée indirectement (trap) — d'où la désactivation de SC2317.
# shellcheck disable=SC2317
save_all_caches() {
    save_hash_cache_merge
    save_torrent_list_cache
    save_arr_inodes_bulk
    save_inode_cache_bulk
    save_torrent_cache_bulk
    rm -f "$ALL_FILES_TMP" "${UNCACHED_TMP}" "${UNCACHED_TMP}.sorted" 2>/dev/null
    [ -n "$SCAN_MEMO_DIR" ] && rm -rf "$SCAN_MEMO_DIR" 2>/dev/null
    return 0
}

# Interruption explicite (Ctrl+C, kill, déconnexion du terminal)
# Appelée indirectement (trap) — d'où la désactivation de SC2317.
# shellcheck disable=SC2317
cleanup_on_signal() {
    $CLEANUP_DONE && return
    CLEANUP_DONE=true
    echo ""
    echo "⚠️  Interruption — sauvegarde des caches..."
    save_all_caches
    exit 130
}

# Fin de script (normale OU après cleanup_on_signal) : sauvegarde silencieuse,
# sans écraser le code de sortie déjà déterminé.
# Appelée indirectement (trap) — d'où la désactivation de SC2317.
# shellcheck disable=SC2317
cleanup_on_exit() {
    $CLEANUP_DONE && return
    CLEANUP_DONE=true
    save_all_caches
}

trap cleanup_on_signal SIGINT SIGTERM SIGHUP
trap cleanup_on_exit EXIT

# -----------------------------------------------------------------------------
# UTILITAIRES
# -----------------------------------------------------------------------------

# ID du filesystem (device) pour vérifier qu'un hardlink est possible
get_fs_id() { stat -c '%d' "$1" 2>/dev/null || echo "0"; }

# Échappe une valeur pour l'insérer dans un fichier de config curl (-K -),
# utilisé pour passer mots de passe / clés API à curl via stdin plutôt qu'en
# argument de ligne de commande — un argument de ligne de commande est
# visible en clair (le temps de l'appel) par tout autre utilisateur local via
# `ps aux` ou `/proc/<pid>/cmdline`.
_curl_cfg_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Chown optionnel si les fichiers créés doivent appartenir à un utilisateur
do_chown() {
    $DRY_RUN && return 0
    $CHOWN_FILES || return 0
    chown "$CHOWN_USER" "$1" 2>/dev/null || true
}

# Sélection du meilleur outil de hachage disponible
pick_hash_tool() {
    if command -v xxh128sum &>/dev/null; then      HASH_CMD="xxh128sum"
    elif command -v xxh64sum &>/dev/null; then     HASH_CMD="xxh64sum"
    elif command -v md5sum &>/dev/null; then       HASH_CMD="md5sum"
    else
        echo "❌ Aucun outil de hachage trouvé (xxh128sum/xxh64sum/md5sum requis)."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# PARCOURS DE RÉPERTOIRES (Python, un seul processus au lieu de find+stat)
# -----------------------------------------------------------------------------
# CORRECTION PERF : le script appelait auparavant `find` puis un `stat`
# externe PAR FICHIER trouvé pour récupérer son inode — sur une bibliothèque
# de plusieurs milliers de fichiers, ça fait des milliers de fork+exec rien
# que pour lire des métadonnées (souvent déjà en cache disque/ARR ZFS, donc
# le vrai coût est le spawn de processus, pas l'accès disque lui-même). Ces
# trois fonctions font le parcours ET le stat en un seul processus Python
# (os.walk + os.lstat), et retournent des lignes "inode<TAB>taille<TAB>chemin".
#
# Limite assumée : le chemin (dernier champ) peut contenir des tabulations
# sans casser le parsing (`read` avec IFS=tab absorbe le reste de la ligne
# dans la dernière variable), mais PAS un retour à la ligne — cas
# infinitésimal pour des noms de fichiers média réels, comme le reste du
# script (caches internes déjà en TSV/pipe-delimited).

# Extensions vidéo reconnues, utilisées à plusieurs endroits (Phases 2-5,
# scan des médias/cross-seed) — centralisées ici pour éviter la répétition.
MEDIA_EXTENSIONS_CSV="mkv,mp4,avi,ts,m4v,mov,wmv,flv,webm"

# Parcourt un ou plusieurs répertoires, filtré par extensions (CSV sans point,
# insensible à la casse) ou sans filtre si la liste est vide. Seuls les
# fichiers réguliers sont retournés (comme `find -type f`, les liens
# symboliques sont exclus, pas suivis lors du parcours).
scan_files() {
    local exts_csv="$1"; shift
    [ "$#" -eq 0 ] && return 0
    python3 -c "
import os, stat, sys

exts_csv = sys.argv[1]
exts = {'.' + e.strip().lower() for e in exts_csv.split(',') if e.strip()} if exts_csv else None
for root in sys.argv[2:]:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            if exts is not None and os.path.splitext(name)[1].lower() not in exts:
                continue
            full = os.path.join(dirpath, name)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            print(f'{st.st_ino}\t{st.st_size}\t{full}')
" "$exts_csv" "$@"
}

# Mémoïsation du parcours des fichiers média d'un torrent : le même
# répertoire est parcouru par les Phases 2, 3, 4 ET 5 au cours d'un même run,
# soit jusqu'à quatre parcours identiques par torrent orphelin.
#
# Le mémo est sur DISQUE et non dans un tableau bash : ces parcours sont
# consommés via une substitution de processus (`done < <(...)`), qui exécute
# la fonction dans un sous-shell — un tableau associatif modifié là serait
# perdu au retour, et la mémoïsation n'aurait servi à rien. Un fichier, lui,
# est bien visible par le shell parent au parcours suivant.
#
# Clé = hash du torrent : déjà unique, déjà hexadécimal, donc utilisable tel
# quel comme nom de fichier sans échappement ni risque de collision.
SCAN_MEMO_DIR=""

scan_torrent_files() {
    local hash="$1" hpath="$2"
    if [ -z "$SCAN_MEMO_DIR" ]; then
        scan_files "$MEDIA_EXTENSIONS_CSV" "$hpath"
        return 0
    fi
    local memo="${SCAN_MEMO_DIR}/${hash}"
    # -f et non -s : un torrent sans fichier média donne un mémo vide, qu'il
    # ne faut pas reconstruire à chaque phase.
    [ -f "$memo" ] || scan_files "$MEDIA_EXTENSIONS_CSV" "$hpath" > "$memo"
    cat "$memo"
}

# Invalide le mémo (après la Phase 5, qui remplace des fichiers par des
# hardlinks et change donc leurs inodes).
reset_scan_memo() {
    [ -n "$SCAN_MEMO_DIR" ] && [ -d "$SCAN_MEMO_DIR" ] && rm -f "${SCAN_MEMO_DIR:?}"/* 2>/dev/null
    return 0
}

# Variante filtrée par taille exacte (octets), sans filtre d'extension —
# utilisée par try_repair_file pour chercher des candidats de même taille
# qu'un fichier orphelin dans toute la bibliothèque.
scan_files_by_size() {
    local size="$1"; shift
    [ "$#" -eq 0 ] && return 0
    python3 -c "
import os, stat, sys

target_size = int(sys.argv[1])
for root in sys.argv[2:]:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode) or st.st_size != target_size:
                continue
            print(f'{st.st_ino}\t{st.st_size}\t{full}')
" "$size" "$@"
}

# Stat en lot une liste de chemins (un par ligne sur stdin, pour éviter toute
# limite ARG_MAX sur de grosses listes) : retourne "inode<TAB>chemin" pour
# chaque chemin qui existe encore.
# os.lstat (et non os.stat) pour rester cohérent avec scan_files : un lien
# symbolique doit rapporter son propre inode, jamais celui de sa cible —
# sinon un symlink de la bibliothèque ferait passer sa cible pour un fichier
# géré par les Arr.
stat_paths_bulk() {
    python3 -c "
import os, sys
for line in sys.stdin:
    path = line.rstrip('\n')
    if not path:
        continue
    try:
        st = os.lstat(path)
    except OSError:
        continue
    print(f'{st.st_ino}\t{path}')
"
}

# -----------------------------------------------------------------------------
# TRANSLATION DE CHEMINS (Docker → Hôte)
# -----------------------------------------------------------------------------
# Les containers qBittorrent voient /data/completed, l'hôte voit /mnt/tank/...
# PATH_MAP fait ce pont de manière bidirectionnelle.
# CORRECTION : parcours trié par préfixe le plus long d'abord pour éviter
# qu'un préfixe court masque un préfixe plus spécifique.
# Le tri est calculé une seule fois et mis en cache : PATH_MAP ne change
# jamais après le chargement de la config, alors que translate_path() est
# appelée des milliers de fois (une fois par torrent, par fichier, ...).
# Recalculer le tri (awk|sort|cut, donc 3 forks) à chaque appel faisait
# gonfler le temps de chargement du cache torrents de manière très visible.
PATH_MAP_SORTED_PREFIXES=()
PATH_MAP_SORTED_READY=false

_init_path_map_sorted_prefixes() {
    $PATH_MAP_SORTED_READY && return
    PATH_MAP_SORTED_READY=true
    local prefix
    for prefix in "${!PATH_MAP[@]}"; do
        PATH_MAP_SORTED_PREFIXES+=("$prefix")
    done
    [ "${#PATH_MAP_SORTED_PREFIXES[@]}" -eq 0 ] && return
    local sorted=() line
    while IFS= read -r line; do
        sorted+=("$line")
    done < <(printf '%s\n' "${PATH_MAP_SORTED_PREFIXES[@]}" | awk '{print length, $0}' | sort -nr | cut -d' ' -f2-)
    PATH_MAP_SORTED_PREFIXES=("${sorted[@]}")
}

translate_path() {
    local container_path="$1"

    # Si le chemin est déjà un chemin hôte, on le retourne tel quel
    if [[ "$container_path" == /mnt/* ]] || [[ "$container_path" == /tank/* ]]; then
        printf '%s' "$container_path"
        return
    fi

    _init_path_map_sorted_prefixes

    local host_path="$container_path"
    local container_prefix matched=""
    for container_prefix in "${PATH_MAP_SORTED_PREFIXES[@]}"; do
        if [[ "$container_path" == "$container_prefix"/* ]]; then
            # Préfixe entre guillemets DANS l'expansion : sans ça, un chemin
            # PATH_MAP contenant *, ? ou [ serait interprété comme un motif
            # au lieu d'un littéral, et retirerait la mauvaise portion.
            local suffix="${container_path#"$container_prefix"/}"
            host_path="${PATH_MAP[$container_prefix]%/}/${suffix}"
            matched="$container_prefix"
            break
        elif [[ "$container_path" == "$container_prefix" ]]; then
            host_path="${PATH_MAP[$container_prefix]}"
            host_path="${host_path%/}"
            matched="$container_prefix"
            break
        fi
    done
    if $DEBUG; then
        if [ -n "$matched" ]; then
            debug_log "translate_path : $container_path (préfixe PATH_MAP[$matched]) → $host_path"
        else
            debug_log "translate_path : $container_path → $host_path (aucun préfixe PATH_MAP ne correspond, inchangé)"
        fi
    fi
    printf '%s' "$host_path"
}

# -----------------------------------------------------------------------------
# NORMALISATION DES NOMS DE FICHIERS
# -----------------------------------------------------------------------------
# Permet de comparer "The.Movie.2023.1080p.mkv" et "Movie.2023.mkv"
# en retirant les stopwords, la casse, et l'année.
normalize_name() {
    local name="$1"
    local base="${name%.*}"
    base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr '._[](){}-' ' ' | tr -s ' ')
    base=$(printf '%s' "$base" | sed -E 's/ [0-9]{4} / /g; s/^[0-9]{4} //; s/ [0-9]{4}$//')

    local result=" $base "
    local w
    for w in "${STOPWORDS[@]}"; do
        result="${result// $w / }"
    done
    result=$(printf '%s' "$result" | sed -E 's/ [a-z]{3,}$//; s/ [a-z]{3,} [a-z]{3,}$//')
    result=$(printf '%s' "$result" | sed 's/^ *//; s/ *$//')
    printf '%s' "$result"
}

# Retourne : exact, partial, ou none
name_similarity() {
    local n1 n2
    n1=$(normalize_name "$1")
    n2=$(normalize_name "$2")
    [ -z "$n1" ] || [ -z "$n2" ] && { echo "none"; return 1; }
    [ "$n1" = "$n2" ] && { echo "exact"; return 0; }
    [[ "$n1" == *"$n2"* ]] || [[ "$n2" == *"$n1"* ]] && { echo "partial"; return 0; }
    local f1="${n1%% *}" f2="${n2%% *}"
    [ -n "$f1" ] && [ "$f1" = "$f2" ] && { echo "partial"; return 0; }
    local y1 y2
    y1=$(printf '%s' "$n1" | grep -oE '[0-9]{4}' | head -1)
    y2=$(printf '%s' "$n2" | grep -oE '[0-9]{4}' | head -1)
    [ -n "$y1" ] && [ "$y1" = "$y2" ] && { echo "partial"; return 0; }
    echo "none"; return 1
}

# =============================================================================
# CACHES DISQUE (résilience face aux interruptions)
# =============================================================================

# --- Cache de hachage (fichier → hash) ---
load_hash_cache() {
    HASH_CACHE=()
    if [ -f "$HASH_CACHE_FILE" ]; then
        while IFS='|' read -r key ts size hash; do
            [ -z "$key" ] && continue
            HASH_CACHE["$key"]="${ts}|${size}|${hash}"
        done < "$HASH_CACHE_FILE"
    fi
    if [ -f "$HASH_JOURNAL_FILE" ]; then
        while IFS='|' read -r key ts size hash; do
            [ -z "$key" ] && continue
            HASH_CACHE["$key"]="${ts}|${size}|${hash}"
        done < "$HASH_JOURNAL_FILE"
        rm -f "$HASH_JOURNAL_FILE"
    fi
}

# Écriture incrémentale (journal) puis fusion périodique
save_hash_entry() {
    local filepath="$1"
    local cached="${HASH_CACHE[$filepath]:-}"
    [ -z "$cached" ] && return
    printf '%s|%s\n' "$filepath" "$cached" >> "$HASH_JOURNAL_FILE"
    HASH_CACHE_DIRTY=$((HASH_CACHE_DIRTY + 1))
    [ "$HASH_CACHE_DIRTY" -ge "$HASH_MERGE_THRESHOLD" ] && save_hash_cache_merge
}

save_hash_cache_merge() {
    [ "$HASH_CACHE_DIRTY" -eq 0 ] && [ ! -f "$HASH_JOURNAL_FILE" ] && return
    if [ -f "$HASH_JOURNAL_FILE" ] && [ -s "$HASH_JOURNAL_FILE" ]; then
        while IFS='|' read -r key ts size hash; do
            [ -z "$key" ] && continue
            HASH_CACHE["$key"]="${ts}|${size}|${hash}"
        done < "$HASH_JOURNAL_FILE"
        rm -f "$HASH_JOURNAL_FILE"
    fi
    local tmpfile="${HASH_CACHE_FILE}.$$"
    : > "$tmpfile"
    local key
    for key in "${!HASH_CACHE[@]}"; do
        printf '%s|%s\n' "$key" "${HASH_CACHE[$key]}" >> "$tmpfile"
    done
    mv "$tmpfile" "$HASH_CACHE_FILE" 2>/dev/null
    HASH_CACHE_DIRTY=0
}

get_cached_hash() {
    local filepath="$1"
    [ ! -f "$filepath" ] && return 1
    local cached="${HASH_CACHE[$filepath]:-}"
    [ -z "$cached" ] && return 1
    local size
    size=$(stat -c '%s' "$filepath" 2>/dev/null) || return 1
    local cached_size="${cached#*|}"
    cached_size="${cached_size%%|*}"
    [ "$cached_size" != "$size" ] && return 1
    printf '%s' "${cached##*|}"
    return 0
}

set_cached_hash() {
    local filepath="$1" hash="$2"
    local ts size
    ts=$(date +%s)
    size=$(stat -c '%s' "$filepath" 2>/dev/null) || return 1
    HASH_CACHE["$filepath"]="${ts}|${size}|${hash}"
}

file_hash() {
    local filepath="$1"
    local cached
    cached=$(get_cached_hash "$filepath")
    [ -n "$cached" ] && printf '%s' "$cached" && return 0
    [ -z "$HASH_CMD" ] && return 1
    local hash
    hash=$("$HASH_CMD" "$filepath" 2>/dev/null | cut -d' ' -f1)
    [ -z "$hash" ] && return 1
    set_cached_hash "$filepath" "$hash"
    save_hash_entry "$filepath"
    printf '%s' "$hash"
    return 0
}

# CORRECTION PERF : pré-filtre avant un hash complet. Hash "rapide" d'un
# fichier basé sur 3 échantillons (début / milieu / fin, ~1 Mo chacun) au
# lieu de lire tout le fichier. Utilisé par try_repair_file pour écarter en
# quelques millisecondes les candidats de même taille mais de contenu
# différent, sans lire des Go de données par candidat testé — le hash
# complet (file_hash, mis en cache) n'est ensuite recalculé que pour
# confirmer une correspondance déjà trouvée par échantillonnage, jamais pour
# rejeter un candidat. Deux fichiers identiques ont forcément les mêmes
# échantillons (aucun faux négatif possible) ; un éventuel faux positif est
# rattrapé par la confirmation en hash complet avant toute action.
# Pas de cache disque dédié : déjà assez rapide pour être recalculé à chaque
# appel (contrairement au hash complet, qui lui reste mis en cache).
QUICK_HASH_SAMPLE_SIZE=$((1024 * 1024))

quick_file_hash() {
    local filepath="$1" fsize="$2"
    [ -z "$HASH_CMD" ] && return 1

    # Fichier assez petit pour que l'échantillonnage n'apporte rien : autant
    # faire directement un hash complet (et profiter de son cache).
    if [ "$fsize" -le "$((QUICK_HASH_SAMPLE_SIZE * 3))" ]; then
        file_hash "$filepath"
        return $?
    fi

    local mid_skip=$(( (fsize / 2) / QUICK_HASH_SAMPLE_SIZE ))
    local end_skip=$(( (fsize - QUICK_HASH_SAMPLE_SIZE) / QUICK_HASH_SAMPLE_SIZE ))

    local hash
    hash=$({
        dd if="$filepath" bs="$QUICK_HASH_SAMPLE_SIZE" count=1 skip=0 2>/dev/null
        dd if="$filepath" bs="$QUICK_HASH_SAMPLE_SIZE" count=1 skip="$mid_skip" 2>/dev/null
        dd if="$filepath" bs="$QUICK_HASH_SAMPLE_SIZE" count=1 skip="$end_skip" 2>/dev/null
    } | "$HASH_CMD" 2>/dev/null | cut -d' ' -f1)
    [ -z "$hash" ] && return 1
    printf '%s' "$hash"
    return 0
}

# --- Cache d'inodes (position : media/cross/inconnu) ---
load_inode_cache() {
    INODE_STATUS_CACHE=()
    INODE_SAMPLE_PATH=()
    [ ! -f "$INODE_CACHE_FILE" ] && return
    local inode status sample_path ci
    while IFS='|' read -r inode status sample_path _; do
        [ -z "$inode" ] && continue
        # Vérification : le fichier sample existe-t-il encore avec le même inode ?
        if [ -n "$sample_path" ] && [ -f "$sample_path" ]; then
            ci=$(stat -c '%i' "$sample_path" 2>/dev/null || echo "0")
            if [ "$ci" = "$inode" ]; then
                INODE_STATUS_CACHE["$inode"]="$status"
                INODE_SAMPLE_PATH["$inode"]="$sample_path"
            fi
        fi
    done < "$INODE_CACHE_FILE"
    printf '   📦 Cache inodes : %d entrées\n' "${#INODE_STATUS_CACHE[@]}"
}

# Écriture incrémentale (append) d'une entrée du cache d'inodes ; la
# réécriture complète et propre du fichier se fait via save_inode_cache_bulk.
# CORRECTION : on alimente aussi le cache EN MÉMOIRE. Sans ça, les inodes
# découverts pendant ce run n'existaient que dans les lignes appendées au
# fichier — que save_inode_cache_bulk écrasait ensuite intégralement (`mv`)
# en n'y remettant que les entrées chargées au démarrage. Les découvertes du
# run étaient donc systématiquement perdues.
save_inode_entry() {
    local inode="$1" status="$2" sample_path="$3"
    INODE_STATUS_CACHE["$inode"]="$status"
    INODE_SAMPLE_PATH["$inode"]="$sample_path"
    printf '%s|%s|%s|%s\n' "$inode" "$status" "$sample_path" "$(date +%s)" >> "$INODE_CACHE_FILE"
}

# Sauvegarde atomique complète du cache d'inodes (remplace les append infinis)
save_inode_cache_bulk() {
    [ "${#INODE_STATUS_CACHE[@]}" -eq 0 ] && return
    local tmpfile="${INODE_CACHE_FILE}.$$"
    : > "$tmpfile"
    local inode now sample
    now=$(date +%s)
    for inode in "${!INODE_STATUS_CACHE[@]}"; do
        # CORRECTION : le fichier témoin DOIT être réécrit. Il était laissé
        # vide ici, alors que load_inode_cache rejette toute entrée sans
        # témoin existant : l'intégralité du cache était donc invalidée au
        # rechargement suivant (« Cache inodes : 0 entrées » à chaque run) et
        # la Phase 3 réanalysait tout à chaque fois.
        sample="${INODE_SAMPLE_PATH[$inode]:-}"
        [ -z "$sample" ] && continue
        printf '%s|%s|%s|%s\n' "$inode" "${INODE_STATUS_CACHE[$inode]}" "$sample" "$now" >> "$tmpfile"
    done
    mv "$tmpfile" "$INODE_CACHE_FILE" 2>/dev/null
}

# --- Cache de statut des torrents ---
# CORRECTION : application effective du TTL. Le timestamp était écrit et
# relu, mais jamais confronté à une durée de validité — les statuts
# « no_media », « orphan » et « delete_ready » (que les Phases 3 et 4
# court-circuitent depuis le cache) étaient donc définitifs. On filtre les
# entrées périmées ici, en un seul point : les trois phases les voient alors
# naturellement comme absentes et reclassifient le torrent de zéro.
load_torrent_cache() {
    TORRENT_CACHE=()
    [ ! -f "$TORRENT_CACHE_FILE" ] && return
    local hash instance status timestamp now expired=0
    now=$(date +%s)
    while IFS='|' read -r hash instance status timestamp; do
        [ -z "$hash" ] && continue
        if [[ "$timestamp" =~ ^[0-9]+$ ]] && \
           [ "$TORRENT_STATUS_TTL" -gt 0 ] && \
           [ "$((now - timestamp))" -ge "$TORRENT_STATUS_TTL" ]; then
            expired=$((expired + 1))
            continue
        fi
        TORRENT_CACHE["${hash}|${instance}"]="${status}|${timestamp}"
    done < "$TORRENT_CACHE_FILE"
    if [ "$expired" -gt 0 ]; then
        printf '   📦 Cache torrents : %d entrées (%d périmée(s) ignorée(s))\n' \
            "${#TORRENT_CACHE[@]}" "$expired"
    else
        printf '   📦 Cache torrents : %d entrées\n' "${#TORRENT_CACHE[@]}"
    fi
}

save_torrent_entry() {
    local hash="$1" instance="$2" status="$3"
    local ts
    ts=$(date +%s)
    # CORRECTION : mettre aussi à jour le cache en mémoire, pas seulement le
    # fichier. Sans ça, un torrent classifié "linked" en Phase 2 n'était pas
    # reconnu comme déjà traité par les Phases 3/4 du même run, qui le
    # reclassifiaient (à tort) en "orphelin".
    TORRENT_CACHE["${hash}|${instance}"]="${status}|${ts}"
    printf '%s|%s|%s|%s\n' "$hash" "$instance" "$status" "$ts" >> "$TORRENT_CACHE_FILE"
}


# --- Cache de la liste des torrents qBittorrent ---
TORRENT_LIST_FILE="${CACHE_DIR}/torrent_list.txt"

load_torrent_list_cache() {
    TORRENT_NAMES=()
    TORRENT_INSTANCE=()
    TORRENT_SAVE_PATH=()
    TORRENT_HOST_PATH=()
    TORRENT_TRACKER=()
    TORRENT_SEEDING_TIME=()
    [ ! -f "$TORRENT_LIST_FILE" ] && return 1

    local now age
    now=$(date +%s)
    age=$(( now - $(stat -c '%Y' "$TORRENT_LIST_FILE" 2>/dev/null || echo 0) ))
    [ "$age" -ge "$TORRENT_CACHE_DURATION" ] && return 1

    # tracker/seeding_time peuvent être absents (anciens fichiers de cache) :
    # ils resteront vides, ce qui déclenche le repli sur l'appel API en Phase 6.
    local hash instance name save_path size tracker seeding_time translated hpath
    while IFS='|' read -r hash instance name save_path size tracker seeding_time; do
        [ -z "$hash" ] && continue
        hash="${hash^^}"
        translated=$(translate_path "$save_path")
        hpath="${translated}/${name}"
        TORRENT_NAMES["$hash"]="$name"
        TORRENT_INSTANCE["$hash"]="$instance"
        TORRENT_SAVE_PATH["$hash"]="$save_path"
        TORRENT_HOST_PATH["$hash"]="$hpath"
        TORRENT_TRACKER["$hash"]="$tracker"
        TORRENT_SEEDING_TIME["$hash"]="$seeding_time"
    done < "$TORRENT_LIST_FILE"

    printf '   📦 Cache torrents qBittorrent : %d entrées (%ss)\n' \
        "${#TORRENT_NAMES[@]}" "$age"
    return 0
}

save_torrent_list_cache() {
    [ "${#TORRENT_NAMES[@]}" -eq 0 ] && return
    local tmpfile="${TORRENT_LIST_FILE}.$$"
    : > "$tmpfile"
    local hash
    for hash in "${!TORRENT_NAMES[@]}"; do
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$hash" "${TORRENT_INSTANCE[$hash]}" "${TORRENT_NAMES[$hash]}" \
            "${TORRENT_SAVE_PATH[$hash]}" "0" \
            "${TORRENT_TRACKER[$hash]:-}" "${TORRENT_SEEDING_TIME[$hash]:-}" >> "$tmpfile"
    done
    mv "$tmpfile" "$TORRENT_LIST_FILE" 2>/dev/null
}


# Sauvegarde atomique complète du cache torrent (remplace les append infinis)
# CORRECTION : purge des torrents qui n'existent plus dans qBittorrent. Le
# fichier n'était jamais élagué et grossissait indéfiniment, run après run,
# en conservant des hashes supprimés depuis longtemps.
# La purge n'a lieu que si la liste des torrents a bien été récupérée : en
# cas d'interruption avant la Phase 0, TORRENT_NAMES est vide et tout élaguer
# reviendrait à effacer le cache.
save_torrent_cache_bulk() {
    [ "${#TORRENT_CACHE[@]}" -eq 0 ] && return
    local prune=false
    [ "${#TORRENT_NAMES[@]}" -gt 0 ] && prune=true
    local tmpfile="${TORRENT_CACHE_FILE}.$$"
    : > "$tmpfile"
    local key hash_part
    for key in "${!TORRENT_CACHE[@]}"; do
        if $prune; then
            hash_part="${key%%|*}"
            [ -z "${TORRENT_NAMES[$hash_part]+set}" ] && continue
        fi
        printf '%s|%s\n' "$key" "${TORRENT_CACHE[$key]}" >> "$tmpfile"
    done
    mv "$tmpfile" "$TORRENT_CACHE_FILE" 2>/dev/null
}

# --- Cache des inodes Arr ---
# Format : inode|chemin|provenance   (provenance = "api" ou "scan")
load_arr_inodes() {
    ARR_MANAGED_INODES=()
    ARR_INODE_SOURCE=()
    ARR_CACHE_LEGACY=false
    [ ! -f "$ARR_INODES_FILE" ] && return
    local inode path src
    while IFS='|' read -r inode path src; do
        [ -z "$inode" ] && continue
        [ -f "$path" ] || continue
        if [ -z "$src" ]; then
            # Fichier écrit par une version antérieure, sans provenance.
            ARR_CACHE_LEGACY=true
            src="scan"
        fi
        ARR_MANAGED_INODES["$inode"]="$path"
        ARR_INODE_SOURCE["$inode"]="$src"
    done < "$ARR_INODES_FILE"
    if $ARR_CACHE_LEGACY; then
        printf "   📦 Cache Arr inodes : %d entrées (format obsolète → réinterrogation de l’API)\n" \
            "${#ARR_MANAGED_INODES[@]}"
    else
        printf '   📦 Cache Arr inodes : %d entrées\n' "${#ARR_MANAGED_INODES[@]}"
    fi
}

save_arr_inodes_bulk() {
    local tmpfile="${ARR_INODES_FILE}.$$"
    : > "$tmpfile"
    local inode
    for inode in "${!ARR_MANAGED_INODES[@]}"; do
        printf '%s|%s|%s\n' "$inode" "${ARR_MANAGED_INODES[$inode]}" \
            "${ARR_INODE_SOURCE[$inode]:-scan}" >> "$tmpfile"
    done
    mv "$tmpfile" "$ARR_INODES_FILE" 2>/dev/null
}

# =============================================================================
# API QBITTORRENT
# =============================================================================

# Retourne "url|user|password" pour l'instance donnée (VPN ou DIRECT).
qbit_vars() {
    local instance="$1"
    case "$instance" in
        VPN)    printf '%s|%s|%s' "${QBIT_VPN_URL}" "${QBIT_VPN_USER}" "${QBIT_VPN_PASS}" ;;
        DIRECT) printf '%s|%s|%s' "${QBIT_DIRECT_URL}" "${QBIT_DIRECT_USER}" "${QBIT_DIRECT_PASS}" ;;
        *)      return 1 ;;
    esac
}

# CORRECTION : reconnexion automatique si le cookie a expiré
qbit_login() {
    local instance="$1"
    local vars
    vars=$(qbit_vars "$instance") || return 1
    IFS='|' read -r url user pass <<< "$vars"
    debug_log "qbit_login [$instance] POST ${url}/api/v2/auth/login (user=${user})"
    local cookie
    # CORRECTION : credentials URL-encodés, passés via -K - (stdin) plutôt
    # qu'en argument de ligne de commande pour ne pas exposer le mot de
    # passe dans `ps aux` le temps de l'appel.
    cookie=$(curl -s -c - -K - --connect-timeout 5 --max-time 10 \
        "${url}/api/v2/auth/login" <<CURLCFG 2>/dev/null | awk '/SID/ {print $NF}'
data-urlencode = "username=$(_curl_cfg_escape "$user")"
data-urlencode = "password=$(_curl_cfg_escape "$pass")"
CURLCFG
)
    if [ -z "$cookie" ]; then
        debug_log "qbit_login [$instance] échec : aucun cookie SID obtenu"
        return 1
    fi
    debug_log "qbit_login [$instance] OK (cookie de ${#cookie} caractères)"
    QBIT_COOKIES["$instance"]="$cookie"
    return 0
}

# CORRECTION PERF : reconnexion réactive (seulement si la session a
# vraiment expiré, HTTP 401/403) au lieu d'un ping système avant CHAQUE
# appel — ça doublait le nombre de requêtes HTTP de tout le script
# (particulièrement sensible en Phase 6, un appel par torrent orphelin).
qbit_get() {
    local instance="$1" path="$2"
    local vars
    vars=$(qbit_vars "$instance") || return 1
    local url="${vars%%|*}"
    debug_log "qbit_get [$instance] GET ${url}${path}"
    local response http_code
    response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 30 \
        -H "Cookie: SID=${QBIT_COOKIES[$instance]:-}" "${url}${path}" 2>/dev/null)
    http_code=$(printf '%s' "$response" | tail -n 1)

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        debug_log "qbit_get [$instance] HTTP $http_code → session expirée, reconnexion"
        qbit_login "$instance" || return 1
        response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 30 \
            -H "Cookie: SID=${QBIT_COOKIES[$instance]}" "${url}${path}" 2>/dev/null)
        http_code=$(printf '%s' "$response" | tail -n 1)
    fi

    if [ "$http_code" != "200" ]; then
        printf '⚠️  qBittorrent [%s] %s → HTTP %s\n' "$instance" "$path" "$http_code" >&2
        return 1
    fi
    debug_log "qbit_get [$instance] HTTP 200, $(printf '%s' "$response" | sed '$d' | wc -c) octet(s) reçus"
    printf '%s' "$response" | sed '$d'
}

# Tags : API qBittorrent exige POST avec champs séparés (pas GET)
qbit_tag_single() {
    local instance="$1" hashes="$2" tag="$3"
    [ -z "$hashes" ] && return
    if $DRY_RUN; then
        printf '   🧪 [DRY-RUN] addTags [%s] « %s » → %d torrent(s) (non appliqué)\n' \
            "$instance" "$tag" "$(printf '%s' "$hashes" | tr '|' '\n' | grep -c .)" >&2
        return
    fi
    local vars
    vars=$(qbit_vars "$instance") || return
    local url="${vars%%|*}"
    debug_log "qbit_tag_single [$instance] POST addTags tags=${tag} sur $(printf '%s' "$hashes" | tr '|' '\n' | grep -c .) hash(es)"
    local response http_code
    response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 30 \
        -H "Cookie: SID=${QBIT_COOKIES[$instance]:-}" \
        --data-urlencode "hashes=${hashes}" \
        --data-urlencode "tags=${tag}" \
        "${url}/api/v2/torrents/addTags" 2>/dev/null)
    http_code=$(printf '%s' "$response" | tail -n 1)

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        qbit_login "$instance" || return
        response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 30 \
            -H "Cookie: SID=${QBIT_COOKIES[$instance]}" \
            --data-urlencode "hashes=${hashes}" \
            --data-urlencode "tags=${tag}" \
            "${url}/api/v2/torrents/addTags" 2>/dev/null)
        http_code=$(printf '%s' "$response" | tail -n 1)
    fi

    if [ "$http_code" != "200" ]; then
        printf '⚠️  addTags [%s] « %s » → HTTP %s\n' "$instance" "$tag" "$http_code" >&2
    else
        debug_log "qbit_tag_single [$instance] HTTP 200"
    fi
}

# Retire un ou plusieurs tags (liste séparée par des virgules) d'un lot de
# torrents (hashes séparés par "|"). Ne PAS appeler directement sur un grand
# nombre de torrents : passer par remove_tags_batches() qui découpe par lots.
qbit_remove_tags() {
    local instance="$1" hashes="$2" tags="$3"
    [ -z "$hashes" ] || [ -z "$tags" ] && return
    if $DRY_RUN; then
        printf '   🧪 [DRY-RUN] removeTags [%s] « %s » → %d torrent(s) (non appliqué)\n' \
            "$instance" "$tags" "$(printf '%s' "$hashes" | tr '|' '\n' | grep -c .)" >&2
        return
    fi
    local vars
    vars=$(qbit_vars "$instance") || return
    local url="${vars%%|*}"
    debug_log "qbit_remove_tags [$instance] POST removeTags tags=${tags} sur $(printf '%s' "$hashes" | tr '|' '\n' | grep -c .) hash(es)"
    local response http_code
    response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 30 \
        -H "Cookie: SID=${QBIT_COOKIES[$instance]:-}" \
        --data-urlencode "hashes=${hashes}" \
        --data-urlencode "tags=${tags}" \
        "${url}/api/v2/torrents/removeTags" 2>/dev/null)
    http_code=$(printf '%s' "$response" | tail -n 1)

    if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
        qbit_login "$instance" || return
        response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 30 \
            -H "Cookie: SID=${QBIT_COOKIES[$instance]}" \
            --data-urlencode "hashes=${hashes}" \
            --data-urlencode "tags=${tags}" \
            "${url}/api/v2/torrents/removeTags" 2>/dev/null)
        http_code=$(printf '%s' "$response" | tail -n 1)
    fi

    if [ "$http_code" != "200" ]; then
        printf '⚠️  removeTags [%s] → HTTP %s\n' "$instance" "$http_code" >&2
    else
        debug_log "qbit_remove_tags [$instance] HTTP 200"
    fi
}

# batch_add/batch_remove n'accumulent QUE la liste en mémoire (TAG_BATCHES),
# sans appel API : c'est apply_tag_batches/remove_tags_batches qui envoient
# réellement les requêtes à qBittorrent, par lots de 90 (l'API en accepte
# ~100 par requête).
# CORRECTION : ajout idempotent. Un même hash pouvait être inséré deux fois
# dans le même lot (Phase 2 classe et met en cache, Phase 4 relit ce cache et
# réinsère). La Phase 9 dédoublonnait bien avec `sort -u`, mais la Phase 5
# itère la chaîne brute et réparait donc deux fois chaque torrent partiel.
batch_add() {
    local inst="$1" tag="$2" hash="$3"
    local seen_key="${inst}|${tag}|${hash}"
    [ -n "${BATCH_SEEN[$seen_key]:-}" ] && return
    BATCH_SEEN["$seen_key"]=1
    TAG_BATCHES["${inst}|${tag}"]="${TAG_BATCHES[${inst}|${tag}]}${hash} "
}

# Retire un hash d'un lot déjà accumulé (ex. un orphelin réparé qui doit
# sortir du lot TAG_ORPHAN avant d'entrer dans TAG_LINKED).
batch_remove() {
    local inst="$1" tag="$2" hash="$3"
    local current="${TAG_BATCHES[${inst}|${tag}]:-}"
    [ -z "$current" ] && return
    unset "BATCH_SEEN[${inst}|${tag}|${hash}]"
    current=$(printf '%s' "$current" | tr ' ' '\n' | grep -Fxv "$hash" | tr '\n' ' ')
    current="${current% }"
    TAG_BATCHES["${inst}|${tag}"]="${current:+${current} }"
}

# Envoie un seul tag à un lot de hashes (chaîne espace-séparée), en
# découpant en requêtes de 90 hashes maximum.
apply_tag_batches() {
    local instance="$1" tag="$2" hashes_str="$3"
    [ -z "$hashes_str" ] && return
    local -a all_hashes
    read -ra all_hashes <<< "$hashes_str"
    local batch_size=90
    local -a batch=()
    local h
    for h in "${all_hashes[@]}"; do
        [ -z "$h" ] && continue
        batch+=("$h")
        if [ "${#batch[@]}" -ge "$batch_size" ]; then
            local batch_str
            batch_str=$(IFS='|'; echo "${batch[*]}")
            qbit_tag_single "$instance" "$batch_str" "$tag"
            batch=()
            sleep 0.2
        fi
    done
    if [ "${#batch[@]}" -gt 0 ]; then
        local batch_str
        batch_str=$(IFS='|'; echo "${batch[*]}")
        qbit_tag_single "$instance" "$batch_str" "$tag"
    fi
}

# CORRECTION : la suppression des anciens tags doit être découpée par lots,
# comme apply_tag_batches le fait déjà pour l'ajout (qBittorrent n'accepte
# qu'~100 hashes par requête). Envoyer tous les torrents d'un coup faisait
# échouer/tronquer la requête sur des bibliothèques de plus d'une centaine
# de torrents, laissant les anciens tags en place indéfiniment.
remove_tags_batches() {
    local instance="$1" tags="$2" hashes_str="$3"
    [ -z "$hashes_str" ] && return
    local -a all_hashes
    read -ra all_hashes <<< "$hashes_str"
    local batch_size=90
    local -a batch=()
    local h
    for h in "${all_hashes[@]}"; do
        [ -z "$h" ] && continue
        batch+=("$h")
        if [ "${#batch[@]}" -ge "$batch_size" ]; then
            local batch_str
            batch_str=$(IFS='|'; echo "${batch[*]}")
            qbit_remove_tags "$instance" "$batch_str" "$tags"
            batch=()
            sleep 0.2
        fi
    done
    if [ "${#batch[@]}" -gt 0 ]; then
        local batch_str
        batch_str=$(IFS='|'; echo "${batch[*]}")
        qbit_remove_tags "$instance" "$batch_str" "$tags"
    fi
}

# =============================================================================
# API RADARR / SONARR
# =============================================================================

# Récupère les fichiers d'UNE série Sonarr et les écrit dans
# "<outdir>/<series_id>.txt". Exportée pour être appelée en parallèle par
# xargs -P depuis fetch_arr_inodes_bulk (voir plus bas) : Sonarr n'expose pas
# d'endpoint global fiable (episodefile sans seriesId retourne parfois HTTP
# 400), donc un appel par série est nécessaire — mais rien n'empêche de les
# faire en parallèle plutôt que strictement l'un après l'autre.
# Appelée indirectement via xargs + export -f — d'où SC2317.
# shellcheck disable=SC2317
_fetch_sonarr_episodefile() {
    local series_id="$1" url="$2" outdir="$3"
    # CORRECTION SÉCURITÉ : la clé arrive par l'environnement (SONARR_API_KEY),
    # plus en argument. Elle était auparavant passée en paramètre positionnel à
    # `bash -c` via xargs, ce qui la rendait lisible en clair dans `ps aux` /
    # /proc/<pid>/cmdline — sur le processus xargs ET sur chacun des 8 bash
    # concurrents, pendant toute la durée du fetch Sonarr. Cela annulait
    # exactement la protection que `-K -` est censé apporter ici.
    # L'environnement d'un processus n'est lisible que par son propriétaire.
    local key="${SONARR_API_KEY:-}"
    local resp
    resp=$(curl -s --connect-timeout 10 --max-time 30 -K - \
        "${url}/api/v3/episodefile?seriesId=${series_id}" <<CURLCFG 2>/dev/null
header = "X-Api-Key: $(_curl_cfg_escape "$key")"
header = "Accept: application/json"
CURLCFG
)
    [ -z "$resp" ] && return
    printf '%s' "$resp" | python3 -c "
import sys, json
try:
    for f in json.load(sys.stdin):
        p = f.get('path', '')
        if p: print(p)
except: pass
" > "${outdir}/${series_id}.txt" 2>/dev/null
}
export -f _fetch_sonarr_episodefile
export -f _curl_cfg_escape

# Récupère tous les chemins de fichiers gérés par les Arr.
# Radarr v3 : /api/v3/movie (movieFile / movieFiles)
# Sonarr v3 : fallback series → episodefile?seriesId= car /episodefile global
#             retourne parfois HTTP 400
fetch_arr_inodes_bulk() {
    local app="$1" url="$2" key="$3"
    local cache_raw="${CACHE_DIR}/arr_raw_${app}.txt"
    printf '   🔄 Récupération %s... ' "$app"

    url="${url%/}"

    if [ "$app" = "radarr" ]; then
        local response http_code payload
        debug_log "fetch_arr_inodes_bulk [radarr] GET ${url}/api/v3/movie"
        # Clé API passée via -K - (stdin), pas en argument -H, pour ne pas
        # l'exposer dans `ps aux` le temps de l'appel.
        response=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 -K - \
            "${url}/api/v3/movie" <<CURLCFG 2>/dev/null
header = "X-Api-Key: $(_curl_cfg_escape "$key")"
header = "Accept: application/json"
CURLCFG
)

        http_code=$(printf '%s' "$response" | tail -n 1)
        payload=$(printf '%s' "$response" | sed '$d')
        debug_log "fetch_arr_inodes_bulk [radarr] HTTP $http_code"

        if [ "$http_code" = "200" ] && [ -n "$payload" ]; then
            printf '%s' "$payload" | python3 -c "
import sys, json
try:
    for m in json.load(sys.stdin):
        mf = m.get('movieFile')
        if mf:
            p = mf.get('path', '')
            if p: print(p)
        mfs = m.get('movieFiles')
        if mfs:
            for f in mfs:
                p = f.get('path', '')
                if p: print(p)
except Exception as e:
    sys.stderr.write('radarr err: %s\n' % str(e))
" > "$cache_raw" 2>/dev/null
            printf 'OK\n'
        else
            printf '⚠️ HTTP %s\n' "$http_code"
            : > "$cache_raw"
        fi

    elif [ "$app" = "sonarr" ]; then
        local response http_code payload
        debug_log "fetch_arr_inodes_bulk [sonarr] GET ${url}/api/v3/series"
        response=$(curl -s -w "\n%{http_code}" --connect-timeout 10 --max-time 30 -K - \
            "${url}/api/v3/series" <<CURLCFG 2>/dev/null
header = "X-Api-Key: $(_curl_cfg_escape "$key")"
header = "Accept: application/json"
CURLCFG
)

        http_code=$(printf '%s' "$response" | tail -n 1)
        payload=$(printf '%s' "$response" | sed '$d')
        debug_log "fetch_arr_inodes_bulk [sonarr] HTTP $http_code"

        if [ "$http_code" != "200" ]; then
            printf '⚠️ HTTP %s (series)\n' "$http_code"
            : > "$cache_raw"
        else
            : > "$cache_raw"
            local series_count
            series_count=$(printf '%s' "$payload" | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin)))
except: print('0')
" 2>/dev/null)
            [[ "$series_count" =~ ^[0-9]+$ ]] || series_count=0

            if [ "$series_count" -gt 0 ]; then
                # CORRECTION PERF : un appel API par série est incontournable
                # (Sonarr n'expose pas d'endpoint fiable pour tout récupérer
                # d'un coup), mais rien n'oblige à les faire un par un — gros
                # gain sur les grosses bibliothèques. 8 requêtes en parallèle :
                # compromis entre vitesse et charge sur l'instance Sonarr.
                local parallel_dir
                parallel_dir=$(mktemp -d "${TMPDIR}/sonarr_fetch.XXXXXX")
                debug_log "fetch_arr_inodes_bulk [sonarr] $series_count série(s), 8 requêtes en parallèle"
                printf '%s' "$payload" | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        sid = s.get('id')
        if sid:
            print(sid)
except: pass
" | SONARR_API_KEY="$key" xargs -P 8 -I{} \
                        bash -c '_fetch_sonarr_episodefile "$@"' _ {} "$url" "$parallel_dir"
                cat "$parallel_dir"/*.txt > "$cache_raw" 2>/dev/null
                rm -rf "$parallel_dir"
            fi

            if [ -s "$cache_raw" ]; then
                printf 'OK (%s séries)\n' "$series_count"
            else
                printf '⚠️ vide\n'
                : > "$cache_raw"
            fi
        fi
    fi

    # Fallback si l'API est vide ou inaccessible.
    # CORRECTION : dernier `find` du script (les autres parcours sont passés
    # à scan_files), et il ne cherchait que 4 extensions codées en dur là où
    # MEDIA_EXTENSIONS_CSV en couvre 9 — les .m4v/.mov/.webm de la
    # bibliothèque étaient invisibles pour ce repli.
    local from_api=true
    if [ ! -s "$cache_raw" ]; then
        printf '⚠️ API vide, scan filesystem... '
        # Ces chemins ne sont PAS déclarés par les Arr : ils ne doivent pas
        # compter comme "api", sans quoi la Phase 7 les tiendrait pour gérés.
        from_api=false
        : > "$cache_raw"
        local media_path
        for media_path in "${MEDIA_DIRS[@]}"; do
            [ -d "$media_path" ] || continue
            scan_files "$MEDIA_EXTENSIONS_CSV" "$media_path" | cut -f3- >> "$cache_raw"
        done
    fi

    # Traduction des chemins (translate_path reste en bash, dépend de
    # PATH_MAP), puis stat en lot de tous les chemins traduits d'un coup
    # (CORRECTION PERF : un seul processus Python au lieu d'un `stat`
    # externe par fichier Arr — potentiellement des milliers).
    local count=0
    local raw_path host_path
    local -a host_paths=()
    while IFS= read -r raw_path; do
        [ -z "$raw_path" ] && continue
        host_path=$(translate_path "$raw_path")
        [ ! -f "$host_path" ] && continue
        host_paths+=("$host_path")
    done < "$cache_raw"

    if [ "${#host_paths[@]}" -gt 0 ]; then
        local inode hpath_stated src="scan"
        $from_api && src="api"
        while IFS=$'\t' read -r inode hpath_stated; do
            ARR_MANAGED_INODES["$inode"]="$hpath_stated"
            ARR_INODE_SOURCE["$inode"]="$src"
            count=$((count + 1))
        done < <(printf '%s\n' "${host_paths[@]}" | stat_paths_bulk)
    fi

    printf '%d fichier(s) → %d inode(s)\n' "$count" "${#ARR_MANAGED_INODES[@]}"
}

# =============================================================================
# RÉPARATION : hardlink manuel des orphelins
# =============================================================================
# À placer juste avant try_repair_file (ligne ~580)

# Création atomique d'un hardlink en remplacement de target : on lie/copie
# toujours vers un fichier temporaire puis on bascule avec `mv -f` (rename
# atomique). La cible n'est donc jamais supprimée avant d'avoir sa remplaçante
# prête : en cas d'échec (ln, reflink, ou même interruption du script), le
# fichier orphelin d'origine reste intact.
create_hardlink_atomic() {
    local source="$1" target="$2"
    local err="" err_file

    if $DEBUG; then
        debug_log "Diagnostic hardlink :"
        debug_log "  source          : $source"
        debug_log "  target          : $target"
        debug_log "  src dev         : $(get_fs_id "$source")"
        debug_log "  tgt dev         : $(get_fs_id "$(dirname "$target")")"
        debug_log "  src inode       : $(stat -c '%i' "$source" 2>/dev/null || echo "?")"
        debug_log "  tgt exists      : $([ -e "$target" ] && echo "oui" || echo "non")"
        debug_log "  parent writable : $([ -w "$(dirname "$target")" ] && echo "oui" || echo "NON")"
    fi

    # Vérification préalable
    if [ ! -f "$source" ]; then
        printf '       ❌ Source introuvable\n'
        return 1
    fi

    local parent
    parent=$(dirname "$target")
    if [ ! -w "$parent" ]; then
        printf '       ❌ Répertoire parent non accessible en écriture : %s\n' "$parent"
        return 1
    fi

    # DRY-RUN : tout ce qui précède (existence, accès en écriture) a été
    # vérifié réellement — seule l'écriture elle-même (ln/mv/cp) est simulée.
    if $DRY_RUN; then
        printf '       🧪 [DRY-RUN] Hardlink simulé, aucune écriture effectuée\n'
        return 0
    fi

    local tmp_link="${target}.linktmp.$$"
    err_file=$(mktemp "${TMPDIR}/ln_err.XXXXXX" 2>/dev/null) || err_file="${TMPDIR}/ln_err.$$"

    # Hardlink vers un fichier temporaire, puis bascule atomique
    if ln "$source" "$tmp_link" 2>"$err_file"; then
        if mv -f "$tmp_link" "$target" 2>"$err_file"; then
            rm -f "$err_file"
            return 0
        fi
        err=$(cat "$err_file" 2>/dev/null)
        rm -f "$tmp_link" "$err_file"
        printf '       ❌ Bascule atomique (mv) a échoué : %s\n' "$err"
        return 1
    fi

    err=$(cat "$err_file" 2>/dev/null)
    printf '       ❌ ln a échoué : %s\n' "$err"

    # Fallback : reflink (copy-on-write) si disponible, toujours via bascule atomique
    if command -v cp &>/dev/null && cp --reflink=auto "$source" "$tmp_link" 2>"$err_file"; then
        if mv -f "$tmp_link" "$target" 2>"$err_file"; then
            rm -f "$err_file"
            printf '       ⚠️  Hardlink impossible, reflink utilisé (copie COW)\n'
            return 0
        fi
        err=$(cat "$err_file" 2>/dev/null)
        rm -f "$tmp_link" "$err_file"
        printf '       ❌ Bascule atomique après reflink a échoué : %s\n' "$err"
        return 1
    fi

    err=$(cat "$err_file" 2>/dev/null)
    rm -f "$err_file" "$tmp_link" 2>/dev/null
    printf '       ❌ Reflink aussi échoué : %s\n' "$err"
    return 1
}

# Cherche dans MEDIA_DIRS un fichier de même taille et même hash que
# orphan_file, priorité aux noms similaires, et le hardlinke à sa place
# (via create_hardlink_atomic) si trouvé.
# Retour : 0 = réparé (ou déjà lié) — 1 = pas de correspondance / échec du
# hardlink — 3 = pas d'outil de hachage disponible (pick_hash_tool a échoué).
try_repair_file() {
    local orphan_file="$1"
    [ -z "$HASH_CMD" ] && return 3
    [ ! -f "$orphan_file" ] && return 1

    local fsize fname orphan_dev norm_orphan
    fsize=$(stat -c '%s' "$orphan_file" 2>/dev/null) || return 1
    fname=$(basename "$orphan_file")
    orphan_dev=$(get_fs_id "$orphan_file")
    norm_orphan=$(normalize_name "$fname")

    printf '       📄 %s (%d octets)\n' "$fname" "$fsize"
    [ -n "$norm_orphan" ] && printf '       🏷️  « %s »\n' "$norm_orphan"

    # Candidats : même taille, même filesystem.
    # CORRECTION PERF : lecture dans l'index taille → candidats construit une
    # seule fois en Phase 1 (voir build_media_size_index). Auparavant, chaque
    # fichier orphelin déclenchait un parcours COMPLET de chacun des
    # MEDIA_DIRS — soit, pour N orphelins et 5 répertoires, 5×N parcours
    # intégraux de la bibliothèque. L'index rend la recherche immédiate.
    local -a all_candidates=() all_candidate_inodes=()
    if $MEDIA_SIZE_INDEX_READY; then
        local c_dev c_inode2 c
        while IFS=$'\t' read -r c_dev c_inode2 c; do
            [ -z "$c" ] && continue
            if [ "$c_dev" != "$orphan_dev" ]; then
                debug_log "try_repair_file : $c ignoré (device $c_dev ≠ device orphelin $orphan_dev, hardlink impossible)"
                continue
            fi
            all_candidates+=("$c")
            all_candidate_inodes+=("$c_inode2")
        done <<< "${MEDIA_SIZE_INDEX[$fsize]:-}"
    else
        # Repli si l'index n'a pas pu être construit : parcours direct.
        local media_dir media_dev
        for media_dir in "${MEDIA_DIRS[@]}"; do
            [ ! -d "$media_dir" ] && continue
            media_dev=$(get_fs_id "$media_dir")
            if [ "$orphan_dev" -ne "$media_dev" ]; then
                debug_log "try_repair_file : $media_dir ignoré (device $media_dev ≠ device orphelin $orphan_dev)"
                continue
            fi
            local c_inode3 c2
            while IFS=$'\t' read -r c_inode3 _ c2; do
                all_candidates+=("$c2")
                all_candidate_inodes+=("$c_inode3")
            done < <(scan_files_by_size "$fsize" "$media_dir")
        done
    fi

    local total_candidates=${#all_candidates[@]}
    printf '       🔍 %d candidat(s) de même taille\n' "$total_candidates"
    [ "$total_candidates" -eq 0 ] && return 1

    # Split : noms similaires en priorité, fallback sinon
    # CORRECTION : tableau associatif pour déduplication rapide
    local -a priority=() fallback=()
    declare -A seen_inodes=()
    local candidate c_inode orphan_inode cand_idx
    orphan_inode=$(stat -c '%i' "$orphan_file" 2>/dev/null || echo "0")
    for cand_idx in "${!all_candidates[@]}"; do
        candidate="${all_candidates[$cand_idx]}"
        c_inode="${all_candidate_inodes[$cand_idx]}"
        [ "$candidate" = "$orphan_file" ] && continue

        # Déjà hardlinké (même inode que le "candidat") : rien à faire,
        # ce n'est pas vraiment un orphelin. Évite un ln/mv inutile qui
        # échoue avec "are the same file".
        if [ "$c_inode" != "0" ] && [ "$c_inode" = "$orphan_inode" ]; then
            printf '       ℹ️  Déjà lié (même inode) à %s\n' "$(basename "$candidate")"
            do_chown "$orphan_file"
            unset "HASH_CACHE[$orphan_file]"
            return 0
        fi

        [ -n "${seen_inodes[$c_inode]:-}" ] && continue
        seen_inodes[$c_inode]=1

        if [ "$(name_similarity "$fname" "$(basename "$candidate")")" != "none" ]; then
            priority+=("$candidate")
        else
            fallback+=("$candidate")
        fi
    done

    printf '       📊 %d nom similaire + %d autre(s)\n' "${#priority[@]}" "${#fallback[@]}"

    # Hachage rapide (échantillonné) du fichier orphelin : pré-filtre avant
    # le hash complet, qui n'est calculé pour l'orphelin lui-même qu'au
    # moment d'une confirmation (voir plus bas), pas systématiquement — si
    # aucun candidat ne correspond même par échantillonnage, il ne sert à
    # rien de lire tout le fichier orphelin.
    printf '       ⏳ Hachage rapide... '
    local fqhash
    fqhash=$(quick_file_hash "$orphan_file" "$fsize")
    [ -z "$fqhash" ] && { printf '❌\n'; return 1; }
    printf '✓ %s...\n' "${fqhash:0:8}"
    debug_log "try_repair_file : hash rapide orphelin = $fqhash"

    # Hash complet de l'orphelin : calculé une seule fois, seulement à la
    # première confirmation nécessaire (voir les deux boucles ci-dessous).
    local fhash=""

    # Test priorité (noms similaires)
    local checked=0 cname cqhash chash
    for candidate in "${priority[@]}"; do
        checked=$((checked + 1))
        cname=$(basename "$candidate")
        printf '       [%d/%d] ⏳ %s... ' "$checked" "${#priority[@]}" "${cname:0:50}"
        cqhash=$(quick_file_hash "$candidate" "$fsize")
        if [ -z "$cqhash" ]; then
            printf '❌\n'
            continue
        fi
        debug_log "try_repair_file : hash rapide candidat $candidate = $cqhash"
        if [ "$cqhash" != "$fqhash" ]; then
            printf '✗\n'
            continue
        fi
        # Pré-filtre passé. Par défaut, le hash rapide (échantillonné) fait
        # foi. Avec --full-hash, on exige en plus une confirmation par hash
        # complet avant toute action.
        if $FULL_HASH; then
            if [ -z "$fhash" ]; then
                fhash=$(file_hash "$orphan_file")
                if [ -z "$fhash" ]; then
                    printf '❌ (hash complet orphelin impossible)\n'
                    continue
                fi
                debug_log "try_repair_file : hash complet orphelin ($HASH_CMD) = $fhash"
            fi
            chash=$(file_hash "$candidate")
            if [ -z "$chash" ]; then
                printf '❌\n'
                continue
            fi
            if [ "$chash" != "$fhash" ]; then
                printf '✗ (faux positif hash rapide)\n'
                continue
            fi
        fi
        printf '✅ CORRESPONDANCE !\n'
        printf '       🔧 Hardlink...\n'
        if create_hardlink_atomic "$candidate" "$orphan_file"; then
            printf '       ✅ Hardlink créé !\n'
            do_chown "$orphan_file"
            unset "HASH_CACHE[$orphan_file]"
            return 0
        else
            printf '       ❌ Échec hardlink\n'
            return 1
        fi
    done

    # Test fallback (noms différents, même taille)
    if [ "${#fallback[@]}" -gt 0 ]; then
        printf '\n'
        printf '       ⚠️  Aucun par nom — %d nom(s) différent(s)...\n' "${#fallback[@]}"
        local total_fb checked_fb
        total_fb=${#fallback[@]}
        checked_fb=0
        for candidate in "${fallback[@]}"; do
            checked_fb=$((checked_fb + 1))
            cname=$(basename "$candidate")
            printf '       [%d/%d] ⏳ %s... ' "$checked_fb" "$total_fb" "${cname:0:50}"
            cqhash=$(quick_file_hash "$candidate" "$fsize")
            if [ -z "$cqhash" ]; then
                printf '❌\n'
                continue
            fi
            debug_log "try_repair_file : hash rapide candidat $candidate = $cqhash"
            if [ "$cqhash" != "$fqhash" ]; then
                printf '✗\n'
                continue
            fi
            if $FULL_HASH; then
                if [ -z "$fhash" ]; then
                    fhash=$(file_hash "$orphan_file")
                    if [ -z "$fhash" ]; then
                        printf '❌ (hash complet orphelin impossible)\n'
                        continue
                    fi
                    debug_log "try_repair_file : hash complet orphelin ($HASH_CMD) = $fhash"
                fi
                chash=$(file_hash "$candidate")
                if [ -z "$chash" ]; then
                    printf '❌\n'
                    continue
                fi
                if [ "$chash" != "$fhash" ]; then
                    printf '✗ (faux positif hash rapide)\n'
                    continue
                fi
            fi
            printf '✅ CORRESPONDANCE (nom différent) !\n'
            printf '       🔧 Hardlink...\n'
            if create_hardlink_atomic "$candidate" "$orphan_file"; then
                printf '       ✅ Hardlink créé !\n'
                do_chown "$orphan_file"
                unset "HASH_CACHE[$orphan_file]"
                return 0
            else
                printf '       ❌ Échec hardlink\n'
                return 1
            fi
        done
    fi

    printf '       ❌ Aucune correspondance\n'
    return 1
}

# =============================================================================
# TRACKER SECRETS (durée minimale de seed)
# =============================================================================

TRACKER_SECRETS_FILE="${SCRIPT_DIR}/cleanup/tracker_secrets.conf"

load_tracker_secrets() {
    declare -gA TRACKER_MIN_SEED=()
    [ -f "$TRACKER_SECRETS_FILE" ] || return
    local domain hours
    while IFS='=' read -r domain hours; do
        [ -z "$domain" ] && continue
        [[ "$domain" =~ ^[[:space:]]*# ]] && continue
        domain=$(printf '%s' "$domain" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        hours=$(printf '%s' "$hours" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$domain" ] && [ -n "$hours" ] && TRACKER_MIN_SEED["$domain"]="$hours"
    done < "$TRACKER_SECRETS_FILE"
}

save_tracker_secrets() {
    local tmpfile="${TRACKER_SECRETS_FILE}.$$"
    : > "$tmpfile"
    local domain
    for domain in "${!TRACKER_MIN_SEED[@]}"; do
        printf '%s=%s\n' "$domain" "${TRACKER_MIN_SEED[$domain]}" >> "$tmpfile"
    done
    mv "$tmpfile" "$TRACKER_SECRETS_FILE" 2>/dev/null
    chmod 600 "$TRACKER_SECRETS_FILE"
}

# Extrait le domaine (sans schéma, chemin ni port) d'une URL de tracker,
# utilisé comme clé dans TRACKER_MIN_SEED / tracker_secrets.conf.
get_tracker_domain() {
    local url="$1"
    printf '%s' "$url" | sed -E 's|https?://||; s|/.*||; s|:.*||'
}

# Demande interactive (1ère fois) ou valeur conservatoire 999999 (non-interactif)
ask_tracker_min_seed() {
    local domain="$1"
    local hours=""
    if [ -t 0 ]; then
        while true; do
            read -r -p "Durée min seed (h) pour [$domain] ? " hours
            [[ "$hours" =~ ^[0-9]+$ ]] && break
            printf "   Entrée invalide. Entrez un nombre entier d’heures (ex: 72).\n"
        done
    else
        printf '⚠️ Tracker [%s] inconnu et mode non-interactif. Durée infinie appliquée.\n' "$domain" >&2
        hours=999999
    fi
    TRACKER_MIN_SEED["$domain"]="$hours"
    save_tracker_secrets
    printf '%s' "$hours"
}

# Récupère la durée : mémoire → fichier → question interactive
get_tracker_min_seed_hours() {
    local domain="$1"
    local hours="${TRACKER_MIN_SEED[$domain]:-}"

    if [ -z "$hours" ]; then
        # Rechargement depuis le fichier (sous-shell précédent ?)
        if [ -f "$TRACKER_SECRETS_FILE" ]; then
            local d h
            while IFS='=' read -r d h; do
                [ -z "$d" ] && continue
                [[ "$d" =~ ^[[:space:]]*# ]] && continue
                d=$(printf '%s' "$d" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                h=$(printf '%s' "$h" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                if [ "$d" = "$domain" ]; then
                    hours="$h"
                    TRACKER_MIN_SEED["$domain"]="$h"
                    break
                fi
            done < "$TRACKER_SECRETS_FILE"
        fi

        if [ -z "$hours" ]; then
            hours=$(ask_tracker_min_seed "$domain")
            TRACKER_MIN_SEED["$domain"]="$hours"
        fi
    fi
    printf '%s' "$hours"
}

# CORRECTION PERF : "seeding_time" est déjà récupéré pour tous les torrents
# en Phase 0 (/torrents/info). On ne rappelle l'API /properties que si cette
# valeur est absente (ex. ancien cache sans ce champ).
get_torrent_seed_hours() {
    local instance="$1" hash="$2"
    local seeding_time="${TORRENT_SEEDING_TIME[$hash]:-}"

    if [ -z "$seeding_time" ]; then
        local props
        props=$(qbit_get "$instance" "/api/v2/torrents/properties?hash=${hash}")
        [ -z "$props" ] && return 1
        seeding_time=$(printf '%s' "$props" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('seeding_time', 0))
" 2>/dev/null)
        [ -z "$seeding_time" ] && seeding_time=0
    fi

    printf '%s' "$((seeding_time / 3600))"
}

# CORRECTION PERF : "tracker" (tracker actuellement actif) est déjà récupéré
# pour tous les torrents en Phase 0 (/torrents/info). On ne rappelle l'API
# /trackers (scan complet + filtrage dht/pex/lsd) que si ce champ est vide
# (aucun tracker actif au moment du fetch initial).
get_torrent_tracker_domain() {
    local instance="$1" hash="$2"
    local url="${TORRENT_TRACKER[$hash]:-}"

    if [ -n "$url" ] && [[ "$url" == http* ]]; then
        get_tracker_domain "$url"
        return 0
    fi

    local trackers
    trackers=$(qbit_get "$instance" "/api/v2/torrents/trackers?hash=${hash}")
    [ -z "$trackers" ] && return 1
    url=$(printf '%s' "$trackers" | python3 -c "
import sys, json
for t in json.load(sys.stdin):
    u = t.get('url', '')
    if not u:
        continue
    lu = u.lower()
    if 'dht' in lu or 'pex' in lu or 'lsd' in lu or 'udp://' in lu:
        continue
    if u.startswith('http'):
        print(u)
        break
" 2>/dev/null)
    [ -z "$url" ] && return 1
    get_tracker_domain "$url"
}

# =============================================================================
# PHASE 7 : Orphelins de disque
# =============================================================================
# Fichiers présents dans MEDIA_DIRS mais ni gérés par Radarr/Sonarr, ni liés à
# un torrent connu : appelée depuis main() uniquement si SCAN_DISK_ORPHANS=true.

phase7_scan_disk_orphans() {
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 7 — Scan des orphelins de disque\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    if [ "${#MEDIA_DIRS[@]}" -eq 0 ]; then
        printf '   ⚠️ MEDIA_DIRS est vide ou non défini !\n' >&2
        printf '═══════════════════════════════════════════════════════════════\n\n'
        return 1
    fi

    # Cette phase ne sait juger que par rapport à ce que les Arr revendiquent.
    # Si l'API n'a rien renvoyé (instance injoignable, clé invalide, repli
    # filesystem), aucun inode n'est marqué "api" et TOUTE la bibliothèque
    # ressemblerait à un orphelin géant. On préfère ne rien affirmer.
    local api_inodes=0 src_inode
    for src_inode in "${!ARR_INODE_SOURCE[@]}"; do
        [ "${ARR_INODE_SOURCE[$src_inode]}" = "api" ] && api_inodes=$((api_inodes + 1))
    done
    if [ "$api_inodes" -eq 0 ]; then
        printf "   ⚠️  Aucun fichier revendiqué par l’API Radarr/Sonarr : impossible de\n" >&2
        printf "      distinguer un orphelin d’un fichier géré. Phase ignorée.\n" >&2
        printf '═══════════════════════════════════════════════════════════════\n\n'
        return 1
    fi

    printf "   Répertoires configurés : %d (%d fichier(s) revendiqué(s) par l’API)\n" \
        "${#MEDIA_DIRS[@]}" "$api_inodes"

    local disk_orphan_log="${DISK_ORPHAN_LOG}"
    local min_size="${DISK_ORPHAN_MIN_SIZE}"
    local disk_orphan_count=0
    local disk_orphan_bytes=0

    mkdir -p "$(dirname "$disk_orphan_log")" 2>/dev/null
    {
        printf '# Orphelins de disque - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# Fichiers présents dans MEDIA_DIRS mais ni connus ARR ni liés torrent\n'
        printf '# inode\ttaille\tchemin\n'
    } > "$disk_orphan_log"

    # Indexation rapide : inodes déjà connus par les torrents (tous les
    # fichiers, pas seulement les extensions média, pour ne pas rater un
    # fichier "orphelin de disque" à tort à cause d'un filtre trop strict).
    declare -A TORRENT_INODE_HASH=()
    local hash hpath f finode
    for hash in "${!TORRENT_NAMES[@]}"; do
        hpath="${TORRENT_HOST_PATH[$hash]:-}"
        [ ! -e "$hpath" ] && continue
        while IFS=$'\t' read -r finode _ f; do
            [ "$finode" = "0" ] && continue
            TORRENT_INODE_HASH["$finode"]="$hash"
        done < <(scan_files "" "$hpath")
    done

    # Boucle EXPLICITE par index
    # CORRECTION : MEDIA_DIRS est un tableau associatif (clés = "animes",
    # "series", ...), pas indexé numériquement. On garde donc un compteur
    # dédié pour l'affichage au lieu de faire de l'arithmétique sur la clé
    # (qui provoquait "series: unbound variable" avec `$((idx+1))`).
    local idx media_dir dir_num=0
    local dir_total=${#MEDIA_DIRS[@]}
    for idx in "${!MEDIA_DIRS[@]}"; do
        dir_num=$((dir_num + 1))
        media_dir="${MEDIA_DIRS[$idx]}"
        [ -d "$media_dir" ] || {
            printf '   ⚠️  [%d/%d] ignoré (inexistant) : %s\n' "$dir_num" "$dir_total" "$media_dir"
            continue
        }

        printf '   Scan [%d/%d] : %s ...\n' "$dir_num" "$dir_total" "$media_dir"

        # DISK_ORPHAN_EXTENSIONS est optionnel (vide = pas de filtre) ;
        # jointure en CSV pour scan_files.
        local ext_csv=""
        if [ "${#DISK_ORPHAN_EXTENSIONS[@]}" -gt 0 ] 2>/dev/null; then
            ext_csv=$(IFS=','; echo "${DISK_ORPHAN_EXTENSIONS[*]}")
        fi

        local fpath fsize
        while IFS=$'\t' read -r finode fsize fpath; do
            [ "$finode" = "0" ] && continue
            [ "$fsize" -lt "$min_size" ] && continue

            # CORRECTION : on teste la PROVENANCE, pas la simple présence
            # dans ARR_MANAGED_INODES. Cet ensemble contient aussi tous les
            # fichiers ajoutés par scan_media_dirs_for_inodes, c'est-à-dire
            # l'intégralité de MEDIA_DIRS — exactement ce que cette phase
            # parcourt. Le filtre était donc toujours vrai et la Phase 7 ne
            # remontait jamais le moindre orphelin. Seul un fichier
            # explicitement revendiqué par l'API Arr compte comme géré.
            [ "${ARR_INODE_SOURCE[$finode]:-}" = "api" ] && continue
            [ -n "${TORRENT_INODE_HASH[$finode]:-}" ] && continue

            disk_orphan_count=$((disk_orphan_count + 1))
            disk_orphan_bytes=$((disk_orphan_bytes + fsize))
            printf '%s\t%s\t%s\n' "$finode" "$fsize" "$fpath" >> "$disk_orphan_log"
            printf '      ⚠️  %s\n' "$fpath"

        done < <(scan_files "$ext_csv" "$media_dir")

        printf '   ✓ [%d/%d] terminé\n' "$dir_num" "$dir_total"
    done

    if [ "$disk_orphan_count" -gt 0 ]; then
        local human_size
        human_size=$(numfmt --to=iec-i --suffix=B "$disk_orphan_bytes" 2>/dev/null || echo "${disk_orphan_bytes}o")
        printf '   ⚠️  %d fichier(s) orphelin(s) trouvé(s) : %s\n' "$disk_orphan_count" "$human_size"
        printf '   📄 Rapport : %s\n' "$disk_orphan_log"
    else
        printf '   ✓ Aucun orphelin de disque\n'
    fi
    printf '═══════════════════════════════════════════════════════════════\n\n'
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local start_ts
    start_ts=$(date +%s)

    printf '╔══════════════════════════════════════════════════════════════╗\n'
    printf '║        qBittorrent Nettoyage — Hardlinks Intelligents       ║\n'
    printf '╚══════════════════════════════════════════════════════════════╝\n'
    printf '\n'
    if $DRY_RUN; then
        printf '🧪 MODE DRY-RUN — aucune écriture réelle (ni filesystem, ni qBittorrent)\n'
    fi
    if $FULL_HASH; then
        printf '🔎 Phase 5 : confirmation par hash complet (--full-hash)\n'
    else
        printf '🔎 Phase 5 : hash rapide (échantillonné) — utilisez --full-hash pour une confirmation par hash complet\n'
    fi
    printf '📁 Configuration : %s\n' "$CONFIG_FILE"
    printf '📁 Cache         : %s\n' "$CACHE_DIR"
    printf '📁 Temporaires   : %s (%s)\n' "$TMPDIR" \
        "$(stat -f -c '%T' "$TMPDIR" 2>/dev/null || echo 'type inconnu')"
    printf '\n'

    if ! command -v curl &>/dev/null; then printf '❌ curl requis\n'; exit 1; fi
    if ! command -v python3 &>/dev/null; then printf '❌ python3 requis\n'; exit 1; fi
    pick_hash_tool
    printf '🔧 Hachage : %s\n' "$HASH_CMD"

    # Mémo de parcours des fichiers de torrents, valable le temps du run.
    # Supprimé par save_all_caches (fin normale comme interruption).
    SCAN_MEMO_DIR=$(mktemp -d "${TMPDIR}/check_hardlinks_scan.XXXXXX") || SCAN_MEMO_DIR=""
    printf '\n'

    if $NO_CACHE; then
        printf '🗄️  --use-no-cache : caches disque ignorés (hash, inodes, statut torrents, Arr)\n'
    else
        printf '🗄️  Chargement des caches...\n'
        load_hash_cache
        load_inode_cache
        load_torrent_cache
        load_arr_inodes
    fi
    printf '\n'

    printf '🔌 Connexion aux instances...\n'
    local instance
    for instance in "${INSTANCES[@]}"; do
        printf '   [%s] ' "$instance"
        qbit_login "$instance" || { printf '❌ Échec connexion\n'; exit 1; }
        printf '✓ Connecté\n'
    done
    printf '\n'

    # -------------------------------------------------------------------------
    # PHASE 0 : Récupération des torrents (avec cache)
    # -------------------------------------------------------------------------
    printf '📥 Récupération des torrents...\n'

    local use_cache=false
    if [ "$TORRENT_CACHE_DURATION" -gt 0 ] && load_torrent_list_cache; then
        use_cache=true
    fi

    if ! $use_cache; then
        TORRENT_NAMES=()
        TORRENT_INSTANCE=()
        TORRENT_SAVE_PATH=()
        TORRENT_HOST_PATH=()
        TORRENT_TRACKER=()
        TORRENT_SEEDING_TIME=()
    fi

    local total=0
    local json count hash name save_path size tracker seeding_time translated hpath
    for instance in "${INSTANCES[@]}"; do
        if $use_cache; then
            local inst_count=0
            local h
            for h in "${!TORRENT_INSTANCE[@]}"; do
                [ "${TORRENT_INSTANCE[$h]}" = "$instance" ] && inst_count=$((inst_count + 1))
            done
            printf '   [%s] %d torrent(s) (cache)\n' "$instance" "$inst_count"
            total=$((total + inst_count))
            continue
        fi

        json=$(qbit_get "$instance" "/api/v2/torrents/info")
        count=$(printf '%s' "$json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
        [ -z "$count" ] && count=0
        printf '   [%s] %d torrent(s)\n' "$instance" "$count"

        # tracker/seeding_time sont déjà dans /torrents/info : on les capture
        # ici pour éviter un appel API séparé par torrent en Phase 6.
        while IFS='|' read -r hash name save_path size tracker seeding_time; do
            [ -z "$hash" ] && continue
            hash="${hash^^}"
            translated=$(translate_path "$save_path")
            hpath="${translated}/${name}"

            TORRENT_NAMES["$hash"]="$name"
            TORRENT_INSTANCE["$hash"]="$instance"
            TORRENT_SAVE_PATH["$hash"]="$save_path"
            TORRENT_HOST_PATH["$hash"]="$hpath"
            TORRENT_TRACKER["$hash"]="$tracker"
            TORRENT_SEEDING_TIME["$hash"]="$seeding_time"
        done < <(printf '%s' "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data:
    tracker = t.get('tracker', '') or ''
    seeding_time = t.get('seeding_time', '')
    seeding_time = '' if seeding_time in (None, '') else seeding_time
    name = str(t.get('name', '')).replace('|', ' ')
    print(f\"{t.get('hash','')}|{name}|{t.get('save_path','')}|{t.get('size',0)}|{tracker}|{seeding_time}\")
" 2>/dev/null)
        total=$((total + count))
    done

    save_torrent_list_cache
    printf '   ✓ %d torrent(s) au total\n' "$total"
    printf '\n'


    local torrent_direct=0 torrent_cross_linked=0 torrent_orphan=0 torrent_partial=0 repaired_count=0
    local torrent_no_media=0 torrent_delete_ready=0

    # -------------------------------------------------------------------------
    # PHASE 1 : Inodes des Arr (Radarr/Sonarr)
    # -------------------------------------------------------------------------
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 1 — Récupération des inodes Radarr/Sonarr\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    local need_fetch_arr=true
    if [ "$ARR_CACHE_DURATION" -gt 0 ] && [ "${#ARR_MANAGED_INODES[@]}" -gt 0 ] \
       && ! $ARR_CACHE_LEGACY; then
        local age
        age=$(( $(date +%s) - $(stat -c '%Y' "$ARR_INODES_FILE" 2>/dev/null || echo 0) ))
        [ "$age" -lt "$ARR_CACHE_DURATION" ] && need_fetch_arr=false
    fi

    if $need_fetch_arr; then
        if [ "$ARR_CACHE_DURATION" -eq 0 ]; then
            printf '   🔄 Cache Arr désactivé (ARR_CACHE_DURATION=0) → interrogation API...\n'
        fi
        ARR_MANAGED_INODES=()
        local seen_urls=""
        local cfg_key
        for instance in "${INSTANCES[@]}"; do
            local has_arr=false
            for cfg_key in "${!ARR_CONFIG[@]}"; do
                [[ "$cfg_key" == "${instance}|"* ]] || continue
                has_arr=true

                local app url key ae
                app="${cfg_key#*|}"
                ae="${ARR_CONFIG[$cfg_key]}"
                url="${ae%%|*}"
                key="${ae#*|}"

                if [ "$app" != "radarr" ] && [ "$app" != "sonarr" ]; then
                    printf '   [%s] ⚠️ App inconnu : "%s"\n' "$instance" "$app"
                    continue
                fi

                if [[ "$seen_urls" == *"|${url}|"* ]]; then
                    printf '   [%s] %s → %s (⏭️ déjà traité)\n' "$instance" "$app" "$url"
                    continue
                fi
                seen_urls="${seen_urls}|${url}|"

                printf '   [%s] %s → %s\n' "$instance" "$app" "$url"
                fetch_arr_inodes_bulk "$app" "$url" "$key"
            done
            if ! $has_arr; then
                printf '   [%s] ⏭️  pas configuré (aucune entrée ARR_CONFIG["%s|..."])\n' "$instance" "$instance"
            fi
        done
        save_arr_inodes_bulk
        printf '   ✓ %d inodes Arr chargés\n' "${#ARR_MANAGED_INODES[@]}"

        # -----------------------------------------------------------------
        # FALLBACK / COMPLEMENT : scan direct des fichiers vidéo dans MEDIA_DIRS
        # -----------------------------------------------------------------
        local media_inode_count=${#ARR_MANAGED_INODES[@]}
        if [ "$media_inode_count" -eq 0 ]; then
            printf '   ⚠️  Aucun inode API valide — scan médias...\n'
        fi
        scan_media_dirs_for_inodes
        if [ "${#ARR_MANAGED_INODES[@]}" -gt "$media_inode_count" ]; then
            printf '   ✓ %d inode(s) supplémentaire(s) via scan médias\n' \
                "$((${#ARR_MANAGED_INODES[@]} - media_inode_count))"
        fi
    else
        printf '   ⏭️  Cache Arr valide (%d inodes, < %ss)\n' \
            "${#ARR_MANAGED_INODES[@]}" "$ARR_CACHE_DURATION"

        # Même si le cache est valide, on complète avec les nouveaux fichiers
        local media_inode_count=${#ARR_MANAGED_INODES[@]}
        scan_media_dirs_for_inodes
        if [ "${#ARR_MANAGED_INODES[@]}" -gt "$media_inode_count" ]; then
            printf '   ✓ %d inode(s) supplémentaire(s) via scan médias\n' \
                "$((${#ARR_MANAGED_INODES[@]} - media_inode_count))"
        fi
    fi

    scan_cross_seed_dir_for_inodes
    [ -n "$CROSS_SEED_DIR" ] && printf '   ✓ %d inode(s) indexé(s) sous CROSS_SEED_DIR\n' "${#CROSS_SEED_INODES[@]}"
    printf '\n'

    # -------------------------------------------------------------------------
    # PHASE 2 : Torrents déjà liés (cache ou inode match)
    # -------------------------------------------------------------------------
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 2 — Marquage des torrents liés (inodes Arr)\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    local arr_matched=0 arr_skipped=0 arr_partial=0 arr_cross_matched=0 idx=0
    local cache_key cached_entry cached_status hpath found_arr all_arr any_file any_cross f finode
    for hash in "${!TORRENT_NAMES[@]}"; do
        idx=$((idx + 1))
        instance="${TORRENT_INSTANCE[$hash]}"
        cache_key="${hash}|${instance}"
        cached_entry="${TORRENT_CACHE[$cache_key]:-}"

        if [ -n "$cached_entry" ]; then
            cached_status="${cached_entry%|*}"
            if [ "$cached_status" = "linked" ]; then
                batch_add "$instance" "$TAG_LINKED" "$hash"
                arr_skipped=$((arr_skipped + 1))
                printf '\r   [%3d/%3d] ⏭️  [%s] (caché) %-50s' "$idx" "$total" "$instance" "${TORRENT_NAMES[$hash]:0:50}"
                continue
            fi
        fi

        hpath="${TORRENT_HOST_PATH[$hash]:-}"
        [ -z "$hpath" ] && continue
        [ ! -e "$hpath" ] && continue

        # CORRECTION : on vérifie TOUS les fichiers du torrent, pas
        # seulement jusqu'au premier trouvé. Un pack de saison où un seul
        # épisode sur dix est déjà hardlinké ne doit pas être marqué
        # "linked" en entier (les 9 autres resteraient alors de vrais
        # doublons non dédupliqués, jamais signalés ni réparés) : il est
        # marqué "partial" à la place. On en profite pour renseigner
        # INODE_IN_MEDIA/INODE_IN_CROSS au passage (évite de rescanner ces
        # fichiers en Phase 3 pour ceux qui finissent linked/partial).
        #
        # CORRECTION : cette phase vérifie maintenant aussi CROSS_SEED_INODES,
        # pas seulement ARR_MANAGED_INODES. Avant, un torrent entièrement lié
        # aux Arr était toujours tagué "linked" ici et mis en cache aussitôt,
        # ce qui l'excluait définitivement de la Phase 3/4 — le seul endroit
        # qui savait détecter "cross-linked". Résultat : ce tag ne pouvait
        # structurellement jamais être appliqué. La détection cross-seed doit
        # se faire ici, au moment même de la décision linked/partial.
        found_arr=false
        all_arr=true
        any_file=false
        any_cross=false
        while IFS=$'\t' read -r finode _ f; do
            any_file=true
            if [ -n "${ARR_MANAGED_INODES[$finode]:-}" ]; then
                found_arr=true
                INODE_IN_MEDIA["$finode"]=true
            else
                all_arr=false
                INODE_IN_MEDIA["$finode"]=false
            fi
            if [ -n "${CROSS_SEED_INODES[$finode]:-}" ]; then
                any_cross=true
                INODE_IN_CROSS["$finode"]=true
            else
                INODE_IN_CROSS["$finode"]=false
            fi
        done < <(scan_torrent_files "$hash" "$hpath")

        if $any_file && $found_arr && $all_arr; then
            if $any_cross; then
                batch_add "$instance" "$TAG_CROSS_LINKED" "$hash"
                save_torrent_entry "$hash" "$instance" "cross_linked"
                arr_cross_matched=$((arr_cross_matched + 1))
                printf '\r   [%3d/%3d] 🔗 [%s] Arr cross-linked %-50s' "$idx" "$total" "$instance" "${TORRENT_NAMES[$hash]:0:50}"
            else
                batch_add "$instance" "$TAG_LINKED" "$hash"
                save_torrent_entry "$hash" "$instance" "linked"
                arr_matched=$((arr_matched + 1))
                printf '\r   [%3d/%3d] ✅ [%s] Arr lié %-50s' "$idx" "$total" "$instance" "${TORRENT_NAMES[$hash]:0:50}"
            fi
        elif $found_arr; then
            batch_add "$instance" "$TAG_PARTIAL" "$hash"
            save_torrent_entry "$hash" "$instance" "partial"
            arr_partial=$((arr_partial + 1))
            printf '\r   [%3d/%3d] 🟡 [%s] Arr partiel %-50s' "$idx" "$total" "$instance" "${TORRENT_NAMES[$hash]:0:50}"
        else
            printf '\r   [%3d/%3d] ❓ [%s] %-50s' "$idx" "$total" "$instance" "${TORRENT_NAMES[$hash]:0:50}"
        fi
    done
    printf '\n'
    printf '   ✓ Arr : %d lié(s) (dont %d depuis cache), %d cross-linked, %d partiel(s)\n' \
        "$arr_matched" "$arr_skipped" "$arr_cross_matched" "$arr_partial"
    printf '\n'

    # CORRECTION : inclure les torrents "linked" retrouvés via le cache
    # (arr_skipped), pas seulement les correspondances Arr fraîches — sinon
    # le compteur "Direct" du rapport final sous-comptait dès qu'un run
    # bénéficiait du cache.
    torrent_direct=$((arr_matched + arr_skipped))
    torrent_partial=$arr_partial
    torrent_cross_linked=$((torrent_cross_linked + arr_cross_matched))

    # -------------------------------------------------------------------------
    # PHASE 3 : Analyse des inodes des fichiers torrents
    # -------------------------------------------------------------------------
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 3 — Analyse des inodes\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    local all_files_tmp uncached_tmp media_count cross_count cache_hits
    all_files_tmp=$(mktemp "${TMPDIR}/check_hardlinks.XXXXXX")
    ALL_FILES_TMP="$all_files_tmp"
    local unprocessed=0

    for hash in "${!TORRENT_NAMES[@]}"; do
        instance="${TORRENT_INSTANCE[$hash]:-}"
        cache_key="${hash}|${instance}"
        [ -n "${TORRENT_CACHE[$cache_key]:-}" ] && continue

        hpath="${TORRENT_HOST_PATH[$hash]:-}"
        [ -z "$hpath" ] && continue
        [ ! -e "$hpath" ] && continue

        while IFS=$'\t' read -r finode _ f; do
            [ "$finode" = "0" ] && continue
            printf '%s|%s|%s\n' "$finode" "$hash" "$f" >> "$all_files_tmp"
        done < <(scan_torrent_files "$hash" "$hpath")
        unprocessed=$((unprocessed + 1))
    done

    printf '   📊 %d torrent(s) à analyser, %d fichier(s)\n' "$unprocessed" "$(wc -l < "$all_files_tmp")"

    uncached_tmp=$(mktemp "${TMPDIR}/check_hardlinks.XXXXXX")
    UNCACHED_TMP="$uncached_tmp"
    media_count=0
    cross_count=0
    cache_hits=0

    while IFS='|' read -r inode hash fpath; do
        cached_status="${INODE_STATUS_CACHE[$inode]:-}"
        if [ -n "$cached_status" ]; then
            if [ "$cached_status" = "media" ]; then
                INODE_IN_MEDIA["$inode"]=true
                INODE_IN_CROSS["$inode"]=false
                media_count=$((media_count + 1))
            elif [ "$cached_status" = "cross" ]; then
                INODE_IN_MEDIA["$inode"]=false
                INODE_IN_CROSS["$inode"]=true
                cross_count=$((cross_count + 1))
            else
                INODE_IN_MEDIA["$inode"]=false
                INODE_IN_CROSS["$inode"]=false
            fi
            cache_hits=$((cache_hits + 1))
        else
            printf '%s|%s|%s\n' "$inode" "$hash" "$fpath" >> "$uncached_tmp"
        fi
    done < "$all_files_tmp"

    sort -t'|' -k1,1 "$uncached_tmp" > "${uncached_tmp}.sorted"

    local current_inode="" current_sample_path="" in_media=false in_cross=false
    local total_uncached processed
    total_uncached=$(wc -l < "${uncached_tmp}.sorted")
    processed=0

    while IFS='|' read -r inode hash fpath; do
        if [ "$inode" != "$current_inode" ] && [ -n "$current_inode" ]; then
            INODE_IN_MEDIA["$current_inode"]=$in_media
            INODE_IN_CROSS["$current_inode"]=$in_cross
            [ "$in_media" = true ] && media_count=$((media_count + 1))
            [ "$in_cross" = true ] && cross_count=$((cross_count + 1))
            local status="inconnu"
            [ "$in_media" = true ] && status="media"
            [ "$in_cross" = true ] && [ "$in_media" = false ] && status="cross"
            [ "$status" != "inconnu" ] && save_inode_entry "$current_inode" "$status" "$current_sample_path"
            in_media=false
            in_cross=false
            current_sample_path=""
            processed=$((processed + 1))

            if [ $((processed % 100)) -eq 0 ] && [ "$total_uncached" -gt 0 ]; then
                printf '\r   Analyse inodes : %3d%% (%d/%d)' "$((processed * 100 / total_uncached))" "$processed" "$total_uncached"
            fi
        fi
        current_inode="$inode"
        [ -z "$current_sample_path" ] && current_sample_path="$fpath"
        # CORRECTION : test par inode réel (ARR_MANAGED_INODES / CROSS_SEED_INODES),
        # pas par préfixe du chemin du torrent — ce dernier ne fonctionne que si le
        # dossier de téléchargement est lui-même sous MEDIA_DIRS/CROSS_SEED_DIR, ce
        # qui n'est pas le cas ici (dossier de téléchargement séparé de la
        # bibliothèque) : tout finissait donc classé "orphelin".
        [ -n "${ARR_MANAGED_INODES[$inode]:-}" ] && in_media=true
        [ -n "${CROSS_SEED_INODES[$inode]:-}" ] && in_cross=true
    done < "${uncached_tmp}.sorted"

    if [ -n "$current_inode" ]; then
        INODE_IN_MEDIA["$current_inode"]=$in_media
        INODE_IN_CROSS["$current_inode"]=$in_cross
        [ "$in_media" = true ] && media_count=$((media_count + 1))
        [ "$in_cross" = true ] && cross_count=$((cross_count + 1))
        local status="inconnu"
        [ "$in_media" = true ] && status="media"
        [ "$in_cross" = true ] && [ "$in_media" = false ] && status="cross"
        [ "$status" != "inconnu" ] && save_inode_entry "$current_inode" "$status" "$current_sample_path"
    fi

    printf '\r   Analyse inodes : 100%% (%d/%d)\n' "$total_uncached" "$total_uncached"
    printf '   ✓ %d media, %d cross (%d depuis cache)\n' "$media_count" "$cross_count" "$cache_hits"
    rm -f "$all_files_tmp" "$uncached_tmp" "${uncached_tmp}.sorted"
    ALL_FILES_TMP=""
    UNCACHED_TMP=""
    printf '\n'

    # -------------------------------------------------------------------------
    # PHASE 4 : Classification finale
    # -------------------------------------------------------------------------
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 4 — Classification\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    local -a unclassified_hashes=()
    local cached_entry4 cached_status4
    for hash in "${!TORRENT_NAMES[@]}"; do
        instance="${TORRENT_INSTANCE[$hash]:-}"
        cached_entry4="${TORRENT_CACHE["${hash}|${instance}"]:-}"
        if [ -n "$cached_entry4" ]; then
            # CORRECTION : un torrent déjà classifié lors d'un run précédent
            # (pas reclassifié ici pour éviter de refaire le scan de fichiers)
            # doit quand même être remis dans TAG_BATCHES, sinon son tag est
            # supprimé en fin de run (nettoyage) sans jamais être réappliqué.
            cached_status4="${cached_entry4%|*}"
            case "$cached_status4" in
                # "linked", "cross_linked" et "partial" ne sont pas comptés
                # ici : la Phase 2 recalcule ces trois statuts À CHAQUE run
                # (elle ne les court-circuite jamais depuis le cache, sauf
                # "linked"-caché qui est déjà compté via arr_skipped), donc
                # ce hash a déjà été compté par la Phase 2 ce run-ci. Un
                # double comptage se produirait sinon.
                linked)       batch_add "$instance" "$TAG_LINKED" "$hash" ;;
                partial)      batch_add "$instance" "$TAG_PARTIAL" "$hash" ;;
                cross_linked) batch_add "$instance" "$TAG_CROSS_LINKED" "$hash" ;;
                no_media)     batch_add "$instance" "$TAG_NO_MEDIA" "$hash"
                              torrent_no_media=$((torrent_no_media + 1)) ;;
                orphan)       batch_add "$instance" "$TAG_ORPHAN" "$hash"
                              torrent_orphan=$((torrent_orphan + 1)) ;;
                delete_ready) batch_add "$instance" "$TAG_DELETE" "$hash"
                              torrent_delete_ready=$((torrent_delete_ready + 1)) ;;
            esac
            continue
        fi
        unclassified_hashes+=("$hash")
    done

    local total_unclass class_idx all_in_media any_cross file_count
    total_unclass=${#unclassified_hashes[@]}
    printf '   📊 %d torrent(s) à classifier\n' "$total_unclass"
    class_idx=0
    for hash in "${unclassified_hashes[@]}"; do
        class_idx=$((class_idx + 1))
        instance="${TORRENT_INSTANCE[$hash]}"
        name="${TORRENT_NAMES[$hash]}"
        hpath="${TORRENT_HOST_PATH[$hash]:-}"
        printf '   [%d/%d] %s... ' "$class_idx" "$total_unclass" "${name:0:60}"

        if [ ! -e "$hpath" ]; then
            printf '⚠️  absent\n'
            continue
        fi

        # CORRECTION : compteur de fichiers média pour détecter les torrents sans média
        all_in_media=true
        any_cross=false
        file_count=0
        while IFS=$'\t' read -r finode _ f; do
            file_count=$((file_count + 1))
            if [ "${INODE_IN_MEDIA[$finode]:-false}" = true ]; then
                [ "${INODE_IN_CROSS[$finode]:-false}" = true ] && any_cross=true
            else
                all_in_media=false
            fi
        done < <(scan_torrent_files "$hash" "$hpath")

        # CORRECTION : torrent sans fichier média
        if [ "$file_count" -eq 0 ]; then
            printf '⚠️  sans média\n'
            batch_add "$instance" "$TAG_NO_MEDIA" "$hash"
            save_torrent_entry "$hash" "$instance" "no_media"
            torrent_no_media=$((torrent_no_media + 1))
            continue
        fi

        if $all_in_media; then
            if $any_cross; then
                printf '🔗 cross-linked\n'
                batch_add "$instance" "$TAG_CROSS_LINKED" "$hash"
                torrent_cross_linked=$((torrent_cross_linked + 1))
                save_torrent_entry "$hash" "$instance" "cross_linked"
            else
                printf '✅ linked\n'
                batch_add "$instance" "$TAG_LINKED" "$hash"
                torrent_direct=$((torrent_direct + 1))
                save_torrent_entry "$hash" "$instance" "linked"
            fi
        else
            printf '❌ orphelin\n'
            batch_add "$instance" "$TAG_ORPHAN" "$hash"
            torrent_orphan=$((torrent_orphan + 1))
            # CORRECTION : contrairement aux autres statuts (linked, cross_linked,
            # no_media, delete_ready), "orphan" n'était jamais persisté. Résultat :
            # un torrent qui reste orphelin d'un run à l'autre repassait à chaque
            # fois par le parcours de fichiers complet des Phases 2/3/4 au lieu de
            # profiter du cache comme tous les autres statuts.
            save_torrent_entry "$hash" "$instance" "orphan"
        fi
    done
    printf '   ✓ Phase 4 terminée\n'

    # Application immédiate des tags Orphelin/Partiel dans qBittorrent (avant
    # la réparation, potentiellement longue, pour que l'état soit visible
    # dans l'UI même si le script est interrompu ensuite).
    printf '   🏷️  Tagging Orphelin/Partiel dans qBittorrent...\n'
    local hashes tag
    for instance in "${INSTANCES[@]}"; do
        for tag in "$TAG_ORPHAN" "$TAG_PARTIAL"; do
            hashes="${TAG_BATCHES[${instance}|${tag}]:-}"
            [ -z "$hashes" ] && continue
            hashes=$(printf '%s' "$hashes" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
            [ -z "$hashes" ] && continue
            printf '      [%s] %d torrent(s) → « %s »\n' "$instance" "$(echo "$hashes" | wc -w)" "$tag"
            apply_tag_batches "$instance" "$tag" "$hashes"
        done
    done
    printf '\n'

    # -------------------------------------------------------------------------
    # PHASE 5 : Réparation automatique des orphelins et des partiels (optionnel)
    # -------------------------------------------------------------------------
    # La réparation passe AVANT la vérification de durée de seed (Phase 6) :
    # un orphelin déjà seedé assez longtemps sur son tracker doit d'abord être
    # tenté en hardlink plutôt que basculer directement en "à effacer" sans
    # avoir eu la chance d'être relié à la bibliothèque.
    if ! $AUTO_REPAIR; then
        printf '═══════════════════════════════════════════════════════════════\n'
        printf 'PHASE 5 — Réparation des orphelins/partiels (DÉSACTIVÉE)\n'
        printf '═══════════════════════════════════════════════════════════════\n'
        printf '   AUTO_REPAIR=false → les orphelins ne sont pas réparés.\n'
        printf '\n'
    else
        printf '═══════════════════════════════════════════════════════════════\n'
        printf 'PHASE 5 — Réparation des orphelins/partiels\n'
        printf '═══════════════════════════════════════════════════════════════\n'

        # Seuls les fichiers revendiqués par Radarr/Sonarr servent de cible.
        if [ "${#MEDIA_SIZE_INDEX[@]}" -eq 0 ]; then
            printf '   ⚠️  Index de réparation vide : aucun fichier revendiqué par les API\n'
            printf '      Radarr/Sonarr. Aucune réparation ne sera tentée (les fichiers\n'
            printf '      présents dans MEDIA_DIRS mais inconnus des Arr ne sont pas des\n'
            printf '      cibles valides).\n'
        else
            printf '   🗂️  Index de réparation : %d taille(s) distincte(s) issues des Arr\n' \
                "${#MEDIA_SIZE_INDEX[@]}"
        fi

        # On traite les lots Orphelin ET Partiel : un pack de saison
        # partiellement lié doit lui aussi tenter de réparer ses épisodes
        # manquants, pas seulement les torrents 100% orphelins.
        local orphan_count=0
        local source_tag hashes_str
        for instance in "${INSTANCES[@]}"; do
            for source_tag in "$TAG_ORPHAN" "$TAG_PARTIAL"; do
                hashes_str="${TAG_BATCHES[${instance}|${source_tag}]:-}"
                local hash
                for hash in $hashes_str; do
                    [ -z "$hash" ] && continue
                    name="${TORRENT_NAMES[$hash]:-}"
                    hpath="${TORRENT_HOST_PATH[$hash]:-}"
                    orphan_count=$((orphan_count + 1))
                    printf '  ⚠️  [%d] %s\n' "$orphan_count" "${name:0:70}"

                    if [ ! -e "$hpath" ]; then
                        printf '       ❌ Introuvable\n'
                        continue
                    fi

                    # Réparation fichier par fichier : on compte combien de
                    # fichiers restaient à réparer et combien ont réussi, pour
                    # savoir si le torrent devient entièrement "linked" ou
                    # seulement "partial" (au lieu de tout-ou-rien comme avant,
                    # ce qui ratait les torrents partiellement réparés).
                    local needs_repair=0 fixed=0
                    while IFS=$'\t' read -r finode _ f; do
                        [ "${INODE_IN_MEDIA[$finode]:-false}" = true ] && continue
                        needs_repair=$((needs_repair + 1))
                        if try_repair_file "$f"; then
                            repaired_count=$((repaired_count + 1))
                            fixed=$((fixed + 1))
                        fi
                    done < <(scan_torrent_files "$hash" "$hpath")

                    # En dry-run, create_hardlink_atomic n'écrit rien : $fixed
                    # ne reflète qu'une simulation. On ne doit surtout pas
                    # persister "linked"/"partial" sur cette base, sinon un
                    # vrai run ultérieur croirait le torrent déjà réparé.
                    if $DRY_RUN; then
                        if [ "$needs_repair" -gt 0 ] && [ "$fixed" -eq "$needs_repair" ]; then
                            printf '       🧪 [DRY-RUN] deviendrait entièrement Linked (non appliqué)\n'
                        elif [ "$fixed" -gt 0 ]; then
                            printf '       🧪 [DRY-RUN] %d/%d fichier(s) réparable(s) → resterait/deviendrait Partial (non appliqué)\n' "$fixed" "$needs_repair"
                        fi
                    elif [ "$needs_repair" -gt 0 ] && [ "$fixed" -eq "$needs_repair" ]; then
                        printf '       🔄 Torrent entièrement réparé → re-tagage Linked\n'
                        batch_remove "$instance" "$source_tag" "$hash"
                        batch_add "$instance" "$TAG_LINKED" "$hash"
                        save_torrent_entry "$hash" "$instance" "linked"
                    elif [ "$fixed" -gt 0 ]; then
                        printf '       🟡 %d/%d fichier(s) réparé(s) → re-tagage Partial\n' "$fixed" "$needs_repair"
                        batch_remove "$instance" "$source_tag" "$hash"
                        batch_add "$instance" "$TAG_PARTIAL" "$hash"
                        save_torrent_entry "$hash" "$instance" "partial"
                    fi
                    printf '\n'
                done
            done
        done

        printf '   ✓ %d fichier(s) réparé(s) sur %d torrent(s) orphelin(s)/partiel(s)\n' "$repaired_count" "$orphan_count"

        # Application des tags Linked/Partial pour les torrents (re)réparés
        if [ "$repaired_count" -gt 0 ]; then
            printf '   🏷️  Tagging des torrents réparés...\n'
            for instance in "${INSTANCES[@]}"; do
                for tag in "$TAG_LINKED" "$TAG_PARTIAL"; do
                    hashes="${TAG_BATCHES[${instance}|${tag}]:-}"
                    [ -z "$hashes" ] && continue
                    hashes=$(printf '%s' "$hashes" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
                    [ -z "$hashes" ] && continue
                    printf '      [%s] %d torrent(s) → « %s »\n' "$instance" "$(echo "$hashes" | wc -w)" "$tag"
                    apply_tag_batches "$instance" "$tag" "$hashes"
                done
            done
        fi
        printf '\n'
    fi

    # La Phase 5 remplace des fichiers par des hardlinks : leurs inodes ont
    # changé. Toute mémoïsation de parcours antérieure est donc périmée et ne
    # doit pas être réutilisée par la Phase 7.
    reset_scan_memo

    # -------------------------------------------------------------------------
    # PHASE 6 : Vérification durée minimale de seed par tracker
    # -------------------------------------------------------------------------
    # Ne porte plus que sur les orphelins n'ayant pas pu être réparés
    # ci-dessus (Phase 5) : un torrent réparé est déjà "linked" et n'est
    # plus dans le lot orphan à ce stade.
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 6 — Vérification durée seed minimale (trackers)\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    load_tracker_secrets

    for instance in "${INSTANCES[@]}"; do
        local orphan_hashes
        orphan_hashes="${TAG_BATCHES[${instance}|${TAG_ORPHAN}]:-}"
        [ -z "$orphan_hashes" ] && continue

        local -a orphan_arr=()
        read -ra orphan_arr <<< "$orphan_hashes"

        local hash tracker_domain min_hours seed_hours
        for hash in "${orphan_arr[@]}"; do
            [ -z "$hash" ] && continue

            tracker_domain=$(get_torrent_tracker_domain "$instance" "$hash")
            if [ -z "$tracker_domain" ]; then
                printf '   [%s] %-50s : tracker non détecté (ignoré)\n' \
                    "$instance" "${TORRENT_NAMES[$hash]:0:50}"
                continue
            fi

            min_hours=$(get_tracker_min_seed_hours "$tracker_domain")
            TRACKER_MIN_SEED["$tracker_domain"]="$min_hours"

            if [ "$min_hours" -eq 999999 ]; then
                printf '   [%s] %-50s : %s → conservatoire\n' \
                    "$instance" "${TORRENT_NAMES[$hash]:0:50}" "$tracker_domain"
                continue
            fi

            seed_hours=$(get_torrent_seed_hours "$instance" "$hash")
            [ -z "$seed_hours" ] && seed_hours=0

            if [ "$seed_hours" -ge "$min_hours" ]; then
                printf '   [%s] %-40s : %sh >= %sh (%s) → %s\n' \
                    "$instance" "${TORRENT_NAMES[$hash]:0:40}" "$seed_hours" "$min_hours" "$tracker_domain" "$TAG_DELETE"
                batch_remove "$instance" "$TAG_ORPHAN" "$hash"
                batch_add "$instance" "$TAG_DELETE" "$hash"
                save_torrent_entry "$hash" "$instance" "delete_ready"
                torrent_delete_ready=$((torrent_delete_ready + 1))
            else
                printf '   [%s] %-40s : %sh < %sh (%s) → conserve Orphelin\n' \
                    "$instance" "${TORRENT_NAMES[$hash]:0:40}" "$seed_hours" "$min_hours" "$tracker_domain"
            fi
        done
    done
    printf '\n'

    # -------------------------------------------------------------------------
    # PHASE 7 : Orphelins de disque (fichiers médias ni ARR ni torrent)
    # -------------------------------------------------------------------------
    if $SCAN_DISK_ORPHANS; then
        phase7_scan_disk_orphans
    fi

    # -------------------------------------------------------------------------
    # PHASE 8 : Nettoyage des anciens tags
    # -------------------------------------------------------------------------
    # On repart d'une ardoise propre sur chaque torrent avant de réappliquer
    # (Phase 9) les tags calculés lors de ce run : évite l'accumulation de
    # tags obsolètes (ex. un torrent réparé qui garderait "orphan" en plus
    # de "linked").
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 8 — Nettoyage des anciens tags\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    local delete_tags_str all_hashes
    delete_tags_str=$(printf "%s," "${DELETE_TAGS[@]}" | sed 's/,$//')
    for instance in "${INSTANCES[@]}"; do
        all_hashes=""
        local hash
        # CORRECTION : ne garder que les torrents de CETTE instance (avant,
        # les hashes de VPN et DIRECT étaient tous envoyés aux deux instances).
        for hash in "${!TORRENT_NAMES[@]}"; do
            [ "${TORRENT_INSTANCE[$hash]:-}" = "$instance" ] && all_hashes="${all_hashes}${hash} "
        done
        all_hashes="${all_hashes% }"
        if [ -n "$all_hashes" ]; then
            printf '   🧹 [%s] Suppression des tags sur %d torrent(s)...\n' "$instance" "$(echo "$all_hashes" | wc -w)"
            remove_tags_batches "$instance" "$delete_tags_str" "$all_hashes"
        fi
    done
    printf '\n'

    # -------------------------------------------------------------------------
    # PHASE 9 : Application des nouveaux tags
    # -------------------------------------------------------------------------
    printf '═══════════════════════════════════════════════════════════════\n'
    printf 'PHASE 9 — Application des nouveaux tags\n'
    printf '═══════════════════════════════════════════════════════════════\n'

    local tag
    for instance in "${INSTANCES[@]}"; do
        for tag in "$TAG_LINKED" "$TAG_CROSS_LINKED" "$TAG_PARTIAL" \
                   "$TAG_NO_MEDIA" "$TAG_ORPHAN" "$TAG_DELETE"; do
            hashes="${TAG_BATCHES[${instance}|${tag}]:-}"
            [ -z "$hashes" ] && continue
            hashes=$(printf '%s' "$hashes" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
            [ -z "$hashes" ] && continue
            printf '   🏷️  [%s] « %s » → %d torrent(s)\n' "$instance" "$tag" "$(echo "$hashes" | wc -w)"
            apply_tag_batches "$instance" "$tag" "$hashes"
            sleep 0.2
        done
    done

    printf '\n'
    printf '💾 Sauvegarde finale des caches...\n'
    save_hash_cache_merge
    save_arr_inodes_bulk
    save_inode_cache_bulk
    save_torrent_cache_bulk
    save_torrent_list_cache


    # -------------------------------------------------------------------------
    # RAPPORT FINAL
    # -------------------------------------------------------------------------
    local end_ts duration
    end_ts=$(date +%s)
    duration=$((end_ts - start_ts))

    printf '\n'
    printf '╔══════════════════════════════════════════════════════════════╗\n'
    printf '║                     RAPPORT FINAL                           ║\n'
    printf '╠══════════════════════════════════════════════════════════════╣\n'
    printf '║  Total torrents traités     : %6d                      ║\n' "$total"
    printf '║  ✅  Direct (Arr/linked)    : %6d                      ║\n' "$torrent_direct"
    printf '║  🔗  Cross-linked           : %6d                      ║\n' "$torrent_cross_linked"
    printf '║  🟡  Partiel                : %6d                      ║\n' "$torrent_partial"
    printf '║  ⚠️   Orphelin              : %6d                      ║\n' "$torrent_orphan"
    printf '║  📀  Sans média             : %6d                      ║\n' "$torrent_no_media"
    [ "$torrent_delete_ready" -gt 0 ] && printf '║  🗑️   À effacer              : %6d                      ║\n' "$torrent_delete_ready"
    if [ "$repaired_count" -gt 0 ]; then
        if $DRY_RUN; then
            printf '║  🧪  Fichiers réparables    : %6d (simulation)         ║\n' "$repaired_count"
        else
            printf '║  🔧  Fichiers réparés       : %6d                      ║\n' "$repaired_count"
        fi
    fi
    printf '╠══════════════════════════════════════════════════════════════╣\n'
    $DRY_RUN && printf '║  🧪  DRY-RUN : aucune modification appliquée               ║\n'
    printf '║  ⏱️  Durée                  : %6d secondes            ║\n' "$duration"
    printf '╚══════════════════════════════════════════════════════════════╝\n'
}

# =============================================================================
# FONCTION AUXILIAIRE : scan direct des médias pour compléter les inodes Arr
# =============================================================================

# Complète ARR_MANAGED_INODES avec tout ce que contient réellement
# MEDIA_DIRS : ces fichiers sont bien « dans la bibliothèque » (ce qui suffit
# aux Phases 2 à 5), mais ils ne sont PAS revendiqués par Radarr/Sonarr — ils
# sont donc marqués "scan" et non "api", faute de quoi la Phase 7 les
# considérerait comme gérés et ne pourrait plus rien détecter.
scan_media_dirs_for_inodes() {
    local media_path f minode msize media_dev
    MEDIA_SIZE_INDEX=()
    for media_path in "${MEDIA_DIRS[@]}"; do
        [ -d "$media_path" ] || continue
        # Device du répertoire, capturé une fois : un hardlink n'est possible
        # qu'entre fichiers du même système de fichiers.
        media_dev=$(get_fs_id "$media_path")
        while IFS=$'\t' read -r minode msize f; do
            [ "$minode" = "0" ] && continue
            if [ -n "${ARR_MANAGED_INODES[$minode]:-}" ]; then
                # Déjà indexé par l'API : c'est une cible de réparation
                # légitime, on l'ajoute à l'index par taille.
                [ "${ARR_INODE_SOURCE[$minode]:-}" = "api" ] && \
                    MEDIA_SIZE_INDEX["$msize"]+="${media_dev}"$'\t'"${minode}"$'\t'"${f}"$'\n'
                continue
            fi
            # Présent sur le disque mais non revendiqué par les Arr : compte
            # comme « déjà dans la bibliothèque » pour la détection (Phases 2
            # à 4), mais JAMAIS comme cible de réparation — c'est justement
            # ce que la Phase 7 signale comme orphelin de disque à nettoyer.
            # Y hardlinker un torrent ne ferait qu'un gain illusoire, annulé
            # dès que le fichier serait supprimé.
            ARR_MANAGED_INODES["$minode"]="$f"
            ARR_INODE_SOURCE["$minode"]="scan"
        done < <(scan_files "$MEDIA_EXTENSIONS_CSV" "$media_path")
    done
    MEDIA_SIZE_INDEX_READY=true
    save_arr_inodes_bulk
}

# Indexe les inodes présents sous CROSS_SEED_DIR, pour la Phase 3 (détection
# "cross-linked" par inode réel, pas par préfixe de chemin — cf. scan des médias).
scan_cross_seed_dir_for_inodes() {
    CROSS_SEED_INODES=()
    [ -z "$CROSS_SEED_DIR" ] && return
    [ -d "$CROSS_SEED_DIR" ] || return
    local f cinode
    while IFS=$'\t' read -r cinode _ f; do
        [ "$cinode" = "0" ] && continue
        CROSS_SEED_INODES["$cinode"]="$f"
    done < <(scan_files "$MEDIA_EXTENSIONS_CSV" "$CROSS_SEED_DIR")
}

main "$@"
exit 0
