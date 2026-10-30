"""config.example から項目と見本の値を読み、config の形を確かめる（bench/aio_check.py・bench/agent_bench.py が使う）。

validate() は、Mac で作った splitterm（`splitterm config check --file`）が無いときに使う **フォールバック（簡易版）**。
アプリの ConfigParser（Swift）を Python で写したものではなく、近いものにすぎない:
  - 書き方（`key = value`・# の行・"..." の引用・空の値で既定値）と、知らない項目は、アプリと同じに見る
  - 値は、見本の値の形（true/false・#RRGGBB・400ms・7d・数・host・palette）から型を推して、形だけを見る
  - 選べる値（keyboard = us / kana など）と数の範囲は見ない
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_EXAMPLE = ROOT / "ios/SplitTerm/Resources/config.example"

SECTION_LINE = re.compile(r"^#\s*─{3,}")
KEY_LINE = re.compile(r"^# ([a-z][a-z0-9-]*) =(?: (.*))?$")
# 見本の値が既定値ではなく例のもの（書かなければ 1 つも無い）
EXAMPLE_ONLY = {"host"}


def load_spec(path: Path = CONFIG_EXAMPLE) -> dict[str, list[str]]:
    """項目 → 見本に書いてある値（書いた順）。先頭の書き方の説明（最初の区分より前）は見ない"""
    spec: dict[str, list[str]] = {}
    started = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if SECTION_LINE.match(line):
            started = True
            continue
        m = KEY_LINE.match(line) if started else None
        if m:
            spec.setdefault(m.group(1), []).append((m.group(2) or "").strip())
    return spec


def kind_of(key: str, examples: list[str]) -> str:
    if key == "host":
        return "host"
    if key == "palette":
        return "palette"
    v = examples[0] if examples else ""
    if v in ("true", "false"):
        return "bool"
    if re.fullmatch(r"#[0-9A-Fa-f]{6}", v):
        return "color"
    if re.fullmatch(r"\d+(\.\d+)?(ms|s)", v):
        return "duration"
    if re.fullmatch(r"\d+(\.\d+)?[dh]", v):
        return "days"
    if re.fullmatch(r"\d+(\.\d+)?", v):
        return "number"
    if re.fullmatch(r"\d+(\s*,\s*\d+)+", v):
        return "int-list"
    return "text"


NAME = re.compile(r"[A-Za-z0-9._-]+")


def parse_host(value: str) -> dict:
    """`名前 ユーザー@アドレス[:ポート] [tmux=名前|none] [auth=key|password]`。だめなら ValueError"""
    fields = value.split()
    if len(fields) < 2:
        raise ValueError("host は `名前 ユーザー@アドレス[:ポート] [tmux=名前|none] [auth=key|password]` です")
    name, target = fields[0], fields[1]
    if not NAME.fullmatch(name):
        raise ValueError(f"host の名前 `{name}` は英数と . _ - だけで書きます")
    user, at, addr = target.rpartition("@")
    if not at:
        raise ValueError(f"`{target}` に ユーザー@ がありません")
    port = 22
    if addr.startswith("["):
        close = addr.find("]")
        if close < 0:
            raise ValueError(f"`{addr}` の ] が閉じていません")
        rest = addr[close + 1:]
        if rest:
            if not rest.startswith(":") or not rest[1:].isdigit():
                raise ValueError(f"ポート `{rest}` が正しくありません")
            port = int(rest[1:])
        addr = addr[1:close]
    elif addr.count(":") == 1:
        addr, p = addr.split(":")
        if not p.isdigit():
            raise ValueError(f"ポート `{p}` が正しくありません")
        port = int(p)
    if not 1 <= port <= 65535:
        raise ValueError(f"ポート `{port}` が正しくありません")
    if not user or not addr:
        raise ValueError("ユーザーかアドレスが空です")
    host = {"name": name, "user": user, "address": addr, "port": str(port), "tmux": "main", "auth": "key"}
    for opt in fields[2:]:
        k, eq, v = opt.partition("=")
        if not eq:
            raise ValueError(f"`{opt}` は key=value の形ではありません")
        if k == "tmux":
            if v != "none" and not NAME.fullmatch(v):
                raise ValueError("tmux のセッション名は英数と . _ - だけで書きます")
            host["tmux"] = v
        elif k == "auth":
            if v not in ("key", "password"):
                raise ValueError("auth は key か password です")
            host["auth"] = v
        else:
            raise ValueError(f"host の知らない指定 `{k}` です")
    return host


def check_value(kind: str, value: str) -> str | None:
    """形が違えば理由、よければ None"""
    if kind == "bool" and value.lower() not in ("true", "false", "yes", "no", "on", "off", "1", "0"):
        return f"`{value}` は true か false で書きます"
    if kind == "color" and not re.fullmatch(r"#?[0-9A-Fa-f]{6}", value):
        return f"`{value}` は #RRGGBB の色ではありません"
    if kind == "duration" and not re.fullmatch(r"\d+(\.\d+)?\s*(ms|s)?", value.lower()):
        return f"`{value}` は時間（例 400ms、60s）ではありません"
    if kind == "days" and not re.fullmatch(r"\d+(\.\d+)?\s*[dh]?", value.lower()):
        return f"`{value}` は日数（例 7d、12h）ではありません"
    if kind == "number" and not re.fullmatch(r"\d+(\.\d+)?", value):
        return f"`{value}` は数ではありません"
    if kind == "int-list" and not re.fullmatch(r"\d+%?(\s*,\s*\d+%?)*", value):
        return f"`{value}` は整数をカンマで並べます"
    if kind == "palette":
        m = re.fullmatch(r"(\d{1,2})\s*=\s*#?[0-9A-Fa-f]{6}", value)
        if not m or int(m.group(1)) > 15:
            return "palette は `palette = 番号(0〜15)=#RRGGBB` の形です"
    return None


def validate(text: str, spec: dict[str, list[str]]) -> list[tuple[int, str]]:
    """（行番号, 理由）の一覧。空なら通った（フォールバックの簡易な検査）"""
    problems: list[tuple[int, str]] = []
    hosts: set[str] = set()
    for no, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, eq, value = line.partition("=")
        if not eq:
            problems.append((no, "`key = value` の形ではありません"))
            continue
        key, value = key.strip().lower(), value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        if key not in spec:
            problems.append((no, f"知らない項目 `{key}` です"))
            continue
        if value == "":
            continue  # 既定値に戻す
        kind = kind_of(key, spec[key])
        if kind == "host":
            try:
                h = parse_host(value)
            except ValueError as e:
                problems.append((no, str(e)))
                continue
            if h["name"] in hosts:
                problems.append((no, f"host の名前 `{h['name']}` が重なっています"))
            hosts.add(h["name"])
            continue
        msg = check_value(kind, value)
        if msg:
            problems.append((no, msg))
    return problems


def entries(text: str) -> tuple[dict[str, str], list[dict]]:
    """読めた行の値（同じ項目は後の行が勝つ）と、host の一覧。採点で期待の値を見るのに使う"""
    values: dict[str, str] = {}
    hosts: list[dict] = []
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip().lower(), value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        if key == "host":
            try:
                hosts.append(parse_host(value))
            except ValueError:
                pass
        else:
            values[key] = value
    return values, hosts
