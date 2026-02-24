#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Erreur: fichier .env introuvable dans $SCRIPT_DIR"
    echo "Copiez .env.example vers .env et renseignez les variables."
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

SCRIPT="${1:-}"
if [ -z "$SCRIPT" ]; then
    echo "Usage: $0 <script>"
    echo ""
    echo "Scripts disponibles :"
    echo "  restore           - Repare les VHDX et recupere sur le Mac"
    echo "  build-parallels   - Construit un disque data Parallels"
    echo "  build-qemu        - Construit un disque MBR bootable QEMU"
    exit 1
fi

case "$SCRIPT" in
    restore)        TARGET="${SCRIPT_DIR}/restore_backup_to_vm.sh" ;;
    build-parallels) TARGET="${SCRIPT_DIR}/build_parallels_data.sh" ;;
    build-qemu)     TARGET="${SCRIPT_DIR}/build_qemu_bootable.sh" ;;
    *)
        echo "Erreur: script inconnu '$SCRIPT'"
        echo "Choix: restore, build-parallels, build-qemu"
        exit 1
        ;;
esac

SESSION="from-backup-${SCRIPT}"
LOG_FILE="${RECON_DIR}/${SCRIPT}.log"
mkdir -p "$RECON_DIR"

# Tuer une session precedente si elle existe
tmux kill-session -t "$SESSION" 2>/dev/null || true

echo "Lancement de $SCRIPT dans tmux session '$SESSION'"
echo "Log: $LOG_FILE"
echo "Suivre: tmux attach -t $SESSION"

tmux new-session -d -s "$SESSION" "bash '$TARGET' 2>&1 | tee '$LOG_FILE'"
