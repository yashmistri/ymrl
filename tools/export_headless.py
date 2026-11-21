#!/usr/bin/env python3
"""Export headless Godot binaries for RL training and evaluation.

Produces a standalone executable that the godot_rl Python wrapper can launch
with --env_path, so training and evaluation run without the editor open.

Usage:
    python tools/export_headless.py                 # export release build
    python tools/export_headless.py --debug         # export debug build
    python tools/export_headless.py --install-templates
    python tools/export_headless.py --check         # report state, change nothing

The script is idempotent: re-running re-exports over the previous build.
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
EXPORT_PRESETS = PROJECT_ROOT / "export_presets.cfg"
BUILD_DIR = PROJECT_ROOT / "build"
PRESET_NAME = "Headless"
EXPORT_TIMEOUT_SECONDS = 900

# Godot names template folders after the full version string, e.g.
# "4.7.2.stable.mono". The editor refuses to export if the folder is missing.
GODOT_VERSION = "4.7.2.stable.mono"


def find_godot() -> Path:
    """Locate the Godot editor binary.

    Order: $GODOT_BIN, then the usual install locations. Console builds are
    preferred on Windows because they surface export errors on stdout.
    """
    env = os.environ.get("GODOT_BIN")
    if env:
        path = Path(env)
        if not path.exists():
            sys.exit(f"GODOT_BIN is set but does not exist: {path}")
        return path

    home = Path.home()
    candidates = [
        home / "Documents" / "Godot_v4.7.2-stable_mono_win64" / "Godot_v4.7.2-stable_mono_win64_console.exe",
        home / "Documents" / "Godot_v4.7.2-stable_mono_win64" / "Godot_v4.7.2-stable_mono_win64.exe",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate

    for name in ("godot", "godot4", "Godot"):
        found = shutil.which(name)
        if found:
            return Path(found)

    sys.exit(
        "Could not find the Godot editor. Set GODOT_BIN to the editor executable, e.g.\n"
        '  $env:GODOT_BIN = "C:\\path\\to\\Godot_v4.7.2-stable_mono_win64_console.exe"'
    )


def templates_dir() -> Path:
    """Where Godot looks for export templates on this platform."""
    if sys.platform == "win32":
        base = Path(os.environ["APPDATA"]) / "Godot"
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support" / "Godot"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "godot"
    return base / "export_templates" / GODOT_VERSION


def templates_installed() -> bool:
    directory = templates_dir()
    if not directory.is_dir():
        return False
    # The Windows and Linux templates are the ones an RL workflow needs; any
    # one of them being present means the install completed.
    return any(directory.glob("*.exe")) or any(directory.glob("*.x86_64"))


def download(url: str, destination: Path, attempts: int = 5) -> None:
    """Download a URL to disk, resuming across transient failures.

    GitHub serves release assets from a signed, short-lived redirect. A slow
    start can hit an expired signature (HTTP 404/403) mid-transfer, so retry
    with backoff and resume from the bytes already on disk via Range requests.
    """
    part = destination.with_suffix(destination.suffix + ".part")
    expected: int | None = None
    for attempt in range(1, attempts + 1):
        existing = part.stat().st_size if part.exists() else 0
        # A complete file from an earlier run needs no transfer at all.
        if expected is not None and existing == expected:
            break
        request = urllib.request.Request(url)
        if existing:
            request.add_header("Range", f"bytes={existing}-")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                # A 206 means the server honoured the range and we append. A 200
                # means it ignored it and is sending the whole file again.
                resuming = existing > 0 and response.status == 206
                if resuming:
                    content_length = int(response.headers.get("Content-Length", 0))
                    expected = existing + content_length
                else:
                    existing = 0
                    expected = int(response.headers.get("Content-Length", 0)) or None
                with open(part, "ab" if resuming else "wb") as handle:
                    read = existing
                    while True:
                        chunk = response.read(1 << 20)
                        if not chunk:
                            break
                        handle.write(chunk)
                        read += len(chunk)
                        if expected:
                            print(f"\r  {read // (1 << 20)} / {expected // (1 << 20)} MB", end="")
            print()
            # A dropped connection ends the read loop early. Detect the shortfall
            # and retry rather than unpacking a truncated archive.
            if expected is None or part.stat().st_size == expected:
                break
            print(f"  incomplete ({part.stat().st_size} of {expected} bytes), resuming")
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            print(f"\n  attempt {attempt}/{attempts} failed: {error}")
            if attempt == attempts:
                raise
            time.sleep(min(2 ** attempt, 30))
    else:
        raise RuntimeError(f"Download did not complete after {attempts} attempts")

    part.replace(destination)


def install_templates() -> None:
    """Download and unpack the Mono export templates for this Godot version."""
    target = templates_dir()
    # GitHub release TAGS use a hyphen ("4.7.2-stable") while Godot's local
    # template DIRECTORY uses dots ("4.7.2.stable.mono"). Deriving the URL
    # straight from GODOT_VERSION produced ".../download/4.7.2.stable/..." and
    # a 404 on every retry, so the tag and the asset name must be built from
    # the dashed form.
    release_tag = GODOT_VERSION.replace(".mono", "").replace(".stable", "-stable")
    url = (
        f"https://github.com/godotengine/godot/releases/download/"
        f"{release_tag}/"
        f"Godot_v{release_tag}_mono_export_templates.tpz"
    )
    archive = BUILD_DIR / "export_templates.tpz"
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    if not archive.exists():
        print(f"Downloading export templates (~1.2 GB):\n  {url}")
        download(url, archive)

    print(f"Extracting into {target}")
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            if entry.is_dir():
                continue
            # Entries are stored as "templates/<file>"; strip the prefix.
            name = Path(entry.filename).name
            if not name:
                continue
            with bundle.open(entry) as source, open(target / name, "wb") as dest:
                shutil.copyfileobj(source, dest)

    # Godot records the installed version here; without it the editor still
    # reports "no export template found".
    (target / "version.txt").write_text(GODOT_VERSION + "\n", encoding="utf-8")
    print(f"Templates installed: {target}")


def write_presets() -> None:
    """Write export_presets.cfg with a Headless preset for this platform.

    The preset is committed so the export is reproducible on a fresh clone.
    Only the fields Godot actually requires are set; everything else defaults.
    """
    if sys.platform == "win32":
        platform_name, extension, binary = "Windows Desktop", ".exe", "YMRL.exe"
    elif sys.platform == "darwin":
        platform_name, extension, binary = "macOS", ".zip", "YMRL.zip"
    else:
        platform_name, extension, binary = "Linux", ".x86_64", "YMRL.x86_64"

    preset = f"""[preset.0]

