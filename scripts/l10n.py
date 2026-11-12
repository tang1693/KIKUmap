#!/usr/bin/env python3
"""KIKUmap's translations.

  python3 scripts/l10n.py extract   → scripts/l10n/keys.json: every English text the app can show, as tr() looks it
                                      up (interpolations as "%@"), with the Chinese beside it where there is one
  python3 scripts/l10n.py build     → Sources/L10nData.swift from scripts/l10n/<lang>.json ({key: text})
  python3 scripts/l10n.py check     → what's missing or broken in each language

The app is written in Chinese and English (`tr("中文", "English")`); keys are the English texts. A literal counts
when it's the English side of a tr() call or of a Chinese/English pair (a table's row), or sits in an argument that
becomes one (ShortcutTable's rows, the demos' typing).
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources")
DIR = os.path.join(ROOT, "scripts", "l10n")
LANGS = ["zh-Hant", "ja", "ko", "es", "pt-BR", "de", "fr"]
CJK = re.compile(r"[㐀-鿿　-〿＀-￯]")


def parse_literal(s, i):
    """The Swift string literal starting at s[i] ('"' or '#"'): (its runtime key with \\(…) as %@, end index)."""
    raw = 0
    while s[i] == "#":
        raw += 1; i += 1
    triple = s.startswith('"""', i)
    q = '"""' if triple else '"'
    i += len(q)
    close = q + "#" * raw
    esc = "\\" + "#" * raw
    out = []
    if triple:
        # the content starts on the next line; indentation is that of the closing delimiter
        nl = s.index("\n", i)
        i = nl + 1
    start = i
    while True:
        if s.startswith(close, i):
            end = i + len(close)
            break
        if s.startswith(esc, i):
            j = i + len(esc)
            c = s[j]
            if c == "(":
                d, k = 1, j + 1
                while d:
                    if s[k] == "(": d += 1
                    elif s[k] == ")": d -= 1
                    elif s[k] == '"':
                        _, k = parse_literal(s, k); continue
                    k += 1
                out.append("\x00")          # an interpolation
                i = k; continue
            if c == "n": out.append("\n")
            elif c == "t": out.append("\t")
            elif c == "u":
                k = s.index("}", j)
                out.append(chr(int(s[j + 2:k], 16))); i = k + 1; continue
            elif c == "\n" and triple:      # line continuation
                i = j + 1; continue
            else: out.append(c)
            i = j + 1; continue
        out.append(s[i]); i += 1
    text = "".join(out)
    if triple:
        lines = text.split("\n")
        indent = len(lines[-1]) - len(lines[-1].lstrip(" "))
        body = lines[:-1]
        text = "\n".join(l[indent:] if l.strip() else "" for l in body)
        # (a line continuation already joined lines; trailing "\" handled above)
    return text.replace("\x00", "%@"), end


def literals(s):
    """Every string literal in a source file: (start, end, key)."""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if s.startswith("//", i):
            i = s.index("\n", i) if "\n" in s[i:] else n; continue
        if s.startswith("/*", i):
            i = s.index("*/", i) + 2; continue
        if c == '"' or (c == "#" and re.match(r'#+"', s[i:])):
            try:
                key, end = parse_literal(s, i)
            except (ValueError, IndexError):
                i += 1; continue
            out.append((i, end, key)); i = end; continue
        i += 1
    return out


def looks_english(k):
    t = k.strip()
    if not t or CJK.search(t) or not re.search(r"[A-Za-z]", t): return False
    if re.fullmatch(r"[a-z][A-Za-z0-9_.:-]*", t): return False              # identifiers, keys, symbol names
    if re.search(r"://|^\.|^/|\\\\|^[A-Z][a-zA-Z]+[A-Z][a-z]+$", t): return False
    if re.fullmatch(r"[A-Za-z0-9_]+\.[a-z]{2,4}", t): return False           # file names
    if re.fullmatch(r"[A-Z_]+", t): return False                            # CONSTANTS
    if re.fullmatch(r"[%@\d\s:.,·hmsdHMy'EaMLz\-/()]+", t): return False      # bare formats
    return True


