#!/usr/bin/env python3
"""Write LoopCtrlApp/ThirdPartyNotices.txt: the license texts of everything
compiled into the app and the runner that LoopCtrl did not write.

That is IDevice.xcframework — idevice's `ffi` crate and every crate it links
for aarch64-apple-ios with the features build-idevice.sh enables, plus musl,
which the static cli/loopctrl carries (cli/musl-COPYRIGHT). Proc macros
and build-only dependencies run on the build machine and are left out. Each
crate's own LICENSE / COPYING / NOTICE files are copied (identical texts are
printed once, with every crate that uses them); a crate that ships none gets
the standard text of its license.

Usage: Scripts/licenses.py [idevice-source-dir]   (default: build/idevice-src)
Run by build-idevice.sh after each build, so the file follows the pinned
version; commit the result.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "LoopCtrlApp", "ThirdPartyNotices.txt")
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "idevice-src")

FILES = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT)([-._].*)?$", re.I)

APACHE = open(os.path.join(ROOT, "LICENSE"), encoding="utf-8").read().strip()
MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


def metadata():
    out = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--locked",
         "--filter-platform", "aarch64-apple-ios", "--features", "obfuscate"],
        cwd=os.path.join(SRC, "ffi"), check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def shipped(meta):
    pkgs = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = next(p["id"] for p in meta["packages"] if p["name"] == "idevice-ffi")
    seen, stack = set(), [root]
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            if any(k["kind"] is None for k in dep["dep_kinds"]):
                stack.append(dep["pkg"])
    keep = [pkgs[i] for i in seen
            if not any("proc-macro" in t["kind"] for t in pkgs[i]["targets"])]
    return sorted(keep, key=lambda p: (p["name"], p["version"]))


def texts_for(pkg):
    """The crate's license files; in a workspace, the workspace root's too."""
    dirs = [os.path.dirname(pkg["manifest_path"])]
    if os.path.abspath(dirs[0]).startswith(os.path.abspath(SRC)):
        dirs.append(SRC)  # idevice's own crates keep LICENSE at the repo root
    found = []
    for d in dirs:
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name)
            if FILES.match(name) and os.path.isfile(path):
                found.append(open(path, encoding="utf-8", errors="replace").read().strip())
        if found:
            break
    if found:
        return found
    lic = pkg.get("license") or ""
    if "MIT" in lic:
        return [MIT]
    if "Apache-2.0" in lic:
        return [APACHE]
    raise SystemExit(f"{pkg['name']} {pkg['version']}: no license file and no known text for {lic!r}")


def normalize(text):
    return re.sub(r"\s+", " ", text).strip()


def group_key(text):
    """Full Apache-2.0 texts differ only in layout and in the appendix's
    template line, so they share one entry; the copyright lines a crate adds
    to its copy are kept with the crate's name instead."""
    flat = normalize(text)
    if flat.startswith("Apache License Version 2.0, January 2004") and "END OF TERMS AND CONDITIONS" in flat:
        extra = [l.strip() for l in text.splitlines()
                 if re.match(r"\s*Copyright\b", l) and "[yyyy]" not in l and "[name of" not in l]
        return "Apache-2.0", extra
    return flat, []


def main():
    pkgs = shipped(metadata())
    groups = {}  # normalized text -> (text, [crate labels])
    for pkg in pkgs:
        label = f"{pkg['name']} {pkg['version']}"
        for text in texts_for(pkg):
            key, extra = group_key(text)
            if key == "Apache-2.0":
                text = APACHE
            entry = label + "".join(f" ({line})" for line in extra)
            groups.setdefault(key, (text, []))[1].append(entry)

    lines = [
        "THIRD-PARTY SOFTWARE NOTICES",
        "",
        "LoopCtrl is licensed under the Apache License, Version 2.0.",
        "Copyright 2026 Ebato and the LoopCtrl contributors.",
        "Portions Copyright 2026 wsvn53 (iCTRL), Apache License, Version 2.0.",
        "",
        "LoopCtrl includes idevice (https://github.com/jkcoxson/idevice), the Rust",
        "libraries it links, and musl (in the bundled loopctrl CLI), listed below",
        "with their licenses. Generated by Scripts/licenses.py; do not edit by",
        "hand.",
        "",
        "COMPONENTS",
        "",
    ]
    for pkg in pkgs:
        lic = pkg.get("license") or "see license text"
        if pkg["name"] == "idevice-ffi":
            lic = "MIT"
        lines.append(f"{pkg['name']} {pkg['version']} — {lic}")
    # cli/loopctrl, which the runner serves, is linked statically against musl.
    musl = open(os.path.join(ROOT, "cli", "musl-COPYRIGHT"), encoding="utf-8").read().strip()
    lines.append("musl 1.2.5 (in cli/loopctrl) — MIT")
    groups["musl"] = (musl, ["musl 1.2.5"])
    for text, labels in sorted(groups.values(), key=lambda g: g[1][0]):
        lines += ["", "=" * 72, "", "Used by: " + ", ".join(labels), "", text]
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(pkgs)} components, {len(groups)} distinct license texts → {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
