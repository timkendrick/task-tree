---
title: "/tmp/tt_audit.py"
created: 2026-08-28T14:09:01Z
updated: 2026-08-28T14:09:01Z
---
#!/usr/bin/env python3
"""Audit: map tt commands -> jj commands (direct + transitive via lib/common.sh)."""
import os, re, json, glob

ROOT = "scripts/cli"
COMMON = os.path.join(ROOT, "lib/common.sh")
FUNC_RE = re.compile(r'^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{')

FLAGS_WITH_ARG = {"-R", "--repository", "--at-operation", "--at-op", "--config",
                  "--config-file", "--color", "--config-toml"}
SUBSUB = {"bookmark", "op", "file", "workspace", "git", "config", "util", "sparse",
          "operation", "debug", "tag"}
# command position: start of line, or after one of these shell operators
CMDPOS = r'(?:^|[|&;(`]|\$\(|\{\s|(?<=\bif )|(?<=\bthen )|(?<=\bdo )|(?<=\belse )|(?<=\b!\s))\s*'


def clean(path):
    """Strip comments and heredoc bodies; return list of (lineno, text)."""
    raw = open(path).read().split("\n")
    out, i, n = [], 0, len(raw)
    heredoc_tag = None
    for idx, ln in enumerate(raw, 1):
        if heredoc_tag is not None:
            if ln.strip() == heredoc_tag:
                heredoc_tag = None
            continue
        m = re.search(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?\s*$', ln)
        s = ln.lstrip()
        if s.startswith("#"):
            out.append((idx, ""))
            continue
        out.append((idx, ln))
        if m:
            heredoc_tag = m.group(1)
    return out


def parse_units(path):
    """-> ({func: [(lineno,text)]}, toplevel [(lineno,text)])"""
    lines = clean(path)
    funcs, top = {}, []
    i, n = 0, len(lines)
    while i < n:
        m = FUNC_RE.match(lines[i][1])
        if m:
            name = m.group(1)
            j = i + 1
            while j < n and not re.match(r'^\}', lines[j][1]):
                j += 1
            funcs[name] = lines[i + 1:j]
            i = j + 1
        else:
            top.append(lines[i])
            i += 1
    return funcs, top


def jj_calls(unit):
    found = []
    for lineno, ln in unit:
        for m in re.finditer(CMDPOS + r'jj\s+([^\n|&;)]*)', ln):
            toks = m.group(1).split()
            k = 0
            while k < len(toks):
                t = toks[k]
                if t in FLAGS_WITH_ARG:
                    k += 2
                elif t.startswith("-"):
                    k += 1
                elif "$" in t or t.startswith('"$'):
                    k += 1
                else:
                    break
            if k >= len(toks):
                continue
            cmd = toks[k]
            if not re.match(r'^[a-z][a-z-]+$', cmd):
                continue
            if cmd in SUBSUB and k + 1 < len(toks) and re.match(r'^[a-z][a-z-]+$', toks[k + 1]):
                cmd += " " + toks[k + 1]
            found.append((cmd, lineno, ln.strip()))
    return found


common_funcs, _ = parse_units(COMMON)
FUNC_NAMES = set(common_funcs)

scripts = []
for d in ["task", "workspace", "worktree", "history"]:
    for p in sorted(glob.glob(os.path.join(ROOT, d, "**"), recursive=True)):
        if p.endswith(".test.sh") or os.path.isdir(p):
            continue
        scripts.append(p)
scripts.append(os.path.join(ROOT, "tt"))

units = {}
for name, body in common_funcs.items():
    units["common:" + name] = body
for p in scripts:
    f, top = parse_units(p)
    body = list(top)
    for fn, b in f.items():
        body += b
    units["script:" + p] = body


def calls_of(unit, self_name=None):
    out = set()
    for lineno, ln in unit:
        for m in re.finditer(CMDPOS + r'([a-zA-Z_][a-zA-Z0-9_]*)\b', ln):
            nm = m.group(1)
            if nm in FUNC_NAMES and nm != self_name:
                out.add(nm)
        # also command-substitution / arguments style: name inside $( )
        for m in re.finditer(r"trap\s+'([a-zA-Z_][a-zA-Z0-9_]*)", ln):
            nm = m.group(1)
            if nm in FUNC_NAMES and nm != self_name:
                out.add(nm)
        for m in re.finditer(r'\$\(\s*([a-zA-Z_][a-zA-Z0-9_]*)\b', ln):
            nm = m.group(1)
            if nm in FUNC_NAMES and nm != self_name:
                out.add(nm)
    return out


edges = {k: calls_of(v, k.split(":", 1)[1] if k.startswith("common:") else None)
         for k, v in units.items()}


def closure(key, seen=None):
    if seen is None:
        seen = set()
    res = set()
    for fn in edges.get(key, ()):
        if fn in seen:
            continue
        seen.add(fn)
        res.add(fn)
        res |= closure("common:" + fn, seen)
    return res


report = {}
for p in scripts:
    key = "script:" + p
    direct = {}
    for c, lineno, txt in jj_calls(units[key]):
        direct.setdefault(c, []).append(lineno)
    fns = closure(key)
    trans = {}
    for fn in sorted(fns):
        for c, lineno, txt in jj_calls(units.get("common:" + fn, [])):
            trans.setdefault(c, set()).add(fn)
    report[p] = {"direct": {k: v for k, v in sorted(direct.items())},
                 "transitive": {k: sorted(v) for k, v in sorted(trans.items())},
                 "fns": sorted(fns)}

# common.sh function -> jj map
fnmap = {}
for name, body in sorted(common_funcs.items()):
    cs = {}
    for c, lineno, txt in jj_calls(body):
        cs.setdefault(c, []).append(lineno)
    if cs:
        fnmap[name] = cs

json.dump({"scripts": report, "common_funcs": fnmap}, open("/tmp/audit.json", "w"), indent=1)

print("### common.sh functions that invoke jj\n")
for fn, cs in fnmap.items():
    print(f"  {fn:34s} {', '.join(f'{c} (L{v[0]})' for c, v in cs.items())}")
print("\n### commands\n")
for p, v in report.items():
    print("== " + p)
    print("   direct    :", ", ".join(v["direct"]) or "-")
    print("   via lib   :", ", ".join(v["transitive"]) or "-")
