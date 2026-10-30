#!/bin/bash
# iPhone・iPad アプリ（ios/）を無料の署名で作り直して、iPhone へ入れ直す（docs/design.md「配布」）。
# 使い方: scripts/ios_reinstall.sh [--if-needed] [--force]
#   --if-needed  launchd から 1 時間ごとに呼ぶ形。入れたアプリの期限の残りが SPLITTERM_IOS_RENEW_H 時間を切ったら、
#                iPhone がロックされているか SplitTerm が動いていない時に入れ直す（残りが SPLITTERM_IOS_URGENT_H 時間を切ったら待たない）
#   引数なし     今すぐ作り直して入れる（コードを変えたとき）
#   --force      メモリの圧迫を見ない
# 無料のプロファイルは 7 日で切れる。Xcode は手元に残った有効なプロファイルを使い続けるので、このアプリの
# プロファイルで残りが SPLITTERM_IOS_RENEW_H 時間を切ったものを tmp/ios/old-profiles へどけてからビルドする（lfm3-vl-server の N0 で実測）
# 環境変数: SPLITTERM_IOS_DEVICE / SPLITTERM_IOS_TEAM / SPLITTERM_IOS_RENEW_H / SPLITTERM_IOS_URGENT_H / SPLITTERM_IOS_DIR / SPLITTERM_IOS_LOG_DIR（README 参照）
# 終了コード: 0 = 入れ直した・まだ要らない・ほかの実行中 / 1 = 失敗 / 2 = 引数誤り
#             3 = メモリが足りず見送った / 5 = iPhone に届かず見送った / 6 = SplitTerm が使われているので見送った
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IF_NEEDED=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --if-needed) IF_NEEDED=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n 2,12p "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

RENEW_H="${SPLITTERM_IOS_RENEW_H:-48}"
URGENT_H="${SPLITTERM_IOS_URGENT_H:-12}"
# 新しいプロファイルは 7 日（168 時間）。入れ直す線がそれ以上だと、新しいものでも線を割って失敗になる（N0 で実際に起きた）
for v in "$RENEW_H" "$URGENT_H"; do
  case "$v" in ""|*[!0-9]*) echo "SPLITTERM_IOS_RENEW_H と SPLITTERM_IOS_URGENT_H は時間（整数）で指定します" >&2; exit 2 ;; esac
done
if [ "$RENEW_H" -ge 168 ] || [ "$URGENT_H" -gt "$RENEW_H" ]; then
  echo "SPLITTERM_IOS_RENEW_H は 168 時間（7 日）より短く、SPLITTERM_IOS_URGENT_H はそれ以下にします" >&2
  exit 2
fi
DIR="${SPLITTERM_IOS_DIR:-$ROOT/tmp/ios}"
LOGD="${SPLITTERM_IOS_LOG_DIR:-$ROOT/logs}"
NOW="${SPLITTERM_TEST_NOW:-$(date +%s)}"
BUNDLE_ID="$(sed -nE 's/^PRODUCT_BUNDLE_IDENTIFIER = (.+)$/\1/p' ios/Config/Base.xcconfig)"
APP="$DIR/DerivedData/Build/Products/Release-iphoneos/SplitTerm.app"
STATE="$DIR/installed.json"   # 入れたアプリの期限（expires）・ビルド・続いている失敗（failure）・知らせた期限（warned）
PROFILE_DIRS=("$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
              "$HOME/Library/MobileDevice/Provisioning Profiles")
mkdir -p "$DIR" "$LOGD"

log() { echo "[ios $(date '+%F %T')] $*"; }
notify() {
  osascript - "$1" >/dev/null 2>&1 <<'EOF' || true
on run argv
  display notification (item 1 of argv) with title "SplitTerm"
end run
EOF
}
# ISO 8601（plutil の出力）を秒に。読めなければ空
epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true; }
# プロファイル（CMS で署名した plist）を 1 回だけほどき、pval で値を読む。読めなければ空
decode() { security cms -D -i "$1" > "$DIR/profile.plist" 2>/dev/null || : > "$DIR/profile.plist"; }
pval() { plutil -extract "$1" raw -o - "$DIR/profile.plist" 2>/dev/null || true; }
state_get() { jq -r "$1" "$STATE"; }
state_set() { jq "$@" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }

