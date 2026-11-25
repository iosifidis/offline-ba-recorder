#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

WORK_DIR="/sdcard/Documents/interviews"
mkdir -p "$WORK_DIR"
WHISPER_BIN="$HOME/whisper.cpp/build/bin/whisper-cli"
WHISPER_MODEL="$HOME/whisper.cpp/models/ggml-small-q5_1.bin"
LLAMA_BIN="$HOME/llama.cpp/build/bin/llama-completion"
LLAMA_MODEL="$HOME/llama.cpp/models/qwen2.5-1.5b-instruct-q4_k_m.gguf"
PID_FILE="$HOME/.ba_recording.pid"
PROC_LOCK="$HOME/.ba_processing.pid"

RESUME_MODE=false
if [ "${1:-}" = "--resume" ]; then
  RESUME_MODE=true
  BASE_FILE="${2:?Missing BASE_FILE for --resume}"
  CLIENT_NAME="$(basename "$BASE_FILE")"
else
  CLIENT_NAME="${1:-client}"
  CLIENT_SLUG=$(echo "$CLIENT_NAME" | tr " " "_" | tr -cd "[:alnum:]_-")
  [ -z "$CLIENT_SLUG" ] && CLIENT_SLUG="client"
  TIMESTAMP=$(date +"%Y%m%d_%H%M")
  BASE_FILE="$WORK_DIR/${TIMESTAMP}_${CLIENT_SLUG}"
fi

RAW_AUDIO="${BASE_FILE}.m4a"
AUDIO_FILE="${BASE_FILE}.wav"
TRANSCRIPT_FILE="${BASE_FILE}_transcript.txt"
SUMMARY_FILE="${BASE_FILE}_BA_analysis.md"
PARTS_DIR="${BASE_FILE}_parts"
LOG_FILE="${BASE_FILE}.log"
TMP_DIR=$(mktemp -d)

exec 2>>"$LOG_FILE"

on_error() {
  local line="$1"
  echo "[$(date +"%H:%M:%S")] ERROR at line $line" >> "$LOG_FILE"
  termux-notification-remove "ba_rec" || true
  termux-notification-remove "ba_proc" || true
  termux-notification \
    --id "ba_err" \
    --title "❌ Σφάλμα Ανάλυσης BA ($CLIENT_NAME)" \
    --content "Δες το log: $(basename "$LOG_FILE")" || true
}
trap 'on_error $LINENO' ERR

cleanup() {
  rm -rf "$TMP_DIR"
  rm -f "$PID_FILE" "$PROC_LOCK"
  termux-wake-unlock || true
}
trap cleanup EXIT

echo "$$" > "$PROC_LOCK"
termux-wake-lock

if [ "$RESUME_MODE" = false ]; then
  # Εμφάνιση μόνιμης ειδοποίησης στην οθόνη με κουμπί STOP
  termux-notification \
    --id "ba_rec" \
    --title "🎙️ Καταγραφή BA: $CLIENT_NAME" \
    --content "Η συνέντευξη καταγράφεται. Πάτα STOP όταν τελειώσετε." \
    --ongoing \
    --button1 "STOP & ΑΝΑΛΥΣΗ" \
    --button1-action "$HOME/.shortcuts/2_Stop_And_Analyze.sh"

  # Έναρξη εγγραφής σε AAC (m4a)
  termux-microphone-record -f "$RAW_AUDIO" -e aac -r 16000 -c 1 -l 0 >/dev/null
  echo "RECORDING" > "$PID_FILE"

  # Αναμονή μέχρι να διαγραφεί το PID_FILE (από το κουμπί STOP)
  while [ -f "$PID_FILE" ]; do
    sleep 1
  done

  termux-microphone-record -q >/dev/null
  sleep 1
  termux-notification-remove "ba_rec" || true
fi

# --- Φάση 1: Μετατροπή & Chunked Απομαγνητοφώνηση (5λεπτα τμήματα + cooldown) ---
termux-notification \
  --id "ba_proc" \
  --title "⏳ [1/2] Απομαγνητοφώνηση..." \
  --content "Προετοιμασία ήχου ($CLIENT_NAME)..." \
  --ongoing

if [ ! -s "$AUDIO_FILE" ]; then
  ffmpeg -y -i "$RAW_AUDIO" -ar 16000 -ac 1 -c:a pcm_s16le "$AUDIO_FILE" >/dev/null 2>&1
