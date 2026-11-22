#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
pkg update -y
pkg upgrade -y -o Dpkg::Options::="--force-confnew"
pkg install -y -o Dpkg::Options::="--force-confnew" \
  git cmake clang make wget coreutils findutils termux-api ffmpeg openssh

termux-wake-lock || true

# 1. Μεταγλώττιση whisper.cpp & λήψη ελληνικού μοντέλου (small-q5_1)
cd ~
if [ ! -d whisper.cpp ]; then
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git
fi
cd ~/whisper.cpp
cmake -B build
cmake --build build -j4 --config Release
bash ./models/download-ggml-model.sh small-q5_1

# 2. Μεταγλώττιση llama.cpp (llama-completion) & λήψη Qwen2.5-1.5B-Instruct (Q4_K_M)
cd ~
if [ ! -d llama.cpp ]; then
  git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
fi
cd ~/llama.cpp
cmake -B build -DLLAMA_CURL=OFF
cmake --build build -j4 --config Release --target llama-completion llama-cli

mkdir -p ~/llama.cpp/models
if [ ! -s ~/llama.cpp/models/qwen2.5-1.5b-instruct-q4_k_m.gguf ]; then
  wget -O ~/llama.cpp/models/qwen2.5-1.5b-instruct-q4_k_m.gguf \
    "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
fi

# 3. Ρύθμιση Termux:Widget external apps & φάκελοι εργασίας
mkdir -p /sdcard/Documents/interviews ~/.shortcuts ~/.termux
if [ -f ~/.termux/termux.properties ]; then
  sed -i 's/^# allow-external-apps = true/allow-external-apps = true/' ~/.termux/termux.properties
else
  echo "allow-external-apps = true" > ~/.termux/termux.properties
fi
termux-reload-settings || true

echo "Εγκατάσταση εργαλείων και μοντέλων ολοκληρώθηκε."
echo "Αντιγράψτε τα ba-engine.sh -> ~/ και 1_Start_Interview.sh, 2_Stop_And_Analyze.sh -> ~/.shortcuts/ και εκτελέστε chmod +x."
