"""원본 본문 공백을 보존하는 OKF 읽기/쓰기와 청크 분할."""

import hashlib
import json
import re
from pathlib import PurePosixPath


def validate_path(path):
    p = PurePosixPath(path)
    if (
        p.is_absolute()
        or ".." in p.parts
        or "\\" in path
        or not p.parts
        or p.parts[0] not in ("library", "decisions")
        or p.suffix != ".md"
    ):
        raise ValueError("library/ 또는 decisions/ 아래 상대 .md 경로가 필요합니다")
    return p.as_posix()


def parse(markdown):
    import yaml

    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)", markdown, re.S)
    if not match:
        return {}, markdown

    # 날짜도 JSON으로 손실 없이 옮기도록 문자열로 읽는다.
    class Loader(yaml.SafeLoader):
        pass

    Loader.yaml_implicit_resolvers = {
        k: [(tag, rx) for tag, rx in v if tag != "tag:yaml.org,2002:timestamp"]
        for k, v in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }
    meta = yaml.load(match[1], Loader=Loader) or {}
    if not isinstance(meta, dict):
        raise ValueError("프론트매터는 mapping이어야 합니다")
    # jsonb가 표현하지 못하는 YAML 값은 조용히 변환하지 않는다.
    json.dumps(meta, ensure_ascii=False, allow_nan=False)
    return meta, markdown[match.end() :]


def render(meta, body):
    if not meta:
        return body
    import yaml

    return (
        "---\n"
        + yaml.safe_dump(meta, allow_unicode=True, sort_keys=False)
        + "---\n"
        + body
    )


def digest(markdown):
    return hashlib.sha256(markdown.encode("utf-8")).hexdigest()


def chunks(body, limit=1500):
    heading, buf = "", ""
    for part in re.split(r"(?m)(?=^## )", body):
        if part.startswith("## "):
            heading = part.splitlines()[0][3:].strip()
        buf = ""
        for paragraph in re.split(r"(?<=\n)\n", part):
            if buf and len(buf) + len(paragraph) > limit:
                yield heading, buf
                buf = ""
            while len(paragraph) > limit:
                if buf:
                    yield heading, buf
                    buf = ""
                yield heading, paragraph[:limit]
                paragraph = paragraph[limit:]
            buf += paragraph
        if buf.strip():
            yield heading, buf


SECRET_PATTERNS = [
    r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    r"\bsk-[A-Za-z0-9_-]{12,}",
    r"\bgh[pousr]_[A-Za-z0-9]{16,}",
    r"\bgithub_pat_[A-Za-z0-9_]{16,}",
    r"\bxox[bp]-[A-Za-z0-9-]{10,}",
    r"-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----",
    r'(?i)\b(?:password|passwd|api_key|secret_key)\s*[:=]\s*["\']?[^\s"\']+',
]


def scan_secrets(markdown):
    if any(re.search(pattern, markdown) for pattern in SECRET_PATTERNS):
        raise ValueError("비밀정보 패턴이 감지되어 저장을 거부했습니다")