fi

if [ ! -s "$TRANSCRIPT_FILE" ]; then
  mkdir -p "$PARTS_DIR"
  if ! ls "$PARTS_DIR"/seg_*.wav >/dev/null 2>&1; then
    ffmpeg -y -i "$AUDIO_FILE" -f segment -segment_time 300 -c copy "$PARTS_DIR/seg_%03d.wav" >/dev/null 2>&1
  fi

  TOTAL_SEGS=$(ls "$PARTS_DIR"/seg_*.wav | wc -l)
  CUR_SEG=0
  for SEG in "$PARTS_DIR"/seg_*.wav; do
    [ -e "$SEG" ] || continue
    CUR_SEG=$((CUR_SEG + 1))
    SEG_TXT="${SEG%.wav}.txt"
    if [ -s "$SEG_TXT" ]; then
      continue
    fi
    termux-notification \
      --id "ba_proc" \
      --title "⏳ [1/2] Απομαγνητοφώνηση ($CUR_SEG/$TOTAL_SEGS)" \
      --content "Τμήμα $CUR_SEG από $TOTAL_SEGS ($CLIENT_NAME)..." \
      --ongoing
    "$WHISPER_BIN" \
      -m "$WHISPER_MODEL" \
      -f "$SEG" \
      -l el \
      -t 3 \
      -mc 0 \
      -otxt \
      -of "${SEG%.wav}" >/dev/null 2>&1
    sleep 10
  done

  cat "$PARTS_DIR"/seg_*.txt > "$TRANSCRIPT_FILE"
fi

# --- Φάση 2: Map-Reduce Chunking (-t 4, cooldown 10s, repeat-penalty 1.15) ---
termux-notification \
  --id "ba_proc" \
  --title "🧠 [2/2] Ανάλυση Απαιτήσεων BA..." \
  --content "Επεξεργασία τμημάτων με Qwen2.5-1.5B..." \
  --ongoing

# Σπάσιμο του transcript σε κομμάτια των 250 λέξεων (~1000-1250 tokens στα Ελληνικά, ασφαλές για -c 2048)
tr -s "[:space:]" "\n" < "$TRANSCRIPT_FILE" | split -l 250 -d - "$TMP_DIR/words_"

COMBINED_NOTES="$TMP_DIR/combined_notes.txt"
: > "$COMBINED_NOTES"

CHUNK_IDX=1
for WORD_FILE in "$TMP_DIR"/words_*; do
  [ -e "$WORD_FILE" ] || continue
  CHUNK_TEXT=$(tr "\n" " " < "$WORD_FILE")
  MAP_PROMPT="$TMP_DIR/map_prompt_${CHUNK_IDX}.txt"

  cat << EOP > "$MAP_PROMPT"
<|im_start|>system
Είσαι Business Analyst. Εξάγεις ΜΟΝΟ τα ουσιαστικά γεγονότα, προβλήματα, λειτουργικές απαιτήσεις, περιορισμούς και ερωτήματα από το απόσπασμα συνέντευξης. Μη χάνεις καμία λεπτομέρεια. Γράψε συνοπτικά bullet points στα Ελληνικά.<|im_end|>
<|im_start|>user
Απόσπασμα #$CHUNK_IDX:
$CHUNK_TEXT<|im_end|>
<|im_start|>assistant
EOP

  echo "--- Σημειώσεις Τμήματος $CHUNK_IDX ---" >> "$COMBINED_NOTES"
  "$LLAMA_BIN" \
    -m "$LLAMA_MODEL" \
    -f "$MAP_PROMPT" \
    -c 2048 \
    -b 256 \
    -n 512 \
    -t 3 \
    --temp 0.1 \
    --repeat-penalty 1.15 \
    --no-display-prompt -no-cnv \
    -e >> "$COMBINED_NOTES"
  echo "" >> "$COMBINED_NOTES"

  CHUNK_IDX=$((CHUNK_IDX + 1))
  sleep 10
done

