#!/usr/bin/env bash
# export-fab.sh — generate fabrication outputs for NESRGB_AV_MultiOut.
#
# Produces into the output directory (default: fab/):
#   gerbers/   gerber layers + excellon drill (JLCPCB-compatible naming)
#   images/    raytraced top/bottom board renders
#   BOM.csv    bill of materials in JLCPCB column format
#   CPL.csv    component placement (pick and place) in JLCPCB column format
#   NESRGB_AV_MultiOut-<version>-JLCPCB.zip   gerbers+drill, ready to upload
#
# Usage: scripts/export-fab.sh [-o OUTDIR] [-v VERSION] [--check]
#   -o, --output   output directory (default: <repo>/fab) — WIPED before export
#   -v, --version  version label for the zip (default: git describe, else "dev")
#   --check        run ERC/DRC first and abort on violations
#
# Requires kicad-cli 9.x.
set -euo pipefail

PROJECT=NESRGB_AV_MultiOut
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$ROOT/fab"
VERSION=""
RUN_CHECKS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)  OUTDIR="$2"; shift 2 ;;
    -v|--version) VERSION="$2"; shift 2 ;;
    --check)      RUN_CHECKS=1; shift ;;
    -h|--help)    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo dev)"

PCB="$ROOT/$PROJECT.kicad_pcb"
SCH="$ROOT/$PROJECT.kicad_sch"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/gerbers" "$OUTDIR/images"

if (( RUN_CHECKS )); then
  echo "== ERC =="
  kicad-cli sch erc --exit-code-violations --output "$OUTDIR/erc.rpt" "$SCH"
  echo "== DRC =="
  kicad-cli pcb drc --exit-code-violations --output "$OUTDIR/drc.rpt" "$PCB"
fi

echo "== Gerbers =="
kicad-cli pcb export gerbers --output "$OUTDIR/gerbers/" \
  --layers F.Cu,B.Cu,F.Paste,B.Paste,F.Mask,B.Mask,F.Silkscreen,B.Silkscreen,Edge.Cuts \
  "$PCB"

echo "== Drill =="
kicad-cli pcb export drill --output "$OUTDIR/gerbers/" \
  --format excellon --excellon-units mm \
  --generate-map --map-format gerberx2 "$PCB"

echo "== BOM =="
kicad-cli sch export bom --output "$OUTDIR/BOM.csv" \
  --fields 'Value,Reference,Footprint,LCSC,${QUANTITY},${DNP}' \
  --labels 'Comment,Designator,Footprint,LCSC Part #,Qty,DNP' \
  --group-by 'Value,Footprint' --exclude-dnp "$SCH"

echo "== CPL (placement) =="
kicad-cli pcb export pos --output "$OUTDIR/cpl-raw.csv" \
  --format csv --units mm --exclude-dnp "$PCB"
python3 - "$OUTDIR/cpl-raw.csv" "$OUTDIR/CPL.csv" <<'PYEOF'
import csv, sys
with open(sys.argv[1]) as fin, open(sys.argv[2], 'w', newline='') as fout:
    w = csv.writer(fout)
    w.writerow(['Designator', 'Mid X', 'Mid Y', 'Layer', 'Rotation'])
    for row in csv.DictReader(fin):
        w.writerow([row['Ref'], row['PosX'], row['PosY'],
                    row['Side'].capitalize(), row['Rot']])
PYEOF
rm "$OUTDIR/cpl-raw.csv"

echo "== Renders =="
kicad-cli pcb render --side top --quality high --background opaque \
  --output "$OUTDIR/images/$PROJECT-top.png" "$PCB"
kicad-cli pcb render --side bottom --quality high --background opaque \
  --output "$OUTDIR/images/$PROJECT-bottom.png" "$PCB"

echo "== Zip =="
ZIP="$OUTDIR/$PROJECT-$VERSION-JLCPCB.zip"
if command -v zip >/dev/null; then
  (cd "$OUTDIR/gerbers" && zip -q "$ZIP" -- *)
else
  (cd "$OUTDIR/gerbers" && python3 -m zipfile -c "$ZIP" -- *)
fi

echo
echo "Fabrication outputs written to $OUTDIR:"
find "$OUTDIR" -type f | sort