# --- 1 つずつ動かす（launchd と手で打ったものが重ならないように） ---
# 鍵は持ち主の pid を指すシンボリックリンク（作るのと pid を書くのが 1 回で済む）。持ち主が死んでいるか、
# その pid が別のプロセスに使い回されていたら、前の実行が落ちて残ったものとして取り直す
LOCK="$DIR/reinstall.lock"
held_by_another() {
  local pid
  pid="$(readlink "$LOCK" 2>/dev/null)" || return 1
  [ "$pid" != "$$" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q 'ios_reinstall\.sh'
}
if ! ln -s "$$" "$LOCK" 2>/dev/null; then
  if held_by_another; then
    log "ほかの入れ直しが動いています"
    exit 0
  fi
  rm -f "$LOCK"
  if ! ln -s "$$" "$LOCK" 2>/dev/null; then
    log "ほかの入れ直しが動いています"
    exit 0
  fi
fi
# 終わり方はすべて quit を通す。通らずに終わったら（set -e・set -u で落ちた）失敗として記録して知らせる。
# bash 3.2 は set -u で落ちても、trap に $? = 0 を渡すことがある（テストで実測）
DONE=0
quit() { DONE=1; exit "$1"; }
on_exit() {
  local rc=$?
  if [ "$DONE" != 1 ]; then
    [ "$rc" != 0 ] || rc=1
    log "途中で止まりました（終了コード ${rc}。直前の行がエラーです）"
    if [ "$(jq -r '.failure // ""' "$STATE" 2>/dev/null)" != crash ]; then
      notify "入れ直しが途中で止まりました（logs/ios_reinstall.log）"
      state_set --arg k crash '.failure = $k' 2>/dev/null || true
    fi
  fi
  [ "$(readlink "$LOCK" 2>/dev/null)" != "$$" ] || rm -f "$LOCK"
  exit "$rc"
}
trap on_exit EXIT

jq -e 'type == "object"' "$STATE" >/dev/null 2>&1 || echo '{}' > "$STATE"
installed_exp="$(state_get '.expires // 0')"
case "$installed_exp" in ""|*[!0-9]*) installed_exp=0 ;; esac
# 記録が無ければ（初めて・Xcode から入れた・記録が壊れた）期限は分からない。入れ直しは要るが、急ぎにはしない
left_h=$(( (installed_exp - NOW) / 3600 ))
URGENT=0
if [ "$installed_exp" = 0 ]; then left_text="入れたアプリの記録がありません"
else
  [ "$left_h" -ge "$URGENT_H" ] || URGENT=1
  if [ "$installed_exp" -le "$NOW" ]; then left_text="期限が切れています"
  else left_text="期限まで ${left_h} 時間です"
  fi
fi

# 失敗を知らせる。同じ失敗が続く間は最初の 1 回だけ通知する（1 時間ごとに鳴らさない）
fail() {
  log "$2"
  [ "$(state_get '.failure // ""')" = "$1" ] || notify "$2"
  state_set --arg k "$1" '.failure = $k'
  quit 1
}
# 見送る。期限が近いのに見送るときだけ、入れたアプリの期限ごとに 1 回知らせる
skip() {
  log "$2"
  if [ "$IF_NEEDED" = 1 ] && [ "$URGENT" = 1 ] && [ "$(state_get '.warned // 0')" != "$installed_exp" ]; then
    notify "${left_text}。$2"
    state_set --argjson e "$installed_exp" '.warned = $e'
  fi
  quit "$1"
}

if [ "$IF_NEEDED" = 1 ] && [ "$installed_exp" != 0 ] && [ "$left_h" -ge "$RENEW_H" ]; then
  log "${left_text}。まだ入れ直しません"
  quit 0
fi
log "${left_text}。入れ直します"

if [ "$FORCE" != 1 ]; then
  level="${SPLITTERM_TEST_PRESSURE_LEVEL:-$(sysctl -n kern.memorystatus_vm_pressure_level)}"
  [ "$level" = 1 ] || skip 3 "メモリに余裕が無いので見送りました（pressure_level=${level}。手で入れるなら --force）"
fi

# --- iPhone を選ぶ（Mac と対になった iPhone が 1 台ならそれ） ---
DEVS="$DIR/devices.json"
xcrun devicectl list devices --timeout 60 --json-output "$DEVS" >/dev/null 2>&1 \
  || fail devicectl "iPhone の一覧を取れませんでした（xcrun devicectl list devices）"
JQ_DEV='def udid: .properties.hardware.udid // .hardwareProperties.udid;
  def phone: (.properties.hardware.platform // .hardwareProperties.platform) == "iOS"
    and (.properties.hardware.reality // .hardwareProperties.reality) == "physical"
    and (.properties.connection.pairingState // .connectionProperties.pairingState) == "paired";
  def state: .properties.connection.state // .connectionProperties.tunnelState // "";'
UDID="${SPLITTERM_IOS_DEVICE:-}"
if [ -z "$UDID" ]; then
  phones="$(jq -r "$JQ_DEV"' [.result.devices[] | select(phone) | udid] | unique | .[]' "$DEVS")"
  case "$(printf '%s' "$phones" | grep -c .)" in
    1) UDID="$phones" ;;
    0) fail device "Mac と対になった iPhone がありません（README の準備を参照）" ;;
    *) fail device "iPhone が 2 台以上あります。SPLITTERM_IOS_DEVICE で UDID を選んでください" ;;
  esac
