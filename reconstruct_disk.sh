#!/bin/bash
set -euo pipefail

# Variables d'environnement requises
: "${VM_NAME:?Erreur: VM_NAME non defini (ex: export VM_NAME='Windows 11')}"
: "${RECON_DIR:?Erreur: RECON_DIR non defini - repertoire de reconstruction sur le Mac (ex: export RECON_DIR='/chemin/vers/reconstruction')}"
: "${RECON_SHARE:?Erreur: RECON_SHARE non defini - chemin UNC du repertoire de reconstruction vu depuis la VM (ex: export RECON_SHARE='\\\\Mac\\Home\\from-backup\\reconstruction')}"

# Configuration derivee
VM_BACKUP_DIR="C:\\WindowsImageBackup"

# Detecter les fichiers VHDX disponibles sur la VM
echo "  Detection des VHDX sur la VM ..."
VHDX_LIST=$(prlctl exec "$VM_NAME" cmd /c "dir \"$VM_BACKUP_DIR\\*.vhdx\" /s /b" 2>/dev/null | tr -d '\r')
if [ -z "$VHDX_LIST" ]; then
    echo "Erreur: aucun fichier VHDX trouve dans $VM_BACKUP_DIR sur la VM '$VM_NAME'"
    exit 1
fi

exec_vm() {
    prlctl exec "$VM_NAME" cmd /c "$*"
}

mkdir -p "$RECON_DIR"

# ==========================================================================
echo "=== 1/4 - Recuperation du backup repare depuis la VM ==="
# ==========================================================================

echo "  Robocopy inverse : VM -> Mac ..."
exec_vm "robocopy \"$VM_BACKUP_DIR\" \"$RECON_SHARE\" /MIR /MT:16 /J /R:3 /W:5 /NP" || true

echo "  Verification des fichiers ..."
ls -lhR "$RECON_DIR"

# Trouver le sous-dossier contenant les VHDX
VHDX_DIR=$(find "$RECON_DIR" -name "*.vhdx" -print -quit | xargs dirname)
if [ -z "$VHDX_DIR" ]; then
    echo "Erreur: aucun fichier VHDX trouve dans $RECON_DIR apres la copie"
    exit 1
fi
echo "  VHDX trouves dans : $VHDX_DIR"

