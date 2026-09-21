#!/bin/bash
# Rebuild DWIM, clear its stale Accessibility entry, relaunch. Then switch DWIM on in the prompt / Settings and relaunch once more.
cd "$(dirname "$0")"
pkill -f "DWIM.app/Contents/MacOS/DWIM"; ./build.sh && tccutil reset Accessibility com.rohitm.dwim; open DWIM.app
