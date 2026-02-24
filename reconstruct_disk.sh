#!/bin/bash
set -euo pipefail

# Variables d'environnement requises
: "${VM_NAME:?Erreur: VM_NAME non defini (ex: export VM_NAME='Windows 11')}"
: "${RECON_DIR:?Erreur: RECON_DIR non defini - repertoire de reconstruction sur le Mac (ex: export RECON_DIR='/chemin/vers/reconstruction')}"
: "${RECON_SHARE:?Erreur: RECON_SHARE non defini - chemin UNC du repertoire de reconstruction vu depuis la VM (ex: export RECON_SHARE='\\\\Mac\\Home\\from-backup\\reconstruction')}"
: "${MANIFEST_FILE:?Erreur: MANIFEST_FILE non defini - chemin du manifeste genere par restore_backup_to_vm.sh}"

# Verifier que le manifeste existe
if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Erreur: manifeste introuvable: $MANIFEST_FILE"
    echo "Lancez d'abord restore_backup_to_vm.sh pour le generer."
    exit 1
fi

# Verifier les outils requis
for tool in qemu-img sgdisk prlctl; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Erreur: $tool introuvable. Installez-le d'abord."
        exit 1
    fi
done

# Configuration derivee
VM_BACKUP_DIR="C:\\WindowsImageBackup"

exec_vm() {
    prlctl exec "$VM_NAME" cmd /c "$*"
}

mkdir -p "$RECON_DIR"

# ==========================================================================
echo "=== 1/4 - Recuperation du backup repare depuis la VM ==="
# ==========================================================================

echo "  Robocopy inverse : VM -> Mac ..."
exec_vm "robocopy \"$VM_BACKUP_DIR\" \"$RECON_SHARE\" /MIR /MT:16 /J /R:3 /W:5 /NP" || true

# Trouver le sous-dossier contenant les VHDX
VHDX_DIR=$(find "$RECON_DIR" -name "*.vhdx" -print -quit | xargs dirname)
if [ -z "$VHDX_DIR" ]; then
    echo "Erreur: aucun fichier VHDX trouve dans $RECON_DIR apres la copie"
    exit 1
fi
echo "  VHDX trouves dans : $VHDX_DIR"

# ==========================================================================
echo ""
echo "=== 2/4 - Conversion des VHDX en raw et analyse GPT ==="
# ==========================================================================

# Lire le manifeste pour identifier le role de chaque VHDX
echo "  Lecture du manifeste : $MANIFEST_FILE"

# Extraire les VHDX et leurs roles depuis le manifeste
# Format attendu: filename + partitions[].role
VHDX_EFI=""
VHDX_MSR=""
VHDX_WINDOWS=""
VHDX_RECOVERY=""

# Parser le manifeste (compatible sans jq)
current_file=""
while IFS= read -r line; do
    # Detecter le nom du fichier
    if echo "$line" | grep -q '"filename"'; then
        current_file=$(echo "$line" | sed 's/.*"filename": *"\([^"]*\)".*/\1/')
    fi
    # Detecter le role
    if echo "$line" | grep -q '"role"'; then
        role=$(echo "$line" | sed 's/.*"role": *"\([^"]*\)".*/\1/')
        case "$role" in
            efi)      VHDX_EFI="$current_file" ;;
            msr)      VHDX_MSR="$current_file" ;;
            windows)  VHDX_WINDOWS="$current_file" ;;
            recovery) VHDX_RECOVERY="$current_file" ;;
            data)     # Si pas de windows identifie, data devient windows
                      [ -z "$VHDX_WINDOWS" ] && VHDX_WINDOWS="$current_file" ;;
        esac
    fi
done < "$MANIFEST_FILE"

echo "  EFI:      ${VHDX_EFI:-non detecte}"
echo "  Windows:  ${VHDX_WINDOWS:-non detecte}"
echo "  Recovery: ${VHDX_RECOVERY:-non detecte}"

if [ -z "$VHDX_WINDOWS" ]; then
    echo "Erreur: impossible d'identifier la partition Windows dans le manifeste"
    exit 1
