#!/bin/bash
# Builds sill-vkenc next to this script. Needs: sudo apt install gcc pkg-config libavcodec-dev libavutil-dev
# The binary is committed (the hosts get it in the download, and need only FFmpeg's libraries):
# rebuild and commit it after changing sill-vkenc.c, on the Ubuntu release the hosts run.
set -e
cd "$(dirname "$0")"
gcc -O2 -Wall -Wextra -o sill-vkenc sill-vkenc.c $(pkg-config --cflags --libs libavcodec libavutil)
echo "built $(pwd)/sill-vkenc"
