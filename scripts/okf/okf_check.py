#!/usr/bin/env python3
"""OKF v0.2 §11 conformance 검사."""
import re, sys, pathlib, datetime
ROOT = pathlib.Path.home()/"claude-library"
RESERVED = {"index.md","log.md"}
ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})")
STATUS = {"draft","stable","deprecated"}
fail = {"no_fm":[], "no_type":[], "bad_status":[], "bad_ts":[], "reserved_fm":[]}
n = 0
for md in sorted(ROOT.rglob("*.md")):
    if any(part.startswith(".") for part in md.relative_to(ROOT).parts):
        continue
    rel = str(md.relative_to(ROOT))
    t = md.read_text(encoding="utf-8")
    if md.name in RESERVED:
        # §8: 루트 index.md 만 프론트매터(okf_version) 허용
        if t.startswith("---") and rel != "index.md":
            fail["reserved_fm"].append(rel)
        continue
    n += 1
    if not t.startswith("---"):
        fail["no_fm"].append(rel); continue
    end = t.find("\n---",3)
    if end == -1:
        fail["no_fm"].append(rel); continue
    fm = t[3:end]
    m = re.search(r"^type: *(.+)$", fm, re.M)
    if not m or not m.group(1).strip().strip('"'):
        fail["no_type"].append(rel)
    ms = re.search(r"^status: *(\S+)", fm, re.M)
    if ms and ms.group(1).strip('"') not in STATUS:
        fail["bad_status"].append(rel + " → " + ms.group(1))
    for ts in re.findall(r"at: *([^\s},]+)", fm):
        if not ISO.fullmatch(ts):
            fail["bad_ts"].append(f"{rel} → {ts}")

print(f"검사 대상 concept: {n}건\n")
ok = True
labels = {"no_fm":"§11.1 프론트매터 없음","no_type":"§11.2 type 없음/빈값",
          "bad_status":"§5.4 status 어휘 위반","bad_ts":"§5 ISO8601 위반",
          "reserved_fm":"§8 예약파일에 프론트매터"}
for k, v in fail.items():
    print(f"{'✅' if not v else '❌'} {labels[k]}: {len(v)}건")
    for x in v[:5]:
        print("     ", x)
    if v: ok = False
print("\nOKF v0.2 CONFORMANT" if ok else "\nNON-CONFORMANT")
sys.exit(0 if ok else 1)
