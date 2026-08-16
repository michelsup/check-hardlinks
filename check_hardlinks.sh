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
DISK_ORPHAN_EXTENSIONS=("${DISK_ORPHAN_EXTENSIONS[@]:-}")
CROSS_SEED_DIR="${CROSS_SEED_DIR:-}"
TMPDIR="${TMPDIR:-/tmp}"

CACHE_DIR="${SCRIPT_DIR}/cleanup"
mkdir -p "$CACHE_DIR"

# -----------------------------------------------------------------------------
# VARIABLES GLOBALES
# -----------------------------------------------------------------------------

# Connexions qBittorrent
declare -A QBIT_COOKIES

# Caches disque
declare -A HASH_CACHE
declare -A INODE_STATUS_CACHE
declare -A TORRENT_CACHE

# Métadonnées torrents
declare -A TORRENT_NAMES
declare -A TORRENT_INSTANCE
declare -A TORRENT_SAVE_PATH
declare -A TORRENT_HOST_PATH
# Tracker et temps de seed déjà présents dans /torrents/info (Phase 0),
# utilisés en Phase 6 pour éviter un appel API séparé par torrent.
declare -A TORRENT_TRACKER
declare -A TORRENT_SEEDING_TIME

# Inodes gérés par les Arr (Radarr/Sonarr)
declare -A ARR_MANAGED_INODES

# Inodes présents dans CROSS_SEED_DIR
declare -A CROSS_SEED_INODES

# Position des inodes (dans MEDIA_DIRS ou CROSS_SEED_DIR)
declare -A INODE_IN_MEDIA
declare -A INODE_IN_CROSS

# Batches de tags à appliquer par instance
declare -A TAG_BATCHES

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
save_all_caches() {
    save_hash_cache_merge
    save_torrent_list_cache
    save_arr_inodes_bulk
    save_inode_cache_bulk
    save_torrent_cache_bulk
    rm -f "$ALL_FILES_TMP" "${UNCACHED_TMP}" "${UNCACHED_TMP}.sorted" 2>/dev/null
}

