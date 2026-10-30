"""iPhone・iPad アプリ（ios/）の入れ直しスクリプトと、プロジェクトの設定を固定する（docs/design.md「配布」）。
lfm3-vl-server の tests/test_ios.py を移したもの（同じスクリプトを同じ偽物で動かす）。

scripts/ios_reinstall.sh は、偽の xcrun・xcodebuild・security・osascript・defaults で動かす。偽の xcodebuild は
N0 で実測した Xcode の動きをまねる: 手元にこのアプリの有効なプロファイルがあればそれを使い続け、
無ければ新しく 7 日のものを作る（どけないと期限が延びない）。
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ios_reinstall.sh"
PLIST = ROOT / "launchd" / "com.dken.splitterm-ios.plist"
UDID = "00008110-0000000000000001"
TEAM = "TEAM000001"
BUNDLE_ID = "io.github.dken-devcat.splitterm"
APP_ID = f"{TEAM}.{BUNDLE_ID}"
H = 3600
NOW = 1_793_340_000  # 2026-10-30 頃（偽の時計）
WEEK = 7 * 24 * H


def utc(ts: int) -> datetime:
    return datetime.fromtimestamp(ts, timezone.utc).replace(tzinfo=None)


def profile(expires: int, app_id: str = APP_ID) -> bytes:
    return plistlib.dumps({
        "UUID": str(uuid.uuid4()),
        "CreationDate": utc(expires - WEEK),
        "ExpirationDate": utc(expires),
        "Entitlements": {"application-identifier": app_id},
    })


def device(udid: str = UDID, state: str = "connected") -> dict:
    return {"properties": {
        "hardware": {"udid": udid, "platform": "iOS", "reality": "physical"},
        "connection": {"pairingState": "paired", "state": state},
    }}


FAKE_XCODEBUILD = """#!{python}
# 偽の xcodebuild: 呼び出しを残し、手元のこのアプリの有効なプロファイルを使う（無ければ 7 日のものを作って手元に置く）
import os, pathlib, plistlib, sys, uuid
from datetime import datetime, timezone
fake = pathlib.Path(os.environ["FAKE"])
with open(fake / "calls", "a") as f:
    f.write("xcodebuild " + " ".join(sys.argv[1:]) + "\\n")
if (fake / "build_rc").exists():
    sys.exit(int((fake / "build_rc").read_text()))
args = sys.argv[1:]
now = int(os.environ["SPLITTERM_TEST_NOW"])
team = next(a.split("=", 1)[1] for a in args if a.startswith("DEVELOPMENT_TEAM="))
app_id = team + ".{bundle_id}"
cache = pathlib.Path(os.environ["HOME"]) / "Library/Developer/Xcode/UserData/Provisioning Profiles"
cache.mkdir(parents=True, exist_ok=True)
def expiry(p):
    return plistlib.loads(p.read_bytes())["ExpirationDate"].replace(tzinfo=timezone.utc).timestamp()
mine = [p for p in sorted(cache.glob("*.mobileprovision"))
        if plistlib.loads(p.read_bytes())["Entitlements"]["application-identifier"] == app_id]
valid = [p for p in mine if expiry(p) > now]
if (fake / "stale").exists():
    data = None
    exp = now + 3600
elif valid:
    data = valid[0].read_bytes()
else:
    exp = now + 7 * 24 * 3600
    data = None
if data is None:
    utc = lambda ts: datetime.fromtimestamp(ts, timezone.utc).replace(tzinfo=None)
    name = str(uuid.uuid4())
    data = plistlib.dumps({{"UUID": name, "CreationDate": utc(exp - 7 * 24 * 3600), "ExpirationDate": utc(exp),
                           "Entitlements": {{"application-identifier": app_id}}}})
    (cache / (name + ".mobileprovision")).write_bytes(data)
app = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release-iphoneos/SplitTerm.app"
app.mkdir(parents=True, exist_ok=True)
(app / "embedded.mobileprovision").write_bytes(data)
"""

FAKE_XCRUN = """#!/bin/bash
# 偽の xcrun devicectl: 一覧・ロックの状態・プロセスは FAKE のファイルを返し（無ければ失敗）、入れるのは install_rc の終了コード
echo "xcrun $*" >> "$FAKE/calls"
[ "$1" = devicectl ] || exit 9
out=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --json-output ] && out="${args[$((i+1))]}"; done
case "$2 $3 $4" in
  "list devices "*) cp "$FAKE/devices.json" "$out" ;;
  "device info lockState") [ -f "$FAKE/lock.json" ] || exit 1; cp "$FAKE/lock.json" "$out" ;;
  "device info processes") [ -f "$FAKE/processes.json" ] || exit 1; cp "$FAKE/processes.json" "$out" ;;
  "device install app") exit "$(cat "$FAKE/install_rc" 2>/dev/null || echo 0)" ;;
  *) exit 9 ;;
esac
"""

FAKE_SECURITY = """#!/bin/bash
# 偽の security: cms -D はファイルをそのまま出す（偽のプロファイルは署名の無い plist）
[ "$1 $2 $3" = "cms -D -i" ] && exec cat "$4"
exit 9
"""

FAKE_OSASCRIPT = """#!/bin/bash
# 偽の osascript: 通知の文を 1 行ずつ残す
cat > /dev/null
echo "$2" >> "$FAKE/notes"
"""

FAKE_DEFAULTS = """#!/bin/bash
# 偽の defaults: export com.apple.dt.Xcode は FAKE の xcode.plist を出す（無ければ失敗）
[ "$1 $2" = "export com.apple.dt.Xcode" ] && [ -f "$FAKE/xcode.plist" ] && exec cat "$FAKE/xcode.plist"
exit 1
"""


class Rig:
    def __init__(self, tmp_path: Path):
        self.tmp = tmp_path
        self.bin = tmp_path / "bin"
        self.fake = tmp_path / "fake"
        self.home = tmp_path / "home"
        self.dir = tmp_path / "ios"
        self.logs = tmp_path / "logs"
        for d in (self.bin, self.fake, self.home):
            d.mkdir()
        fakes = {
            "xcodebuild": FAKE_XCODEBUILD.format(python=sys.executable, bundle_id=BUNDLE_ID),
            "xcrun": FAKE_XCRUN, "security": FAKE_SECURITY, "osascript": FAKE_OSASCRIPT, "defaults": FAKE_DEFAULTS,
        }
        for name, body in fakes.items():
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.cache = self.home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        self.devices([device()])
        self.locked(True)
        self.app_running(False)

    def devices(self, devs: list[dict]) -> None:
        (self.fake / "devices.json").write_text(json.dumps({"result": {"devices": devs}}))

    def locked(self, locked: bool | None) -> None:
        f = self.fake / "lock.json"
        if locked is None:
            f.unlink(missing_ok=True)
        else:
            f.write_text(json.dumps({"result": {"passcodeRequired": locked, "unlockedSinceBoot": True}}))

    def app_running(self, running: bool | None) -> None:
        """iPhone で動いているプロセス。None なら一覧を取れない"""
        f = self.fake / "processes.json"
        if running is None:
            f.unlink(missing_ok=True)
            return
        procs = [{"executable": "file:///sbin/launchd", "processIdentifier": 1},
                 {"executable": "file:///System/Library/CoreServices/SpringBoard.app/SpringBoard",
                  "processIdentifier": 34}]
        if running:
            procs.append({"executable": "file:///private/var/containers/Bundle/Application/"
                                        "0D1F0C6A-0000-4000-8000-000000000000/SplitTerm.app/SplitTerm",
                          "processIdentifier": 812})
        f.write_text(json.dumps({"result": {"deviceIdentifier": "x", "runningProcesses": procs}}))

    def installed(self, expires, **extra) -> None:
        self.dir.mkdir(exist_ok=True)
        (self.dir / "installed.json").write_text(json.dumps({"expires": expires, "build": "old", **extra}))

    def state(self) -> dict:
        return json.loads((self.dir / "installed.json").read_text())

    def cached(self, expires: int, app_id: str = APP_ID) -> Path:
        self.cache.mkdir(parents=True, exist_ok=True)
        p = self.cache / f"{uuid.uuid4()}.mobileprovision"
        p.write_bytes(profile(expires, app_id))
        return p

    def embedded_expiry(self) -> int:
        app = self.dir / "DerivedData/Build/Products/Release-iphoneos/SplitTerm.app"
        exp = plistlib.loads((app / "embedded.mobileprovision").read_bytes())["ExpirationDate"]
        return int(exp.replace(tzinfo=timezone.utc).timestamp())

    def calls(self, tool: str = "") -> list[str]:
        f = self.fake / "calls"
        lines = f.read_text().splitlines() if f.exists() else []
        return [c for c in lines if c.startswith(tool)]

    def notes(self) -> list[str]:
        f = self.fake / "notes"
        return f.read_text().splitlines() if f.exists() else []

    def run(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        base = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "FAKE": str(self.fake),
            "SPLITTERM_IOS_DIR": str(self.dir),
            "SPLITTERM_IOS_LOG_DIR": str(self.logs),
            "SPLITTERM_TEST_NOW": str(NOW),
            "SPLITTERM_TEST_PRESSURE_LEVEL": "1",
            "SPLITTERM_IOS_TEAM": TEAM,
            # 見つかったこと: ターミナル（UTF-8 のロケール）の bash 3.2 は "$name。" の全角を名前の一部と読む。
            # C ロケールでは通ってしまうので、ふだんのターミナルと同じロケールで動かす
            "LANG": "en_US.UTF-8",
        }
        base.update(env)
        base = {k: v for k, v in base.items() if v is not None}
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=base, capture_output=True, text=True,
                              timeout=60)


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


# --- いつ入れ直すか ---

def test_waits_while_plenty_left(rig: Rig):
    rig.installed(NOW + 49 * H)
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stderr
    assert "まだ入れ直しません" in r.stdout
    assert rig.calls() == []


def test_renews_while_locked_within_two_days(rig: Rig):
    rig.installed(NOW + 47 * H)
    old = rig.cached(NOW + 47 * H)
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stdout + r.stderr
    # 残りの少ないプロファイルをどけたので、新しい 7 日のプロファイルで作られる
    assert not old.exists()
    assert (rig.dir / "old-profiles" / old.name).exists()
    assert rig.embedded_expiry() == NOW + WEEK
    build = datetime.fromtimestamp(NOW).strftime("%Y%m%d%H%M")
    [xb] = rig.calls("xcodebuild")
    for part in ("-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", f"id={UDID}",
                 f"DEVELOPMENT_TEAM={TEAM}", f"CURRENT_PROJECT_VERSION={build}", "-configuration Release"):
        assert part in xb
    assert rig.calls("xcrun devicectl device install app") != []
    assert rig.state() == {"expires": NOW + WEEK, "build": build, "installed_at": NOW, "device": UDID}
    assert len(rig.notes()) == 1 and rig.notes()[0].startswith("入れ直しました")


def test_waits_while_the_app_is_in_use(rig: Rig):
    rig.installed(NOW + 47 * H)
    rig.locked(False)
    rig.app_running(True)
    r = rig.run("--if-needed")
    assert r.returncode == 6
    assert "SplitTerm が使われているので" in r.stdout
    assert rig.calls("xcodebuild") == []
    assert rig.notes() == []


def test_installs_while_unlocked_if_the_app_is_not_running(rig: Rig):
    # パスコードの無い iPhone はロック中と読めない。SplitTerm が動いていなければ閉じる心配は無い
    rig.installed(NOW + 47 * H)
    rig.locked(False)
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stdout
    assert rig.calls("xcrun devicectl device info processes") != []
    assert rig.state()["expires"] == NOW + WEEK


@pytest.mark.parametrize("listing", [None, {"result": {"deviceIdentifier": "x"}}])
def test_an_unreadable_process_list_counts_as_in_use(rig: Rig, listing):
    rig.installed(NOW + 47 * H)
    rig.locked(False)
    rig.app_running(None)
    if listing is not None:
        (rig.fake / "processes.json").write_text(json.dumps(listing))
    r = rig.run("--if-needed")
    assert r.returncode == 6
    assert rig.calls("xcodebuild") == []


def test_does_not_wait_for_the_lock_in_the_last_12_hours(rig: Rig):
    rig.installed(NOW + 11 * H)
    rig.locked(False)
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stdout
    assert rig.calls("xcrun devicectl device info") == []
    assert rig.state()["expires"] == NOW + WEEK


def test_without_a_record_it_is_due_but_not_urgent(rig: Rig):
    # 記録が無い（初めて・Xcode から入れた・記録が壊れた）なら期限は分からない。入れ直すが、SplitTerm が使われていれば待つ
    rig.locked(False)
    rig.app_running(True)
    r = rig.run("--if-needed")
    assert r.returncode == 6
    assert "入れたアプリの記録がありません" in r.stdout
    rig.app_running(False)
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stdout
    assert rig.state()["expires"] == NOW + WEEK


def test_an_expiry_that_is_not_a_number_counts_as_no_record(rig: Rig):
    # $(( )) は値の中の a[$(...)] を実行してしまう。整数でなければ記録が無いのと同じに扱う
    pwned = rig.tmp / "pwned"
    rig.installed(f"a[$(touch {pwned})]")
    r = rig.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "入れたアプリの記録がありません" in r.stdout
    assert not pwned.exists()


def test_manual_run_builds_now(rig: Rig):
    rig.installed(NOW + 150 * H)
    rig.locked(False)
    r = rig.run()
    assert r.returncode == 0, r.stdout
    assert rig.calls("xcodebuild") != []


# --- プロファイル ---

def test_keeps_a_fresh_profile_from_an_earlier_renewal(rig: Rig):
    # 前の回で新しくしたが入れられなかった: 手元のプロファイルは新しいので、どけずにそれで作る
    rig.installed(NOW + 5 * H)
    fresh = rig.cached(NOW + 150 * H)
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stdout
    assert fresh.exists()
    assert rig.state()["expires"] == NOW + 150 * H


def test_leaves_other_apps_profiles_alone(rig: Rig):
    rig.installed(NOW + 5 * H)
    other = rig.cached(NOW + H, app_id=f"{TEAM}.com.example.other")
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stdout
    assert other.exists()


def test_a_profile_with_an_unreadable_expiry_is_moved_aside(rig: Rig):
    rig.cache.mkdir(parents=True, exist_ok=True)
    odd = rig.cache / "odd.mobileprovision"
    odd.write_bytes(plistlib.dumps({"ExpirationDate": "soon", "Entitlements": {"application-identifier": APP_ID}}))
    r = rig.run()
    assert r.returncode == 0, r.stdout
    assert not odd.exists() and (rig.dir / "old-profiles" / odd.name).exists()


def test_a_profile_that_was_not_renewed_is_an_error(rig: Rig):
    rig.installed(NOW + 5 * H)
    (rig.fake / "stale").write_text("")
    r = rig.run("--if-needed")
    assert r.returncode == 1
    assert "プロファイルが新しくなりませんでした" in r.stdout
    assert rig.calls("xcrun devicectl device install") == []
    assert rig.state()["expires"] == NOW + 5 * H


# --- 見送りと失敗 ---

def test_skips_on_memory_pressure(rig: Rig):
    rig.installed(NOW + 47 * H)
    r = rig.run("--if-needed", SPLITTERM_TEST_PRESSURE_LEVEL="2")
    assert r.returncode == 3
    assert rig.calls() == []


def test_force_ignores_memory_pressure(rig: Rig):
    r = rig.run("--force", SPLITTERM_TEST_PRESSURE_LEVEL="2")
    assert r.returncode == 0, r.stdout
    assert rig.calls("xcodebuild") != []


def test_unreachable_phone_is_told_once_when_the_end_is_near(rig: Rig):
    rig.installed(NOW + 47 * H)
    rig.devices([device(state="unavailable")])
    r = rig.run("--if-needed")
    assert r.returncode == 5
    assert rig.notes() == []  # まだ 12 時間より先なので知らせない
    rig.installed(NOW + 11 * H)
    for _ in range(2):
        r = rig.run("--if-needed")
        assert r.returncode == 5
    assert rig.notes() == ["期限まで 11 時間です。iPhone に届きません（同じ Wi-Fi にいないか、電源が切れています）"]
    assert rig.calls("xcodebuild") == []


def test_build_failure_is_told_once_until_it_works(rig: Rig):
    rig.installed(NOW + 5 * H)
    (rig.fake / "build_rc").write_text("65")
    for _ in range(2):
        r = rig.run("--if-needed")
        assert r.returncode == 1
    assert len(rig.notes()) == 1 and rig.notes()[0].startswith("ビルドに失敗しました")
    (rig.fake / "build_rc").unlink()
    r = rig.run("--if-needed")
    assert r.returncode == 0, r.stdout
    assert rig.notes()[-1].startswith("入れ直しました")
    assert "failure" not in rig.state()


def test_install_failure_keeps_the_record(rig: Rig):
    rig.installed(NOW + 5 * H)
    (rig.fake / "install_rc").write_text("1")
    r = rig.run("--if-needed")
    assert r.returncode == 1
    assert rig.state()["expires"] == NOW + 5 * H
    assert rig.state()["failure"] == "install"


def test_unreadable_lock_state_counts_as_unreachable(rig: Rig):
    rig.installed(NOW + 47 * H)
    rig.locked(None)
    r = rig.run("--if-needed")
    assert r.returncode == 5
    assert rig.calls("xcodebuild") == []


# --- iPhone と Team を選ぶ ---

def test_two_phones_need_a_choice(rig: Rig):
    other = "00008110-0000000000000002"
    rig.devices([device(), device(udid=other)])
    r = rig.run()
    assert r.returncode == 1
    assert "SPLITTERM_IOS_DEVICE" in r.stdout
    r = rig.run(SPLITTERM_IOS_DEVICE=other)
    assert r.returncode == 0, r.stdout
    assert f"id={other}" in rig.calls("xcodebuild")[0]


def test_reads_devices_in_the_older_json_shape(rig: Rig):
    # Xcode 27 は properties を使い、古いキー（hardwareProperties など）は廃止予定。どちらでも読む
    rig.devices([{"hardwareProperties": {"udid": UDID, "platform": "iOS", "reality": "physical"},
                  "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"}}])
    r = rig.run()
    assert r.returncode == 0, r.stdout
    assert f"id={UDID}" in rig.calls("xcodebuild")[0]


def test_team_comes_from_xcode_settings(rig: Rig):
    teams = {"IDEProvisioningTeamByIdentifier": {"acct": [
        {"teamID": "PAIDTEAM01", "isFreeProvisioningTeam": False},
        {"teamID": TEAM, "isFreeProvisioningTeam": True, "teamType": "Personal Team"},
    ]}}
    (rig.fake / "xcode.plist").write_bytes(plistlib.dumps(teams))
    r = rig.run(SPLITTERM_IOS_TEAM=None)
    assert r.returncode == 0, r.stdout
    assert f"DEVELOPMENT_TEAM={TEAM}" in rig.calls("xcodebuild")[0]


def test_without_a_free_team_it_says_what_to_do(rig: Rig):
    r = rig.run(SPLITTERM_IOS_TEAM=None)
    assert r.returncode == 1
    assert "Xcode に Apple ID でサインイン" in r.stdout
    assert rig.calls("xcodebuild") == []


# --- 1 つずつ動かす ---

def test_another_run_in_progress_is_left_alone(rig: Rig):
    # 動いている入れ直しのふり（コマンドの名前に ios_reinstall.sh が入る）
    other = rig.tmp / "other" / "ios_reinstall.sh"
    other.parent.mkdir()
    other.write_text("sleep 30\n")
    proc = subprocess.Popen(["/bin/bash", str(other)])
    try:
        lock = rig.dir / "reinstall.lock"
        rig.dir.mkdir()
        lock.symlink_to(str(proc.pid))
        r = rig.run()
        assert r.returncode == 0
        assert "ほかの入れ直しが動いています" in r.stdout
        assert rig.calls() == []
        assert os.readlink(lock) == str(proc.pid)
    finally:
        proc.kill()
        proc.wait()


@pytest.mark.parametrize("owner", ["dead", "reused"])
def test_a_lock_left_by_a_crash_is_taken_over(rig: Rig, owner: str):
    # dead: 持ち主の pid がもう無い。reused: その pid を別のプロセス（ここでは pytest）が使っている
    if owner == "dead":
        p = subprocess.Popen(["/usr/bin/true"])
        p.wait()
        pid = p.pid
    else:
        pid = os.getpid()
    rig.dir.mkdir()
    lock = rig.dir / "reinstall.lock"
    lock.symlink_to(str(pid))
    r = rig.run()
    assert r.returncode == 0, r.stdout
    assert rig.calls("xcodebuild") != []
    assert not lock.is_symlink()


def test_unknown_option(rig: Rig):
    assert rig.run("--now").returncode == 2


@pytest.mark.parametrize("renew,urgent", [("168", "12"), ("170", "12"), ("48", "49"), ("2d", "12")])
def test_thresholds_must_leave_room_for_a_new_profile(rig: Rig, renew: str, urgent: str):
    # 見つかったこと: 線を 170 時間にして launchd で試したら、届いた 7 日のプロファイルも線を割って失敗になった
    r = rig.run("--if-needed", SPLITTERM_IOS_RENEW_H=renew, SPLITTERM_IOS_URGENT_H=urgent)
    assert r.returncode == 2
    assert rig.calls() == []


def test_the_longest_threshold_still_takes_a_new_profile(rig: Rig):
    rig.installed(NOW + 166 * H)
    r = rig.run("--if-needed", SPLITTERM_IOS_RENEW_H="167")
    assert r.returncode == 0, r.stdout
    assert rig.state()["expires"] == NOW + WEEK


def test_a_crash_is_told_once_and_not_reported_as_success(rig: Rig):
    # 見つかったこと: 後始末の trap が、set -u で落ちたときの終了コードを 0 にしていた。
    # 落ちたことはログと通知で知らせ（同じ失敗の間は 1 回だけ）、鍵も外す
    for _ in range(2):
        r = rig.run(SPLITTERM_TEST_NOW="soon")
        assert r.returncode != 0
        assert "unbound variable" in r.stderr
        assert "途中で止まりました" in r.stdout
        assert not (rig.dir / "reinstall.lock").is_symlink()
    assert rig.notes() == ["入れ直しが途中で止まりました（logs/ios_reinstall.log）"]
    assert rig.state()["failure"] == "crash"


def test_no_variable_runs_into_japanese_text():
    # "$name。" は UTF-8 のロケールで壊れる（上の LANG のコメント）。全角の前の変数は ${name} と書く
    for script in sorted((ROOT / "scripts").glob("*.sh")):
        for n, line in enumerate(script.read_text().splitlines(), 1):
            assert not re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]", line), f"{script.name}:{n}: {line}"


# --- launchd とプロジェクトの設定 ---

def test_launchd_checks_every_hour():
    p = plistlib.loads(PLIST.read_bytes())
    assert p["Label"] == PLIST.stem
    assert p["StartInterval"] == 3600
    bash, script, *args = p["ProgramArguments"]
    assert bash == "/bin/bash" and script.endswith("/scripts/ios_reinstall.sh") and args == ["--if-needed"]
    path = p["EnvironmentVariables"]["PATH"].split(":")
    assert "/usr/bin" in path and "/usr/sbin" in path  # xcrun・xcodebuild・jq と sysctl
    assert p["StandardOutPath"].endswith("/logs/ios_reinstall.log")


def test_docs_name_the_same_thresholds():
    # 数値の正本はスクリプトの既定値。docs/design.md「配布」と合わせる
    src = SCRIPT.read_text()
    renew = re.search(r'RENEW_H="\$\{SPLITTERM_IOS_RENEW_H:-(\d+)\}"', src).group(1)
    urgent = re.search(r'URGENT_H="\$\{SPLITTERM_IOS_URGENT_H:-(\d+)\}"', src).group(1)
    doc = (ROOT / "docs" / "design.md").read_text()
    start = doc.index("## 配布")
    section = doc[start:doc.index("\n## ", start + 1)]
    assert f"{renew} 時間" in section and f"{urgent} 時間" in section and "1 時間ごと" in section










def test_team_stays_out_of_git():
    # 自分の Team は Local.xcconfig（git に入れない）に置き、プロジェクトには書かない
    assert "DEVELOPMENT_TEAM" not in (ROOT / "ios/SplitTerm.xcodeproj/project.pbxproj").read_text()
    base = (ROOT / "ios/Config/Base.xcconfig").read_text()
    assert '#include? "Local.xcconfig"' in base
    assert not re.search(r"^DEVELOPMENT_TEAM", base, re.M)
    assert "ios/Config/Local.xcconfig" in (ROOT / ".gitignore").read_text().splitlines()


def test_script_reads_the_bundle_id_of_the_project():
    base = (ROOT / "ios/Config/Base.xcconfig").read_text()
    assert re.search(r"^PRODUCT_BUNDLE_IDENTIFIER = (.+)$", base, re.M).group(1) == BUNDLE_ID


def test_scheme_builds_the_app_target():
    pbx = (ROOT / "ios/SplitTerm.xcodeproj/project.pbxproj").read_text()
    scheme = (ROOT / "ios/SplitTerm.xcodeproj/xcshareddata/xcschemes/SplitTerm.xcscheme").read_text()
    target = re.search(r"(\w{24}) /\* SplitTerm \*/ = \{\s*isa = PBXNativeTarget;", pbx).group(1)
    assert f'BlueprintIdentifier = "{target}"' in scheme


def test_app_is_landscape_only_on_iphone_and_ipad():
    # 横持ちだけ（docs/design.md「画面構成」）。iPhone と iPad の両方に入れる
    base = (ROOT / "ios/Config/Base.xcconfig").read_text()
    land = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
    assert re.search(rf"^INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = {land}$", base, re.M)
    assert re.search(rf"^INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = {land}$", base, re.M)
    assert re.search(r"^TARGETED_DEVICE_FAMILY = 1,2$", base, re.M)
    assert re.search(r"^IPHONEOS_DEPLOYMENT_TARGET = 16\.0$", base, re.M)


def test_config_file_is_reachable_from_files_app():
    # 設定ファイル（Documents/config）を「ファイル」アプリと devicectl から触れる
    info = plistlib.loads((ROOT / "ios/Config/Info.plist").read_bytes())
    assert info["UIFileSharingEnabled"] is True
    base = (ROOT / "ios/Config/Base.xcconfig").read_text()
    assert re.search(r"^INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = YES$", base, re.M)
    assert (ROOT / "ios/SplitTerm/Resources/config.example").exists()


def test_package_minimum_matches_the_app():
    pkg = (ROOT / "ios/TermKit/Package.swift").read_text()
    assert ".iOS(.v16)" in pkg

