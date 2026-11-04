from pathlib import Path

import pytest


def write(root, repo, category, slug, title, body="본문", description="", tags=""):
    path = Path(root) / "decisions" / repo / category / f"{slug}.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"---\ntype: Decision\ntitle: \"{title}\"\ndescription: \"{description}\"\n"
        f"tags: [{tags}]\nstatus: stable\n---\n\n# {title}\n\n{body}\n"
    )


@pytest.fixture
def library(tmp_path, monkeypatch):
    import server
    root = tmp_path / "lib"
    monkeypatch.setattr(server, "LIBRARY_ROOT", root)
    monkeypatch.setattr(server, "_current_repo", lambda: "contests")
    write(root, "contests", "process", "board-update",
          "현황판·리스트 갱신 방법 전체",
          "전 계정에서 갖고 오는 절차.\n\n## 순서\n- 덤프한다",
          description="현황판·리스트 다시 갱신, 전 계정에서 갖고 오기", tags="현황판, 리스트, 갱신")
    write(root, "game", "scope", "frames", "반복 모션은 전부 8장으로", "전에 만든 모션과 리스트를 맞춘다.")
    write(root, "contests", "process", "postal", "우편 접수 공모전은 인터넷우체국으로 낸다", "못 낸다고 빼지 않는다.")
    return server


def test_decision_search_finds_procedure_from_raw_colloquial_sentence(library):
    out = library.decision_search("야 리스트랑 현황판 다시갱신해야하는거아님 ? 전에 게정에서 갖고와야하는거아냐 ㅍ")
    assert out.index("board-update") < out.find("frames") or "frames" not in out
    assert "decisions/contests/process/board-update.md" in out
    assert "전 계정에서 갖고 오는 절차" in out  # Decision Outcome 절이 없어도 요약이 나온다


def test_library_search_attaches_decision_for_raw_sentence(library):
    out = library.library_search("리스트랑 현황판 다시갱신해야하는거아님")
    assert "decisions/contests/process/board-update.md" in out
    assert "decision_read" in out


def test_decision_search_prefers_current_repo_and_handles_no_match(library):
    assert "결정사항 없음" in library.decision_search("쿠버네티스")
    assert library.decision_search("야").startswith("검색어 없음")
    only = library.decision_search("모션", repo="game")
    assert "frames" in only and "board-update" not in only


def test_split_compound_only_touches_unknown_korean_terms():
    from kb.relevance import Corpus
    corpus = Corpus([{"title": "현황판 갱신", "path": "a.md"}, {"title": "http 갱신해야", "path": "b.md"}])
    assert corpus._expanded(["현황판", "http"]) == ["현황판", "http"]
    assert corpus._expanded(["다시갱신하는거아님"]) == ["갱신"]
    assert corpus._expanded(["전혀없는단어들"]) == ["전혀없는단어들"]


def test_instructions_cover_chores_and_blocked_claims():
    import server
    for phrase in ("FIRST tool call", "chores", "blocked", "NOT a reason", "decision_read"):
        assert phrase in server.INSTRUCTIONS


def test_decision_title_comes_from_frontmatter():
    import server
    """결정 대부분은 # 제목 없이 프론트매터 title 만 있다. 그 제목이 검색 점수에 들어가야 한다."""
    entry = {"title": "우편 접수만 받는 공모전", "name": "slug", "body": "# 결정\n본문"}
    assert server._decision_title(entry) == "우편 접수만 받는 공모전"
    assert server._decision_title({**entry, "title": ""}) == "slug"
    assert server._decision_title({"title": "", "name": "slug", "body": "# 진짜 제목"}) == "진짜 제목"


def test_decision_lead_without_heading():
    import server
    assert server._decision_lead({"body": "- 첫 줄\n- 둘째 줄"}) == "- 첫 줄"


def test_related_decisions_use_local_folder_name(monkeypatch, tmp_path):
    """원격 이름이 달라도 로컬 폴더 이름의 결정을 찾는다."""
    import subprocess
    import server
    root = tmp_path / "lib"
    monkeypatch.setattr(server, "LIBRARY_ROOT", root)
    write(root, "contests", "process", "board-update", "현황판·리스트 갱신 방법 전체", "전 계정에서 갖고 오는 절차.",
          description="현황판·리스트 다시 갱신", tags="현황판, 리스트, 갱신")
    repo = tmp_path / "contests"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "remote", "add", "origin", "git@github.com:me/other-remote.git"], cwd=repo, check=True)
    monkeypatch.chdir(repo)
    assert server._current_repos() == {"other-remote", "contests"}
    assert any("board-update" in e["path"] for e in server._related_decisions("현황판 리스트 다시 갱신"))


def test_related_decisions_show_five(library):
    root = library.LIBRARY_ROOT
    for i in range(7):
        write(root, "contests", "process", f"board-{i}", f"현황판 규칙 {i}", "현황판 내용")
    assert len(library._related_decisions("현황판 규칙")) == 5
