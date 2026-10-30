#!/usr/bin/env python3
"""手元の `claude -p` にサイトの URL だけを渡して質問に答えさせ、config を書かせ、自動で採点する
（ベンチマーク B。docs/proposal-2026-10-30.md「3」、docs/site.md）。Python の標準ライブラリだけで動く。

2 つの腕で比べる: site（llms.txt の URL を渡す）と baseline（渡さない。基準線）。
有料の API は呼ばない（claude -p はサブスクリプションの枠で動く）。CI では動かさない。
使い方: python3 bench/agent_bench.py [--arm site|baseline|both] [--only ID,...] [--model M]
        python3 bench/agent_bench.py --dry-run
  --dry-run      tasks.json の形と、採点の見本（examples）が期待どおりに採点されるかだけを確かめる。claude は呼ばない
  --validator    config の検査: auto（既定。splitterm を作ってあればそれ、無ければフォールバック）/ splitterm / fallback
  --base         サイトの URL（既定 site/site.json の base_url）
  --results-dir  結果の置き場所（既定 bench/results。<日付>-<腕>.json）
  --claude       claude コマンド（既定 PATH の claude）
  --timeout      1 問の制限時間（秒、既定 300）
終了コード: 0 = site の腕が合格の線（tasks.json の thresholds）を超えた・baseline だけを記録した・dry-run が通った
            1 = 合格の線に届かない・dry-run の不合格 / 2 = 準備の誤り（claude が無い・引数の誤り など）
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent
sys.path.insert(0, str(BENCH))
import configspec  # noqa: E402

TASKS = BENCH / "tasks.json"
RESULTS = BENCH / "results"
SITE_JSON = ROOT / "site/site.json"
SPLITTERM = ROOT / "ios/TermCore/.build/release/splitterm"
ARMS = ("site", "baseline")
HOST_FIELDS = ("name", "user", "address", "port", "tmux", "auth")

PREAMBLE = {
    ("site", "ja"): "次のサイトを読んで答えてください: {base}/llms.txt\n"
                    "サイトに書いてあることだけを根拠にし、ほかの検索はしないこと。\n\n",
    ("site", "en"): "Answer using this site: {base}/en/llms.txt\n"
                    "Rely only on what the site says; do not search elsewhere.\n\n",
    ("baseline", "ja"): "知っている範囲で答えてください。分からないことは分からないと書くこと。\n\n",
    ("baseline", "en"): "Answer from what you know. Say so if you do not know.\n\n",
}
CONFIG_SUFFIX = {
    "ja": "\n\nconfig ファイルの中身だけを、``` で囲んだコードブロック 1 つで出してください。",
    "en": "\n\nOutput only the contents of the config file, in a single ``` code block.",
}
# 読み書きとシェルは止める（リポジトリの中を読んで答えさせない）。site の腕だけ、サイトのドメインの取得を許す
BLOCKED_TOOLS = ("Bash", "Edit", "Write", "NotebookEdit", "Read", "Glob", "Grep", "WebSearch")


class SetupError(Exception):
    pass


# ─── 採点 ───────────────────────────────────────────────

def grade_qa(task: dict, answer: str) -> list[str]:
    """だめな理由の一覧（空なら合格）。正規表現は大文字と小文字を区別しない"""
    reasons = []
    for group in task.get("required", []):
        if not any(re.search(p, answer, re.I) for p in group):
            reasons.append("足りない: " + " | ".join(group))
    for p in task.get("forbidden", []):
        m = re.search(p, answer, re.I)
        if m:
            reasons.append(f"言ってはいけない: 「{m.group(0)}」")
    pos = -1
    for p in task.get("order", []):
        m = re.compile(p, re.I).search(answer, pos + 1)
        if not m:
            reasons.append(f"順序が違う: 「{p}」が前の段より後に出てこない")
            break
        pos = m.start()
    return reasons


def extract_config(answer: str) -> str:
    """答えの最後の ``` の中身。無ければ答え全体"""
    blocks = re.findall(r"```[^\n]*\n(.*?)```", answer, re.S)
    return blocks[-1] if blocks else answer


class Validator:
    """config の検査。splitterm（アプリと同じ TermCore）があればそれ、無ければ configspec のフォールバック"""

    def __init__(self, mode: str = "auto", binary: Path = SPLITTERM):
        if mode not in ("auto", "splitterm", "fallback"):
            raise SetupError(f"--validator は auto / splitterm / fallback です（{mode}）")
        usable = binary.is_file() and os.access(binary, os.X_OK)
        if mode == "splitterm" and not usable:
            raise SetupError(f"splitterm がありません: {binary}（swift build -c release --package-path ios/TermCore）")
        self.binary = binary if usable and mode != "fallback" else None
        self.spec = configspec.load_spec()
        self.name = "splitterm config check" if self.binary else "フォールバック（configspec の簡易な検査）"

    def check(self, text: str) -> list[str]:
        if self.binary is None:
            return [f"{n} 行目: {m}" for n, m in configspec.validate(text, self.spec)]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config"
            path.write_text(text, encoding="utf-8")
            r = subprocess.run([str(self.binary), "config", "check", "--file", str(path)],
                               capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            return []
        if r.returncode == 1:
            lines = [x.strip() for x in (r.stdout + "\n" + r.stderr).splitlines() if x.strip()]
            return lines or ["splitterm config check に通らない"]
        raise SetupError(f"splitterm config check が終了コード {r.returncode} で終わりました: {r.stderr.strip()}")


def grade_config(task: dict, answer: str, validator: Validator) -> list[str]:
    text = extract_config(answer)
    values, hosts = configspec.entries(text)
    reasons = [f"検査（{validator.name}）: {p}" for p in validator.check(text)]
    if not values and not hosts:
        reasons.append("読める config の行がありません")
    for key, pat in task.get("expect", {}).items():
        if key not in values:
            reasons.append(f"{key} がありません")
        elif not re.fullmatch(pat, values[key], re.I):
            reasons.append(f"{key} = {values[key]}（期待: {pat}）")
    for key, pat in task.get("forbid", {}).items():
        if key in values and re.fullmatch(pat, values[key], re.I):
            reasons.append(f"{key} = {values[key]} にしてはいけない")
    want = task.get("expect_host")
    if want and not any(all(re.fullmatch(p, h.get(k, ""), re.I) for k, p in want.items()) for h in hosts):
        reasons.append(f"期待の host がありません（{want}、書いてあったもの: {hosts}）")
    return reasons


def grade(task: dict, answer: str, validator: Validator) -> list[str]:
    return grade_config(task, answer, validator) if task["kind"] == "config" else grade_qa(task, answer)


# ─── tasks.json ───────────────────────────────────────────

def load_tasks(path: Path = TASKS) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_tasks(data: dict, spec: dict[str, list[str]]) -> list[str]:
    """tasks.json の形のだめな所"""
    bad = []
    th = data.get("thresholds", {})
    for k in ("qa", "config"):
        if not isinstance(th.get(k), (int, float)) or not 0 <= th[k] <= 1:
            bad.append(f"thresholds.{k} は 0〜1 の数です")
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        return bad + ["tasks がありません"]
    seen = set()
    for t in tasks:
        tid = t.get("id", "?")
        if not re.fullmatch(r"[a-z0-9-]+", str(tid)) or tid in seen:
            bad.append(f"{tid}: id は英小文字・数字・- で、重ならないようにします")
        seen.add(tid)
        if t.get("kind") not in ("qa", "config"):
            bad.append(f"{tid}: kind は qa か config です")
        if t.get("lang") not in ("ja", "en"):
            bad.append(f"{tid}: lang は ja か en です")
        if not isinstance(t.get("prompt"), str) or not t["prompt"].strip():
            bad.append(f"{tid}: prompt がありません")
        patterns: list[str] = []
        if t.get("kind") == "qa":
            req = t.get("required")
            if not isinstance(req, list) or not req or not all(isinstance(g, list) and g for g in req):
                bad.append(f"{tid}: required は「正規表現のどれか」の組の一覧です")
            else:
                patterns += [p for g in req for p in g]
            patterns += t.get("forbidden", []) + t.get("order", [])
            if set(t) & {"expect", "forbid", "expect_host"}:
                bad.append(f"{tid}: qa に config の採点（expect など）は書けません")
        elif t.get("kind") == "config":
            if not (t.get("expect") or t.get("expect_host")):
                bad.append(f"{tid}: config の課題には expect か expect_host が要ります")
            for field in ("expect", "forbid"):
                for key, pat in t.get(field, {}).items():
                    if key not in spec:
                        bad.append(f"{tid}: {field} の {key} は config.example に無い項目です")
                    patterns.append(pat)
            for key, pat in t.get("expect_host", {}).items():
                if key not in HOST_FIELDS:
                    bad.append(f"{tid}: expect_host の {key} は {HOST_FIELDS} のどれかです")
                patterns.append(pat)
            if set(t) & {"required", "forbidden", "order"}:
                bad.append(f"{tid}: config に qa の採点（required など）は書けません")
        for p in patterns:
            try:
                re.compile(p)
            except (re.error, TypeError) as e:
                bad.append(f"{tid}: 正規表現 {p!r} が読めません（{e}）")
        ex = t.get("examples", {})
        if not ex.get("pass") or not ex.get("fail"):
            bad.append(f"{tid}: examples に pass と fail を 1 つ以上書きます（採点の見本）")
    return bad


def dry_run(data: dict, validator: Validator) -> int:
    bad = validate_tasks(data, validator.spec)
    n = 0
    if not bad:
        for t in data["tasks"]:
            for want, answers in (("pass", t["examples"]["pass"]), ("fail", t["examples"]["fail"])):
                for a in answers:
                    n += 1
                    reasons = grade(t, a, validator)
                    if (want == "pass") != (not reasons):
                        got = "合格" if not reasons else "不合格（" + "、".join(reasons) + "）"
                        bad.append(f"{t['id']}: {want} の見本が {got}: {a[:60]!r}")
    print(f"dry-run: 課題 {len(data.get('tasks', []))} 件、採点の見本 {n} 件、config の検査は {validator.name}")
    for b in bad:
        print(f"  ✗ {b}")
    print("結果: " + ("不合格" if bad else "すべて期待どおり"))
    return 1 if bad else 0


# ─── claude -p で解かせる ─────────────────────────────────────

def build_prompt(task: dict, arm: str, base: str) -> str:
    text = PREAMBLE[(arm, task["lang"])].format(base=base) + task["prompt"]
    if task["kind"] == "config":
        text += CONFIG_SUFFIX[task["lang"]]
    return text


def claude_command(claude: str, arm: str, base: str, model: str | None) -> list[str]:
    """プロンプトは標準入力で渡す（--allowedTools などの後ろに置くと、その値として読まれるため）"""
    blocked = list(BLOCKED_TOOLS)
    cmd = [claude, "-p", "--output-format", "json", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    if arm == "site":
        cmd += ["--allowedTools", f"WebFetch(domain:{urllib.parse.urlparse(base).hostname})"]
    else:
        blocked.append("WebFetch")
    cmd += ["--disallowedTools", ",".join(blocked)]
    if model:
        cmd += ["--model", model]
    return cmd


def ask(cmd: list[str], prompt: str, timeout: int) -> dict:
    """claude -p を、空のフォルダで動かす（リポジトリや CLAUDE.md を読ませない）"""
    with tempfile.TemporaryDirectory() as cwd:
        try:
            r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        except subprocess.TimeoutExpired:
            return {"answer": "", "error": f"{timeout} 秒で終わらなかった"}
    try:
        out = json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"answer": r.stdout, "error": None if r.returncode == 0 else f"終了コード {r.returncode}: {r.stderr[-300:]}"}
    return {
        "answer": out.get("result") or "",
        "error": f"claude のエラー: {out.get('subtype')}" if out.get("is_error") or r.returncode else None,
        "duration_ms": out.get("duration_ms"),
        "num_turns": out.get("num_turns"),
    }


def summarize(rows: list[dict]) -> dict:
    out = {}
    for kind in ("qa", "config"):
        ks = [r for r in rows if r["kind"] == kind]
        passed = sum(r["passed"] for r in ks)
        out[kind] = {"passed": passed, "total": len(ks), "rate": round(passed / len(ks), 3) if ks else None}
    return out


def fmt(s: dict, kind: str) -> str:
    x = s.get(kind) or {}
    if not x.get("total"):
        return "–"
    return f"{x['passed']}/{x['total']}（{round(100 * x['rate'])}%）"


def previous(results_dir: Path, arm: str) -> tuple[Path | None, dict | None]:
    files = sorted(results_dir.glob(f"*-{arm}.json"))
    if not files:
        return None, None
    try:
        return files[-1], json.loads(files[-1].read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return files[-1], None


def compare(arm: str, now: dict, prev_path: Path | None, prev: dict | None) -> list[str]:
    lines = [f"== {arm}（{'サイトの URL を渡す' if arm == 'site' else 'サイトなし。基準線'}） {now['date']}",
             f"  答える課題: {fmt(now['summary'], 'qa')}  config の課題: {fmt(now['summary'], 'config')}"]
    if prev is None:
        lines.append("  前回の結果はありません")
        return lines
    lines.append(f"  前回（{prev_path.name if prev_path else '?'}）: 答える課題 {fmt(prev.get('summary', {}), 'qa')}"
                 f"  config の課題 {fmt(prev.get('summary', {}), 'config')}")
    before = {r["id"]: r["passed"] for r in prev.get("tasks", [])}
    for r in now["tasks"]:
        if r["id"] in before and before[r["id"]] != r["passed"]:
            lines.append(f"  変わった: {r['id']} {'○→✕' if before[r['id']] else '✕→○'}")
    return lines


def run(args: argparse.Namespace, data: dict, validator: Validator) -> int:
    claude = shutil.which(args.claude)
    if not claude:
        raise SetupError(f"{args.claude} が見つかりません。Claude Code を入れてログインしてから動かします"
                         "（有料の API は使わない。採点の確認だけなら --dry-run）")
    version = subprocess.run([claude, "--version"], capture_output=True, text=True, timeout=60).stdout.strip()
    tasks = data["tasks"]
    if args.only:
        ids = set(args.only.split(","))
        unknown = ids - {t["id"] for t in tasks}
        if unknown:
            raise SetupError(f"--only に知らない課題があります: {sorted(unknown)}")
        tasks = [t for t in tasks if t["id"] in ids]
    arms = ARMS if args.arm == "both" else (args.arm,)
    today = dt.date.today().isoformat()
    args.results_dir.mkdir(parents=True, exist_ok=True)
    print(f"claude: {version}  サイト: {args.base}  config の検査: {validator.name}")
    report, summaries = [], {}
    for arm in arms:
        prev_path, prev = previous(args.results_dir, arm)
        cmd = claude_command(claude, arm, args.base, args.model)
        rows = []
        for t in tasks:
            res = ask(cmd, build_prompt(t, arm, args.base), args.timeout)
            reasons = ([res["error"]] if res.get("error") else []) + grade(t, res["answer"], validator)
            rows.append({"id": t["id"], "kind": t["kind"], "passed": not reasons, "reasons": reasons,
                         "answer": res["answer"], "duration_ms": res.get("duration_ms"),
                         "num_turns": res.get("num_turns")})
            print(f"  [{arm}] {t['id']}: {'○' if not reasons else '✕ ' + '、'.join(reasons)[:160]}")
        now = {"date": today, "arm": arm, "site": args.base if arm == "site" else None, "claude": version,
               "model": args.model, "validator": validator.name, "summary": summarize(rows), "tasks": rows}
        out = args.results_dir / f"{today}-{arm}.json"
        out.write_text(json.dumps(now, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        summaries[arm] = now["summary"]
        report += compare(arm, now, prev_path, prev) + [f"  記録: {out}"]
    if len(summaries) == 2:
        s, b = summaries["site"], summaries["baseline"]
        delta = [f"{label} {s[k]['passed'] - b[k]['passed']:+d}" for k, label in (("qa", "答える課題"), ("config", "config の課題"))
                 if s[k]["total"]]
        report.append("== サイトの効果（site − baseline）: " + "、".join(delta))
    print("\n".join(report))
    if "site" not in summaries:
        return 0
    th = data["thresholds"]
    s = summaries["site"]
    ok = all(s[k]["rate"] is None or s[k]["rate"] >= th[k] for k in ("qa", "config"))
    print(f"合格の線（答える {round(100 * th['qa'])}%・config {round(100 * th['config'])}%）: {'超えた' if ok else '届かない'}")
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="手元の claude -p でサイトの効き目を測る（ベンチマーク B）")
    ap.add_argument("--arm", choices=("site", "baseline", "both"), default="both")
    ap.add_argument("--only", help="この課題だけ（id をカンマで）")
    ap.add_argument("--model", help="claude -p に渡すモデル")
    ap.add_argument("--dry-run", action="store_true", help="tasks.json と採点の見本を確かめるだけ（claude は呼ばない）")
    ap.add_argument("--validator", default="auto", help="auto / splitterm / fallback")
    ap.add_argument("--tasks", type=Path, default=TASKS)
    ap.add_argument("--base", help="サイトの URL（既定 site/site.json の base_url）")
    ap.add_argument("--results-dir", type=Path, default=RESULTS)
    ap.add_argument("--claude", default="claude")
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args(argv)
    try:
        args.base = (args.base or json.loads(SITE_JSON.read_text(encoding="utf-8"))["base_url"]).rstrip("/")
        validator = Validator(args.validator)
        data = load_tasks(args.tasks)
        if args.dry_run:
            return dry_run(data, validator)
        bad = validate_tasks(data, validator.spec)
        if bad:
            raise SetupError("tasks.json の形が違います（--dry-run で見る）: " + bad[0])
        return run(args, data, validator)
    except SetupError as e:
        print(f"動かせません: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
