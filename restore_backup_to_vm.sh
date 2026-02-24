#!/bin/bash
set -euo pipefail

# Variables d'environnement requises
: "${VM_NAME:?Erreur: VM_NAME non defini (ex: export VM_NAME='Windows 11')}"
: "${BACKUP_SOURCE:?Erreur: BACKUP_SOURCE non defini - chemin UNC du backup vu depuis la VM (ex: export BACKUP_SOURCE='\\\\Mac\\Home\\mon_dossier\\WindowsImageBackup')}"
: "${BACKUP_SUBDIR:?Erreur: BACKUP_SUBDIR non defini - sous-dossier contenant les VHDX (ex: export BACKUP_SUBDIR='MON-PC\\Backup 2026-02-16 124141')}"
: "${MANIFEST_FILE:?Erreur: MANIFEST_FILE non defini - chemin du fichier manifeste a generer (ex: export MANIFEST_FILE='/chemin/vers/manifest.json')}"

# Configuration derivee
DEST="C:\\WindowsImageBackup"
VHDX_DIR="${DEST}\\${BACKUP_SUBDIR}"
DRIVE_LETTER="E"

exec_vm() {
    prlctl exec "$VM_NAME" cmd /c "$*"
}

echo "=== 1/4 - Copie avec robocopy ==="
echo "Source : $BACKUP_SOURCE"
echo "Destination : $DEST"

exec_vm "mkdir \"$DEST\" 2>nul & robocopy \"$BACKUP_SOURCE\" \"$DEST\" /MIR /MT:16 /J /R:3 /W:5 /NP /NFL /NDL" || true

echo ""
echo "=== 2/4 - Suppression du flag sparse et decompression NTFS ==="

for VHDX in $(exec_vm "dir \"$VHDX_DIR\\*.vhdx\" /b" 2>/dev/null); do
    VHDX=$(echo "$VHDX" | tr -d '\r')
    FULL="${VHDX_DIR}\\${VHDX}"
    echo "  Traitement de $VHDX ..."
    exec_vm "fsutil sparse setflag \"$FULL\" 0"
    exec_vm "compact /u \"$FULL\""
done

echo ""
echo "=== 3/4 - Montage et chkdsk /f sur tous les VHDX ==="

# Initialiser le manifeste JSON
echo '{' > "$MANIFEST_FILE"
echo '  "backup_subdir": "'"$BACKUP_SUBDIR"'",' >> "$MANIFEST_FILE"
echo '  "vhdx_files": [' >> "$MANIFEST_FILE"

