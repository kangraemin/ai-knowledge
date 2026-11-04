import json
from datetime import datetime, timezone

import pytest

from kb import instructions


NOW = datetime(2026, 11, 4, tzinfo=timezone.utc)


def line(text, **extra):
    row = {"type": "user", "timestamp": "2026-10-20T01:00:00Z", "origin": {"kind": "human"},
           "entrypoint": "cli", "message": {"role": "user", "content": text}}
    row.update(extra)
    return json.dumps(row, ensure_ascii=False) + "\n"


@pytest.fixture
def transcripts(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "cfg"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    folder = tmp_path / "cfg/projects/-proj"
    folder.mkdir(parents=True)
    return folder / "s.jsonl"


def test_extract_keeps_only_what_a_person_typed():
    keep = [line("현황판은 옛 계정에서 받아 와"),
            line("<channel source=\"telegram\">텔레그램으로 시킨 말입니다</channel>", origin={"kind": "channel"})]
    assert [instructions.extract(k.encode())["text"] for k in keep] == [
        "현황판은 옛 계정에서 받아 와", "텔레그램으로 시킨 말입니다"]
    drop = [line("자동으로 넣은 말입니다", isMeta=True),
            line("서브에이전트 프롬프트", isSidechain=True),
            line("스크립트 프롬프트입니다", entrypoint="sdk-cli"),
            line("완료 알림입니다요", origin={"kind": "task-notification"}),
            line("<command-name>/foo</command-name>"),
            json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "x", "content": "결과"}]}}),
            json.dumps({"type": "assistant", "message": {"content": "모델이 한 말입니다"}})]
    assert [instructions.extract(d.encode()) for d in drop] == [None] * len(drop)


def test_sync_is_incremental_dedupes_and_skips_half_written_line(transcripts):
    transcripts.write_text(line("현황판 갱신은 옛 계정 덤프부터") + line("현황판 갱신은 옛 계정 덤프부터"))
    assert instructions.sync()
    with transcripts.open("a") as f:
        f.write(line("리스트도 같은 순서로 옮겨") + '{"type":"user","message":')
    instructions.sync()
    assert [r["text"] for r in instructions._rows()] == ["현황판 갱신은 옛 계정 덤프부터", "리스트도 같은 순서로 옮겨"]
    with transcripts.open("a") as f:
        f.write('{"content":"끝"}}\n' + line("마지막으로 시킨 지시입니다"))
    instructions.sync()
    assert instructions._rows()[-1]["text"] == "마지막으로 시킨 지시입니다"
    assert oct((instructions.store_dir() / "instructions.jsonl").stat().st_mode)[-3:] == "600"


def test_sync_budget_resumes_where_it_stopped(transcripts):
    transcripts.write_text("".join(line(f"지시 번호 {i} 입니다") for i in range(50)))
    assert instructions.sync(budget=-1) is False
    instructions.sync()
    assert len(instructions._rows()) == 50


def test_search_finds_earlier_instruction_from_colloquial_sentence(transcripts):
    transcripts.write_text(line("현황판 리스트는 전 계정 db를 받아서 합쳐") + line("로고 색을 파랗게 바꿔 주세요") +
                           line("리스트 다시 보여 주세요") + line("오늘 날씨 어떤가요 궁금함"))
    instructions.sync()
    found = instructions.search("현황판이랑 리스트 전에 계정에서 갖고와", project="-proj", now=NOW)
    assert [r["text"] for r in found] == ["현황판 리스트는 전 계정 db를 받아서 합쳐"]
    assert instructions.search("쿠버네티스 배포", project="-proj", now=NOW) == []
    assert instructions.search("현황판 리스트", project="-other", now=NOW) == []
    assert instructions.search("현황판 리스트", project="-other", all_projects=True, now=NOW)


def test_search_leaves_out_what_was_just_said(transcripts):
    text = "현황판 리스트 다시 갱신해야 하는 거 아님"
    transcripts.write_text(line(text, timestamp="2026-11-03T23:59:00Z"))
    instructions.sync()
    assert instructions.search("현황판 리스트 갱신", project="-proj", now=NOW) == []


def test_off_switch_and_missing_store(transcripts, monkeypatch):
    assert instructions.search("현황판 리스트", project="-proj", now=NOW) == []
    monkeypatch.setenv("LIBRARY_INSTRUCTIONS", "off")
    transcripts.write_text(line("현황판 리스트 갱신 지시입니다"))
    assert instructions.lookup("현황판 리스트 갱신") == []
    assert not (instructions.store_dir() / "instructions.jsonl").exists()


