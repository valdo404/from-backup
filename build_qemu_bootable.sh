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

for tool in qemu-img qemu-system-x86_64 sgdisk; do
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
echo "=== 1/4 - Identification des partitions via le manifeste ==="
# ==========================================================================

VHDX_BOOT=""
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
            efi|boot)     VHDX_BOOT="$current_file" ;;
            windows|data) [ -z "$VHDX_WINDOWS" ] && VHDX_WINDOWS="$current_file" ;;
            recovery)     VHDX_RECOVERY="$current_file" ;;
        esac
    fi
done < "$MANIFEST_FILE"

echo "  Boot:     ${VHDX_BOOT:-non detecte}"
echo "  Windows:  ${VHDX_WINDOWS:-non detecte}"
echo "  Recovery: ${VHDX_RECOVERY:-non detecte}"

if [ -z "$VHDX_WINDOWS" ]; then
    echo "Erreur: impossible d'identifier la partition Windows dans le manifeste"
    exit 1
fi

# ==========================================================================
echo ""
echo "=== 2/4 - Conversion VHDX -> raw et analyse GPT ==="
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

    echo "    Partition: secteurs $start_sec-$end_sec ($((( end_sec - start_sec + 1) * SEC / 1024 / 1024)) Mo)"
    echo "$raw_path $start_sec $end_sec"
}

# Convertir chaque VHDX
declare -A RAW_PATH RAW_START RAW_END RAW_SIZE

for role in boot windows recovery; do
    eval "vhdx=\${VHDX_$(echo $role | tr a-z A-Z):-}"
    [ -z "$vhdx" ] && continue

    echo "  --- $role ($vhdx) ---"
    info_output=$(convert_and_parse "$vhdx")
    last_line=$(echo "$info_output" | tail -1)

    RAW_PATH[$role]=$(echo "$last_line" | awk '{print $1}')
    RAW_START[$role]=$(echo "$last_line" | awk '{print $2}')
    RAW_END[$role]=$(echo "$last_line" | awk '{print $3}')
    RAW_SIZE[$role]=$(((RAW_END[$role] - RAW_START[$role] + 1) * SEC))
done

# ==========================================================================
echo ""
echo "=== 3/4 - Assemblage du disque MBR bootable ==="
# ==========================================================================

# Calcul de la taille totale
BOOT_SIZE=${RAW_SIZE[boot]:-0}
WIN_SIZE=${RAW_SIZE[windows]}
REC_SIZE=${RAW_SIZE[recovery]:-0}

# MBR: 1 Mo d'overhead au debut (MBR + alignement)
MBR_OVERHEAD=$ALIGN
DISK_SIZE=$((MBR_OVERHEAD + BOOT_SIZE + WIN_SIZE + REC_SIZE + ALIGN))

DISK_RAW="${RECON_DIR}/qemu_bootable.raw"
echo "  Taille disque: $((DISK_SIZE / 1024 / 1024 / 1024)) Go"
echo "  Creation de $DISK_RAW ..."
dd if=/dev/zero of="$DISK_RAW" bs=1 count=0 seek=$DISK_SIZE 2>/dev/null

# Creer la table MBR avec sfdisk
OFFSET_SEC=$((MBR_OVERHEAD / SEC))
SFDISK_SCRIPT=""
PART_NUM=0

# Partition 1: System Reserved (boot) - NTFS, bootable
if [ "$BOOT_SIZE" -gt 0 ]; then
    BOOT_DEST_SEC=$OFFSET_SEC
    BOOT_SIZE_SEC=$((BOOT_SIZE / SEC))
    SFDISK_SCRIPT+="${DISK_RAW}${PART_NUM:+p}$((PART_NUM + 1)) : start=$BOOT_DEST_SEC, size=$BOOT_SIZE_SEC, type=7, bootable\n"
    OFFSET_SEC=$((OFFSET_SEC + BOOT_SIZE_SEC))
    PART_NUM=$((PART_NUM + 1))
fi

