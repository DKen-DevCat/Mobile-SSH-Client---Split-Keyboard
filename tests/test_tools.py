"""設定ファイルを送るスクリプトと、公開鍵を取り込むスクリプト（docs/design.md「設定ファイル」「配布」）、
色の見比べ用の見本（scripts/colortest.sh。「描画と解像度」の「色」）。
偽の xcrun（devicectl）で動かす。macOS の道具に頼らないので Linux でも通る。"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import unicodedata
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


FAKE_SSH_KEYGEN = """#!/usr/bin/env python3
# 偽の ssh-keygen -lf: 鍵の本体の SHA-256 を ssh-keygen と同じ形で出す
import base64, hashlib, sys
line = open(sys.argv[-1]).readline().split()
blob = line[1].encode()
try:
    blob = base64.b64decode(line[1] + "=" * (-len(line[1]) % 4))
except Exception:
    pass
fp = base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
print(f"256 SHA256:{fp} splitterm (ECDSA)")
"""


def fingerprint(line: str) -> str:
    import base64
    import hashlib
    b = line.split()[1]
    try:
        blob = base64.b64decode(b + "=" * (-len(b) % 4))
    except Exception:
        blob = b.encode()
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


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
        for name, body in (("xcrun", FAKE_XCRUN), ("ssh-keygen", FAKE_SSH_KEYGEN)):
            f = self.bin / name
            f.write_text(body)
            f.chmod(0o755)
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
        # stdin は tty でない（エージェントや MCP から動かすのと同じ）
        return subprocess.run([str(ROOT / "scripts" / script), *args], env=e, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL)

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
    assert "--domain-type appDataContainer --domain-identifier io.github.dken-devcat.mobile-ssh-client-split-keyboard" in copy


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


def put_pub(rig: Rig, line: str) -> None:
    (rig.fake / "device/Documents").mkdir(parents=True, exist_ok=True)
    (rig.fake / "device/Documents/splitterm.pub").write_text(line + "\n")


def test_pubkey_is_added_once_with_the_matching_fingerprint(rig: Rig):
    put_pub(rig, KEY)
    r = rig.run("ios_pubkey.sh", "--fingerprint", fingerprint(KEY))
    assert r.returncode == 0, r.stderr
    auth = rig.home / ".ssh/authorized_keys"
    # 端末だけを許す（ポート転送・エージェント転送などは止める）
    assert auth.read_text() == "restrict,pty " + KEY + "\n"
    assert oct(auth.stat().st_mode & 0o777) == "0o600"
    r = rig.run("ios_pubkey.sh", "--fingerprint", fingerprint(KEY))
    assert "もう登録してあります" in r.stdout
    assert auth.read_text() == "restrict,pty " + KEY + "\n"


def test_pubkey_with_a_different_fingerprint_is_refused(rig: Rig):
    # 「ファイル」アプリで splitterm.pub を他人の鍵に替えられても、アプリの指紋と違えば足さない
    put_pub(rig, KEY)
    r = rig.run("ios_pubkey.sh", "--fingerprint", "SHA256:somethingelse")
    assert r.returncode == 1
    assert "違います" in r.stderr
    assert not (rig.home / ".ssh/authorized_keys").exists()


def test_pubkey_without_a_way_to_confirm_is_not_added(rig: Rig):
    put_pub(rig, KEY)
    r = rig.run("ios_pubkey.sh")
    assert r.returncode == 1
    assert "--fingerprint" in r.stderr
    assert not (rig.home / ".ssh/authorized_keys").exists()


def test_pubkey_print_shows_the_fingerprint_and_does_not_touch_authorized_keys(rig: Rig):
    put_pub(rig, KEY)
    r = rig.run("ios_pubkey.sh", "--print")
    assert r.returncode == 0
    assert r.stdout.splitlines() == [KEY, "指紋: " + fingerprint(KEY)]
    assert not (rig.home / ".ssh/authorized_keys").exists()


@pytest.mark.parametrize("line", [
    'command="rm -rf ~" ecdsa-sha2-nistp256 AAAA splitterm',
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA splitterm",
    "ecdsa-sha2-nistp256 AAAA splitterm extra",
    "ecdsa-sha2-nistp256 AAAA attacker",
])
def test_pubkey_rejects_anything_but_the_apps_key_line(rig: Rig, line: str):
    put_pub(rig, line)
    r = rig.run("ios_pubkey.sh", "--fingerprint", fingerprint(line) if len(line.split()) > 1 else "x")
    assert r.returncode == 1
    assert not (rig.home / ".ssh/authorized_keys").exists()


def test_pubkey_file_with_two_lines_is_refused(rig: Rig):
    # 1 行目に他人の鍵、2 行目に本物を置いて、見せる指紋と足す鍵を食い違わせる手を止める
    other = "ecdsa-sha2-nistp256 AAAAOTHERKEY splitterm"
    put_pub(rig, other + "\n" + KEY)
    r = rig.run("ios_pubkey.sh", "--fingerprint", fingerprint(KEY))
    assert r.returncode == 1
    assert "1 行ではありません" in r.stderr
    assert not (rig.home / ".ssh/authorized_keys").exists()


def test_an_old_unrestricted_line_gets_restricted(rig: Rig):
    put_pub(rig, KEY)
    ssh = rig.home / ".ssh"
    ssh.mkdir()
    (ssh / "authorized_keys").write_text("ssh-ed25519 AAAAothers me@mac\n" + KEY + "\n")
    r = rig.run("ios_pubkey.sh", "--fingerprint", fingerprint(KEY))
    assert r.returncode == 0, r.stderr
    assert (ssh / "authorized_keys").read_text() == "ssh-ed25519 AAAAothers me@mac\nrestrict,pty " + KEY + "\n"
    assert "restrict,pty を付けました" in r.stdout


def test_pubkey_missing_on_device(rig: Rig):
    r = rig.run("ios_pubkey.sh")
    assert r.returncode == 1
    assert "Mobile-SSH-Client---Split-Keyboard を一度開いてから" in r.stderr


def test_fingerprint_option_needs_a_value(rig: Rig):
    assert rig.run("ios_pubkey.sh", "--fingerprint").returncode == 2


# ─── scripts/colortest.sh（色の見比べ。Ghostty とアプリで同じものを流す）──────────────────

COLORTEST = ROOT / "scripts" / "colortest.sh"
ESCAPE = re.compile(r"\x1b\[[0-9;]*m")


def colortest(*args: str, shell: str = "sh") -> subprocess.CompletedProcess:
    """バイトで受けて UTF-8 に直す（実行する環境の locale に頼らない）。端末ではなく、パイプに流す"""
    r = subprocess.run([shell, str(COLORTEST), *args], capture_output=True, stdin=subprocess.DEVNULL,
                       env={"PATH": os.environ["PATH"], "LANG": "C"})
    return subprocess.CompletedProcess(r.args, r.returncode, r.stdout.decode("utf-8"), r.stderr.decode("utf-8"))


def visible_width(line: str) -> int:
    """端末で占める桁数（色の指定を除き、全角は 2）"""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in ESCAPE.sub("", line))


def test_colortest_is_a_posix_sh_script():
    text = COLORTEST.read_text(encoding="utf-8")
    assert text.startswith("#!/bin/sh\n")
    assert os.access(COLORTEST, os.X_OK)
    # POSIX sh と printf だけ（echo -e・bash の拡張・外のコマンドを使わない）
    assert "echo -e" not in text and "[[" not in text and "seq " not in text and "$'" not in text


def test_colortest_prints_true_color_and_256_color_and_16_color():
    r = colortest()
    assert r.returncode == 0, r.stderr
    out = r.stdout
    # true color（24bit）の指定と、256 色の指定の両方
    assert "\x1b[38;2;" in out and "\x1b[48;2;" in out
    assert "\x1b[38;5;" in out and "\x1b[48;5;" in out
    # 16 色（通常と明るい、文字と背景）と、太字
    for sgr in ("30", "37", "90", "97", "40", "47", "100", "107", "1"):
        assert f"\x1b[{sgr}m" in out, sgr
    assert "\x1b[1;31m" in out  # 太字の赤（bold-is-bright の見比べ）
    assert out.endswith("\x1b[0m")


def test_colortest_256_colors_cover_the_whole_table():
    out = colortest("256").stdout
    shown = {int(n) for n in re.findall(r"\x1b\[48;5;(\d+)m", out)}
    assert shown == set(range(256))


def test_colortest_true_color_bands_are_smooth_not_quantized():
    out = colortest("true").stdout
    triples = [tuple(map(int, m)) for m in re.findall(r"\x1b\[48;2;(\d+);(\d+);(\d+)m", out)]
    reds = {r for r, _, _ in triples}
    # 256 色の立方体なら赤は 6 段（0・95・135・175・215・255）。滑らかな帯は、それよりずっと多くの値を使う
    assert len(reds) >= 40
    assert 0 in reds and 255 in reds
    assert all(0 <= v <= 255 for t in triples for v in t)


def test_colortest_has_claude_code_like_swatches():
    out = colortest("claude").stdout
    assert "\x1b[38;2;215;119;87m" in out  # オレンジ
    assert "\x1b[48;2;215;119;87m" in out
    assert "38;5;" not in out  # 256 色に丸めた色は混ぜない（true color の見本だけ）


def test_colortest_bold_section_compares_bold_and_normal():
    out = colortest("bold").stdout
    for n in range(8):
        assert f"\x1b[{30 + n}m" in out and f"\x1b[1;{30 + n}m" in out and f"\x1b[{90 + n}m" in out
    assert "\x1b[1;38;5;1m" in out and "\x1b[38;5;9m" in out  # 256 色の 1 と 9
    assert "\x1b[1;38;2;205;49;49m" in out and "\x1b[38;2;205;49;49m" in out  # true color は太字でも変わらない


def test_colortest_sections_are_separate():
    kinds = {
        "16": ("\x1b[30m", ("38;2;", "48;5;")),
        "256": ("\x1b[48;5;196m", ("38;2;", "48;2;")),
        "true": ("\x1b[48;2;", ("38;5;", "48;5;")),
        "claude": ("\x1b[38;2;215;119;87m", ("38;5;", "48;5;")),
        "bold": ("\x1b[1;31m", ("48;2;", "48;5;")),
    }
    for section, (has, lacks) in kinds.items():
        r = colortest(section)
        assert r.returncode == 0, (section, r.stderr)
        assert has in r.stdout, section
        for s in lacks:
            assert s not in r.stdout, (section, s)
    assert colortest("all").stdout.count("\x1b[") > colortest("256").stdout.count("\x1b[")


def test_colortest_unknown_section_is_a_usage_error():
    r = colortest("nope")
    assert r.returncode == 2
    assert "usage" in r.stderr and r.stdout == ""


def test_colortest_only_changes_colors_and_fits_a_phone_screen():
    out = colortest().stdout
    # 色の指定（ESC [ … m）のほかの制御列（カーソルの移動・画面消去・OSC）を出さない
    assert "\x1b" not in ESCAPE.sub("", out)
    # 1 行が 13 mini のシェルの桁数（85% 表示で 57）に収まる
    assert max(visible_width(line) for line in out.split("\n")) <= 57


def test_colortest_gives_the_same_output_under_dash():
    dash = shutil.which("dash")
    if dash is None:
        pytest.skip("dash が無い")
    assert colortest(shell=dash).stdout == colortest().stdout
