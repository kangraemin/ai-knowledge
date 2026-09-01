#!/usr/bin/env python3
"""OKF §8 index.md 전면 재생성 + §9 log.md + 루트 문서 프론트매터."""
import re, json, pathlib, datetime, subprocess, collections

ROOT = pathlib.Path.home() / "claude-library"
RESERVED = {"index.md", "log.md"}
_PRES = pathlib.Path(__file__).parent / "index_preserve.json"
PRESERVE = json.load(open(_PRES)) if _PRES.exists() else {}


def fm_of(p):
    t = p.read_text(encoding="utf-8")
    if not t.startswith("---"):
        return {}
    end = t.find("\n---", 3)
    if end == -1:
        return {}
    meta, key = {}, None
    for line in t[3:end].splitlines():
        m = re.match(r"^([A-Za-z_][\w-]*): ?(.*)$", line)
        if m:
            key = m.group(1)
            v = m.group(2).strip()
            if v.startswith('"'):
                try:
                    v = json.loads(v)          # 따옴표+이스케이프 정상 해제
                except Exception:
                    v = v.strip('"').replace('\\"', '"')
            meta[key] = v
        elif key and line.startswith("  "):
            pass
    return meta


def gen_index(d: pathlib.Path):
    """디렉토리 하나의 index.md 를 OKF §8 형식으로."""
    subdirs = sorted([x for x in d.iterdir() if x.is_dir() and not x.name.startswith(".")])
    files = sorted([x for x in d.iterdir() if x.is_file() and x.suffix == ".md" and x.name not in RESERVED])
    if not subdirs and not files:
        return None

    name = d.name if d != ROOT else "claude-library"
    out = []
    if d == ROOT:
        out.append('---')
        out.append('okf_version: "0.2"')
        out.append('---')
        out.append('')
    out.append(f"# {name}")
    out.append("")

    keep = PRESERVE.get(str(d.relative_to(ROOT) / "index.md"), {})
    if keep.get("intro"):
        out.extend(keep["intro"]); out.append("")

    if files:
        for f in files:
            m = fm_of(f)
            title = m.get("title") or f.stem.replace("-", " ")
            desc = m.get("description", "")
            typ = m.get("type", "")
            label = f"* [{title}]({f.name})"
            bits = [b for b in (typ, desc) if b]
            out.append(label + (" - " + " · ".join(bits) if bits else ""))
        out.append("")

    if subdirs:
        out.append("# 하위 디렉토리" if d != ROOT else "# 섹션")
        out.append("")
        for s in subdirs:
            n = len(list(s.rglob("*.md")))
            out.append(f"* [{s.name}]({s.name}/) - {n}개 문서")
        out.append("")

    if keep.get("related"):
        out.append("# 관련 주제")
        out.append("")
        out.extend(keep["related"]); out.append("")
    return "\n".join(out).rstrip() + "\n"


count = 0
for d in sorted(set([ROOT] + [p.parent for p in (ROOT / "library").rglob("*.md")]
                    + [p.parent for p in (ROOT / "policy").rglob("*.md")]
                    + [ROOT / "library", ROOT / "policy"])):
    txt = gen_index(d)
    if txt:
        (d / "index.md").write_text(txt, encoding="utf-8")
        count += 1
print("index.md 생성:", count)

# --- §9 log.md : git 이력에서 생성 ---
out = subprocess.run(["git", "-C", str(ROOT), "log", "--format=@%aI|%s", "--name-status",
                      "--diff-filter=AM", "--", "library", "policy"],
                     capture_output=True, text=True).stdout
days = collections.OrderedDict()
cur = None
for line in out.splitlines():
    if line.startswith("@"):
        cur = line[1:].split("|")[0][:10]
    elif cur and "\t" in line:
        st, f = line.split("\t")[0], line.split("\t")[-1]
        if not f.endswith(".md") or f.endswith("index.md"):
            continue
        days.setdefault(cur, []).append(("Creation" if st == "A" else "Update", f))

