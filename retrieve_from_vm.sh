#!/bin/bash
set -euo pipefail

# Variables d'environnement requises
: "${VM_NAME:?Erreur: VM_NAME non defini (ex: export VM_NAME='Windows 11')}"
: "${RECON_DIR:?Erreur: RECON_DIR non defini - repertoire de reconstruction sur le Mac (ex: export RECON_DIR='/chemin/vers/reconstruction')}"
: "${RECON_SHARE:?Erreur: RECON_SHARE non defini - chemin UNC du repertoire vu depuis la VM (ex: export RECON_SHARE='\\\\Mac\\Home\\from-backup\\reconstruction')}"
: "${MANIFEST_FILE:?Erreur: MANIFEST_FILE non defini - chemin du manifeste genere par restore_backup_to_vm.sh}"

VM_BACKUP_DIR="C:\\WindowsImageBackup"

exec_vm() {
    prlctl exec "$VM_NAME" cmd /c "$*"
}

mkdir -p "$RECON_DIR"

# Verifier que le manifeste existe (genere par restore_backup_to_vm.sh)
if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Erreur: manifeste introuvable: $MANIFEST_FILE"
    echo "Lancez d'abord restore_backup_to_vm.sh pour le generer."
    exit 1
fi

echo "=== Recuperation du backup repare depuis la VM ==="
echo "  VM: $VM_NAME"
echo "  Source: $VM_BACKUP_DIR"
echo "  Destination: $RECON_DIR"
echo "  Manifeste: $MANIFEST_FILE"

echo ""
echo "  Robocopy inverse : VM -> Mac ..."
exec_vm "robocopy \"$VM_BACKUP_DIR\" \"$RECON_SHARE\" /MIR /MT:16 /J /R:3 /W:5 /NP" || true

# Verifier qu'on a bien des VHDX
VHDX_DIR=$(find "$RECON_DIR" -name "*.vhdx" -print -quit | xargs dirname 2>/dev/null)
if [ -z "$VHDX_DIR" ]; then
    echo "Erreur: aucun fichier VHDX trouve dans $RECON_DIR apres la copie"
    exit 1
fi

# Copier le manifeste dans le repertoire de reconstruction pour reference
cp "$MANIFEST_FILE" "$RECON_DIR/manifest.json" 2>/dev/null || true

echo ""
echo "  Fichiers recuperes :"
ls -lh "$VHDX_DIR"/*.vhdx
echo ""
echo "  Manifeste :"
cat "$MANIFEST_FILE"
echo ""
echo "=== Termine ==="
echo "VHDX disponibles dans : $VHDX_DIR"
echo "Prochaine etape : ./build_parallels_data.sh ou ./build_qemu_bootable.sh"
