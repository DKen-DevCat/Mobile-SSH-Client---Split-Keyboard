# ios_push_config.sh・ios_pubkey.sh が読み込む共通の部分（単体では動かさない）。
# Mac と対になった iPhone（または iPad）を 1 台選んで UDID に入れる。SPLITTERM_IOS_DEVICE で選べる
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="$(sed -nE 's/^PRODUCT_BUNDLE_IDENTIFIER = (.+)$/\1/p' "$ROOT/ios/Config/Base.xcconfig")"
DIR="${SPLITTERM_IOS_DIR:-$ROOT/tmp/ios}"
mkdir -p "$DIR"

pick_device() {
  UDID="${SPLITTERM_IOS_DEVICE:-}"
  [ -n "$UDID" ] && return 0
  local devs="$DIR/devices.json" phones
  xcrun devicectl list devices --timeout 60 --json-output "$devs" >/dev/null 2>&1 \
    || { echo "端末の一覧を取れませんでした（xcrun devicectl list devices）" >&2; exit 1; }
  phones="$(jq -r '[.result.devices[]
      | select((.properties.hardware.platform // .hardwareProperties.platform) == "iOS"
          and (.properties.hardware.reality // .hardwareProperties.reality) == "physical"
          and (.properties.connection.pairingState // .connectionProperties.pairingState) == "paired")
      | (.properties.hardware.udid // .hardwareProperties.udid)] | unique | .[]' "$devs")"
  case "$(printf '%s' "$phones" | grep -c .)" in
    1) UDID="$phones" ;;
    0) echo "Mac と対になった端末がありません（README の準備を参照）" >&2; exit 1 ;;
    *) echo "端末が 2 台以上あります。SPLITTERM_IOS_DEVICE で UDID を選んでください" >&2; exit 1 ;;
  esac
}