def call_args(s, lits):
    """Every bracketed list in the file as its top-level arguments, each a list of the literal keys in it (literals
    inside an interpolation or a nested call are that call's, not this one's)."""
    starts = {a: (b, k) for a, b, k in lits}
    out, stack = [], []          # stack: [args, current arg's literals, depth-kind]
    i, n = 0, len(s)
    while i < n:
        if i in starts:
            b, k = starts[i]
            if stack: stack[-1][1].append(k)
            i = b; continue
        if s.startswith("//", i):
            j = s.find("\n", i); i = n if j < 0 else j; continue
        if s.startswith("/*", i):
            i = s.index("*/", i) + 2; continue
        c = s[i]
        if c in "([":
            stack.append([[], [], c])
        elif c in ")]" and stack:
            args, cur, _ = stack.pop()
            args.append(cur)
            out.append(args)
        elif c == "," and stack:
            stack[-1][0].append(stack[-1][1]); stack[-1][1] = []
        i += 1
    return out


def extract():
    keys = {}
    files = [os.path.join(SRC, f) for f in sorted(os.listdir(SRC))] + [os.path.join(ROOT, "Widget", f) for f in sorted(os.listdir(os.path.join(ROOT, "Widget")))]
    for path in files:
        f = os.path.basename(path)
        if not f.endswith(".swift") or f.startswith("L10nData"): continue
        s = open(path).read()
        for args in call_args(s, literals(s)):
            for x, y in zip(args, args[1:]):
                if not x or not y: continue
                if not all(CJK.search(k) for k in x) or any(CJK.search(k) for k in y): continue
                for i, k in enumerate(y):
                    # beside a Chinese text it's shown, even a single lowercase word ("or", "tap"): only skip what's
                    # plainly not words (paths, addresses, patterns, bare formats)
                    if not re.search(r"[A-Za-z]", k) or re.search(r"://|^[/~.]\S*$|\\[dswb(]", k) or re.fullmatch(r"[%@\d\s:.,·hmsdHMy'EaMLz\-/()]+", k): continue
                    zh = x[min(i, len(x) - 1)]
                    keys.setdefault(k, {"zh": zh, "where": f, "ctx": "paired"})
        # counts inside a sentence (L10n.count, and Archive's n(k, "chat", "chats")): "1 chat" and "%@ chats"
        for m in re.finditer(r'\b(?:n|L10n\.count)\(\s*[^,()]+,\s*"([^"]+)",\s*"([^"]+)"\s*\)', s):
            keys.setdefault("1 " + m.group(1), {"zh": "1 个", "where": f, "ctx": "count"})
            keys.setdefault("%@ " + m.group(2), {"zh": "%@ 个", "where": f, "ctx": "count"})
    os.makedirs(DIR, exist_ok=True)
    json.dump(keys, open(os.path.join(DIR, "keys.json"), "w"), ensure_ascii=False, indent=1, sort_keys=True)
    print(f"{len(keys)} English texts → scripts/l10n/keys.json")


def build():
    keys = json.load(open(os.path.join(DIR, "keys.json")))
    tables = {l: (json.load(open(os.path.join(DIR, l + ".json"))) if os.path.exists(os.path.join(DIR, l + ".json")) else {}) for l in LANGS}
    out = {}
    for k in sorted(keys):
        row = [tables[l].get(k, "") for l in LANGS]
        if any(row): out[k] = row
    js = json.dumps(out, ensure_ascii=False, separators=(",", ":"))
    assert '"""#' not in js
    path = os.path.join(SRC, "L10nData.swift")
    open(path, "w").write("// Generated by scripts/l10n.py from the translations in scripts/l10n/: don't edit by hand.\n"
                          "// English key → [" + ", ".join(LANGS) + "].\n"
                          "enum L10nData {\n    static let json = #\"\"\"\n" + js + "\n\"\"\"#\n}\n")
    print(f"{len(out)} keys → Sources/L10nData.swift")


def check():
    keys = json.load(open(os.path.join(DIR, "keys.json")))
    for l in LANGS:
        p = os.path.join(DIR, l + ".json")
        t = json.load(open(p)) if os.path.exists(p) else {}
        missing = [k for k in keys if not t.get(k)]
        bad = [k for k in keys if t.get(k) and (k.count("%@") != t[k].count("%@") + len(re.findall(r"%\d\$@", t[k])))]
        print(f"{l}: {len(keys) - len(missing)}/{len(keys)} translated, {len(bad)} with a different number of %@")
        for k in bad[:5]: print("   ", repr(k[:60]), "→", repr(t[k][:60]))


if __name__ == "__main__":
    {"extract": extract, "build": build, "check": check}[sys.argv[1] if len(sys.argv) > 1 else "check"]()
