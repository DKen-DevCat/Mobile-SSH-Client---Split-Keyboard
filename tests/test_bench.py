"""ベンチマーク B（bench/agent_bench.py）の採点と、config の簡易な検査（bench/configspec.py）（docs/site.md）。
本物の claude は呼ばない（偽の claude と偽の splitterm で動かす）。Python の標準ライブラリと pytest だけ。"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
BENCH = ROOT / "bench"
sys.path.insert(0, str(BENCH))
import agent_bench  # noqa: E402
import configspec  # noqa: E402

SPEC = configspec.load_spec()


def run(*args, **env) -> subprocess.CompletedProcess:
    e = {**os.environ, **env}
    return subprocess.run([sys.executable, str(BENCH / "agent_bench.py"), *map(str, args)],
                          capture_output=True, text=True, cwd=ROOT, env=e)


@pytest.fixture
def fallback() -> agent_bench.Validator:
    return agent_bench.Validator("fallback")


# ─── tasks.json ───────────────────────────────────────────

def test_dry_run_passes_on_the_committed_tasks():
    r = run("--dry-run", "--validator", "fallback")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "すべて期待どおり" in r.stdout


def test_tasks_cover_the_required_questions():
    ids = {t["id"] for t in agent_bench.load_tasks()["tasks"]}
    assert {"min-ios", "price", "app-store", "install-steps", "video-claude-code", "config-location",
            "mcp-register"} <= ids
    kinds = [t["kind"] for t in agent_bench.load_tasks()["tasks"]]
    assert kinds.count("config") >= 3 and len(kinds) >= 15


def test_dry_run_fails_when_an_example_is_graded_wrongly(tmp_path: Path):
    data = agent_bench.load_tasks()
    data["tasks"][0]["examples"]["pass"] = ["iOS 16 以上"]  # 合格のはずの見本が不合格になる
    path = tmp_path / "tasks.json"
    path.write_text(json.dumps(data, ensure_ascii=False))
    r = run("--dry-run", "--validator", "fallback", "--tasks", path)
    assert r.returncode == 1
    assert "min-ios: pass の見本が 不合格" in r.stdout


def test_validate_tasks_finds_shape_errors():
    bad = agent_bench.validate_tasks({
        "thresholds": {"qa": 2, "config": 1},
        "tasks": [
            {"id": "a", "kind": "qa", "lang": "ja", "prompt": "?", "required": [["("]],
             "examples": {"pass": ["x"], "fail": ["y"]}},
            {"id": "a", "kind": "config", "lang": "fr", "prompt": "?", "expect": {"no-such-key": "1"},
             "examples": {"pass": ["x"]}},
        ],
    }, SPEC)
    text = "\n".join(bad)
    assert "thresholds.qa" in text
    assert "正規表現" in text
    assert "重ならない" in text
    assert "lang" in text
    assert "no-such-key は config.example に無い項目" in text
    assert "examples に pass と fail" in text


# ─── 答えの採点 ─────────────────────────────────────────────

def test_qa_needs_every_required_group():
    task = {"required": [["17"], ["Xcode", "ソース"]]}
    assert agent_bench.grade_qa(task, "iOS 17 以上。ソースからビルドする") == []
    assert agent_bench.grade_qa(task, "iOS 17 以上") == ["足りない: Xcode | ソース"]


def test_qa_forbidden_and_case():
    task = {"required": [["ssh"]], "forbidden": ["SplitTerm"]}
    assert agent_bench.grade_qa(task, "An SSH terminal") == []
    assert agent_bench.grade_qa(task, "An SSH terminal called splitterm")[0].startswith("言ってはいけない")


def test_qa_order():
    task = {"order": ["Apple ID", "ios_reinstall", "信頼"]}
    assert agent_bench.grade_qa(task, "Apple ID → ios_reinstall.sh → 開発元を信頼") == []
    assert agent_bench.grade_qa(task, "開発元を信頼 → Apple ID → ios_reinstall.sh")[0].startswith("順序が違う")


def test_extract_config_takes_the_last_block():
    answer = "例:\n```bash\necho hi\n```\n本番:\n```text\nfont-size = 12\n```\n"
    assert agent_bench.extract_config(answer) == "font-size = 12\n"
    assert agent_bench.extract_config("font-size = 12") == "font-size = 12"


def test_config_grading(fallback):
    task = {"expect": {"font-size": "12"}, "forbid": {"app-lock": "false"},
            "expect_host": {"user": "dken", "tmux": "main"}}
    good = "```\nhost = mac dken@mac.example.ts.net\nfont-size = 12\n```"
    assert agent_bench.grade_config(task, good, fallback) == []
    bad = "```\nhost = mac me@mac\nfont-size = 11\napp-lock = false\nfont = x\n```"
    reasons = agent_bench.grade_config(task, bad, fallback)
    assert any("知らない項目 `font`" in r for r in reasons)
    assert any(r.startswith("font-size = 11") for r in reasons)
    assert any("app-lock = false にしてはいけない" in r for r in reasons)
    assert any("期待の host がありません" in r for r in reasons)
    assert "読める config の行がありません" in agent_bench.grade_config(task, "分かりません", fallback)


# ─── config の簡易な検査（フォールバック） ──────────────────────────

def test_spec_has_the_example_keys_and_not_the_header():
    assert {"host", "palette", "font-size", "agent", "video-frames", "clipboard-clear"} <= set(SPEC)
    assert "key" not in SPEC  # 先頭の書き方の説明（#   key = value）は項目ではない
    assert len(SPEC["palette"]) == 16


@pytest.mark.parametrize("text", [
    "font-size = 12",
    "  font-size=12  ",
    "# コメント\n\nkeyboard = kana",
    'media-insert = "{paths} "',
    "font-size =",  # 空は既定値に戻す
    "cursor-blink = yes",
    "key-repeat-delay = 300ms",
    "keepalive = 30",
    "media-retention = 12h",
    "zoom-steps = 85%, 100%",
    "palette = 15=#FFFFFF",
    "host = pi pi@[::1]:2222 tmux=none auth=password",
])
def test_fallback_accepts(text: str):
    assert configspec.validate(text, SPEC) == []


@pytest.mark.parametrize("text, message", [
    ("font-size 12", "`key = value` の形ではありません"),
    ("fontsize = 12", "知らない項目 `fontsize`"),
    ("cursor-blink = maybe", "true か false"),
    ("background = red", "#RRGGBB"),
    ("key-repeat-delay = soon", "時間"),
    ("palette = 16=#FFFFFF", "palette は"),
    ("host = mac", "host は"),
    ("host = mac dken@mac tmux=a;b", "tmux のセッション名"),
    ("host = mac a@b\nhost = mac c@d", "重なっています"),
    ("host = mac a@b:99999", "ポート"),
])
def test_fallback_rejects(text: str, message: str):
    problems = configspec.validate(text, SPEC)
    assert problems and message in problems[-1][1], problems


def test_parse_host_defaults():
    assert configspec.parse_host("mac dken@mac.local") == {
        "name": "mac", "user": "dken", "address": "mac.local", "port": "22", "tmux": "main", "auth": "key"}


# ─── splitterm があるときは、それで検査する ─────────────────────────

FAKE_SPLITTERM = """#!/usr/bin/env python3
# 偽の splitterm config check --file F: 「bad」を含む行があれば行番号付きで出して 1
import sys
assert sys.argv[1:4] == ["config", "check", "--file"], sys.argv
lines = open(sys.argv[4]).read().split("\\n")
bad = [f"{i} 行目: だめ" for i, l in enumerate(lines, 1) if "bad" in l]
print("\\n".join(bad))
sys.exit(1 if bad else 0)
"""


def test_splitterm_validator_is_used_when_built(tmp_path: Path):
    fake = tmp_path / "splitterm"
    fake.write_text(FAKE_SPLITTERM)
    fake.chmod(0o755)
    v = agent_bench.Validator("auto", binary=fake)
    assert v.binary == fake
    assert v.check("font-size = 12\n") == []
    assert v.check("font-size = 12\nbad = 1\n") == ["2 行目: だめ"]
    assert agent_bench.Validator("fallback", binary=fake).binary is None


def test_splitterm_validator_required_but_missing(tmp_path: Path):
    with pytest.raises(agent_bench.SetupError):
        agent_bench.Validator("splitterm", binary=tmp_path / "none")


# ─── claude -p で解かせる（偽の claude） ──────────────────────────────

FAKE_CLAUDE = """#!/usr/bin/env python3
# 偽の claude: 引数とプロンプトを残し、サイトの URL があれば正しく、無ければ外れた答えを返す
import json, os, sys
if "--version" in sys.argv:
    print("0.0.0 (fake)"); sys.exit(0)
