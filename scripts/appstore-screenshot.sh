#!/bin/bash
# appstore-screenshot.sh
# Capture une fenêtre macOS et génère une image App Store Connect.
# La capture est ajustée au format choisi, sans déformation.

set -euo pipefail

OUTPUT="${1:-$HOME/Desktop/appstore.png}"
formats=(1920x1080 2880x1800 2560x1600 1440x900 1280x800)
echo "Choisis la résolution du PNG :"
for i in "${!formats[@]}"; do
    format=${formats[i]}
    printf '%d) %s × %s px (Mac)\n' "$((i + 1))" "${format%x*}" "${format#*x}"
done

while true; do
    printf 'Numéro du format [2 par défaut] : '
    IFS= read -r choix || exit 1
    choix=${choix:-2}
    case "$choix" in
        [1-5]) format=${formats[choix-1]}; break ;;
        *) echo "Saisis un numéro de 1 à 5." ;;
    esac
done
WIDTH=${format%x*}
HEIGHT=${format#*x}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Clique sur la fenêtre de ton application..."
screencapture -x -o -W "$TMP/capture.png"

read -r W H < <(
    sips -g pixelWidth -g pixelHeight "$TMP/capture.png" |
    awk '/pixelWidth:/ {w=$2} /pixelHeight:/ {h=$2} END {print w, h}'
)

if [[ -z "$W" || -z "$H" ]]; then
    echo "Erreur : impossible de lire les dimensions."
    exit 1
fi

echo "Capture originale : ${W} × ${H}"

# Redimensionnement proportionnel, sans déformation.
if (( W * HEIGHT > H * WIDTH )); then
    sips --resampleWidth "$WIDTH" "$TMP/capture.png" \
        --out "$TMP/resized.png" >/dev/null
else
    sips --resampleHeight "$HEIGHT" "$TMP/capture.png" \
        --out "$TMP/resized.png" >/dev/null
fi

# Création d'un fond blanc aux dimensions exactes.
# L'image est centrée sans étirement.
swift - "$TMP/resized.png" "$OUTPUT" "$WIDTH" "$HEIGHT" <<'SWIFT'
import AppKit
import Foundation

let args = CommandLine.arguments
let source = URL(fileURLWithPath: args[1])
let destination = URL(fileURLWithPath: args[2])
let width = Int(args[3])!
let height = Int(args[4])!

guard let image = NSImage(contentsOf: source),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else {
    fatalError("Impossible de charger la capture.")
}

let output = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)

NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let x = (width - bitmap.pixelsWide) / 2
let y = (height - bitmap.pixelsHigh) / 2

NSGraphicsContext.current?.imageInterpolation = .high

image.draw(
    in: NSRect(
        x: x,
        y: y,
        width: bitmap.pixelsWide,
        height: bitmap.pixelsHigh
    ),
    from: NSRect(
        x: 0,
        y: 0,
        width: bitmap.pixelsWide,
        height: bitmap.pixelsHigh
    ),
    operation: .copy,
    fraction: 1
)

NSGraphicsContext.restoreGraphicsState()

guard let data = output.representation(using: .png, properties: [:]) else {
    fatalError("Impossible de générer le PNG.")
}

try data.write(to: destination)
print("Capture créée : \(destination.path)")
SWIFT

sips -g pixelWidth -g pixelHeight "$OUTPUT"

# Installation dans un dépôt Git :
# chmod +x appstore-screenshot.sh
# git add appstore-screenshot.sh
# git commit -m "feat: add macOS App Store screenshot generator"

# Utilisation :
# ./appstore-screenshot.sh
# ./appstore-screenshot.sh ~/Desktop/ma-capture.png
