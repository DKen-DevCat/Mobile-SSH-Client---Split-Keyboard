#!/bin/bash
# iPhone・iPad の Mobile-SSH-Client---Split-Keyboard の公開鍵（Secure Enclave の鍵）を取ってきて、この Mac の
# authorized_keys に足す。秘密鍵は端末の外に出ない。取ってくるのは、アプリが書類フォルダに置いた公開鍵（splitterm.pub）だけ。
# そのファイルは「ファイル」アプリから書き換えられるので、足す前に指紋をアプリの表示（＋ →「公開鍵をコピー」）と見比べる。
# 足す行には restrict,pty を付ける（ポート転送・エージェント転送などを止め、端末だけを許す）。
# 使い方: scripts/ios_pubkey.sh [--print] [--fingerprint SHA256:...]
#   --print        表示するだけで、authorized_keys には足さない
#   --fingerprint  アプリに出た指紋。これと一致したときだけ、聞かずに足す（エージェントや MCP から使うとき）
# 指定が無ければ、端末（tty）で指紋を見せて y で足す。tty が無ければ足さない
# 終了コード: 0 = 足した・もうあった・表示した / 1 = 失敗・指紋が違う・確かめられない / 2 = 引数誤り
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_device.sh"

PRINT=0
EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --print) PRINT=1 ;;
    --fingerprint) [ $# -ge 2 ] || { echo "--fingerprint には指紋を続けます" >&2; exit 2; }; EXPECT="$2"; shift ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

pick_device
PUB="$DIR/splitterm.pub"
rm -f "$PUB"
xcrun devicectl device copy from --device "$UDID" --timeout 60 \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Documents/splitterm.pub --destination "$PUB" > "$DIR/pubkey.log" 2>&1 \
  || { echo "公開鍵を取れませんでした（${DIR}/pubkey.log）。Mobile-SSH-Client---Split-Keyboard を一度開いてから、もう一度試してください" >&2; exit 1; }
# 中身は 1 行だけ（2 行目以降に別の鍵を混ぜて、見せる指紋と足す鍵を食い違わせないため）
if [ "$(grep -c . "$PUB")" != 1 ]; then
  echo "公開鍵のファイルが 1 行ではありません。足しません" >&2
  exit 1
fi
line="$(grep . "$PUB")"
# 鍵の種類と本体（base64）だけを受け付ける。オプション（command= など）や余計な語は通さない
if ! printf '%s' "$line" | grep -Eq '^ecdsa-sha2-nistp256 [A-Za-z0-9+/]+=* splitterm$'; then
  echo "公開鍵の形が違います: ${line}" >&2
  exit 1
fi
# 指紋は、確かめたこの 1 行から計算する（足すのもこの 1 行）
CHECKED="$DIR/splitterm.checked.pub"
printf '%s\n' "$line" > "$CHECKED"
fp="$(ssh-keygen -lf "$CHECKED" | awk '{print $2}')"
case "$fp" in SHA256:*) ;; *) echo "指紋を計算できませんでした" >&2; exit 1 ;; esac
echo "$line"
echo "指紋: ${fp}"
[ "$PRINT" = 1 ] && exit 0

if [ -n "$EXPECT" ]; then
  [ "$EXPECT" = "$fp" ] || { echo "指紋がアプリの表示（${EXPECT}）と違います。足しません" >&2; exit 1; }
elif [ -t 0 ]; then
  read -r -p "アプリの ＋ →「公開鍵をコピー」に出た指紋と同じなら y: " answer
  [ "$answer" = y ] || { echo "足しませんでした"; exit 1; }
else
  echo "指紋を確かめられないので足しません（--fingerprint でアプリに出た指紋を渡してください）" >&2
  exit 1
fi

AUTH="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
key="$(printf '%s' "$line" | awk '{print $2}')"
if [ -f "$AUTH" ] && grep -qF "$key" "$AUTH"; then
  if grep -F "$key" "$AUTH" | grep -qv '^restrict,pty '; then
    # 前に restrict,pty なしで足した行は、付けた行に替える
    awk -v k="$key" -v l="restrict,pty $line" 'index($0, k) && $0 !~ /^restrict,pty / { print l; next } { print }' \
      "$AUTH" > "$AUTH.tmp" && chmod 600 "$AUTH.tmp" && mv "$AUTH.tmp" "$AUTH"
    echo "登録してあった行に restrict,pty を付けました: ${AUTH}"
  else
    echo "もう登録してあります: ${AUTH}"
  fi
  exit 0
fi
printf 'restrict,pty %s\n' "$line" >> "$AUTH"
chmod 600 "$AUTH"
echo "足しました: ${AUTH}"
