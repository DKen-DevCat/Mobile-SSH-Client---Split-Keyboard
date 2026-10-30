"""scripts/pr_status.py（このブランチの PR と CI の状態、次の一手）。通信も git も使わず、判定と読み方だけを確かめる。"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "pr_status.py"

_spec = importlib.util.spec_from_file_location("pr_status", SCRIPT)
ps = importlib.util.module_from_spec(_spec)
sys.modules["pr_status"] = ps  # dataclass が自分のモジュールを引くので、読み込む前に登録する
_spec.loader.exec_module(ps)

HEAD = "a" * 40
OLD = "b" * 40
MAIN_SHA = "c" * 40


def pr(state="open", number=3, head=HEAD, title="題名") -> ps.Pr:
    return ps.Pr(number=number, title=title, url=f"https://github.com/o/r/pull/{number}", state=state, head_sha=head)


def ok(n=5) -> ps.Checks:
    return ps.Checks(success=n)


# --- remote の URL の読み方 -------------------------------------------------


@pytest.mark.parametrize("url", [
    "https://github.com/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard",
    "https://github.com/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard.git",
    "https://github.com/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard/",
    "git@github.com:DKen-DevCat/Mobile-SSH-Client---Split-Keyboard.git",
    "ssh://git@github.com/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard.git",
    "ssh://git@github.com:22/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard.git",
    "http://local_proxy@127.0.0.1:34567/git/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard",
    "  https://github.com/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard.git\n",
])
def test_parse_remote_reads_owner_and_repo(url):
    assert ps.parse_remote(url) == ("DKen-DevCat", "Mobile-SSH-Client---Split-Keyboard")


@pytest.mark.parametrize("url", [
    "",
    "origin",
    "/home/user/repo",
    "file:///home/user/repo",
    "https://github.com/onlyowner",
    "https://github.com/",
    "../relative/path",
    "https://github.com/o/r r",
])
def test_parse_remote_gives_up_on_unreadable_urls(url):
    assert ps.parse_remote(url) is None


def test_default_repo_falls_back_when_the_remote_is_unreadable():
    assert ps.default_repo(lambda *a: (0, "/home/user/repo")) == tuple(ps.DEFAULT_REPO.split("/", 1))
    assert ps.default_repo(lambda *a: (128, "")) == tuple(ps.DEFAULT_REPO.split("/", 1))
    assert ps.default_repo(lambda *a: (0, "git@github.com:a/b.git")) == ("a", "b")


# --- 判定 -----------------------------------------------------------------


def test_no_pr_means_create_one():
    d = ps.decide(None, HEAD, None, None)
    assert (d.code, d.text) == ("create_pr", "PR なし → 作る")


def test_open_pr_with_green_ci_can_be_merged():
    d = ps.decide(pr(), HEAD, False, ok())
    assert (d.code, d.text) == ("merge", "CI 成功 → マージできる")


def test_open_pr_with_failing_ci_names_the_failures():
    c = ps.Checks(success=3, failure=2, failed=["swift", "site-and-tests"])
    d = ps.decide(pr(), HEAD, False, c)
    assert d.code == "fix_ci"
    assert d.text == "CI 失敗（swift、site-and-tests）→ 直す"
    # 失敗があれば、実行中が残っていても失敗を先に言う
    c.running = 1
    assert ps.decide(pr(), HEAD, False, c).code == "fix_ci"


def test_many_failures_are_shortened():
    c = ps.Checks(failure=7, failed=[f"job{i}" for i in range(7)])
    assert ps.decide(pr(), HEAD, False, c).text == "CI 失敗（job0、job1、job2、job3、job4 ほか 2 件）→ 直す"


def test_open_pr_with_running_ci_waits():
    d = ps.decide(pr(), HEAD, False, ps.Checks(success=2, running=1))
    assert (d.code, d.text) == ("wait_ci", "CI 実行中 → 待つ")


def test_open_pr_without_any_check_waits():
    assert ps.decide(pr(), HEAD, False, ps.Checks()).code == "wait_ci"


def test_unreadable_ci_is_reported_not_guessed():
    assert ps.decide(pr(), HEAD, False, None).code == "ci_unknown"


def test_merged_pr_means_start_over_from_main():
    d = ps.decide(pr("merged"), HEAD, True, ok())
    assert (d.code, d.text) == ("rebase_on_main", "PR #3 は取り込み済み → main から切り直す")
    # CI が赤くても、取り込み済みが先
    assert ps.decide(pr("merged"), HEAD, None, ps.Checks(failure=1, failed=["x"])).code == "rebase_on_main"


def test_closed_pr_whose_head_is_in_main_counts_as_merged():
    # このリポジトリは手でマージすることがある（GitHub 上は closed のまま）
    d = ps.decide(pr("closed"), HEAD, True, ok())
    assert d.code == "rebase_on_main"
    assert "取り込み済み" in d.text


def test_closed_pr_not_in_main_is_not_merged():
    for in_main in (False, None):
        d = ps.decide(pr("closed"), HEAD, in_main, ok())
        assert d.code == "reopen_pr"


def test_stale_pr_head_means_push():
    # 手元の HEAD が PR の head より進んでいる。今の CI は古い head のものなので、結果より push が先
    d = ps.decide(pr(head=OLD), HEAD, False, ps.Checks(failure=1, failed=["swift"]), relation="ahead")
    assert (d.code, d.text) == ("update_pr", "PR #3（open）→ push して更新する")
    assert ps.decide(pr(head=OLD), HEAD, False, ok()).code == "update_pr"  # 関係が分からなくても


def test_local_behind_the_pr_means_pull_first():
    d = ps.decide(pr(head=OLD), HEAD, False, ok(), relation="behind")
    assert d.code == "pull"


def test_unknown_local_head_is_not_called_stale():
    assert ps.decide(pr(), None, False, ok()).code == "merge"


# --- check-runs のまとめ方 ------------------------------------------------


def test_summarize_checks():
    runs = [
        {"name": "a", "status": "completed", "conclusion": "success"},
        {"name": "b", "status": "completed", "conclusion": "skipped"},
        {"name": "c", "status": "completed", "conclusion": "neutral"},
        {"name": "d", "status": "completed", "conclusion": "failure"},
        {"name": "e", "status": "completed", "conclusion": "cancelled"},
        {"name": "f", "status": "in_progress", "conclusion": None},
        {"name": "g", "status": "queued", "conclusion": None},
    ]
    c = ps.summarize_checks(runs)
    assert (c.success, c.failure, c.running) == (3, 2, 2)
    assert c.failed == ["d", "e"]
    assert c.total == 7
    assert ps.summarize_checks([]).total == 0


# --- PR の選び方 ----------------------------------------------------------


def item(number, state="open", merged_at=None, sha=HEAD):
    return {"number": number, "title": f"t{number}", "html_url": f"https://x/{number}", "state": state,
            "merged_at": merged_at, "head": {"sha": sha}, "base": {"ref": "main"}}


def test_from_api_reads_state():
    assert ps.Pr.from_api(item(1)).state == "open"
    assert ps.Pr.from_api(item(2, "closed")).state == "closed"
    assert ps.Pr.from_api(item(3, "closed", merged_at="2026-10-30T00:00:00Z")).state == "merged"
    assert ps.Pr.from_api(item(4)).head_sha == HEAD


def test_pick_pr_prefers_the_open_one_then_the_newest():
    items = [item(9, "closed", "2026-10-30T00:00:00Z"), item(7, "open"), item(5, "closed")]
    assert ps.pick_pr(items).number == 7
    assert ps.pick_pr([item(9, "closed"), item(5, "closed")]).number == 9
    assert ps.pick_pr([]) is None
    assert ps.pick_pr([{"nope": 1}]) is None


# --- 集める部分（git と GitHub は偽物） ------------------------------------


class FakeGit:
    def __init__(self, branch="feat", head=HEAD, left_right="0\t3", in_main=None, relations=None):
        self.branch, self.head, self.left_right = branch, head, left_right
        self.in_main = in_main or {}  # sha -> 0/1/128（merge-base --is-ancestor sha origin/main の終了コード）
        self.relations = relations or {}  # (a, b) -> 終了コード
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        if args == ("rev-parse", "--abbrev-ref", "HEAD"):
            return 0, self.branch
        if args == ("rev-parse", "HEAD"):
            return 0, self.head
        if args[:3] == ("rev-list", "--left-right", "--count"):
            return 0, self.left_right
        if args[:2] == ("merge-base", "--is-ancestor"):
            a, b = args[2], args[3]
            if b == ps.MAIN:
                return self.in_main.get(a, 128), ""
            return self.relations.get((a, b), 1), ""
        return 128, ""


class FakeApi:
    def __init__(self, pulls=None, checks=None, compare=None, fail=()):
        self.pulls, self.checks, self.compare, self.fail = pulls or [], checks, compare, set(fail)
        self.calls = []

    def __call__(self, path):
        self.calls.append(path)
        kind = "pulls" if "/pulls?" in path else "checks" if "/check-runs" in path else "compare"
        if kind in self.fail:
            raise ps.ApiError("GitHub API 500 boom")
        if kind == "pulls":
            return self.pulls
        if kind == "checks":
            return {"check_runs": self.checks or []}
        return self.compare or {}


REPO = ("o", "r")


def run(item_list, checks=None, git=None, branch=None, **api_kwargs):
    git = git or FakeGit()
    api = FakeApi(pulls=item_list, checks=checks, **api_kwargs)
    return ps.collect(branch, REPO, git, api), git, api


def test_collect_without_a_pr():
    report, git, api = run([])
    assert report["branch"] == "feat"
    assert report["main"] == {"ahead": 3, "behind": 0}
    assert report["pr"] is None and report["checks"] is None
    assert report["next"]["code"] == "create_pr"
    # PR を探す 1 回だけ。CI は PR が無ければ聞かない
    assert api.calls == ["/repos/o/r/pulls?state=all&head=o%3Afeat&per_page=10"]
    # git fetch はしない
    assert not any(c[0] == "fetch" for c in git.calls)


def test_collect_open_pr_green():
    runs = [{"name": "swift", "status": "completed", "conclusion": "success"}]
    report, _, api = run([item(3)], runs)
    assert report["pr"]["state"] == "open"
    assert report["pr"]["head_matches_local"] is True
    assert report["checks"]["success"] == 1
    assert report["next"]["code"] == "merge"
    assert api.calls[1] == f"/repos/o/r/commits/{HEAD}/check-runs?per_page=100"


def test_collect_open_pr_failing():
    runs = [{"name": "swift", "status": "completed", "conclusion": "failure"},
            {"name": "site", "status": "completed", "conclusion": "success"}]
    report, _, _ = run([item(3)], runs)
    assert report["next"] == {"code": "fix_ci", "text": "CI 失敗（swift）→ 直す"}


def test_collect_open_pr_running():
    runs = [{"name": "swift", "status": "in_progress", "conclusion": None}]
    report, _, _ = run([item(3)], runs)
    assert report["next"]["code"] == "wait_ci"


def test_collect_stale_head():
    # PR の head は OLD、手元は HEAD（OLD を含む）
    git = FakeGit(relations={(OLD, HEAD): 0})
    report, _, _ = run([item(3, sha=OLD)], [], git=git)
    assert report["pr"]["head_matches_local"] is False
    assert report["pr"]["relation"] == "ahead"
    assert report["next"]["code"] == "update_pr"


def test_collect_local_behind():
    git = FakeGit(relations={(HEAD, OLD): 0})  # 手元が PR の head に含まれる
    report, _, _ = run([item(3, sha=OLD)], [], git=git)
    assert report["pr"]["relation"] == "behind"
    assert report["next"]["code"] == "pull"


def test_collect_merged_pr():
    report, _, _ = run([item(2, "closed", "2026-10-30T00:00:00Z")], [], git=FakeGit(in_main={HEAD: 0}))
    assert report["pr"]["state"] == "merged"
    assert report["pr"]["head_in_main"] is True
    assert report["next"]["code"] == "rebase_on_main"


def test_collect_closed_pr_contained_in_main():
    report, _, _ = run([item(2, "closed")], [], git=FakeGit(in_main={HEAD: 0}))
    assert report["pr"]["state"] == "closed"
    assert report["next"]["code"] == "rebase_on_main"


def test_collect_closed_pr_not_in_main():
    report, _, _ = run([item(2, "closed")], [], git=FakeGit(in_main={HEAD: 1}))
    assert report["next"]["code"] == "reopen_pr"


def test_collect_closed_pr_with_unknown_commit_asks_github():
    # 手元にコミットが無い（merge-base が 128）。GitHub の compare で「main に含まれる」と分かる
    report, _, api = run([item(2, "closed")], [], compare={"status": "behind"})
    assert report["pr"]["head_in_main"] is True
    assert report["next"]["code"] == "rebase_on_main"
    assert any("/compare/main..." in p for p in api.calls)
    report, _, _ = run([item(2, "closed")], [], compare={"status": "diverged"})
    assert report["next"]["code"] == "reopen_pr"


def test_collect_survives_api_failures():
    report, _, _ = run([item(3)], [], fail={"checks"})
    assert report["checks"] is None
    assert "checks" in report["errors"]
    assert report["next"]["code"] == "ci_unknown"

    api = FakeApi(fail={"pulls"})
    report = ps.collect(None, REPO, FakeGit(), api)
    assert report["next"]["code"] == "api_error"
    assert report["pr"] is None


def test_collect_another_branch_uses_its_local_ref():
    class Git(FakeGit):
        def __call__(self, *args):
            if args == ("rev-parse", "--verify", "-q", "refs/heads/other"):
                return 0, OLD
            return super().__call__(*args)

    report, _, api = run([], git=Git(), branch="other")
    assert report["branch"] == "other"
    assert report["local_head"] == OLD
    assert "head=o%3Aother" in api.calls[0]


def test_collect_needs_a_branch():
    class Detached(FakeGit):
        def __call__(self, *args):
            if args == ("rev-parse", "--abbrev-ref", "HEAD"):
                return 0, "HEAD"
            return super().__call__(*args)

    with pytest.raises(ps.UsageError):
        ps.collect(None, REPO, Detached(), FakeApi())


def test_collect_without_origin_main():
    report, _, _ = run([], git=FakeGit(left_right=""))
    assert report["main"] is None


# --- 表示 ------------------------------------------------------------------


def test_render_shows_each_fact_and_the_next_step():
    runs = [{"name": "swift", "status": "completed", "conclusion": "failure"},
            {"name": "site", "status": "completed", "conclusion": "success"}]
    report, _, _ = run([item(3)], runs)
    text = ps.render(report)
    lines = text.splitlines()
    assert lines[0].startswith("ブランチ: feat（手元 aaaaaaa）")
    assert "先行 3・遅れ 0" in text and "古いかもしれない" in text
    assert "PR: #3 t3［open］ https://x/3" in text
    assert "手元の HEAD と同じ" in text
    assert "CI: 成功 1・失敗 1・実行中 0（失敗: swift）" in text
    assert lines[-1] == "次の一手: CI 失敗（swift）→ 直す"


def test_render_without_pr():
    report, _, _ = run([])
    text = ps.render(report)
    assert "PR: なし" in text
    assert text.splitlines()[-1] == "次の一手: PR なし → 作る"


def test_render_notes_a_different_head():
    git = FakeGit(relations={(OLD, HEAD): 0})
    report, _, _ = run([item(3, sha=OLD)], [], git=git)
    assert "手元の HEAD と違う（手元が先）" in ps.render(report)


# --- コマンドライン --------------------------------------------------------


def test_main_prints_json(monkeypatch, capsys):
    git = FakeGit()
    api = FakeApi(pulls=[item(3)], checks=[{"name": "swift", "status": "completed", "conclusion": "success"}])
    monkeypatch.setattr(ps, "run_git", git)
    monkeypatch.setattr(ps, "make_api", lambda token: api)
    assert ps.main(["--json", "--repo", "o/r"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert data["next"]["code"] == "merge"
    assert data["pr"]["number"] == 3
    assert data["repo"] == "o/r"


def test_main_prints_text_and_reads_the_token(monkeypatch, capsys):
    seen = []
    monkeypatch.setattr(ps, "run_git", FakeGit())
    monkeypatch.setattr(ps, "make_api", lambda token: (seen.append(token), FakeApi())[1])
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.setenv("GITHUB_TOKEN", "tok")
    assert ps.main(["--repo", "o/r"]) == 0
    assert seen == ["tok"]
    assert "次の一手: PR なし → 作る" in capsys.readouterr().out
    monkeypatch.setenv("GH_TOKEN", "first")
    ps.main(["--repo", "o/r"])
    assert seen[-1] == "first"


def test_main_rejects_a_bad_repo(capsys):
    assert ps.main(["--repo", "nonsense"]) == 2
    assert ps.main(["--repo", "a/b/c"]) == 2
    assert "OWNER/REPO" in capsys.readouterr().err


def test_main_api_failure_exits_nonzero(monkeypatch, capsys):
    monkeypatch.setattr(ps, "run_git", FakeGit())
    monkeypatch.setattr(ps, "make_api", lambda token: FakeApi(fail={"pulls"}))
    assert ps.main(["--repo", "o/r"]) == 1
    assert "取れなかった" in capsys.readouterr().out


def test_script_is_executable():
    assert os.access(SCRIPT, os.X_OK)
    assert SCRIPT.read_text(encoding="utf-8").startswith("#!/usr/bin/env python3")
