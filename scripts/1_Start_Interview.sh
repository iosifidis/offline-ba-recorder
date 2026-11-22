#!/data/data/com.termux/files/usr/bin/bash

if [ -f "$HOME/.ba_recording.pid" ]; then
  termux-toast "Υπάρχει ήδη ενεργή ηχογράφηση!"
  exit 1
fi

# Εμφανίζει native Android pop-up πληκτρολόγιο για όνομα πελάτη
RESPONSE=$(termux-dialog text -t "Νέα Συνέντευξη BA" -i "Όνομα Πελάτη / Project")
CLIENT=$(echo "$RESPONSE" | grep -o '"text": *"[^"]*"' | cut -d'"' -f4)

if [ -z "$CLIENT" ]; then
  CLIENT="Client_$(date +%H%M)"
fi

termux-toast "Ξεκίνησε η καταγραφή για: $CLIENT"
nohup "$HOME/ba-engine.sh" "$CLIENT" >/dev/null 2>&1 &
