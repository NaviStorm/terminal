#!/bin/sh
# Compile, notarise et agrafe mTerm avant de préparer l’image disque.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 1 ]; then
    echo "Usage : $0 [profil-du-trousseau]" >&2
    exit 2
fi
profile=${1:-${NOTARY_PROFILE:-mTerm}}
output_dir="$project_dir/DerivedData/Distribution"
mkdir -p "$output_dir"
work=$(mktemp -d "$output_dir/.mterm-dmg.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

notarize() {
    archive=$1
    result="$work/notary.plist"
    echo "Soumission à Apple : $(basename "$archive")"
    if ! xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait --output-format plist > "$result" ||
       [ "$(plutil -extract status raw "$result" 2>/dev/null)" != Accepted ]; then
        id=$(plutil -extract id raw "$result" 2>/dev/null || true)
        if [ -n "$id" ]; then
            echo "Soumission $id : journal Apple" >&2
            xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
        fi
        echo "La notarisation de $(basename "$archive") a échoué." >&2
        exit 1
    fi
}

# Vérifier les identifiants avant de lancer la compilation.
xcrun notarytool history --keychain-profile "$profile" >/dev/null
"$project_dir/scripts/build_developer_id.sh" "$work/build"
mkdir "$work/volume"
app="$work/volume/mTerm.app"
ditto "$work/build/Build/Products/Release/mTerm.app" "$app"

# Utiliser le certificat exact choisi par Xcode, y compris sur un Mac
# possédant plusieurs identités Developer ID Application.
(cd "$work" && codesign -d --extract-certificates "$app")
identity=$(shasum -a 1 "$work/codesign0" | awk '{print $1}')
codesign --force --sign "$identity" --options runtime --timestamp "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$work/mTerm.zip"
notarize "$work/mTerm.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
name="mTerm-$version-$build.dmg"
ln -s /Applications "$work/volume/Applications"
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --volumeName mTerm --format UDZO "$work/volume" "$work/$name"
else
    # Compatibilité avec les versions de macOS antérieures à cette commande.
    hdiutil create -volname mTerm -srcfolder "$work/volume" -fs HFS+ -format UDZO "$work/$name"
fi
codesign --sign "$identity" --timestamp "$work/$name"
notarize "$work/$name"
xcrun stapler staple "$work/$name"
xcrun stapler validate "$work/$name"
hdiutil verify "$work/$name"
mv -f "$work/$name" "$output_dir/$name"
printf 'DMG prêt : %s\n' "$output_dir/$name"
