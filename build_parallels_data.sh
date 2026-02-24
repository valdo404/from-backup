#!/bin/bash
set -euo pipefail

# Variables d'environnement requises
: "${RECON_DIR:?Erreur: RECON_DIR non defini - repertoire contenant les VHDX recuperes}"
: "${MANIFEST_FILE:?Erreur: MANIFEST_FILE non defini - chemin du manifeste genere par restore_backup_to_vm.sh}"

# Verifier les prerequis
if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Erreur: manifeste introuvable: $MANIFEST_FILE"
    echo "Lancez d'abord restore_backup_to_vm.sh pour le generer."
    exit 1
fi

for tool in qemu-img sgdisk; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Erreur: $tool introuvable (brew install qemu gptfdisk)"
        exit 1
    fi
done

# Trouver les VHDX
VHDX_DIR=$(find "$RECON_DIR" -name "*.vhdx" -print -quit | xargs dirname 2>/dev/null)
if [ -z "$VHDX_DIR" ]; then
    echo "Erreur: aucun VHDX dans $RECON_DIR. Lancez retrieve_from_vm.sh d'abord."
    exit 1
fi

# ==========================================================================
echo "=== 1/3 - Identification des partitions via le manifeste ==="
# ==========================================================================

# Lire le manifeste pour trouver la partition Windows (data)
VHDX_WINDOWS=""
VHDX_RECOVERY=""

current_file=""
while IFS= read -r line; do
    if echo "$line" | grep -q '"filename"'; then
        current_file=$(echo "$line" | sed 's/.*"filename": *"\([^"]*\)".*/\1/')
    fi
    if echo "$line" | grep -q '"role"'; then
        role=$(echo "$line" | sed 's/.*"role": *"\([^"]*\)".*/\1/')
        case "$role" in
            windows|data) [ -z "$VHDX_WINDOWS" ] && VHDX_WINDOWS="$current_file" ;;
            recovery)     VHDX_RECOVERY="$current_file" ;;
        esac
    fi
done < "$MANIFEST_FILE"

echo "  Windows: ${VHDX_WINDOWS:-non detecte}"
echo "  Recovery: ${VHDX_RECOVERY:-non detecte}"

if [ -z "$VHDX_WINDOWS" ]; then
    echo "Erreur: impossible d'identifier la partition Windows dans le manifeste"
    exit 1
fi

# ==========================================================================
echo ""
echo "=== 2/3 - Conversion VHDX -> raw et assemblage ==="
# ==========================================================================

SEC=512
ALIGN=$((1024 * 1024))

