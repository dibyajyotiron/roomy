r"""Builds a sanitised demo snapshot for screenshots from a real Roomy snapshot.

    python3 -I scripts/roomy-demo-snapshot.py ~/Library/Application\ Support/Roomy/snapshot.json demo.json [forbidden words...]
    ROOMY_DEMO=demo.json /Applications/Roomy.app/Contents/MacOS/Roomy

Allowlist-based: anything not known to be generic is dropped or replaced with a neutral example. Your username and
any extra words you pass (project, company or account names) must not appear in the output, or it refuses to write."""
import json, re, sys, copy

import os
src, dst = sys.argv[1], sys.argv[2]
USER = os.environ.get("USER", "")
d = json.load(open(src))
GB = 1_000_000_000

APPS = {"Xcode", "Google Chrome", "Visual Studio Code", "ChatGPT", "Claude", "LM Studio", "Discord", "Postman",
        "WhatsApp", "Safari", "Ghostty", "Roomy", "Prime Video", "Netflix", "Spark Desktop"}
DOT = {".codex", ".claude", ".npm", ".cache", ".nvm", ".rustup", ".cargo", ".lmstudio", ".ollama", ".gradle", ".docker",
       ".vscode", ".bun", ".pnpm-store", ".m2", ".cline", ".dart-tool", ".dartServer", ".codestream", ".dbclient"}
HOME_KIDS = {"Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Applications", "Public"} | DOT

d["disk"].update({"used": d["disk"]["total"] - int(128.6 * GB), "free": int(128.6 * GB)})

# Apps and everything listed per app
d["apps"] = [a for a in d["apps"] if a["name"] in APPS]
d["languageFiles"] = [i for i in d.get("languageFiles", []) if any(a in i["name"] for a in APPS)]
d["universalBinaries"] = [i for i in d.get("universalBinaries", []) if any(a in i["name"] for a in APPS)]
d["outdated"] = [o for o in d.get("outdated", []) if o["name"] in {"codex", "orbstack", "google-chrome", "visual-studio-code"}]

# Startup items: everyday helpers only
d["launchItems"] = [l for l in d.get("launchItems", []) if re.match(r"^(com\.google\.|homebrew\.mxcl\.|com\.docker\.|com\.microsoft\.|com\.adobe\.|com\.proxyman\.)", l["name"])]

# Leftovers: a realistic, generic set
def left(path, name, b, note, review):
    return {"path": path, "name": name, "bytes": int(b), "count": 1, "note": note, "review": review}
d["leftovers"] = [
    left("~/Library/HTTPStorages/com.openai.atlas", "com.openai.atlas", 3.6e6, "HTTPStorages · changed 5 months ago · rebuilds if the app comes back", False),
    left("~/Library/WebKit/com.openai.atlas.web", "com.openai.atlas.web", 3.0e6, "WebKit · changed 5 months ago · rebuilds if the app comes back", False),
    left("~/Library/Application Support/com.openai.atlas", "com.openai.atlas", 1.67e9, "Application Support · changed 2 months ago · may hold the app's data, so you choose", True),
    left("~/Library/Preferences/com.openai.atlas.plist", "com.openai.atlas", 14588, "Preferences · changed 2 months ago · may hold the app's data, so you choose", True),
    left("~/Library/WebKit/us.zoom.xos", "us.zoom.xos", 410e3, "WebKit · changed 4 months ago · rebuilds if the app comes back", False),
    left("~/Library/Application Support/zoom.us", "zoom.us", 83.2e6, "Application Support · changed 4 months ago · may hold the app's data, so you choose", True),
    left("~/Library/HTTPStorages/company.thebrowser.dia", "company.thebrowser.dia", 156e3, "HTTPStorages · changed 3 months ago · rebuilds if the app comes back", False),
    left("~/Library/Caches/com.todesktop.230313mzl4w4u92", "com.todesktop.230313mzl4w4u92", 82e3, "Caches · changed 6 months ago · rebuilds if the app comes back", False),
    left("~/Library/Group Containers/JQ525L2MZD.com.adobe.GrowthSDK", "JQ525L2MZD.com.adobe.GrowthSDK", 541e6, "Group Containers · changed 8 months ago · may hold the app's data, so you choose", True),
    left("~/.dart-tool", ".dart-tool", 168e3, "Its tool looks uninstalled · may hold settings, so check first", True),
    left("~/.dartServer", ".dartServer", 71e6, "Its tool looks uninstalled · may hold settings, so check first", True),
]

# Your files: neutral examples (no real file names)
def lf(path, b, days):
    return {"path": path, "bytes": int(b), "isPackage": False, "insideAppData": False}
d["largeFiles"] = [lf(p, b, 0) for p, b in [
    ("/Users/Shared/Virtual Machines.localized/Windows 11 Arm.vmwarevm", 42.1 * GB), ("~/Downloads/Xcode_26.xip", 9.4 * GB),
    ("~/Movies/Conference talk (4K).mov", 4.2 * GB), ("~/Downloads/ubuntu-24.04-desktop-arm64.iso", 3.1 * GB),
    ("~/Documents/Archive 2024.zip", 2.3 * GB), ("~/Movies/Screen Recording 2026-03-02.mov", 1.4 * GB),
    ("~/Downloads/Figma-agent.dmg", 0.6 * GB)]]