# Partition 2: Windows - NTFS
WIN_DEST_SEC=$OFFSET_SEC
WIN_SIZE_SEC=$((WIN_SIZE / SEC))
SFDISK_SCRIPT+="start=$WIN_DEST_SEC, size=$WIN_SIZE_SEC, type=7\n"
OFFSET_SEC=$((OFFSET_SEC + WIN_SIZE_SEC))
PART_NUM=$((PART_NUM + 1))

# Partition 3: Recovery - NTFS (type 27 = Windows Recovery)
if [ "$REC_SIZE" -gt 0 ]; then
    REC_DEST_SEC=$OFFSET_SEC
    REC_SIZE_SEC=$((REC_SIZE / SEC))
    SFDISK_SCRIPT+="start=$REC_DEST_SEC, size=$REC_SIZE_SEC, type=27\n"
    OFFSET_SEC=$((OFFSET_SEC + REC_SIZE_SEC))
fi

echo "  Creation de la table MBR ..."
echo -e "label: dos\n$SFDISK_SCRIPT" | sfdisk "$DISK_RAW" 2>/dev/null

echo "  Table de partitions :"
sfdisk -l "$DISK_RAW"

# Ecrire les partitions
echo ""
echo "  Ecriture des partitions ..."

if [ "$BOOT_SIZE" -gt 0 ]; then
    echo "  -> Boot ($((BOOT_SIZE / 1024 / 1024)) Mo) ..."
    dd if="${RAW_PATH[boot]}" of="$DISK_RAW" \
        bs=$SEC skip=${RAW_START[boot]} seek=$BOOT_DEST_SEC \
        count=$BOOT_SIZE_SEC conv=notrunc status=progress 2>&1
fi

echo "  -> Windows ($((WIN_SIZE / 1024 / 1024 / 1024)) Go) ..."
dd if="${RAW_PATH[windows]}" of="$DISK_RAW" \
    bs=$SEC skip=${RAW_START[windows]} seek=$WIN_DEST_SEC \
    count=$WIN_SIZE_SEC conv=notrunc status=progress 2>&1

if [ "$REC_SIZE" -gt 0 ]; then
    echo "  -> Recovery ($((REC_SIZE / 1024 / 1024)) Mo) ..."
    dd if="${RAW_PATH[recovery]}" of="$DISK_RAW" \
        bs=$SEC skip=${RAW_START[recovery]} seek=$REC_DEST_SEC \
        count=$REC_SIZE_SEC conv=notrunc status=progress 2>&1
fi

# Installer un MBR bootable depuis la partition System Reserved
# Le VBR de la partition boot contient deja le bootloader Windows (bootmgr)
# On a juste besoin d'un MBR generique qui charge la partition active
echo "  Installation du MBR bootstrap ..."
# Copier les 440 premiers octets du boot sector de la partition boot comme MBR code
if [ "$BOOT_SIZE" -gt 0 ]; then
    dd if="${RAW_PATH[boot]}" of="$DISK_RAW" \
        bs=1 skip=$((RAW_START[boot] * SEC)) count=440 \
        conv=notrunc 2>/dev/null
fi

# ==========================================================================
echo ""
echo "=== 4/4 - Conversion en qcow2 ==="
# ==========================================================================

QCOW2_FILE="${RECON_DIR}/windows_bootable.qcow2"
echo "  Conversion raw -> qcow2 (compression) ..."
qemu-img convert -f raw -O qcow2 -c "$DISK_RAW" "$QCOW2_FILE"

echo "  Nettoyage des raws intermediaires ..."
for role in boot windows recovery; do
    rm -f "${RAW_PATH[$role]:-}" 2>/dev/null
done
rm -f "$DISK_RAW"

echo ""
echo "=== Termine ==="
echo "Disque QEMU bootable: $QCOW2_FILE"
echo ""
echo "Pour booter :"
echo "  qemu-system-x86_64 \\"
echo "    -m 4G -smp 2 -cpu qemu64 \\"
echo "    -drive file=$QCOW2_FILE,format=qcow2 \\"
echo "    -display default"
echo ""
ls -lh "$QCOW2_FILE"