prompt = sys.stdin.read()
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "prompt": prompt, "cwd": os.getcwd()}, ensure_ascii=False) + "\\n")
site = "/llms.txt" in prompt
if "コードブロック" in prompt:
    ans = "```\\nfont-size = 12\\nhost = mac dken@mac.example.ts.net tmux=main\\n```" if site else "```\\nfontSize: 12\\n```"
else:
    ans = "iOS / iPadOS 17 以上。" if site else "分かりません"
print(json.dumps({"type": "result", "is_error": False, "result": ans, "duration_ms": 1, "num_turns": 1}))
"""


@pytest.fixture
def fake_claude(tmp_path: Path) -> tuple[Path, Path]:
    claude = tmp_path / "claude"
    claude.write_text(FAKE_CLAUDE)
    claude.chmod(0o755)
    return claude, tmp_path / "calls.jsonl"


def test_run_records_both_arms_and_compares(fake_claude, tmp_path: Path):
    claude, log = fake_claude
    results = tmp_path / "results"
    args = ("--claude", claude, "--results-dir", results, "--only", "min-ios,config-font-host", "--validator", "fallback")
    r = run(*args, FAKE_LOG=str(log))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "前回の結果はありません" in r.stdout
    assert "サイトの効果（site − baseline）: 答える課題 +1、config の課題 +1" in r.stdout
    site = json.loads(next(results.glob("*-site.json")).read_text())
    base = json.loads(next(results.glob("*-baseline.json")).read_text())
    assert site["summary"]["qa"] == {"passed": 1, "total": 1, "rate": 1.0}
    assert base["summary"]["config"]["passed"] == 0
    assert site["validator"].startswith("フォールバック")

    calls = [json.loads(line) for line in log.read_text().splitlines()]
    site_call = next(c for c in calls if "/llms.txt" in c["prompt"])
    base_call = next(c for c in calls if "/llms.txt" not in c["prompt"])
    # site はサイトのドメインの取得だけを許し、baseline は取得も止める。どちらもリポジトリの外の空のフォルダで動く
    assert "WebFetch(domain:" in " ".join(site_call["argv"])
    assert "WebFetch" in base_call["argv"][base_call["argv"].index("--disallowedTools") + 1]
    assert "Read" in site_call["argv"][site_call["argv"].index("--disallowedTools") + 1]
    assert "--strict-mcp-config" in site_call["argv"]
    assert not Path(site_call["cwd"]).resolve().is_relative_to(ROOT)

    # 2 回目は前回と比べる
    r = run(*args, "--arm", "site", FAKE_LOG=str(log))
    assert "前回（" in r.stdout and "前回の結果はありません" not in r.stdout


def test_run_fails_below_the_threshold(fake_claude, tmp_path: Path):
    claude, log = fake_claude
    r = run("--claude", claude, "--results-dir", tmp_path / "r", "--only", "price", "--arm", "site",
            "--validator", "fallback", FAKE_LOG=str(log))
    assert r.returncode == 1
    assert "届かない" in r.stdout


def test_missing_claude_is_a_setup_error(tmp_path: Path):
    r = run("--claude", tmp_path / "no-claude", "--results-dir", tmp_path / "r", "--validator", "fallback")
    assert r.returncode == 2
    assert "見つかりません" in r.stderr
    assert not (tmp_path / "r").exists()


def test_unknown_only_id(fake_claude, tmp_path: Path):
    claude, log = fake_claude
    r = run("--claude", claude, "--results-dir", tmp_path / "r", "--only", "nope", "--validator", "fallback",
            FAKE_LOG=str(log))
    assert r.returncode == 2
