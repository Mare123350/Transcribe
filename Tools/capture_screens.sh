#!/bin/zsh
# Captures the Transcribe window in each state the Debug screenshot tour sets up.
# Usage: Tools/capture_screens.sh <path to Transcribe.app> <label> <output folder>
# Needs Screen Recording permission for the app running this script.
set -u
APP=$1; LABEL=$2; OUT=$3
TMP=~/Library/Containers/app.transcribe.Transcribe/Data/tmp/screenshots
mkdir -p "$OUT"; rm -rf "$TMP"; mkdir -p "$TMP"
"$APP/Contents/MacOS/Transcribe" -UIScreenshots "$LABEL" ${EXTRA:-} >/dev/null 2>&1 &
PID=$!
last=""
while kill -0 $PID 2>/dev/null; do
  if [[ -f "$TMP/shot.txt" ]]; then
    read -r name window < "$TMP/shot.txt"
    if [[ "$name" == "done" ]]; then break; fi
    if [[ "$name" != "$last" ]]; then
      screencapture -x -o -l"$window" "$OUT/$name.png" && echo "captured $name"
      touch "$TMP/ack-$name"
      last=$name
    fi
  fi
  sleep 0.2
done
wait $PID 2>/dev/null
