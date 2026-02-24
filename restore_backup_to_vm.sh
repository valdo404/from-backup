#!/bin/bash
set -euo pipefail

# Variables d'environnement requises
: "${VM_NAME:?Erreur: VM_NAME non defini (ex: export VM_NAME='Windows 11')}"
: "${BACKUP_SOURCE:?Erreur: BACKUP_SOURCE non defini - chemin UNC du backup vu depuis la VM (ex: export BACKUP_SOURCE='\\\\Mac\\Home\\mon_dossier\\WindowsImageBackup')}"
: "${BACKUP_SUBDIR:?Erreur: BACKUP_SUBDIR non defini - sous-dossier contenant les VHDX (ex: export BACKUP_SUBDIR='MON-PC\\Backup 2026-02-16 124141')}"

# Configuration derivee
DEST="C:\\WindowsImageBackup"
VHDX_DIR="${DEST}\\${BACKUP_SUBDIR}"
DRIVE_LETTER="E"

exec_vm() {
    prlctl exec "$VM_NAME" cmd /c "$*"
}

echo "=== 1/3 - Copie avec robocopy ==="
echo "Source : $BACKUP_SOURCE"
echo "Destination : $DEST"

exec_vm "mkdir \"$DEST\" 2>nul & robocopy \"$BACKUP_SOURCE\" \"$DEST\" /MIR /MT:16 /J /R:3 /W:5 /NP /NFL /NDL" || true
# /MIR   : miroir (copie + supprime les fichiers absents de la source)
# /MT:16 : 16 threads en parallele pour maximiser la bande passante
# /J     : copie sans buffer (unbuffered I/O), optimal pour les gros fichiers
# robocopy retourne des codes > 0 meme en cas de succes (code 1 = fichiers copies)

echo ""
echo "=== 2/3 - Suppression du flag sparse et decompression NTFS ==="

for VHDX in $(exec_vm "dir \"$VHDX_DIR\\*.vhdx\" /b" 2>/dev/null); do
    VHDX=$(echo "$VHDX" | tr -d '\r')
    FULL="${VHDX_DIR}\\${VHDX}"
    echo "  Traitement de $VHDX ..."
    exec_vm "fsutil sparse setflag \"$FULL\" 0"
    exec_vm "compact /u \"$FULL\""
done

echo ""
echo "=== 3/3 - Montage et chkdsk /f sur tous les VHDX ==="

for VHDX in $(exec_vm "dir \"$VHDX_DIR\\*.vhdx\" /b /o:-s" 2>/dev/null); do
    VHDX=$(echo "$VHDX" | tr -d '\r')
    VHDX_PATH="${VHDX_DIR}\\${VHDX}"
    echo ""
    echo "--- $VHDX ---"

    # Monter le VHDX
    echo "  Montage ..."
    exec_vm "echo select vdisk file=\"$VHDX_PATH\" > C:\\dp.txt & echo attach vdisk >> C:\\dp.txt & diskpart /s C:\\dp.txt"

    # Trouver le numero du disque monte (le dernier disque online)
    DISK_NUM=$(exec_vm "echo list disk > C:\\dp.txt & diskpart /s C:\\dp.txt" | grep -i "online" | tail -1 | awk '{print $2}')
    DISK_NUM=$(echo "$DISK_NUM" | tr -d '\r')
    echo "  Disque : $DISK_NUM"

    # Lister les partitions et faire chkdsk sur chacune
    PARTITIONS=$(exec_vm "echo select disk $DISK_NUM > C:\\dp.txt & echo list partition >> C:\\dp.txt & diskpart /s C:\\dp.txt" | grep -i "Partition" | grep -vi "Reserved\|Type" | awk '{print $2}')

    for PART_NUM in $PARTITIONS; do
        PART_NUM=$(echo "$PART_NUM" | tr -d '\r')
        echo "  Assignation partition $PART_NUM -> $DRIVE_LETTER: ..."
        exec_vm "echo select disk $DISK_NUM > C:\\dp.txt & echo select partition $PART_NUM >> C:\\dp.txt & echo assign letter=$DRIVE_LETTER >> C:\\dp.txt & diskpart /s C:\\dp.txt"

        echo "  chkdsk /f ${DRIVE_LETTER}: ..."
        exec_vm "chkdsk ${DRIVE_LETTER}: /f" || true

        # Retirer la lettre apres chkdsk
        exec_vm "echo select disk $DISK_NUM > C:\\dp.txt & echo select partition $PART_NUM >> C:\\dp.txt & echo remove letter=$DRIVE_LETTER >> C:\\dp.txt & diskpart /s C:\\dp.txt"
    done

    # Demonter le VHDX
    echo "  Demontage ..."
    exec_vm "echo select vdisk file=\"$VHDX_PATH\" > C:\\dp.txt & echo detach vdisk >> C:\\dp.txt & diskpart /s C:\\dp.txt"
done

echo ""
echo "=== Termine ==="
echo "Tous les VHDX ont ete verifies et corriges."