log = ["# Update Log", ""]
for day, items in list(days.items())[:120]:
    log.append(f"## {day}")
    seen = set()
    for kind, f in items:
        if f in seen:
            continue
        seen.add(f)
        title = f.rsplit("/", 1)[-1][:-3]
        if (ROOT / f).exists():
            log.append(f"* **{kind}**: [{title}]({f})")
        else:
            # 이후 이동·삭제된 문서 — 이력은 남기되 깨진 링크는 만들지 않는다
            log.append(f"* **{kind}**: {title} `{f}`")
    log.append("")
(ROOT / "log.md").write_text("\n".join(log), encoding="utf-8")
print("log.md 생성:", len(days), "일자")

# --- 루트 문서 프론트매터 (OKF §11 conformance) ---
DOCS = {
    "GUIDE.md": ("Reference", "Library 작성 가이드 — 지식 문서의 구조·분류·형식"),
    "TAXONOMY.md": ("Reference", "지식 분류 체계 — 카테고리/서브카테고리 등록부"),
    "CHANGELOG.md": ("Reference", "claude-library 변경 이력"),
    "policy/POLICY-GUIDE.md": ("Reference", "정책(Decision History) 작성 가이드"),
}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for rel, (typ, desc) in DOCS.items():
    p = ROOT / rel
    if not p.exists():
        continue
    t = p.read_text(encoding="utf-8")
    if t.startswith("---"):
        continue
    p.write_text(f"---\ntype: {typ}\ntitle: {rel.rsplit('/',1)[-1][:-3]}\n"
                 f"description: {desc}\nstatus: stable\n"
                 f"generated: {{ by: claude-code/opus, at: {now} }}\n---\n\n" + t, encoding="utf-8")
    print("프론트매터 추가:", rel)

# --- LIBRARY.md 재생성 (프론트매터가 단일 소스) ---
rows = []
for md in sorted((ROOT / "library").rglob("*.md")):
    if md.name in RESERVED or md.name == "_template.md":
        continue
    m = fm_of(md)
    rel = md.relative_to(ROOT)
    title = m.get("title") or md.stem.replace("-", " ")
    desc = m.get("description", "")
    rows.append((str(rel), title, desc, m.get("type", ""), m.get("status", "stable")))

# 생성 시각이 아니라 "가장 최근 문서의 시각" — 매 실행마다 diff 나는 걸 막는다
_ats = []
for _md in (ROOT/"library").rglob("*.md"):
    if _md.name in RESERVED: continue
    _g = fm_of(_md).get("generated", "")
    _m = re.search(r"at: *(\S+?)\s*}", _g) or re.search(r"at: *(\S+)", _g)
    if _m: _ats.append(_m.group(1))
_now = max(_ats) if _ats else "1970-01-01T00:00:00Z"
lines = ["---", "type: Reference", "title: LIBRARY",
         "description: 지식 라이브러리 전체 롤업 (자동 생성)", "status: stable",
         "generated: { by: process:okf-index, at: " + _now + " }", "---", "",
         "# LIBRARY", "",
         "> 자동 생성 파일. 직접 수정하지 마라 — 각 문서의 OKF 프론트매터가 단일 소스다.",
         f"> 문서 {len(rows)}건. OKF v0.2.", ""]
bycat = {}
for rel, title, desc, typ, st in rows:
    bycat.setdefault(rel.split("/")[1], []).append((rel, title, desc, typ, st))
for cat in sorted(bycat):
    lines.append(f"## {cat}")
    lines.append("")
    for rel, title, desc, typ, st in bycat[cat]:
        tail = " — " + desc if desc else ""
        mark = "" if st == "stable" else f" `[{st}]`"
        lines.append(f"- [{title}]({rel}){mark}{tail}")
    lines.append("")
(ROOT / "LIBRARY.md").write_text("\n".join(lines), encoding="utf-8")
print("LIBRARY.md 재생성:", len(rows), "건")
