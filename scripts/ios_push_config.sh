#!/bin/bash
# Mac の設定ファイル 1 枚を、iPhone・iPad の SplitTerm へ送る（docs/design.md「設定ファイル」）。
# アプリはファイルが変わったのを見て、すぐ読み直す（開いていなければ次に開いたとき）。
# 使い方: scripts/ios_push_config.sh [--init]
#   --init  設定ファイルが無ければ、全項目の説明付きの見本から作る（送らない）
# 環境変数: SPLITTERM_CONFIG（既定 ~/.config/splitterm/config）/ SPLITTERM_IOS_DEVICE
# 終了コード: 0 = 送った・作った / 1 = 失敗 / 2 = 引数誤り
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_device.sh"

CONFIG="${SPLITTERM_CONFIG:-$HOME/.config/splitterm/config}"
EXAMPLE="$ROOT/ios/SplitTerm/Resources/config.example"
INIT=0
for a in "$@"; do
  case "$a" in
    --init) INIT=1 ;;
    -h|--help) sed -n 2,8p "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [ "$INIT" = 1 ]; then
  if [ -e "$CONFIG" ]; then
    echo "もうあります: ${CONFIG}"
  else
    mkdir -p "$(dirname "$CONFIG")"
    cp "$EXAMPLE" "$CONFIG"
    echo "作りました: ${CONFIG}（host の行を書いてから、もう一度このスクリプトを引数なしで動かす）"
  fi
  exit 0
fi

[ -f "$CONFIG" ] || { echo "設定ファイルがありません: ${CONFIG}（--init で見本から作れます）" >&2; exit 1; }
pick_device
xcrun devicectl device copy to --device "$UDID" --timeout 60 \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source "$CONFIG" --destination Documents/config > "$DIR/push_config.log" 2>&1 \
  || { echo "送れませんでした（${DIR}/push_config.log）。SplitTerm を一度開いてから、もう一度試してください" >&2; exit 1; }
echo "送りました: ${CONFIG} → ${UDID}"
