#!/bin/bash
# iPhone・iPad の SplitTerm の公開鍵（Secure Enclave の鍵）を取ってきて、この Mac の authorized_keys に足す。
# 秘密鍵は端末の外に出ない。取ってくるのは、アプリが書類フォルダに置いた公開鍵（splitterm.pub）だけ。
# 使い方: scripts/ios_pubkey.sh [--print]
#   --print  表示するだけで、authorized_keys には足さない
# 終了コード: 0 = 足した・もうあった・表示した / 1 = 失敗 / 2 = 引数誤り
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_device.sh"

PRINT=0
for a in "$@"; do
  case "$a" in
    --print) PRINT=1 ;;
    -h|--help) sed -n 2,7p "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

pick_device
PUB="$DIR/splitterm.pub"
rm -f "$PUB"
xcrun devicectl device copy from --device "$UDID" --timeout 60 \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Documents/splitterm.pub --destination "$PUB" > "$DIR/pubkey.log" 2>&1 \
  || { echo "公開鍵を取れませんでした（${DIR}/pubkey.log）。SplitTerm を一度開いてから、もう一度試してください" >&2; exit 1; }
line="$(head -n 1 "$PUB")"
case "$line" in
  "ecdsa-sha2-nistp256 "*) ;;
  *) echo "公開鍵の形が違います: ${line}" >&2; exit 1 ;;
esac
echo "$line"
[ "$PRINT" = 1 ] && exit 0

AUTH="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
key="$(printf '%s' "$line" | awk '{print $2}')"
if [ -f "$AUTH" ] && grep -qF "$key" "$AUTH"; then
  echo "もう登録してあります: ${AUTH}"
  exit 0
fi
printf '%s\n' "$line" >> "$AUTH"
chmod 600 "$AUTH"
echo "足しました: ${AUTH}"