fi

# Convertir les VHDX en raw
declare -A RAW_FILES
for role in efi windows recovery; do
    eval "vhdx=\${VHDX_$(echo $role | tr a-z A-Z):-}"
    [ -z "$vhdx" ] && continue

    raw="${RECON_DIR}/${vhdx%.vhdx}.raw"
    RAW_FILES[$role]="$raw"

    if [ -f "$raw" ]; then
        echo "  $raw existe deja, skip"
        continue
    fi
    echo "  Conversion de $vhdx -> raw ..."
    qemu-img convert -f vhdx -O raw "$VHDX_DIR/$vhdx" "$raw"
done

# ==========================================================================
echo ""
echo "=== 3/4 - Assemblage du disque GPT complet ==="
# ==========================================================================

# Parser la table GPT de chaque raw pour trouver le vrai offset de la partition utile
get_partition_info() {
    local raw_file="$1"
    # sgdisk --print retourne les partitions avec start sector et end sector
    sgdisk --print "$raw_file" 2>/dev/null | awk '
        /^ *[0-9]/ {
            num=$1; start=$2; end=$3; size=$4; unit=$5; code=$6
            # Ignorer MSR (code 0C01) et les partitions reservees
            if (code != "0C01" && code != "E3C9") {
                print start, end, code
            }
        }
    ' | head -1
}

SEC=512
ALIGN=$((1024 * 1024))

# Extraire l'offset et la taille reels de chaque partition utile
declare -A PART_START_BYTES PART_SIZE_BYTES

for role in efi windows recovery; do
    raw="${RAW_FILES[$role]:-}"
    [ -z "$raw" ] && continue

    info=$(get_partition_info "$raw")
    if [ -z "$info" ]; then
        echo "Erreur: impossible de lire la table GPT de $raw"
        exit 1
    fi

    start_sec=$(echo "$info" | awk '{print $1}')
    end_sec=$(echo "$info" | awk '{print $2}')

    start_bytes=$((start_sec * SEC))
    size_bytes=$(((end_sec - start_sec + 1) * SEC))

    PART_START_BYTES[$role]=$start_bytes
    PART_SIZE_BYTES[$role]=$size_bytes

    echo "  $role: offset=${start_bytes} octets, taille=$((size_bytes / 1024 / 1024)) Mo (secteurs $start_sec-$end_sec)"
done

# Calcul du disque final
MSR_SIZE=$((16 * 1024 * 1024))
GPT_OVERHEAD=$((2 * 1024 * 1024))  # 1 Mo debut + 1 Mo fin

EFI_SIZE=${PART_SIZE_BYTES[efi]:-0}
WIN_SIZE=${PART_SIZE_BYTES[windows]}
REC_SIZE=${PART_SIZE_BYTES[recovery]:-0}

DISK_SIZE=$((GPT_OVERHEAD + EFI_SIZE + MSR_SIZE + WIN_SIZE + REC_SIZE))

DISK_RAW="${RECON_DIR}/windows_full.raw"
echo ""
echo "  Taille disque final: $((DISK_SIZE / 1024 / 1024 / 1024)) Go"
echo "  Creation de $DISK_RAW ..."

# Creer un fichier sparse de la bonne taille
dd if=/dev/zero of="$DISK_RAW" bs=1 count=0 seek=$DISK_SIZE 2>/dev/null

# Calcul des offsets dans le disque final (alignes sur 1 Mo)
OFFSET=$ALIGN
PART_NUM=1

# Partition 1: EFI System
if [ "$EFI_SIZE" -gt 0 ]; then
    EFI_START=$OFFSET
    EFI_END=$((OFFSET + EFI_SIZE))
    EFI_START_S=$((EFI_START / SEC))
    EFI_END_S=$(((EFI_END / SEC) - 1))
    sgdisk --new=${PART_NUM}:${EFI_START_S}:${EFI_END_S} --typecode=${PART_NUM}:EF00 --change-name=${PART_NUM}:"EFI System" "$DISK_RAW"
    OFFSET=$EFI_END
    PART_NUM=$((PART_NUM + 1))
