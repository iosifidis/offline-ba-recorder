#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WORK_DIR="/sdcard/Documents/interviews"

if [ -f "$HOME/.ba_recording.pid" ]; then
  termux-toast "Υπάρχει ενεργή ηχογράφηση. Δοκίμασε ξανά αφού ολοκληρωθεί."
  exit 1
fi

PENDING_BASES=()
shopt -s nullglob
for f in "$WORK_DIR"/*.m4a "$WORK_DIR"/*.wav; do
  BASE="${f%.*}"
  if [ ! -s "${BASE}_BA_analysis.md" ]; then
    # Αποφυγή διπλοεγγραφής αν υπάρχουν και .m4a και .wav
    ALREADY=false
    for p in "${PENDING_BASES[@]:-}"; do
      [ "$p" = "$BASE" ] && ALREADY=true && break
    done
    [ "$ALREADY" = false ] && PENDING_BASES+=("$BASE")
  fi
done
shopt -u nullglob

COUNT=${#PENDING_BASES[@]}
if [ "$COUNT" -eq 0 ]; then
  termux-toast "Δεν βρέθηκαν εκκρεμείς συνεντεύξεις!"
  exit 0
fi

termux-toast "Βρέθηκαν $COUNT εκκρεμείς συνεντεύξεις. Ξεκινάει η επεξεργασία..."
nohup bash -c '
  for BASE in "$@"; do
    "$HOME/ba-engine.sh" --resume "$BASE"
  done
' _ "${PENDING_BASES[@]}" >/dev/null 2>&1 &
