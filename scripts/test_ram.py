#!/usr/bin/env python3
"""Mesure une Release de mTerm avec un à cinq volets et des shells zsh au repos."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", nargs="?", type=Path, default=Path("/Applications/mTerm.app"),
                        help="bundle à mesurer (par défaut : /Applications/mTerm.app)")
    source = parser.parse_args().application.resolve()
    info = source / "Contents/Info.plist"
    if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleExecutable") != "mTerm":
        parser.error(f"Application mTerm introuvable : {source}")

    probe = Path(__file__).resolve().with_name("test_ram_probe.m")
    with tempfile.TemporaryDirectory(prefix="mterm-ram-") as tmp:
        bundle = Path(tmp) / "Mesure.app"
        library = Path(tmp) / "mesure.dylib"
        identifier = f"local.test.mterm.ram.{uuid.uuid4().hex}"
        subprocess.run(["xcrun", "clang", "-O2", "-fobjc-arc", "-dynamiclib", probe,
                        "-framework", "AppKit", "-framework", "Foundation", "-o", library], check=True)
        subprocess.run(["ditto", source, bundle], check=True)
        subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string", identifier,
                        bundle / "Contents/Info.plist"], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", bundle], check=True)
        try:
            subprocess.run([bundle / "Contents/MacOS/mTerm"], check=True, timeout=75,
                           env={**os.environ, "DYLD_INSERT_LIBRARIES": str(library), "SHELL": "/bin/zsh"})
        finally:
            subprocess.run(["defaults", "delete", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Test mémoire interrompu : {error}") from error
