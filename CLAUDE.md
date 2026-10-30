# SplitTerm（Mobile-SSH-Client---Split-Keyboard）

開発運用ルールはグローバル `~/.claude/CLAUDE.md` を正本とする。ここにはこのプロジェクト固有の事項だけを置く。

## 正本

- 要件・設計の正本は `docs/design.md`。設計を変えたら設計書も同じ変更で直す
- 配布の作り（無料の署名・`scripts/ios_reinstall.sh`・launchd）は lfm3-vl-server を踏襲する。スクリプトを直すときは、向こうの `scripts/ios_reinstall.sh` と `tests/test_ios.py` との違いを意識する
- config の項目を足したら、`ConfigParser`・`ios/SplitTerm/Resources/config.example`・設計書「設定ファイル」の 3 つをそろえる（`ConfigParserTests` が見本と既定値の一致を確かめる）

## 不変の制約

- 横持ちだけ。縦持ちとシステムキーボードは使わない
- 端末ごとに寸法を作り分けない。配置は `LayoutEngine` で画面サイズ・セーフエリア・入力手段から算出する
- 設定は config ファイル 1 枚。設定画面を作らない。秘密（鍵・パスワード）は config に書かない
- 鍵は Secure Enclave（端末の外に出さない）。ホスト鍵が変わったら接続を止める（受け入れる道を作らない）
- ターミナルの内容はディスクに書かず、外へ送らない（テレメトリ・クラウド同期・AI 機能を持たない）
- 受信の解釈はメインスレッドで行わない。描画は Metal で、変化が無ければ描かない
- 最低 OS は iOS / iPadOS 17。古い OS のために操作感を落とさない。依存は公式か保守の続く最新の版だけ（非公式のフォーク・保守の止まった版は使わない）
- 接続先は信頼しない（`isProcessTrusted` は false。OSC 52・DECRQCRA・題名の送り返しに答えない）。かな漢字変換は学習しない
- 段階の呼び方は設計書「技術スタックと段階計画」の表に合わせる

## 確かめ方

- `(cd ios/TermKit && swift test)`（Mac）
- `python3 -m pytest tests`（`test_ios.py` の多くは macOS の道具に頼るので Mac で流す）
