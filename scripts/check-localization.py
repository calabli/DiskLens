#!/usr/bin/env python3
"""Checks that every Chinese string in the app is localizable and translated.

Builds DiskLensApp with the compiler's string extraction (the same one Xcode uses for
string catalogs), then:
  1. every string literal with Chinese text in Sources/DiskLensApp and DiskLensCore must
     be one the compiler extracted, i.e. it reaches the UI through Text, Button, L(...)
     and so on, not as a plain String shown verbatim; a literal that is not UI text
     (matched against command output, say) carries a `// l10n: ignore` comment;
  2. every extracted key must have an English translation in
     Localization/en.lproj/Localizable.strings.
Pass --keys to print the missing keys in .strings format, ready to translate.
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, ".build", "l10n-strings")
CJK = re.compile(r"[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]")


def build():
    os.makedirs(OUT, exist_ok=True)
    flags = []
    for f in ["-emit-localized-strings", "-emit-localized-strings-path", OUT]:
        flags += ["-Xswiftc", f]
    subprocess.run(["swift", "build", "--scratch-path", os.path.join(ROOT, ".build", "l10n"),
                    "--product", "DiskLensApp"] + flags, cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)


def extracted():
    keys, locations = {}, set()
    for name in os.listdir(OUT):
        if not name.endswith(".stringsdata"):
            continue
        data = json.load(open(os.path.join(OUT, name)))
        source = os.path.realpath(data["source"])
        for entries in data["tables"].values():
            for e in entries:
                loc = (source, e["location"]["startingLine"], e["location"]["startingColumn"])
                locations.add(loc)
                keys.setdefault(e["key"], loc)
    return keys, locations


def literals(path):
    """(line, column, text) of each string literal, skipping comments and following interpolations."""
    src = open(path, encoding="utf-8").read()
    out, i, line, col = [], 0, 1, 1
    n = len(src)

    def advance(k):
        nonlocal i, line, col
        for _ in range(k):
            if src[i] == "\n":
                line, col = line + 1, 1
            else:
                col += len(src[i].encode("utf-8"))  # the compiler counts UTF-8 bytes
            i += 1

    def string(start_line, start_col):
        # i is just past the opening quote(s); returns the literal text.
        triple = src.startswith('""', i - 1) and src[i - 1:i + 2] == '"""'
        if triple:
            advance(2)
        text = []
        while i < n:
            if src[i] == "\\" and i + 1 < n and src[i + 1] == "(":
                advance(2)
                depth = 1
                while i < n and depth:
                    c = src[i]
                    if c == '"':
                        l, k = line, col
                        advance(1)
                        string(l, k)
                        continue
                    depth += c == "("
                    depth -= c == ")"
                    advance(1)
                text.append("%@")
                continue
            if src[i] == "\\":
                text.append(src[i:i + 2])
                advance(2)
                continue
            if triple and src.startswith('"""', i):
                advance(3)
                break
            if not triple and src[i] == '"':
                advance(1)
                break
            text.append(src[i])
            advance(1)
        out.append((start_line, start_col, "".join(text)))

    while i < n:
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                advance(1)
        elif src.startswith("/*", i):
            while i < n and not src.startswith("*/", i):
                advance(1)
            advance(2)
        elif src[i] == '"':
            l, c = line, col
            advance(1)
            string(l, c)
        else:
            advance(1)
    return out, src.split("\n")


def translations(path):
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8").read()
    pattern = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
    unescape = lambda s: s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
    return {unescape(k): unescape(v) for k, v in pattern.findall(text)}


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main():
    build()
    keys, locations = extracted()
    problems = 0
    for target in ["Sources/DiskLensApp", "Sources/DiskLensCore"]:
        for dirpath, _, files in os.walk(os.path.join(ROOT, target)):
            for f in sorted(files):
                if not f.endswith(".swift"):
                    continue
                path = os.path.realpath(os.path.join(dirpath, f))
                found, lines = literals(path)
                for line, col, text in found:
                    if not CJK.search(text) or (path, line, col) in locations:
                        continue
                    if "l10n: ignore" in lines[line - 1]:
                        continue
                    problems += 1
                    print(f"{os.path.relpath(path, ROOT)}:{line}:{col}: not localizable: \"{text}\"")
    english = translations(os.path.join(ROOT, "Localization", "en.lproj", "Localizable.strings"))
    missing = sorted(k for k in keys if CJK.search(k) and k not in english)
    unused = sorted(k for k in english if k not in keys)
    if "--keys" in sys.argv:
        for k in missing:
            print(f'"{escape(k)}" = "";')
        return
    for k in missing:
        source, line, _ = keys[k]
        print(f"{os.path.relpath(source, ROOT)}:{line}: no English: \"{k}\"")
    for k in unused:
        print(f"unused translation: \"{k}\"")
    problems += len(missing)
    print(f"{len(keys)} keys, {len(english)} translations, {problems} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
