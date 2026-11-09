#!/bin/sh
# Compile mTerm puis installe ou remplace /Applications/mTerm.app.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$project_dir/DerivedData"
destination=/Applications/mTerm.app

"$project_dir/scripts/build_developer_id.sh" "$derived_data"

# Préparer la copie sur le volume de destination avant de toucher à la version installée.
staging=$(mktemp -d /Applications/.mTerm.XXXXXX)
trap 'rm -rf "$staging"' EXIT
trap 'exit 1' HUP INT TERM
candidate="$staging/mTerm.app"
ditto "$derived_data/Build/Products/Release/mTerm.app" "$candidate"
test -x "$candidate/Contents/MacOS/mTerm"
codesign --verify --strict "$candidate"

# Sur macOS, l’échange atomique fonctionne aussi avec un bundle non vide.
xcrun swift - "$candidate" "$destination" <<'SWIFT'
import Darwin

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST,
          renamex_np(source, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("Installation de mTerm")
        exit(1)
    }
}
SWIFT

printf 'mTerm installé dans %s\n' "$destination"