# Interruption explicite (Ctrl+C, kill, déconnexion du terminal)
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
do_chown()  { ! $DRY_RUN && $CHOWN_FILES && chown "$CHOWN_USER" "$1" 2>/dev/null || true; }

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
# TRANSLATION DE CHEMINS (Docker → Hôte)
# -----------------------------------------------------------------------------
# Les containers qBittorrent voient /data/completed, l'hôte voit /mnt/tank/...
# PATH_MAP fait ce pont de manière bidirectionnelle.
# CORRECTION : parcours trié par préfixe le plus long d'abord pour éviter
# qu'un préfixe court masque un préfixe plus spécifique.
translate_path() {
    local container_path="$1"

    # Si le chemin est déjà un chemin hôte, on le retourne tel quel
    if [[ "$container_path" == /mnt/* ]] || [[ "$container_path" == /tank/* ]]; then
        printf '%s' "$container_path"
        return
    fi

    local host_path="$container_path"
    local container_prefix matched=""
    for container_prefix in $(printf '%s\n' "${!PATH_MAP[@]}" | awk '{print length, $0}' | sort -nr | cut -d' ' -f2-); do
        if [[ "$container_path" == "$container_prefix"/* ]]; then
            local suffix="${container_path#$container_prefix/}"
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
    > "$tmpfile"
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
    [ ! -f "$INODE_CACHE_FILE" ] && return
    local inode status sample_path mtime ci
    while IFS='|' read -r inode status sample_path mtime; do
        [ -z "$inode" ] && continue
        # Vérification : le fichier sample existe-t-il encore avec le même inode ?
        if [ -n "$sample_path" ] && [ -f "$sample_path" ]; then
            ci=$(stat -c '%i' "$sample_path" 2>/dev/null || echo "0")
            [ "$ci" = "$inode" ] && INODE_STATUS_CACHE["$inode"]="$status"
        fi
    done < "$INODE_CACHE_FILE"
    printf '   📦 Cache inodes : %d entrées\n' "${#INODE_STATUS_CACHE[@]}"
}

# Écriture incrémentale (append) d'une entrée du cache d'inodes ; la
# réécriture complète et propre du fichier se fait via save_inode_cache_bulk.
save_inode_entry() {
    local inode="$1" status="$2" sample_path="$3"
    printf '%s|%s|%s|%s\n' "$inode" "$status" "$sample_path" "$(date +%s)" >> "$INODE_CACHE_FILE"
}

# Sauvegarde atomique complète du cache d'inodes (remplace les append infinis)
save_inode_cache_bulk() {
    [ "${#INODE_STATUS_CACHE[@]}" -eq 0 ] && return
    local tmpfile="${INODE_CACHE_FILE}.$$"
    > "$tmpfile"
    local inode
    for inode in "${!INODE_STATUS_CACHE[@]}"; do
        # On ne peut pas restaurer le sample_path, on laisse vide
        printf '%s|%s||%s\n' "$inode" "${INODE_STATUS_CACHE[$inode]}" "$(date +%s)" >> "$tmpfile"
    done
    mv "$tmpfile" "$INODE_CACHE_FILE" 2>/dev/null
}

# --- Cache de statut des torrents ---
load_torrent_cache() {
    TORRENT_CACHE=()
    [ ! -f "$TORRENT_CACHE_FILE" ] && return
    local hash instance status timestamp
    while IFS='|' read -r hash instance status timestamp; do
        [ -z "$hash" ] && continue
        TORRENT_CACHE["${hash}|${instance}"]="${status}|${timestamp}"
    done < "$TORRENT_CACHE_FILE"
    printf '   📦 Cache torrents : %d entrées\n' "${#TORRENT_CACHE[@]}"
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
    > "$tmpfile"
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
save_torrent_cache_bulk() {
    [ "${#TORRENT_CACHE[@]}" -eq 0 ] && return
    local tmpfile="${TORRENT_CACHE_FILE}.$$"
    > "$tmpfile"
    local key
    for key in "${!TORRENT_CACHE[@]}"; do
        printf '%s|%s\n' "$key" "${TORRENT_CACHE[$key]}" >> "$tmpfile"
    done
    mv "$tmpfile" "$TORRENT_CACHE_FILE" 2>/dev/null
}

# --- Cache des inodes Arr ---
load_arr_inodes() {
    ARR_MANAGED_INODES=()
    [ ! -f "$ARR_INODES_FILE" ] && return
    local inode path
    while IFS='|' read -r inode path; do
        [ -z "$inode" ] && continue
        [ -f "$path" ] && ARR_MANAGED_INODES["$inode"]="$path"
    done < "$ARR_INODES_FILE"
    printf '   📦 Cache Arr inodes : %d entrées\n' "${#ARR_MANAGED_INODES[@]}"
}

save_arr_inodes_bulk() {
    local tmpfile="${ARR_INODES_FILE}.$$"
    > "$tmpfile"
    local inode
    for inode in "${!ARR_MANAGED_INODES[@]}"; do
        printf '%s|%s\n' "$inode" "${ARR_MANAGED_INODES[$inode]}" >> "$tmpfile"
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
batch_add() {
    local inst="$1" tag="$2" hash="$3"
    TAG_BATCHES["${inst}|${tag}"]="${TAG_BATCHES[${inst}|${tag}]}${hash} "
}

# Retire un hash d'un lot déjà accumulé (ex. un orphelin réparé qui doit
# sortir du lot TAG_ORPHAN avant d'entrer dans TAG_LINKED).
batch_remove() {
    local inst="$1" tag="$2" hash="$3"
    local current="${TAG_BATCHES[${inst}|${tag}]:-}"
    [ -z "$current" ] && return
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
_fetch_sonarr_episodefile() {
    local series_id="$1" url="$2" key="$3" outdir="$4"
    local resp
    # Clé API passée via -K - (stdin), pas en argument -H, pour ne pas
    # l'exposer dans `ps aux` — d'autant plus visible ici avec jusqu'à 8
    # appels curl concurrents (voir fetch_arr_inodes_bulk).
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
            > "$cache_raw"
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
            > "$cache_raw"
        else
            > "$cache_raw"
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
" | xargs -P 8 -I{} bash -c '_fetch_sonarr_episodefile "$@"' _ {} "$url" "$key" "$parallel_dir"
                cat "$parallel_dir"/*.txt > "$cache_raw" 2>/dev/null
                rm -rf "$parallel_dir"
            fi

            if [ -s "$cache_raw" ]; then
                printf 'OK (%s séries)\n' "$series_count"
            else
                printf '⚠️ vide\n'
                > "$cache_raw"
            fi
        fi
    fi

    # Fallback si l'API est vide ou inaccessible
    if [ ! -s "$cache_raw" ]; then
        printf '⚠️ API vide, scan filesystem... '
        > "$cache_raw"
        local media_path
        for media_path in "${MEDIA_DIRS[@]}"; do
            [ -d "$media_path" ] && \
                find "$media_path" -type f \( -name "*.mkv" -o -name "*.mp4" -o \
                    -name "*.avi" -o -name "*.ts" \) 2>/dev/null >> "$cache_raw"
        done
    fi

    # Traduction des chemins et indexation par inode
    local count=0
    local raw_path
    while IFS= read -r raw_path; do
        [ -z "$raw_path" ] && continue
        local host_path
        host_path=$(translate_path "$raw_path")
        [ ! -f "$host_path" ] && continue
        local inode
        inode=$(stat -c '%i' "$host_path" 2>/dev/null || echo "0")
        [ "$inode" = "0" ] && continue
        ARR_MANAGED_INODES["$inode"]="$host_path"
        count=$((count + 1))
    done < "$cache_raw"

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

    # Candidats : même taille, même filesystem
    local -a all_candidates=()
    local media_dir media_dev
    for media_dir in "${MEDIA_DIRS[@]}"; do
        [ ! -d "$media_dir" ] && continue
        media_dev=$(get_fs_id "$media_dir")
        if [ "$orphan_dev" -ne "$media_dev" ]; then
            debug_log "try_repair_file : $media_dir ignoré (device $media_dev ≠ device orphelin $orphan_dev, hardlink impossible)"
            continue
        fi
        local c
        while IFS= read -r -d '' c; do
            all_candidates+=("$c")
        done < <(find "$media_dir" -type f -size "${fsize}c" -print0 2>/dev/null)
    done

    local total_candidates=${#all_candidates[@]}
    printf '       🔍 %d candidat(s) de même taille\n' "$total_candidates"
    [ "$total_candidates" -eq 0 ] && return 1

    # Split : noms similaires en priorité, fallback sinon
    # CORRECTION : tableau associatif pour déduplication rapide
    local -a priority=() fallback=()
    declare -A seen_inodes
    local candidate c_inode orphan_inode
    orphan_inode=$(stat -c '%i' "$orphan_file" 2>/dev/null || echo "0")
    for candidate in "${all_candidates[@]}"; do
        [ "$candidate" = "$orphan_file" ] && continue
        c_inode=$(stat -c '%i' "$candidate" 2>/dev/null || echo "0")

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
    declare -gA TRACKER_MIN_SEED
    TRACKER_MIN_SEED=()
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
    > "$tmpfile"
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
            printf '   Entrée invalide. Entrez un nombre entier d’heures (ex: 72).\n'
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

    printf '   Répertoires configurés : %d\n' "${#MEDIA_DIRS[@]}"

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

    # Indexation rapide : inodes déjà connus par les torrents
    declare -A TORRENT_INODE_HASH
    local hash hpath f finode
    for hash in "${!TORRENT_NAMES[@]}"; do
        hpath="${TORRENT_HOST_PATH[$hash]:-}"
        [ ! -e "$hpath" ] && continue
        while IFS= read -r -d '' f; do
            finode=$(stat -c '%i' "$f" 2>/dev/null || echo "0")
            [ "$finode" = "0" ] && continue
            TORRENT_INODE_HASH["$finode"]="$hash"
        done < <(find "$hpath" -type f -print0 2>/dev/null)
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

        local -a find_args=()
        find_args+=("$media_dir")
        find_args+=("-type" "f")

        if [ "${#DISK_ORPHAN_EXTENSIONS[@]}" -gt 0 ] 2>/dev/null; then
            local ext_idx ext
            for ext_idx in "${!DISK_ORPHAN_EXTENSIONS[@]}"; do
                ext="${DISK_ORPHAN_EXTENSIONS[$ext_idx]}"
                if [ "$ext_idx" -eq 0 ]; then
                    find_args+=("(" "-iname" "*.${ext}")
                else
                    find_args+=("-o" "-iname" "*.${ext}")
                fi
            done
            find_args+=(")")
        fi

        find_args+=("-print0")

        local fpath fsize
        while IFS= read -r -d '' fpath; do
            finode=$(stat -c '%i' "$fpath" 2>/dev/null || echo "0")
            [ "$finode" = "0" ] && continue

            fsize=$(stat -c '%s' "$fpath" 2>/dev/null || echo "0")
            [ "$fsize" -lt "$min_size" ] && continue

            [ -n "${ARR_MANAGED_INODES[$finode]:-}" ] && continue
            [ -n "${TORRENT_INODE_HASH[$finode]:-}" ] && continue

            disk_orphan_count=$((disk_orphan_count + 1))
            disk_orphan_bytes=$((disk_orphan_bytes + fsize))
            printf '%s\t%s\t%s\n' "$finode" "$fsize" "$fpath" >> "$disk_orphan_log"
            printf '      ⚠️  %s\n' "$fpath"

        done < <(find "${find_args[@]}" 2>/dev/null)

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
    printf '\n'

    if ! command -v curl &>/dev/null; then printf '❌ curl requis\n'; exit 1; fi
    if ! command -v python3 &>/dev/null; then printf '❌ python3 requis\n'; exit 1; fi
    pick_hash_tool
    printf '🔧 Hachage : %s\n' "$HASH_CMD"
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
    if [ "$ARR_CACHE_DURATION" -gt 0 ] && [ "${#ARR_MANAGED_INODES[@]}" -gt 0 ]; then
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
        while IFS= read -r -d '' f; do
            any_file=true
            finode=$(stat -c '%i' "$f" 2>/dev/null || echo "0")
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
        done < <(find "$hpath" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.ts" -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" \) -print0 2>/dev/null)

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

        while IFS= read -r -d '' f; do
            finode=$(stat -c '%i' "$f" 2>/dev/null || echo "0")
            [ "$finode" = "0" ] && continue
            printf '%s|%s|%s\n' "$finode" "$hash" "$f" >> "$all_files_tmp"
        done < <(find "$hpath" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.ts" -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" \) -print0 2>/dev/null)
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
        while IFS= read -r -d '' f; do
            file_count=$((file_count + 1))
            finode=$(stat -c '%i' "$f" 2>/dev/null || echo "0")
            if [ "${INODE_IN_MEDIA[$finode]:-false}" = true ]; then
                [ "${INODE_IN_CROSS[$finode]:-false}" = true ] && any_cross=true
            else
                all_in_media=false
            fi
        done < <(find "$hpath" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.ts" -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" \) -print0 2>/dev/null)

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
                    while IFS= read -r -d '' f; do
                        finode=$(stat -c '%i' "$f" 2>/dev/null || echo "0")
                        [ "${INODE_IN_MEDIA[$finode]:-false}" = true ] && continue
                        needs_repair=$((needs_repair + 1))
                        if try_repair_file "$f"; then
                            repaired_count=$((repaired_count + 1))
                            fixed=$((fixed + 1))
                        fi
                    done < <(find "$hpath" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.ts" -o -iname "*.m4v" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" \) -print0 2>/dev/null)

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

scan_media_dirs_for_inodes() {
    local media_path f minode
    for media_path in "${MEDIA_DIRS[@]}"; do
        [ -d "$media_path" ] || continue
        while IFS= read -r -d '' f; do
            minode=$(stat -c '%i' "$f" 2>/dev/null || echo "0")
            [ "$minode" = "0" ] && continue
            [ -n "${ARR_MANAGED_INODES[$minode]:-}" ] && continue
            ARR_MANAGED_INODES["$minode"]="$f"
        done < <(find "$media_path" -type f \( \
            -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o \
            -iname "*.ts" -o -iname "*.m4v" -o -iname "*.mov" -o \
            -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" \
        \) -print0 2>/dev/null)
    done
    save_arr_inodes_bulk
}

# Indexe les inodes présents sous CROSS_SEED_DIR, pour la Phase 3 (détection
# "cross-linked" par inode réel, pas par préfixe de chemin — cf. scan des médias).
scan_cross_seed_dir_for_inodes() {
    CROSS_SEED_INODES=()
    [ -z "$CROSS_SEED_DIR" ] && return
    [ -d "$CROSS_SEED_DIR" ] || return
    local f cinode
    while IFS= read -r -d '' f; do
        cinode=$(stat -c '%i' "$f" 2>/dev/null || echo "0")
        [ "$cinode" = "0" ] && continue
        CROSS_SEED_INODES["$cinode"]="$f"
    done < <(find "$CROSS_SEED_DIR" -type f \( \
        -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o \
        -iname "*.ts" -o -iname "*.m4v" -o -iname "*.mov" -o \
        -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" \
    \) -print0 2>/dev/null)
}

main "$@"
exit 0
