"""設定ファイルを送るスクリプトと、公開鍵を取り込むスクリプト（docs/design.md「設定ファイル」「配布」）。
偽の xcrun（devicectl）で動かす。macOS の道具に頼らないので Linux でも通る。"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
UDID = "00008110-0000000000000001"
KEY = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBExample splitterm"

FAKE_XCRUN = """#!/bin/bash
# 偽の xcrun: 呼び出しを残し、devicectl の一覧と copy を真似る
echo "$*" >> "$FAKE/calls"
args=("$@")
out=""; src=""; dst=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --json-output) out="${args[i+1]}" ;;
    --source) src="${args[i+1]}" ;;
    --destination) dst="${args[i+1]}" ;;
  esac
done
case "$*" in
  "devicectl list devices"*) cp "$FAKE/devices.json" "$out" ;;
  "devicectl device copy to"*)
    [ -f "$FAKE/copy_fails" ] && exit 1
    mkdir -p "$FAKE/device/$(dirname "$dst")"; cp "$src" "$FAKE/device/$dst" ;;
  "devicectl device copy from"*)
    [ -f "$FAKE/device/$src" ] || exit 1
    cp "$FAKE/device/$src" "$dst" ;;
esac
"""


def device(udid: str) -> dict:
    return {"properties": {
        "hardware": {"udid": udid, "platform": "iOS", "reality": "physical"},
        "connection": {"pairingState": "paired", "state": "connected"},
    }}


class Rig:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.fake = tmp / "fake"
        self.bin = tmp / "bin"
        self.home = tmp / "home"
        for d in (self.fake, self.bin, self.home):
            d.mkdir()
        xcrun = self.bin / "xcrun"
        xcrun.write_text(FAKE_XCRUN)
        xcrun.chmod(0o755)
        self.devices([UDID])

    def devices(self, udids: list[str]) -> None:
        (self.fake / "devices.json").write_text(json.dumps({"result": {"devices": [device(u) for u in udids]}}))

    def run(self, script: str, *args: str, **env: str) -> subprocess.CompletedProcess:
        e = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.home),
            "FAKE": str(self.fake),
            "SPLITTERM_IOS_DIR": str(self.tmp / "state"),
            "LANG": "en_US.UTF-8",
        }
        e.update(env)
        return subprocess.run([str(ROOT / "scripts" / script), *args], env=e, capture_output=True, text=True)

    def calls(self) -> list[str]:
        p = self.fake / "calls"
        return p.read_text().splitlines() if p.exists() else []


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def test_init_creates_the_documented_example(rig: Rig):
    r = rig.run("ios_push_config.sh", "--init")
    assert r.returncode == 0, r.stderr
    made = rig.home / ".config/splitterm/config"
    assert made.read_text() == (ROOT / "ios/SplitTerm/Resources/config.example").read_text()
    assert rig.calls() == []  # 作るだけで送らない
    # 2 回目は上書きしない
    made.write_text("host = mac me@mac\n")
    assert rig.run("ios_push_config.sh", "--init").returncode == 0
    assert made.read_text() == "host = mac me@mac\n"


def test_push_copies_into_the_app_documents(rig: Rig):
    cfg = rig.home / ".config/splitterm/config"
    cfg.parent.mkdir(parents=True)
    cfg.write_text("font-size = 11\n")
    r = rig.run("ios_push_config.sh")
    assert r.returncode == 0, r.stderr
    assert (rig.fake / "device/Documents/config").read_text() == "font-size = 11\n"
    copy = [c for c in rig.calls() if "copy to" in c][0]
    assert f"--device {UDID}" in copy
    assert "--domain-type appDataContainer --domain-identifier io.github.dken-devcat.splitterm" in copy


def test_push_without_a_config_says_how_to_make_one(rig: Rig):
    r = rig.run("ios_push_config.sh")
    assert r.returncode == 1
    assert "--init" in r.stderr


def test_push_honours_a_custom_path_and_device(rig: Rig):
    cfg = rig.tmp / "my.conf"
    cfg.write_text("keyboard = kana\n")
    rig.devices([UDID, "00008110-0000000000000002"])
    assert rig.run("ios_push_config.sh", SPLITTERM_CONFIG=str(cfg)).returncode == 1  # 2 台は選ばせる
    r = rig.run("ios_push_config.sh", SPLITTERM_CONFIG=str(cfg), SPLITTERM_IOS_DEVICE="00008110-0000000000000002")
    assert r.returncode == 0, r.stderr
    assert "--device 00008110-0000000000000002" in rig.calls()[-1]


def test_push_failure_is_reported(rig: Rig):
    cfg = rig.home / ".config/splitterm/config"
    cfg.parent.mkdir(parents=True)
    cfg.write_text("")
    (rig.fake / "copy_fails").touch()
    r = rig.run("ios_push_config.sh")
    assert r.returncode == 1
    assert "送れませんでした" in r.stderr


def test_pubkey_is_added_once(rig: Rig):
    (rig.fake / "device/Documents").mkdir(parents=True)
    (rig.fake / "device/Documents/splitterm.pub").write_text(KEY + "\n")
    r = rig.run("ios_pubkey.sh")
    assert r.returncode == 0, r.stderr
    auth = rig.home / ".ssh/authorized_keys"
    assert auth.read_text() == KEY + "\n"
    assert oct(auth.stat().st_mode & 0o777) == "0o600"
    r = rig.run("ios_pubkey.sh")
    assert "もう登録してあります" in r.stdout
    assert auth.read_text() == KEY + "\n"


def test_pubkey_print_does_not_touch_authorized_keys(rig: Rig):
    (rig.fake / "device/Documents").mkdir(parents=True)
    (rig.fake / "device/Documents/splitterm.pub").write_text(KEY + "\n")
    r = rig.run("ios_pubkey.sh", "--print")
    assert r.returncode == 0
    assert r.stdout.strip() == KEY
    assert not (rig.home / ".ssh/authorized_keys").exists()


def test_pubkey_rejects_anything_but_an_ecdsa_key(rig: Rig):
    (rig.fake / "device/Documents").mkdir(parents=True)
    (rig.fake / "device/Documents/splitterm.pub").write_text("command=\"rm -rf ~\" ssh-ed25519 AAAA\n")
    r = rig.run("ios_pubkey.sh")
    assert r.returncode == 1
    assert not (rig.home / ".ssh/authorized_keys").exists()


def test_pubkey_missing_on_device(rig: Rig):
    r = rig.run("ios_pubkey.sh")
    assert r.returncode == 1
    assert "SplitTerm を一度開いてから" in r.stderr