def test_reads_both_default_and_account_projects(tmp_path, monkeypatch):
    """계정 폴더가 기본 폴더와 다르면 둘 다, 심볼릭 링크로 같으면 한 번만 읽는다."""
    from kb import instructions
    home = tmp_path / "home"
    (home / ".claude/projects").mkdir(parents=True)
    account = tmp_path / "account"
    (account / "projects").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(account))
    assert len(instructions.projects_roots()) == 2
    (account / "projects").rmdir()
    (account / "projects").symlink_to(home / ".claude/projects")
    assert instructions.projects_roots() == [(home / ".claude/projects").resolve()]


def _line(**fields):
    return json.dumps({"entrypoint": "cli", "timestamp": "2026-11-04T10:00:00Z", **fields}, ensure_ascii=False).encode()


@pytest.mark.parametrize("raw,expected", [
    # 작업 중에 쳐서 대기열로 들어간 말
    (_line(type="attachment", attachment={"type": "queued_command", "prompt": "훅으로 고치지말라고",
                                          "commandMode": "prompt", "origin": {"kind": "human"}}), "훅으로 고치지말라고"),
    (_line(type="attachment", attachment={"type": "queued_command", "prompt": "<task-notification>끝남</task-notification>",
                                          "commandMode": "prompt", "origin": {"kind": "task-notification"}}), None),
    # 명령 인자
    (_line(type="system", content="<command-name>/goal</command-name>\n<command-message>goal</command-message>\n"
                                  "<command-args>전부 기록하도록해</command-args>"), "/goal 전부 기록하도록해"),
    (_line(type="user", message={"content": "<command-name>/autocompact</command-name><command-args>250</command-args>"}), None),
    (_line(type="system", content="<local-command-stdout>Goal set: 전부 기록하도록해</local-command-stdout>"), None),
    # 말머리가 있어도 사람이 친 말
    (_line(type="user", origin={"kind": "human"}, message={"content": "[Image #6] 이것도 사진 하나씩 분리해줘"}), "이것도 사진 하나씩 분리해줘"),
    (_line(type="user", origin={"kind": "human"}, message={"content": "[정정] 방금 지시 취소해"}), "[정정] 방금 지시 취소해"),
    (_line(type="user", origin={"kind": "human"}, message={"content": "<pasted_content id=\"a\">링크입니다</pasted_content id=\"a\"> 이것도 확인해봐"}), "링크입니다 이것도 확인해봐"),
    (_line(type="user", isMeta=True, origin={"kind": "channel"}, message={"content": "<channel source=\"t\">폰에서 보낸 지시</channel>"}), "폰에서 보낸 지시"),
    # 짧은 말과 origin 없는 옛 형식의 말머리도 사람 말
    (_line(type="user", origin={"kind": "human"}, message={"content": "ㅇㅇ"}), "ㅇㅇ"),
    (_line(type="user", origin={"kind": "human"}, message={"content": "계속해"}), "계속해"),
    (_line(type="user", message={"content": "[정정] 그거 아니고 저거로 해"}), "[정정] 그거 아니고 저거로 해"),
    # 사람 말이 아닌 줄
    (_line(type="user", origin={"kind": "human"}, message={"content": "ㅇ"}), None),
    (_line(type="user", message={"content": "[Request interrupted by user]"}), None),
    (_line(type="user", message={"content": "This session is being continued from a previous"}), None),
    (_line(type="user", isMeta=True, message={"content": "Stop hook feedback 내용입니다"}), None),
    (_line(type="user", entrypoint="sdk-cli", origin={"kind": "human"}, message={"content": "스크립트가 부른 말입니다"}), None),
    (_line(type="user", isSidechain=True, message={"content": "서브에이전트 지시문입니다"}), None),
])
def test_extract_forms(raw, expected):
    from kb.instructions import extract
    row = extract(raw + b"\n")
    assert (row["text"] if row else None) == expected


def test_long_instruction_is_kept_truncated():
    from kb.instructions import extract
    row = extract(_line(type="user", origin={"kind": "human"}, message={"content": "가" * 3000}) + b"\n")
    assert len(row["text"]) == 2000


def test_same_word_terms():
    assert "스샷" in instructions._terms("화면 스크린샷 보내", ["스샷말고 동영상으로", "화면 보내"])