# Fonction: convertir un VHDX en raw et parser sa GPT
convert_and_parse() {
    local vhdx_name="$1"
    local raw_path="${RECON_DIR}/${vhdx_name%.vhdx}.raw"

    if [ ! -f "$raw_path" ]; then
        echo "  Conversion de $vhdx_name -> raw ..."
        qemu-img convert -f vhdx -O raw "$VHDX_DIR/$vhdx_name" "$raw_path"
    else
        echo "  $raw_path existe deja, skip"
    fi

    # Parser la GPT pour trouver la partition utile (ignorer MSR)
    local info
    info=$(sgdisk --print "$raw_path" 2>/dev/null | awk '
        /^ *[0-9]/ {
            num=$1; start=$2; end=$3; code=$6
            if (code != "0C01" && code != "E3C9") {
                print start, end
            }
        }
    ' | head -1)

    if [ -z "$info" ]; then
        echo "Erreur: impossible de lire la GPT de $raw_path"
        exit 1
    fi

    local start_sec end_sec
    start_sec=$(echo "$info" | awk '{print $1}')
    end_sec=$(echo "$info" | awk '{print $2}')

    echo "    Partition utile: secteurs $start_sec-$end_sec ($((( end_sec - start_sec + 1) * SEC / 1024 / 1024)) Mo)"
    echo "$raw_path $start_sec $end_sec"
}

# Convertir Windows
echo "  --- Windows ---"
WIN_INFO=$(convert_and_parse "$VHDX_WINDOWS")
WIN_RAW=$(echo "$WIN_INFO" | tail -1 | awk '{print $1}')
WIN_START_SEC=$(echo "$WIN_INFO" | tail -1 | awk '{print $2}')
WIN_END_SEC=$(echo "$WIN_INFO" | tail -1 | awk '{print $3}')
WIN_SIZE=$(((WIN_END_SEC - WIN_START_SEC + 1) * SEC))

# Convertir Recovery si present
REC_RAW="" REC_START_SEC=0 REC_END_SEC=0 REC_SIZE=0
if [ -n "$VHDX_RECOVERY" ]; then
    echo "  --- Recovery ---"
    REC_INFO=$(convert_and_parse "$VHDX_RECOVERY")
    REC_RAW=$(echo "$REC_INFO" | tail -1 | awk '{print $1}')
    REC_START_SEC=$(echo "$REC_INFO" | tail -1 | awk '{print $2}')
    REC_END_SEC=$(echo "$REC_INFO" | tail -1 | awk '{print $3}')
    REC_SIZE=$(((REC_END_SEC - REC_START_SEC + 1) * SEC))
fi

# Calculer la taille du disque (GPT simple, pas d'EFI, pas de MSR)
GPT_OVERHEAD=$((2 * ALIGN))
DISK_SIZE=$((GPT_OVERHEAD + WIN_SIZE + REC_SIZE))
DISK_RAW="${RECON_DIR}/parallels_data.raw"

echo ""
echo "  Taille disque: $((DISK_SIZE / 1024 / 1024 / 1024)) Go"
echo "  Creation de $DISK_RAW ..."
dd if=/dev/zero of="$DISK_RAW" bs=1 count=0 seek=$DISK_SIZE 2>/dev/null

# Table GPT
OFFSET=$ALIGN
PART_NUM=1

# Partition 1: Windows data
P_START=$OFFSET
P_END=$((OFFSET + WIN_SIZE))
sgdisk --new=${PART_NUM}:$((P_START / SEC)):$(((P_END / SEC) - 1)) \
    --typecode=${PART_NUM}:0700 --change-name=${PART_NUM}:"Windows Data" "$DISK_RAW"
WIN_DEST_OFFSET=$P_START
OFFSET=$P_END
PART_NUM=$((PART_NUM + 1))

# Partition 2: Recovery (optionnelle)
if [ "$REC_SIZE" -gt 0 ]; then
    P_START=$OFFSET
    P_END=$((OFFSET + REC_SIZE))
    sgdisk --new=${PART_NUM}:$((P_START / SEC)):$(((P_END / SEC) - 1)) \
        --typecode=${PART_NUM}:2700 --change-name=${PART_NUM}:"Recovery" \
        --attributes=${PART_NUM}:set:63 "$DISK_RAW"
    REC_DEST_OFFSET=$P_START
    OFFSET=$P_END
fi

echo ""
sgdisk --print "$DISK_RAW"

# Ecrire les partitions
echo ""
echo "  Ecriture de la partition Windows ..."
dd if="$WIN_RAW" of="$DISK_RAW" \
    bs=$SEC skip=$WIN_START_SEC seek=$((WIN_DEST_OFFSET / SEC)) \
    count=$((WIN_SIZE / SEC)) conv=notrunc status=progress 2>&1

if [ "$REC_SIZE" -gt 0 ]; then
    echo "  Ecriture de la partition Recovery ..."
    dd if="$REC_RAW" of="$DISK_RAW" \
        bs=$SEC skip=$REC_START_SEC seek=$((REC_DEST_OFFSET / SEC)) \
        count=$((REC_SIZE / SEC)) conv=notrunc status=progress 2>&1
fi

sgdisk --verify "$DISK_RAW"

# ==========================================================================
echo ""
echo "=== 3/3 - Conversion en format Parallels HDD ==="
# ==========================================================================

HDD_FILE="${RECON_DIR}/windows_data.hdd"
echo "  Conversion raw -> Parallels HDD ..."
qemu-img convert -f raw -O parallels "$DISK_RAW" "$HDD_FILE"

echo "  Nettoyage des raws intermediaires ..."
rm -f "$WIN_RAW" "${REC_RAW:-/dev/null/nonexistent}" "$DISK_RAW"

echo ""
echo "=== Termine ==="
echo "Disque Parallels (data): $HDD_FILE"
echo ""
echo "Pour l'utiliser :"
echo "  1. Dans Parallels, ajouter $HDD_FILE comme disque supplementaire"
echo "  2. Demarrer la VM, le disque apparaitra comme un lecteur secondaire"
echo "  3. Acceder aux fichiers dans E:\\Users\\..."
ls -lh "$HDD_FILE"