fi
state="$(jq -r --arg u "$UDID" "$JQ_DEV"' [.result.devices[] | select(udid == $u) | state] | first // ""' "$DEVS")"
case "$state" in
  ""|unavailable) skip 5 "iPhone に届きません（同じ Wi-Fi にいないか、電源が切れています）" ;;
esac

# --- 使っている最中に閉じないよう、ロック中か SplitTerm が動いていない時に入れる（期限が近ければ待たない） ---
# パスコードの無い iPhone はロック中と読めないので、SplitTerm が動いているかでも見る
if [ "$IF_NEEDED" = 1 ] && [ "$URGENT" != 1 ]; then
  xcrun devicectl device info lockState --device "$UDID" --timeout 60 --json-output "$DIR/lock_state.json" \
    >/dev/null 2>&1 || skip 5 "iPhone に届きません（ロックの状態を読めませんでした）"
  if [ "$(jq -r '.result.passcodeRequired' "$DIR/lock_state.json")" != true ]; then
    xcrun devicectl device info processes --device "$UDID" --timeout 60 --json-output "$DIR/processes.json" \
      >/dev/null 2>&1 || skip 6 "SplitTerm が動いているか分からないので、ロックされるまで待ちます"
    # 一覧の形が読めなければ、動いているとみなして待つ
    running="$(jq -r 'if (.result.runningProcesses | type) == "array"
      then [.result.runningProcesses[] | .executable // "" | select(endswith("/SplitTerm.app/SplitTerm"))] | length
      else "unknown" end' "$DIR/processes.json" 2>/dev/null || true)"
    [ "$running" = 0 ] || skip 6 "SplitTerm が使われているので、ロックされるか閉じられるまで待ちます"
  fi
fi

# --- 無料の Team（Xcode にサインインした Apple ID の Personal Team） ---
TEAM="${SPLITTERM_IOS_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM="$(defaults export com.apple.dt.Xcode - 2>/dev/null \
    | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null \
    | jq -r '[.[][] | select(.isFreeProvisioningTeam == true) | .teamID] | unique | if length == 1 then .[0] else empty end' \
      2>/dev/null || true)"
fi
[ -n "$TEAM" ] || fail team "無料の Team が分かりません。Xcode に Apple ID でサインインするか、SPLITTERM_IOS_TEAM を指定してください"

# --- 残りの少ないプロファイルをどけて、Xcode に新しく作らせる（このアプリのものだけ） ---
for d in "${PROFILE_DIRS[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*.mobileprovision; do
    [ -f "$f" ] || continue
    decode "$f"
    [ "$(pval Entitlements.application-identifier)" = "$TEAM.$BUNDLE_ID" ] || continue
    exp="$(pval ExpirationDate)"
    e="$(epoch "$exp")"
    if [ -z "$e" ] || [ $(( e - NOW )) -lt $(( RENEW_H * 3600 )) ]; then
      mkdir -p "$DIR/old-profiles"
      mv "$f" "$DIR/old-profiles/"
      log "残りの少ないプロファイルをどけました: $(basename "$f")（期限 ${exp:-不明}）"
    fi
  done
done

# --- ビルド（署名とプロファイルの更新は Xcode に任せる） ---
BUILD="$(date -r "$NOW" +%Y%m%d%H%M)"
log "ビルドします（ビルド ${BUILD}、iPhone ${UDID}）"
xcodebuild -project ios/SplitTerm.xcodeproj -scheme SplitTerm -configuration Release -destination "id=$UDID" \
  -derivedDataPath "$DIR/DerivedData" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD" build > "$LOGD/ios_build.log" 2>&1 \
  || fail build "ビルドに失敗しました（logs/ios_build.log）。Xcode の Apple ID のサインインが切れていないか見てください"
decode "$APP/embedded.mobileprovision"
exp="$(pval ExpirationDate)"
new_exp="$(epoch "$exp")"
[ -n "$new_exp" ] || fail profile "作ったアプリのプロファイルを読めませんでした"
[ $(( new_exp - NOW )) -ge $(( RENEW_H * 3600 )) ] \
  || fail profile "プロファイルが新しくなりませんでした（期限 ${exp}）"

# --- 入れる ---
xcrun devicectl device install app --device "$UDID" --timeout 300 "$APP" > "$LOGD/ios_install.log" 2>&1 \
  || fail install "iPhone に入れられませんでした（logs/ios_install.log）"
jq -n --argjson e "$new_exp" --arg b "$BUILD" --argjson t "$NOW" --arg u "$UDID" \
  '{expires: $e, build: $b, installed_at: $t, device: $u}' > "$STATE"
msg="入れ直しました（ビルド ${BUILD}）。次の期限は $(date -r "$new_exp" '+%m/%d %H:%M')"
log "$msg"
notify "$msg"
quit 0
