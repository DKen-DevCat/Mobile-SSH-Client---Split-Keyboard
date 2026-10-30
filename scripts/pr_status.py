#!/usr/bin/env python3
"""このブランチの PR と CI の状態を数行で見て、最後に「次の一手」を 1 行で出す。

使い方: python3 scripts/pr_status.py [ブランチ] [--json] [--repo OWNER/REPO]

- ブランチの既定は今のブランチ。repo の既定は `git remote get-url origin` から（読めなければ DEFAULT_REPO）
- GitHub の REST API を読む（GH_TOKEN か GITHUB_TOKEN があれば使う。公開リポジトリなので無くても読める）
- 手元は `git fetch` しない（速さのため）。origin/main は最後に fetch した時点のもので、古いかもしれない
- 判定は decide() に集めた純粋な関数。通信と git は collect() に関数で渡すので、tests/test_pr_status.py は通信しない
- 標準ライブラリだけ
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = "DKen-DevCat/Mobile-SSH-Client---Split-Keyboard"
API = "https://api.github.com"
TIMEOUT = 15
MAIN = "origin/main"

GitFn = Callable[..., tuple[int, str]]
ApiFn = Callable[[str], object]


# ---------------------------------------------------------------------------
# 純粋な部分（通信も git も使わない）
# ---------------------------------------------------------------------------

_SEGMENT = re.compile(r"^[A-Za-z0-9._-]+$")
_REMOTE_SCHEMES = {"http", "https", "ssh", "git", "git+ssh", "ssh+git"}


def parse_remote(url: str) -> tuple[str, str] | None:
    """`git remote get-url origin` の値から (owner, repo) を読む。読めなければ None。

    https://github.com/O/R(.git)・git@github.com:O/R.git・ssh://git@github.com/O/R.git のほか、
    ローカルの proxy の http://…/git/O/R も読める（パスの最後の 2 つを owner と repo にする）。
    ローカルのパス（/home/user/repo や file://）は読まない
    """
    url = url.strip()
    if "://" in url:
        parts = urllib.parse.urlsplit(url)
        if parts.scheme.lower() not in _REMOTE_SCHEMES:
            return None
        path = parts.path
    else:
        m = re.match(r"^[\w.-]+@[\w.-]+:(.+)$", url)  # git@github.com:O/R.git
        if not m:
            return None
        path = m.group(1)
    segments = [s for s in path.split("/") if s]
    if len(segments) < 2:
        return None
    owner, repo = segments[-2], segments[-1]
    if repo.endswith(".git"):
        repo = repo[: -len(".git")]
    if not (_SEGMENT.match(owner) and _SEGMENT.match(repo)):
        return None
    return owner, repo


@dataclass
class Pr:
    number: int
    title: str
    url: str
    state: str  # "open" | "closed" | "merged"
    head_sha: str
    base_ref: str = "main"

    @staticmethod
    def from_api(item: dict) -> "Pr":
        if item.get("merged_at") or item.get("merged"):
            state = "merged"
        else:
            state = "open" if item.get("state") == "open" else "closed"
        return Pr(
            number=int(item["number"]),
            title=str(item.get("title", "")),
            url=str(item.get("html_url", "")),
            state=state,
            head_sha=str((item.get("head") or {}).get("sha", "")),
            base_ref=str((item.get("base") or {}).get("ref") or "main"),
        )


def pick_pr(items: list[dict]) -> Pr | None:
    """同じブランチの PR が複数あるとき: 開いているものを先に、無ければ新しいもの（API は新しい順）"""
    prs = [Pr.from_api(i) for i in items if isinstance(i, dict) and "number" in i]
    for pr in prs:
        if pr.state == "open":
            return pr
    return prs[0] if prs else None


@dataclass
class Checks:
    success: int = 0
    failure: int = 0
    running: int = 0
    failed: list[str] = field(default_factory=list)

    @property
    def total(self) -> int:
        return self.success + self.failure + self.running


_OK = {"success", "neutral", "skipped"}


def summarize_checks(runs: list[dict]) -> Checks:
    """check-runs の一覧を、成功・失敗・実行中の数と、失敗した名前にまとめる"""
    c = Checks()
    for r in runs:
        if r.get("status") != "completed":
            c.running += 1
        elif r.get("conclusion") in _OK:
            c.success += 1
        else:  # failure・timed_out・cancelled・action_required・stale など。緑ではない
            c.failure += 1
            c.failed.append(str(r.get("name", "?")))
    return c


@dataclass
class Decision:
    code: str
    text: str


def decide(pr: Pr | None, local_head: str | None, head_in_main: bool | None, checks: Checks | None,
           relation: str | None = None) -> Decision:
    """次の一手。

    relation は PR の head から見た手元の HEAD: "same" / "ahead"（手元が先）/ "behind"（手元が遅れ）/ "diverged"。
    分からなければ None（違っていれば、手元が先として扱う）
    """
    if pr is None:
        return Decision("create_pr", "PR なし → 作る")
    n = pr.number
    # このリポジトリは手でマージすることがある。closed でも head が main に含まれていれば、取り込み済み
    if pr.state == "merged" or (pr.state == "closed" and head_in_main):
        return Decision("rebase_on_main", f"PR #{n} は取り込み済み → main から切り直す")
    if pr.state == "closed":
        return Decision("reopen_pr", f"PR #{n} は閉じられていて、取り込まれていない → 開き直すか、新しく作る")
    # ここから open
    differs = bool(local_head) and local_head != pr.head_sha
    if differs and relation == "behind":
        return Decision("pull", f"PR #{n}（open）→ 手元が遅れている。取り込んでから push する")
    if differs:
        # 今の CI は古い head のもの。push してから見る
        return Decision("update_pr", f"PR #{n}（open）→ push して更新する")
    if checks is None:
        return Decision("ci_unknown", f"PR #{n}（open）→ CI の状態を取れなかった。もう一度流す")
    if checks.total == 0:
        return Decision("wait_ci", f"PR #{n}（open）→ CI の結果がまだ無い。待つ（push の直後なら数十秒）")
    if checks.failure:
        names = "、".join(checks.failed[:5]) + (f" ほか {len(checks.failed) - 5} 件" if len(checks.failed) > 5 else "")
        return Decision("fix_ci", f"CI 失敗（{names}）→ 直す")
    if checks.running:
        return Decision("wait_ci", "CI 実行中 → 待つ")
    return Decision("merge", "CI 成功 → マージできる")


def short(sha: str | None) -> str:
    return sha[:7] if sha else "-"


def render(report: dict) -> str:
    """report（collect の結果）を、日本語の数行に"""
    lines = [f"ブランチ: {report['branch']}（手元 {short(report['local_head'])}）  repo: {report['repo']}"]
    m = report["main"]
    if m is None:
        lines.append(f"{MAIN}: 手元に無い（git fetch すると分かる）")
    else:
        lines.append(f"{MAIN}: 先行 {m['ahead']}・遅れ {m['behind']}（git fetch していないので、古いかもしれない）")
    pr = report["pr"]
    if pr is None:
        lines.append("PR: なし" if not report["errors"].get("pr") else "PR: 取れなかった")
    else:
        lines.append(f"PR: #{pr['number']} {pr['title']}［{pr['state']}］ {pr['url']}")
        notes = []
        if pr["head_matches_local"] is True:
            notes.append(f"head {short(pr['head_sha'])} は手元の HEAD と同じ")
        elif pr["head_matches_local"] is False:
            rel = {"ahead": "手元が先", "behind": "手元が遅れ", "diverged": "枝分かれ"}.get(pr["relation"] or "", "")
            notes.append(f"head {short(pr['head_sha'])} は手元の HEAD と違う" + (f"（{rel}）" if rel else ""))
        else:
            notes.append(f"head {short(pr['head_sha'])}")
        if pr["head_in_main"]:
            notes.append(f"{MAIN} に含まれる")
        lines.append("    " + "。".join(notes))
    c = report["checks"]
    if c is not None:
        tail = f"（失敗: {'、'.join(c['failed'])}）" if c["failed"] else ""
        lines.append(f"CI: 成功 {c['success']}・失敗 {c['failure']}・実行中 {c['running']}{tail}")
    elif pr is not None:
        why = report["errors"].get("checks")
        lines.append(f"CI: 取れなかった（{why}）" if why else "CI: 結果なし")
    for key, message in report["errors"].items():
        if message:
            lines.append(f"注意（{key}）: {message}")
    lines.append(f"次の一手: {report['next']['text']}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 集める部分（git と GitHub を関数で受け取る）
# ---------------------------------------------------------------------------


class UsageError(Exception):
    pass


class ApiError(Exception):
    pass


def _local_sha(branch: str, current: str | None, git: GitFn) -> str | None:
    if branch == current:
        code, out = git("rev-parse", "HEAD")
        return out if code == 0 and out else None
    for ref in (f"refs/heads/{branch}", f"refs/remotes/origin/{branch}"):
        code, out = git("rev-parse", "--verify", "-q", ref)
        if code == 0 and out:
            return out
    return None


def _is_ancestor(ancestor: str, descendant: str, git: GitFn) -> bool | None:
    """0 なら含まれる、1 なら含まれない、それ以外（コミットが手元に無い など）は分からない"""
    code, _ = git("merge-base", "--is-ancestor", ancestor, descendant)
    return True if code == 0 else False if code == 1 else None


def collect(branch: str | None, repo: tuple[str, str], git: GitFn, api: ApiFn) -> dict:
    owner, name = repo
    errors: dict[str, str] = {}

    code, out = git("rev-parse", "--abbrev-ref", "HEAD")
    current = out if code == 0 and out else None
    branch = branch or current
    if not branch or branch == "HEAD":
        raise UsageError("ブランチを指定してください（今のブランチが分かりません）")
    local = _local_sha(branch, current, git)

    # origin/main との先行・遅れ（git fetch はしない）
    main = None
    if local:
        code, out = git("rev-list", "--left-right", "--count", f"{MAIN}...{local}")
        parts = out.split()
        if code == 0 and len(parts) == 2 and all(p.isdigit() for p in parts):
            main = {"ahead": int(parts[1]), "behind": int(parts[0])}

    # このブランチを head とする PR
    pr: Pr | None = None
    pr_known = True
    query = urllib.parse.urlencode({"state": "all", "head": f"{owner}:{branch}", "per_page": 10})
    try:
        items = api(f"/repos/{owner}/{name}/pulls?{query}")
        pr = pick_pr(items if isinstance(items, list) else [])
    except ApiError as e:
        pr_known = False
        errors["pr"] = str(e)

    head_in_main: bool | None = None
    relation: str | None = None
    checks: Checks | None = None
    if pr is not None and pr.head_sha:
        head_in_main = _is_ancestor(pr.head_sha, MAIN, git)
        if head_in_main is None and pr.state == "closed":
            # 手元にそのコミットが無い。閉じた PR だけは、取り込み済みかを GitHub に聞く
            try:
                cmp = api(f"/repos/{owner}/{name}/compare/{pr.base_ref}...{pr.head_sha}")
                status = cmp.get("status") if isinstance(cmp, dict) else None
                head_in_main = status in ("behind", "identical") if status else None
            except ApiError as e:
                errors["compare"] = str(e)
        if local:
            if local == pr.head_sha:
                relation = "same"
            else:
                down = _is_ancestor(pr.head_sha, local, git)  # PR の head は手元に含まれるか
                up = _is_ancestor(local, pr.head_sha, git)  # 手元は PR の head に含まれるか
                if down:
                    relation = "ahead"
                elif up:
                    relation = "behind"
                elif down is False and up is False:
                    relation = "diverged"
        try:
            data = api(f"/repos/{owner}/{name}/commits/{pr.head_sha}/check-runs?per_page=100")
            runs = data.get("check_runs", []) if isinstance(data, dict) else []
            checks = summarize_checks(runs)
        except ApiError as e:
            errors["checks"] = str(e)

    if pr_known:
        decision = decide(pr, local, head_in_main, checks, relation)
    else:
        decision = Decision("api_error", "GitHub から PR を取れなかった → 通信か GH_TOKEN を確かめる")

    return {
        "repo": f"{owner}/{name}",
        "branch": branch,
        "local_head": local,
        "main": main,
        "pr": None if pr is None else {
            **asdict(pr),
            "head_matches_local": None if not local or not pr.head_sha else local == pr.head_sha,
            "relation": relation,
            "head_in_main": head_in_main,
        },
        "checks": None if checks is None else asdict(checks),
        "next": asdict(decision),
        "errors": errors,
    }


# ---------------------------------------------------------------------------
# 実際の git と GitHub
# ---------------------------------------------------------------------------


def run_git(*args: str) -> tuple[int, str]:
    try:
        p = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return p.returncode, p.stdout.strip()


def make_api(token: str | None, timeout: float = TIMEOUT) -> ApiFn:
    def get(path: str) -> object:
        def fetch(with_token: bool) -> object:
            headers = {
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "pr-status",
            }
            if with_token and token:
                headers["Authorization"] = f"Bearer {token}"
            req = urllib.request.Request(API + path, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as res:
                return json.loads(res.read().decode("utf-8"))

        try:
            try:
                return fetch(True)
            except urllib.error.HTTPError as e:
                if e.code == 401 and token:
                    return fetch(False)  # 期限切れの token でも、公開リポジトリは読める
                raise
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = json.loads(e.read().decode("utf-8")).get("message", "")
            except Exception:
                pass
            raise ApiError(f"GitHub API {e.code} {e.reason}" + (f": {detail}" if detail else "")) from e
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ApiError(f"GitHub API に届きません（{getattr(e, 'reason', e)}）") from e
        except ValueError as e:
            raise ApiError(f"GitHub API の答えを読めません（{e}）") from e

    return get


def default_repo(git: GitFn) -> tuple[str, str]:
    code, out = git("remote", "get-url", "origin")
    parsed = parse_remote(out) if code == 0 else None
    if parsed:
        return parsed
    owner, name = DEFAULT_REPO.split("/", 1)
    return owner, name


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="このブランチの PR と CI の状態、次の一手を出す")
    ap.add_argument("branch", nargs="?", help="ブランチ（既定は今のブランチ）")
    ap.add_argument("--json", action="store_true", help="機械向けに JSON で出す")
    ap.add_argument("--repo", metavar="OWNER/REPO", help="既定は git remote get-url origin から")
    args = ap.parse_args(argv)

    if args.repo:
        parts = args.repo.split("/")
        if len(parts) != 2 or not all(_SEGMENT.match(p) for p in parts):
            print("--repo は OWNER/REPO の形で書きます", file=sys.stderr)
            return 2
        repo = (parts[0], parts[1])
    else:
        repo = default_repo(run_git)

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    try:
        report = collect(args.branch, repo, run_git, make_api(token))
    except UsageError as e:
        print(str(e), file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render(report))
    return 1 if report["next"]["code"] == "api_error" else 0


if __name__ == "__main__":
    sys.exit(main())