# --- Ιεραρχική συμπύκνωση αν οι σημειώσεις ξεπερνούν τις 450 λέξεις (~1800-2200 tokens στα Ελληνικά) ---
REDUCE_ROUND=1
while [ "$(wc -w < "$COMBINED_NOTES")" -gt 450 ]; do
  NEXT_NOTES="$TMP_DIR/combined_round_${REDUCE_ROUND}.txt"
  : > "$NEXT_NOTES"
  rm -f "$TMP_DIR"/rwords_*
  tr -s "[:space:]" "\n" < "$COMBINED_NOTES" | split -l 400 -d - "$TMP_DIR/rwords_"
  for R_FILE in "$TMP_DIR"/rwords_*; do
    [ -e "$R_FILE" ] || continue
    R_TEXT=$(tr "\n" " " < "$R_FILE")
    R_PROMPT="$TMP_DIR/r_prompt_${REDUCE_ROUND}_$(basename "$R_FILE").txt"
    cat << EOP > "$R_PROMPT"
<|im_start|>system
Είσαι Business Analyst. Συγχώνευσε και συμπύκνωσε τις παρακάτω σημειώσεις στα Ελληνικά διατηρώντας όλα τα ουσιαστικά γεγονότα, απαιτήσεις και ερωτήματα σε σύντομα bullet points.<|im_end|>
<|im_start|>user
$R_TEXT<|im_end|>
<|im_start|>assistant
EOP
    "$LLAMA_BIN" \
      -m "$LLAMA_MODEL" \
      -f "$R_PROMPT" \
      -c 3072 \
      -b 256 \
      -n 300 \
      -t 3 \
      --temp 0.1 \
      --repeat-penalty 1.15 \
      --no-display-prompt -no-cnv \
      -e >> "$NEXT_NOTES"
    echo "" >> "$NEXT_NOTES"
    sleep 10
  done
  mv "$NEXT_NOTES" "$COMBINED_NOTES"
  REDUCE_ROUND=$((REDUCE_ROUND + 1))
done

# --- Τελική Σύνθεση (Reduce) ---
REDUCE_PROMPT="$TMP_DIR/reduce_prompt.txt"
cat << EOP > "$REDUCE_PROMPT"
<|im_start|>system
Είσαι Senior Business & Systems Analyst. Συνθέτεις τις σημειώσεις μιας συνέντευξης πελάτη σε ένα ολοκληρωμένο, επαγγελματικό έγγραφο απαιτήσεων στα Ελληνικά.
Απαγορεύεται να επινοήσεις πληροφορίες που δεν υπάρχουν στις σημειώσεις. Χρησιμοποίησε καθαρό Markdown.<|im_end|>
<|im_start|>user
Με βάση τις παρακάτω εξαχθείσες σημειώσεις από όλη τη διάρκεια της συνέντευξης, σύνταξε την τελική ανάλυση στις εξής 5 ενότητες:

1. **Σύνοψη Συνέντευξης (Executive Summary)** (3-5 προτάσεις)
2. **Επιχειρηματικά Προβλήματα & Στόχοι (Pain Points)**
3. **Λειτουργικές Απαιτήσεις (Functional Requirements)**
4. **Μη Λειτουργικές Απαιτήσεις & Περιορισμοί (Security, Integrations, Budget, Χρονοδιάγραμμα)**
5. **Ανοιχτά Ερωτήματα & Ασάφειες προς Διευκρίνιση (Open Questions)**

Σημειώσεις Συνέντευξης:
$(cat "$COMBINED_NOTES")<|im_end|>
<|im_start|>assistant
EOP

{
  echo "# Business Analysis: $CLIENT_NAME"
  echo "- **Ημερομηνία:** $(date +"%d/%m/%Y %H:%M")"
  echo "- **Αρχείο Ήχου:** \`$(basename "$AUDIO_FILE")\`"
  echo "- **Απομαγνητοφώνηση:** \`$(basename "$TRANSCRIPT_FILE")\`"
  echo ""
  echo "---"
  echo ""
  "$LLAMA_BIN" \
    -m "$LLAMA_MODEL" \
    -f "$REDUCE_PROMPT" \
    -c 3072 \
    -b 256 \
    -n 1024 \
    -t 3 \
    --temp 0.2 \
    --repeat-penalty 1.15 \
    --no-display-prompt -no-cnv \
    -e
} > "$SUMMARY_FILE"

rm -rf "$PARTS_DIR"
termux-notification-remove "ba_proc" || true
termux-vibrate -d 300 || true
termux-notification \
  --id "ba_done" \
  --title "✅ Ολοκληρώθηκε η Ανάλυση BA ($CLIENT_NAME)" \
  --content "Έτοιμο το αρχείο: $(basename "$SUMMARY_FILE")"