# Lister les VHDX par taille croissante
VHDX_FILES=$(ls -S "$VHDX_DIR"/*.vhdx | xargs -n1 basename)
VHDX_DATA=$(ls -S "$VHDX_DIR"/*.vhdx | head -1 | xargs basename)
echo "  VHDX principal (donnees) : $VHDX_DATA"

# ==========================================================================
echo ""
echo "=== 2/4 - Conversion des VHDX en raw ==="
# ==========================================================================
# Chaque VHDX contient un mini-disque GPT avec:
#   - Partition 1: MSR 15 Mo (a ignorer)
#   - Partition 2: les donnees

for VHDX in $VHDX_FILES; do
    RAW="${RECON_DIR}/${VHDX%.vhdx}.raw"
    if [ -f "$RAW" ]; then
        echo "  $RAW existe deja, skip"
        continue
    fi
    echo "  Conversion de $VHDX -> raw ..."
    qemu-img convert -f vhdx -O raw "$VHDX_DIR/$VHDX" "$RAW"
done

# ==========================================================================
echo ""
echo "=== 3/4 - Assemblage du disque GPT complet ==="
# ==========================================================================
# Structure GPT Windows standard:
#   Partition 1: EFI System    (FAT32)  - plus petit VHDX (~76 Mo)
#   Partition 2: MSR           (Microsoft Reserved) - 16 Mo vide
#   Partition 3: Windows       (NTFS)   - plus gros VHDX (~90 Go)
#   Partition 4: Recovery      (NTFS)   - VHDX moyen (~488 Mo)

# Trier les raw par taille pour identifier boot (petit), recovery (moyen), data (gros)
RAW_FILES=$(ls -S "$RECON_DIR"/*.raw)
RAW_DATA=$(echo "$RAW_FILES" | head -1)
RAW_RECOVERY=$(echo "$RAW_FILES" | head -2 | tail -1)
RAW_BOOT=$(echo "$RAW_FILES" | tail -1)

echo "  EFI (boot):    $(basename "$RAW_BOOT")"
echo "  Recovery:      $(basename "$RAW_RECOVERY")"
echo "  Data (Windows): $(basename "$RAW_DATA")"

# Chaque raw a: 17KB offset GPT, 15MB MSR, puis la partition utile a offset 16MB
PART_OFFSET=$((16 * 1024 * 1024))

# Tailles des partitions utiles (taille raw - 16 Mo d'overhead GPT+MSR)
BOOT_RAW_SIZE=$(stat -f%z "$RAW_BOOT")
RECOVERY_RAW_SIZE=$(stat -f%z "$RAW_RECOVERY")
DATA_RAW_SIZE=$(stat -f%z "$RAW_DATA")

BOOT_PART_SIZE=$((BOOT_RAW_SIZE - PART_OFFSET))
RECOVERY_PART_SIZE=$((RECOVERY_RAW_SIZE - PART_OFFSET))
DATA_PART_SIZE=$((DATA_RAW_SIZE - PART_OFFSET))

echo "  Taille partition EFI:      $((BOOT_PART_SIZE / 1024 / 1024)) Mo"
echo "  Taille partition Recovery:  $((RECOVERY_PART_SIZE / 1024 / 1024)) Mo"
echo "  Taille partition Data:      $((DATA_PART_SIZE / 1024 / 1024 / 1024)) Go"

# Calcul du disque final
# GPT header: 1 Mo | EFI | MSR: 16Mo | Windows | Recovery | GPT backup: 1 Mo
MSR_SIZE=$((16 * 1024 * 1024))
GPT_OVERHEAD=$((2 * 1024 * 1024))  # 1 Mo debut + 1 Mo fin
DISK_SIZE=$((GPT_OVERHEAD + BOOT_PART_SIZE + MSR_SIZE + DATA_PART_SIZE + RECOVERY_PART_SIZE))

DISK_RAW="${RECON_DIR}/windows_full.raw"
echo "  Taille disque final: $((DISK_SIZE / 1024 / 1024 / 1024)) Go"
echo "  Creation de $DISK_RAW ..."

# Creer un fichier sparse de la bonne taille
dd if=/dev/zero of="$DISK_RAW" bs=1 count=0 seek=$DISK_SIZE 2>/dev/null

# Calcul des offsets (alignes sur 1 Mo)
ALIGN=$((1024 * 1024))
EFI_START=$ALIGN
EFI_END=$((EFI_START + BOOT_PART_SIZE))
MSR_START=$EFI_END
MSR_END=$((MSR_START + MSR_SIZE))
WIN_START=$MSR_END
WIN_END=$((WIN_START + DATA_PART_SIZE))
REC_START=$WIN_END
REC_END=$((REC_START + RECOVERY_PART_SIZE))

# Convertir en secteurs (512 octets)
SEC=512
EFI_START_S=$((EFI_START / SEC))
EFI_END_S=$(((EFI_END / SEC) - 1))
MSR_START_S=$((MSR_START / SEC))
MSR_END_S=$(((MSR_END / SEC) - 1))
WIN_START_S=$((WIN_START / SEC))
WIN_END_S=$(((WIN_END / SEC) - 1))
REC_START_S=$((REC_START / SEC))
REC_END_S=$(((REC_END / SEC) - 1))

echo "  Creation de la table GPT ..."
sgdisk --zap-all "$DISK_RAW" > /dev/null 2>&1

# Partition 1: EFI System
sgdisk --new=1:${EFI_START_S}:${EFI_END_S} --typecode=1:EF00 --change-name=1:"EFI System" "$DISK_RAW"
# Partition 2: Microsoft Reserved
sgdisk --new=2:${MSR_START_S}:${MSR_END_S} --typecode=2:0C01 --change-name=2:"Microsoft Reserved" "$DISK_RAW"
# Partition 3: Windows (Basic Data)
sgdisk --new=3:${WIN_START_S}:${WIN_END_S} --typecode=3:0700 --change-name=3:"Windows" "$DISK_RAW"
# Partition 4: Recovery
sgdisk --new=4:${REC_START_S}:${REC_END_S} --typecode=4:2700 --change-name=4:"Recovery" --attributes=4:set:63 "$DISK_RAW"

sgdisk --print "$DISK_RAW"

echo "  Ecriture des partitions dans le disque ..."
# EFI
dd if="$RAW_BOOT" of="$DISK_RAW" bs=$ALIGN skip=$((PART_OFFSET / ALIGN)) seek=$((EFI_START / ALIGN)) conv=notrunc status=progress 2>&1
# Windows
dd if="$RAW_DATA" of="$DISK_RAW" bs=$ALIGN skip=$((PART_OFFSET / ALIGN)) seek=$((WIN_START / ALIGN)) conv=notrunc status=progress 2>&1
# Recovery
dd if="$RAW_RECOVERY" of="$DISK_RAW" bs=$ALIGN skip=$((PART_OFFSET / ALIGN)) seek=$((REC_START / ALIGN)) conv=notrunc status=progress 2>&1

# ==========================================================================
echo ""
echo "=== 4/4 - Conversion en format Parallels HDD ==="
# ==========================================================================

HDD_FILE="${RECON_DIR}/windows_restored.hdd"
echo "  Conversion raw -> Parallels HDD ..."
qemu-img convert -f raw -O parallels "$DISK_RAW" "$HDD_FILE"

echo ""
echo "  Nettoyage des fichiers intermediaires ..."
rm -f "${RECON_DIR}"/*.raw

echo ""
echo "=== Termine ==="
echo "Disque Parallels cree : $HDD_FILE"
echo ""
echo "Pour l'utiliser :"
echo "  1. Creer une nouvelle VM Parallels (Windows 11, sans disque)"
echo "  2. Ajouter $HDD_FILE comme disque dur existant"
echo "  3. S'assurer que le boot EFI est active"
ls -lh "$HDD_FILE"