d["duplicates"] = [
    {"hash": "a1", "name": "Product photos.zip", "bytes": int(21e6), "files": ["~/Downloads/Product photos.zip", "~/Documents/Assets/Product photos.zip"]},
    {"hash": "b2", "name": "invoice-template.pdf", "bytes": int(8e6), "files": ["~/Documents/invoice-template.pdf", "~/Desktop/invoice-template.pdf", "~/Downloads/invoice-template.pdf"]},
    {"hash": "c3", "name": "logo@2x.png", "bytes": int(1.2e6), "files": ["~/Desktop/logo@2x.png", "~/Documents/Brand/logo@2x.png"]},
]
d["photos"], d["photosChecked"] = [], 0
d["installers"] = []
d["artifacts"] = [dict(a, path=p) for a, p in zip(d["artifacts"][:6], [
    "~/Developer/web-app/node_modules", "~/Developer/api-server/node_modules", "~/Developer/dashboard/.next",
    "~/Developer/landing-page/dist", "~/Developer/data-tools/.venv", "~/Developer/mobile-app/build"])]
for a in d["artifacts"]:
    for k in ("project", "name"):
        if k in a: a[k] = a["path"].split("/")[2]

# AI tools: worktrees renamed to a neutral project
NAMES = ["dark-mode", "onboarding", "search-filters", "quick-fix", "settings-page", "api-retry", "charts", "export"]
for i, w in enumerate(d["aiCare"].get("worktrees", [])):
    w["path"] = "~/Developer/web-app/.claude/worktrees/" + NAMES[i % len(NAMES)] + ("" if i < len(NAMES) else str(i))
    w["project"] = "web-app"; w["name"] = w["path"].split("/")[-1]
    if "repoRoot" in w: w["repoRoot"] = "~/Developer/web-app"

# Container internals carry container names: leave them out
for c in d["categories"]:
    for k in ("items", "held", "kept"):
        c[k] = [i for i in c.get(k, []) if "OrbStack/docker/containers" not in i["path"] and ".orbstack" not in i["path"]]

# AI chats: same counts and sizes, neutral file paths
import uuid
for c in d["aiCare"].get("chats", []):
    root = c["path"]
    for i, f in enumerate(c["files"]):
        f["path"] = (root.rstrip("/") + "/" + ("-Developer-web-app/" if ".claude" in root else "") + str(uuid.UUID(int=i + 1)) + ".jsonl")
        if "title" in f: f["title"] = None

# Storage: generic names only
FRIENDLY = {"Codex data", "LM Studio data", "Node versions (nvm)", "Rust toolchains", "Tool caches", "VS Code extensions", "Claude Code data", ".codeium"}
GENERIC_DOCS = {"Desktop", "Documents", "Downloads", "Music", "Movies", "Pictures", "Sandboxed apps' containers", "System services' containers",
                "Other files in Home", "WhatsApp iCloud data"}
for s in d["storage"]["segments"]:
    k = s["key"]
    if k == "apps": s["children"] = [c for c in s["children"] if c["name"] == "Apps' data in Application Support" or c["name"] in APPS]
    elif k == "docs": s["children"] = [c for c in s["children"] if c["name"] in GENERIC_DOCS]
    elif k == "icloud": s["children"] = [c for c in s["children"] if c["name"] in {"iCloud Drive folder", "iCloud Drive's local database"}]
    elif k == "others":
        kids = []
        for c in s["children"]:
            if c["name"] == "Virtual machines": kids.append(c)
            elif "account" in c["name"]: kids.append(dict(c, name="Another account", path="/Users/guest"))
        s["children"] = kids
    for c in s["children"]:
        if c.get("children"):
            c["children"] = [x for x in c["children"] if x["name"] in FRIENDLY or x["name"] in DOT or x["name"] in APPS or x["name"] in GENERIC_DOCS]
    for c in s["children"]:
        if c["name"] == "Only macOS can see this":
            c["why"] = "Space no app can read, even with Full Disk Access: Spotlight's search index and file-system records, and system folders only an administrator can read."

# Disk Map: top two levels with generic names only
def lens(n, depth):
    if depth >= 2:
        n["children"] = None
        return n
    kids = []
    for c in n.get("children") or []:
        name = c["name"]
        ok = depth == 0 or name in HOME_KIDS or name in APPS or name.replace(".app", "") in APPS or name in {"Cellar", "var", "Caskroom", "share", "lib", "opt", "Virtual Machines.localized", "Smaller items", "Application Support", "Caches", "Fonts", "Developer", "Audio"}
        if ok: kids.append(lens(c, depth + 1))
    n["children"] = kids
    return n
if d.get("lens"): d["lens"] = lens(d["lens"], 0)

# History: a few plain entries
d["history"] = [{k: v for k, v in h.items() if k not in ("removed", "failures")} for h in d["history"][:4]]

out = json.dumps(d).replace("/Users/" + USER, "~")
# zsh names its completion cache after the computer ("~/.zcompdump-Someones-MacBook-Pro-5.9"): keep the version only.
out = re.sub(r'\.zcompdump-[^"/\\]*?-(\d+\.\d+)', r'.zcompdump-Mac-\1', out)
bad = [w.lower() for w in [USER, "/Users/" + USER] + sys.argv[3:] if w]
found = [b for b in bad if b in out.lower()]
if found:
    hits = {b: [m.start() for m in re.finditer(re.escape(b), out.lower())][:3] for b in found}
    for b, pos in hits.items():
        for p in pos: print(b, "…", out[max(0, p - 80):p + 40].replace("\n", " "))
    sys.exit("personal strings remain: " + ", ".join(found))
open(dst, "w").write(out)
print("ok", len(out), "bytes")
