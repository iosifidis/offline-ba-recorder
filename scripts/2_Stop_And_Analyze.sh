#!/data/data/com.termux/files/usr/bin/bash

if [ -f "$HOME/.ba_recording.pid" ]; then
  rm -f "$HOME/.ba_recording.pid"
  termux-toast "Η εγγραφή σταμάτησε. Ξεκινάει η AI ανάλυση..."
else
  termux-toast "Δεν βρέθηκε ενεργή ηχογράφηση."
fi
