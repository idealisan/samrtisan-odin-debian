#!/bin/bash
# Rebuild the ODIN initramfs with device nodes and pack it.
# Run INSIDE the odin-build container (needs root for mknod).
set -euo pipefail
SRC="$1"   # staging dir copy
OUT="$2"   # output cpio.gz path

cd "$SRC"
rm -f .odin-debian-marker-note
mknod -m 600 dev/console c 5 1
mknod -m 666 dev/null   c 1 3

find . -print0 | LC_ALL=C sort -z \
  | cpio --null -o -H newc --owner=0:0 --quiet \
  | gzip -9 > "$OUT"

echo "packed: $(ls -la "$OUT")"