FIRST_VHDX=true

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

    # Collecter les infos de partitions pour le manifeste
    PART_OUTPUT=$(exec_vm "echo select disk $DISK_NUM > C:\\dp.txt & echo list partition >> C:\\dp.txt & diskpart /s C:\\dp.txt")

    # Lister les partitions non-Reserved
    PARTITIONS=$(echo "$PART_OUTPUT" | grep -i "Partition" | grep -vi "Reserved\|Type" | awk '{print $2}')

    # Collecter les details de chaque partition
    PART_ENTRIES=""
    for PART_NUM in $PARTITIONS; do
        PART_NUM=$(echo "$PART_NUM" | tr -d '\r')
        echo "  Assignation partition $PART_NUM -> $DRIVE_LETTER: ..."
        exec_vm "echo select disk $DISK_NUM > C:\\dp.txt & echo select partition $PART_NUM >> C:\\dp.txt & echo assign letter=$DRIVE_LETTER >> C:\\dp.txt & diskpart /s C:\\dp.txt"

        # Detecter le type de filesystem et le label
        VOL_INFO=$(exec_vm "echo list volume > C:\\dp.txt & diskpart /s C:\\dp.txt" | grep "\*" | head -1)
        FS_TYPE=$(echo "$VOL_INFO" | awk '{print $5}' | tr -d '\r')
        VOL_LABEL=$(echo "$VOL_INFO" | awk '{print $4}' | tr -d '\r')

        # Detecter le type de partition via detail partition
        DETAIL=$(exec_vm "echo select disk $DISK_NUM > C:\\dp.txt & echo select partition $PART_NUM >> C:\\dp.txt & echo detail partition >> C:\\dp.txt & diskpart /s C:\\dp.txt")
        TYPE_GUID=$(echo "$DETAIL" | grep -i "Type" | head -1 | awk '{print $NF}' | tr -d '\r')

        # Determiner le role de la partition
        ROLE="unknown"
        case "$TYPE_GUID" in
            c12a7328-f81f-11d2-ba4b-00a0c93ec93b) ROLE="efi" ;;
            e3c9e316-0b5c-4db8-817d-f92df00215ae) ROLE="msr" ;;
            ebd0a0a2-b9e5-4433-87c0-68b6b72699c7)
                # Basic Data - distinguer Windows vs Recovery par la taille ou le marker
                if exec_vm "dir ${DRIVE_LETTER}:\\Recovery /b >nul 2>&1 & if exist ${DRIVE_LETTER}:\\Recovery\\WindowsRE echo RECOVERY" 2>/dev/null | grep -q "RECOVERY"; then
                    ROLE="recovery"
                elif exec_vm "dir ${DRIVE_LETTER}:\\\$WINRE_BACKUP_PARTITION.MARKER /b >nul 2>&1 & if exist ${DRIVE_LETTER}:\\\$WINRE_BACKUP_PARTITION.MARKER echo RECOVERY" 2>/dev/null | grep -q "RECOVERY"; then
                    ROLE="recovery"
                elif exec_vm "dir ${DRIVE_LETTER}:\\Windows\\System32 /b >nul 2>&1 & if exist ${DRIVE_LETTER}:\\Windows\\System32 echo WINDOWS" 2>/dev/null | grep -q "WINDOWS"; then
                    ROLE="windows"
                else
                    ROLE="data"
                fi
                ;;
            de94bba4-06d1-4d40-a16a-bfd50179d6ac) ROLE="recovery" ;;
        esac

        # Taille de la partition
        PART_SIZE_LINE=$(echo "$PART_OUTPUT" | grep -i "Partition *$PART_NUM" | head -1)
        PART_SIZE=$(echo "$PART_SIZE_LINE" | grep -oE '[0-9]+ [KMGT]B' | head -1 | tr -d ' ')

        echo "    Partition $PART_NUM: fs=$FS_TYPE role=$ROLE type_guid=$TYPE_GUID size=$PART_SIZE"

        PART_ENTRIES="${PART_ENTRIES}        {\"number\": $PART_NUM, \"filesystem\": \"$FS_TYPE\", \"role\": \"$ROLE\", \"type_guid\": \"$TYPE_GUID\"},"

        echo "  chkdsk /f ${DRIVE_LETTER}: ..."
        exec_vm "chkdsk ${DRIVE_LETTER}: /f" || true

        # Retirer la lettre apres chkdsk
        exec_vm "echo select disk $DISK_NUM > C:\\dp.txt & echo select partition $PART_NUM >> C:\\dp.txt & echo remove letter=$DRIVE_LETTER >> C:\\dp.txt & diskpart /s C:\\dp.txt"
    done

    # Retirer la derniere virgule des partitions
    PART_ENTRIES=$(echo "$PART_ENTRIES" | sed 's/,$//')

    # Ajouter au manifeste
    if [ "$FIRST_VHDX" = true ]; then
        FIRST_VHDX=false
    else
        echo ',' >> "$MANIFEST_FILE"
    fi
    cat >> "$MANIFEST_FILE" <<ENTRY
    {
      "filename": "$VHDX",
      "partitions": [
$PART_ENTRIES
      ]
    }
ENTRY

    # Demonter le VHDX
    echo "  Demontage ..."
    exec_vm "echo select vdisk file=\"$VHDX_PATH\" > C:\\dp.txt & echo detach vdisk >> C:\\dp.txt & diskpart /s C:\\dp.txt"
done

# Fermer le JSON
echo '' >> "$MANIFEST_FILE"
echo '  ]' >> "$MANIFEST_FILE"
echo '}' >> "$MANIFEST_FILE"

echo ""
echo "=== 4/4 - Manifeste genere ==="
echo "  $MANIFEST_FILE"
cat "$MANIFEST_FILE"

echo ""
echo "=== Termine ==="
echo "Tous les VHDX ont ete verifies et corriges."
echo "Manifeste pret pour reconstruct_disk.sh"