fi

# Partition 2: Microsoft Reserved
MSR_START=$OFFSET
MSR_END=$((OFFSET + MSR_SIZE))
MSR_START_S=$((MSR_START / SEC))
MSR_END_S=$(((MSR_END / SEC) - 1))
sgdisk --new=${PART_NUM}:${MSR_START_S}:${MSR_END_S} --typecode=${PART_NUM}:0C01 --change-name=${PART_NUM}:"Microsoft Reserved" "$DISK_RAW"
OFFSET=$MSR_END
PART_NUM=$((PART_NUM + 1))

# Partition 3: Windows
WIN_START=$OFFSET
WIN_END=$((OFFSET + WIN_SIZE))
WIN_START_S=$((WIN_START / SEC))
WIN_END_S=$(((WIN_END / SEC) - 1))
sgdisk --new=${PART_NUM}:${WIN_START_S}:${WIN_END_S} --typecode=${PART_NUM}:0700 --change-name=${PART_NUM}:"Windows" "$DISK_RAW"
WIN_PART_NUM=$PART_NUM
OFFSET=$WIN_END
PART_NUM=$((PART_NUM + 1))

# Partition 4: Recovery
if [ "$REC_SIZE" -gt 0 ]; then
    REC_START=$OFFSET
    REC_END=$((OFFSET + REC_SIZE))
    REC_START_S=$((REC_START / SEC))
    REC_END_S=$(((REC_END / SEC) - 1))
    sgdisk --new=${PART_NUM}:${REC_START_S}:${REC_END_S} --typecode=${PART_NUM}:2700 --change-name=${PART_NUM}:"Recovery" --attributes=${PART_NUM}:set:63 "$DISK_RAW"
    OFFSET=$REC_END
    PART_NUM=$((PART_NUM + 1))
fi

echo ""
echo "  Table GPT finale :"
sgdisk --print "$DISK_RAW"

echo ""
echo "  Ecriture des partitions dans le disque ..."

write_partition() {
    local role="$1"
    local dest_start="$2"
    local raw="${RAW_FILES[$role]}"
    local src_start="${PART_START_BYTES[$role]}"
    local size="${PART_SIZE_BYTES[$role]}"

    echo "  -> $role : $((size / 1024 / 1024)) Mo depuis offset $src_start"
    dd if="$raw" of="$DISK_RAW" \
        bs=$SEC \
        skip=$((src_start / SEC)) \
        seek=$((dest_start / SEC)) \
        count=$((size / SEC)) \
        conv=notrunc status=progress 2>&1
}

[ "$EFI_SIZE" -gt 0 ] && write_partition "efi" "$EFI_START"
write_partition "windows" "$WIN_START"
[ "$REC_SIZE" -gt 0 ] && write_partition "recovery" "$REC_START"

# Verification de la table GPT du disque final
echo ""
echo "  Verification de la table GPT ..."
sgdisk --verify "$DISK_RAW"

# ==========================================================================
echo ""
echo "=== 4/4 - Conversion en format Parallels HDD ==="
# ==========================================================================

HDD_FILE="${RECON_DIR}/windows_restored.hdd"
echo "  Conversion raw -> Parallels HDD ..."
qemu-img convert -f raw -O parallels "$DISK_RAW" "$HDD_FILE"

echo ""
echo "  Nettoyage des fichiers intermediaires ..."
rm -f "${RAW_FILES[efi]:-}" "${RAW_FILES[windows]}" "${RAW_FILES[recovery]:-}" "$DISK_RAW"

echo ""
echo "=== Termine ==="
echo "Disque Parallels cree : $HDD_FILE"
echo ""
echo "Pour l'utiliser :"
echo "  1. Creer une nouvelle VM Parallels (Windows 11, sans disque)"
echo "  2. Ajouter $HDD_FILE comme disque dur existant"
echo "  3. S'assurer que le boot EFI est active"
ls -lh "$HDD_FILE"