name="{PRESET_NAME}"
platform="{platform_name}"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path="{BUILD_DIR.name}/{binary}"
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.0.options]

custom_template/debug=""
custom_template/release=""
debug/export_console_wrapper=0
binary_format/embed_pck=true
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
binary_format/architecture="x86_64"
codesign/enable=false
application/modify_resources=false
application/export_angle=0
application/export_d3d12=0
application/d3d12_agility_sdk_multiarch=true
application/icon=""
application/console_wrapper_icon=""
application/icon_interpolation=4
dotnet/include_scripts_content=false
dotnet/include_debug_symbols=false
dotnet/embed_build_outputs=false
"""
    EXPORT_PRESETS.write_text(preset, encoding="utf-8")
    print(f"Wrote {EXPORT_PRESETS.name} (preset '{PRESET_NAME}', platform '{platform_name}')")


def _binary_settled(path: Path) -> bool:
    """True once the file stops growing, i.e. Godot finished writing it."""
    try:
        first = path.stat().st_size
        time.sleep(0.5)
        return first > 0 and path.stat().st_size == first
    except FileNotFoundError:
        return False


def running_editors() -> list[int]:
    """PIDs of Godot processes already holding this project open.

    A second editor instance on the same project blocks the export: it waits on
    the project lock and never writes output. Detect that up front instead of
    hanging until the timeout.
    """
    if sys.platform != "win32":
        return []
    query = (
        "Get-CimInstance Win32_Process | "
        "Where-Object { $_.Name -like 'Godot*' -and $_.CommandLine -like '*ymrl*' } | "
        "Select-Object -ExpandProperty ProcessId"
    )
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", query],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (subprocess.SubprocessError, OSError):
        return []
    return [int(line) for line in result.stdout.split() if line.strip().isdigit()]


def check(godot: Path) -> int:
    print(f"Godot:      {godot}")
    print(f"Version:    {GODOT_VERSION}")
    print(f"Templates:  {templates_dir()} -> {'OK' if templates_installed() else 'MISSING'}")
    print(f"Presets:    {EXPORT_PRESETS.name} -> {'OK' if EXPORT_PRESETS.exists() else 'MISSING'}")
    return 0 if templates_installed() and EXPORT_PRESETS.exists() else 1


def export(godot: Path, debug: bool) -> int:
    mode = "--export-debug" if debug else "--export-release"
    if sys.platform == "win32":
        binary = BUILD_DIR / "YMRL.exe"
    elif sys.platform == "darwin":
        binary = BUILD_DIR / "YMRL.zip"
    else:
        binary = BUILD_DIR / "YMRL.x86_64"

    editors = running_editors()
    if editors:
        print(
            "A Godot editor is already open on this project "
            f"(PID {', '.join(map(str, editors))}). Close it first: the export "
            "waits on the project lock and will not produce a binary.",
            file=sys.stderr,
        )
        return 1

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    # Remove the previous binary so a stale build cannot pass the check below.
    if binary.exists():
        binary.unlink()
    print(f"Exporting ({'debug' if debug else 'release'}) -> {binary}")

    # Godot writes a lot of progress output. Send it to a file rather than a
    # pipe: an unread pipe fills up and blocks the child, which looks like a
    # hang. The binary appearing on disk is the real success signal, so poll
    # for it instead of waiting on process exit (Godot does not always exit).
    log_path = BUILD_DIR / "export.log"
    with open(log_path, "w", encoding="utf-8") as log:
        process = subprocess.Popen(
            [str(godot), "--headless", "--path", str(PROJECT_ROOT), mode, PRESET_NAME, str(binary)],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + EXPORT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if process.poll() is not None:
                break
            if binary.exists() and _binary_settled(binary):
                # Give Godot a moment to flush the data directory, then stop it.
                time.sleep(1.0)
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                break
            time.sleep(0.5)
        else:
            process.kill()
            print(f"Export timed out after {EXPORT_TIMEOUT_SECONDS}s. See {log_path}", file=sys.stderr)
            return 1

    output = log_path.read_text(encoding="utf-8", errors="replace")
    # Godot exits 0 even when the export fails, so scan the log as well.
    failed = not binary.exists() or "Export FAILED" in output
    if failed:
        print("\n".join(output.strip().splitlines()[-30:]))
        print(f"\nExport FAILED. Full log: {log_path}", file=sys.stderr)
        return 1

    print(f"Exported: {binary}")
    print("\nTrain headless with:")
    print(f"  python tools/train_sb3.py --env_path {binary}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--debug", action="store_true", help="Export a debug build instead of release.")
    parser.add_argument("--install-templates", action="store_true", help="Download and install export templates, then exit.")
    parser.add_argument("--check", action="store_true", help="Report prerequisites and exit without changing anything.")
    parser.add_argument("--force-presets", action="store_true", help="Overwrite export_presets.cfg even if it exists.")
    args = parser.parse_args()

    godot = find_godot()

    if args.check:
        return check(godot)

    if args.install_templates:
        install_templates()
        return 0

    if not templates_installed():
        print("Export templates are missing.", file=sys.stderr)
        print("Run: python tools/export_headless.py --install-templates", file=sys.stderr)
        return 1

    if not EXPORT_PRESETS.exists() or args.force_presets:
        write_presets()

    return export(godot, args.debug)


if __name__ == "__main__":
    sys.exit(main())
