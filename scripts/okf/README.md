# OKF 유지보수 스크립트

라이브러리를 [Open Knowledge Format v0.2](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md) 상태로 유지한다.

| 스크립트 | 역할 |
|---|---|
| `okf_index.py` | `index.md`(§8) · `log.md`(§9) · `LIBRARY.md` 재생성. 각 문서의 프론트매터가 단일 소스이므로 언제 돌려도 멱등 |
| `okf_check.py` | §11 conformance 검사. 위반 시 exit 1 |

```bash
python3 scripts/okf/okf_index.py     # 인덱스 재생성
python3 scripts/okf/okf_check.py     # 준수 검사
```

문서를 추가·수정한 뒤에는 `okf_index.py`를 돌린다. `index.md`/`LIBRARY.md`를
손으로 고치면 다음 재생성에서 덮어써진다 — 프론트매터를 고쳐야 한다.
