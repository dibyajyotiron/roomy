#!/usr/bin/env python3
"""Local release validation. No publishing, installation, or application execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
REPO = "dibyajyotiron/roomy"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def git(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0")
    return run(["/usr/bin/git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", str(ROOT), *args], env=env)


def source_info():
    return {"schema": 1, "sourceCommit": git("rev-parse", "HEAD"),
            "dirty": bool(git("status", "--porcelain", "--untracked-files=normal")),
            "version": (ROOT / "VERSION").read_text().strip(),
            "moleCommit": (ROOT / "MOLE_COMMIT").read_text().strip()}


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def names(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Invalid release version")
    return [f"Roomy-{version}.pkg", f"Roomy-{version}.zip", f"Roomy-{version}.sha256", "appcast.xml"]


def check_checksum_list(text, version, assets):
    expected = {f"Roomy-{version}.{ext}": assets[f"Roomy-{version}.{ext}"] for ext in ("pkg", "zip")}
    found = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (Roomy-[0-9.]+\.(?:pkg|zip))", line)
        if not match or match[2] in found:
            raise ValueError("Invalid or duplicate checksum-list entry")
        found[match[2]] = match[1]
    if found != expected:
        raise ValueError("Published checksum list disagrees with the signed manifest")


def manifest(dist):
    info = source_info()
    if info["dirty"]:
        raise ValueError("Release manifest requires a clean source checkout, including untracked files")
    result = {"schema": 1, "version": info["version"], "commit": info["sourceCommit"],
              "moleCommit": info["moleCommit"], "assets": {n: sha(dist / n) for n in names(info["version"])}}
    (dist / "release-manifest.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


def archive_info(path, version, commit, mole_commit):
    """Check paths and symlink targets before any extraction; then inspect the sealed provenance."""
    with zipfile.ZipFile(path) as z:
        seen = set()
        for item in z.infolist():
            name = item.filename
            parts = PurePosixPath(name).parts
            if name in seen or "\\" in name or any(ord(c) < 32 for c in name) or name.startswith("/") or ".." in parts:
                raise ValueError("Unsafe or duplicate archive path")
            seen.add(name)
            if not parts or parts[0] not in ("Roomy.app", "__MACOSX"):
                raise ValueError("Unexpected archive root")
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = z.read(item).decode("utf-8")
                if target.startswith("/") or "\\" in target or any(ord(c) < 32 for c in target):
                    raise ValueError("Unsafe archive symlink")
                resolved = list(parts[:-1])
                for part in PurePosixPath(target).parts:
                    if part == "..":
                        if len(resolved) <= 1:
                            raise ValueError("Archive symlink escapes its root")
                        resolved.pop()
                    elif part != ".":
                        resolved.append(part)
        # No archive entry may write through a symlink ancestor, even when the link itself is internal.
        links = {i.filename.rstrip("/") for i in z.infolist() if stat.S_ISLNK(i.external_attr >> 16)}
        for name in seen:
            parent = PurePosixPath(name).parent
            while str(parent) != ".":
                if str(parent) in links:
                    raise ValueError("Archive entry writes through a symlink")
                parent = parent.parent
        p = "Roomy.app/Contents/"
        info = json.loads(z.read(p + "Resources/BuildInfo.json"))
        if info.get("sourceCommit") != commit or info.get("dirty") is not False or info.get("version") != version or info.get("moleCommit") != mole_commit:
            raise ValueError("Archive provenance does not match the release commit, version, or Mole pin")
        plist = plistlib.loads(z.read(p + "Info.plist"))
        if plist.get("CFBundleIdentifier") != "app.roomy.Roomy" or plist.get("CFBundleShortVersionString") != version:
            raise ValueError("Archive is not the production Roomy version")
        bundled = z.read(p + "Resources/mole/ROOMY_MOLE_COMMIT").decode().strip()
        if bundled != mole_commit:
            raise ValueError("Archive Mole provenance does not match the pin")


def verifier():
    work = tempfile.TemporaryDirectory(prefix="roomy-verify-")
    exe = Path(work.name) / "verify"
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-module-cache-path", str(Path(work.name) / "cache"),
                    str(ROOT / "scripts/verify-release.swift"), "-o", str(exe)], check=True)
    return work, exe


def verify(dist, version, commit):
    names(version)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected a full source commit")
    key = (ROOT / "Roomy/Resources/sparkle-public-ed-key.txt").read_text().strip()
    work, exe = verifier()
    try:
        subprocess.run([str(exe), key, str(dist / "release-manifest.sig"), str(dist / "release-manifest.json")], check=True)
        data = json.loads((dist / "release-manifest.json").read_text())
        mole = (ROOT / "MOLE_COMMIT").read_text().strip()
        if data.get("schema") != 1 or data.get("commit") != commit or data.get("version") != version or data.get("moleCommit") != mole:
            raise ValueError("Signed manifest does not match the expected source and dependency")
        if set(data.get("assets", {})) != set(names(version)):
            raise ValueError("Unexpected signed asset set")
        for name, expected in data["assets"].items():
            if not re.fullmatch(r"[0-9a-f]{64}", expected) or sha(dist / name) != expected:
                raise ValueError("Signed asset digest mismatch: " + name)
        check_checksum_list((dist / f"Roomy-{version}.sha256").read_text(), version, data["assets"])
        feed = ET.parse(dist / "appcast.xml").getroot()
        items = feed.findall("./channel/item")
        if len(items) != 1 or items[0].findtext(SPARKLE + "shortVersionString") != version:
            raise ValueError("Appcast version mismatch")
        enclosure = items[0].find("enclosure")
        zipname = f"Roomy-{version}.zip"
        if enclosure is None or enclosure.get("url") != f"https://github.com/{REPO}/releases/download/v{version}/{zipname}" or enclosure.get("length") != str((dist / zipname).stat().st_size):
            raise ValueError("Appcast URL or size mismatch")
        sig = Path(work.name) / "archive.sig"
        sig.write_text(enclosure.get(SPARKLE + "edSignature", ""))
        subprocess.run([str(exe), key, str(sig), str(dist / zipname)], check=True)
        archive_info(dist / zipname, version, commit, mole)
    finally:
        work.cleanup()


def ci_passed(checks, runs, commit):
    """Only GitHub Actions' latest check and main push of this workflow count."""
    checks = [c for c in checks if c.get("name") == "Build Roomy" and c.get("head_sha") == commit and c.get("app", {}).get("id") == 15368]
    runs = [r for r in runs if r.get("head_sha") == commit and r.get("event") == "push" and r.get("head_branch") == "main" and r.get("path") == ".github/workflows/build.yml"]
    return bool(checks and runs and max(checks, key=lambda c: c["id"]).get("conclusion") == "success"
                and max(checks, key=lambda c: c["id"]).get("status") == "completed"
                and max(runs, key=lambda r: r["id"]).get("conclusion") == "success"
                and max(runs, key=lambda r: r["id"]).get("status") == "completed")


def ci(commit):
    def api(endpoint):
        return json.loads(run(["gh", "api", f"repos/{REPO}/{endpoint}"]))
    checks = api(f"commits/{commit}/check-runs?per_page=100")["check_runs"]
    runs = api(f"actions/workflows/build.yml/runs?head_sha={commit}&event=push&per_page=100")["workflow_runs"]
    if not ci_passed(checks, runs, commit):
        raise ValueError("The latest GitHub Actions Build Roomy check and main push run must both pass for this exact commit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build-info", "manifest", "verify", "ci"])
    parser.add_argument("path")
    parser.add_argument("--version")
    parser.add_argument("--commit")
    a = parser.parse_args()
    if a.action == "build-info":
        (Path(a.path) / "Contents/Resources/BuildInfo.json").write_text(json.dumps(source_info(), indent=2, sort_keys=True) + "\n")
    elif a.action == "manifest":
        manifest(Path(a.path))
    elif a.action == "ci":
        ci(a.path)
    else:
        verify(Path(a.path), a.version, a.commit)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        raise SystemExit("Release validation failed: " + str(error))
