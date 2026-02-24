#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

: "${RECON_DIR:?Erreur: RECON_DIR non defini}"

for tool in qemu-img sgdisk; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Erreur: $tool introuvable (brew install qemu gptfdisk)"
        exit 1
    fi
done

# Trouver les VHDX
VHDX_DIR=$(find "$RECON_DIR" -name "*.vhdx" -print -quit 2>/dev/null | xargs dirname 2>/dev/null)
if [ -z "$VHDX_DIR" ]; then
    echo "Erreur: aucun VHDX dans $RECON_DIR"
    exit 1
fi

# Identifier le VHDX Windows via le manifeste ou par taille
VHDX_NAME=""
MANIFEST="${RECON_DIR}/manifest.json"
if [ -f "$MANIFEST" ]; then
    current_file=""
    while IFS= read -r line; do
        if echo "$line" | grep -q '"filename"'; then
            current_file=$(echo "$line" | sed 's/.*"filename": *"\([^"]*\)".*/\1/')
        fi
        if echo "$line" | grep -q '"role": *"windows"'; then
            VHDX_NAME="$current_file"
            break
        fi
    done < "$MANIFEST"
fi

if [ -z "$VHDX_NAME" ]; then
    VHDX_NAME=$(ls -S "$VHDX_DIR"/*.vhdx | head -1 | xargs basename)
fi

VHDX_PATH="$VHDX_DIR/$VHDX_NAME"
RAW_DISK="${RECON_DIR}/${VHDX_NAME%.vhdx}.raw"
NTFS_RAW="${RECON_DIR}/windows_ntfs.raw"

echo "=== Extraction de la partition NTFS ==="
echo "  Source: $VHDX_PATH"

# Etape 1: VHDX -> raw
if [ ! -f "$RAW_DISK" ]; then
    echo ""
    echo "  Conversion VHDX -> raw ..."
    qemu-img convert -f vhdx -O raw "$VHDX_PATH" "$RAW_DISK"
else
    echo "  Raw existant: $RAW_DISK"
fi

# Etape 2: trouver la partition NTFS dans la table GPT
echo ""
echo "  Analyse de la table GPT ..."
sgdisk --print "$RAW_DISK"

PART_INFO=$(sgdisk --print "$RAW_DISK" 2>/dev/null | awk '
    /^ *[0-9]/ {
        code=$6
        # Ignorer MSR (0C01) et Reserved (E3C9)
        if (code != "0C01" && code != "E3C9") {
            print $2, $3
        }
    }
' | head -1)

if [ -z "$PART_INFO" ]; then
    echo "Erreur: aucune partition data trouvee"
    exit 1
fi

START_SEC=$(echo "$PART_INFO" | awk '{print $1}')
END_SEC=$(echo "$PART_INFO" | awk '{print $2}')
COUNT=$((END_SEC - START_SEC + 1))
SIZE_MB=$((COUNT * 512 / 1024 / 1024))

echo ""
echo "  Partition NTFS: secteurs $START_SEC-$END_SEC ($SIZE_MB Mo)"

# Etape 3: extraire la partition
echo ""
echo "  Extraction ..."
dd if="$RAW_DISK" of="$NTFS_RAW" bs=512 skip="$START_SEC" count="$COUNT" status=progress 2>&1

# Supprimer le raw du disque complet
echo ""
echo "  Suppression du raw intermediaire ..."
rm -f "$RAW_DISK"

echo ""
echo "=== Termine ==="
echo "Partition NTFS: $NTFS_RAW"
echo ""
echo "Pour monter (lecture seule) :"
echo "  hdiutil attach -readonly -imagekey diskimage-class=CRawDiskImage '$NTFS_RAW'"
echo ""
echo "Si ca ne fonctionne pas, installez macFUSE + ntfs-3g :"
echo "  brew install --cask macfuse"
echo "  brew install gromgit/fuse/ntfs-3g-mac"
echo "  mkdir -p /Volumes/WindowsBackup"
echo "  ntfs-3g '$NTFS_RAW' /Volumes/WindowsBackup -o ro"
ls -lh "$NTFS_RAW"
