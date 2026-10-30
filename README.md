# SplitTerm

iPhone と iPad を横持ちにして、左右に分けたキーボードでシェルを挟む SSH ターミナル。自分の Mac の tmux（と Claude Code）を操作するためのフロントエンドで、通信の速さと操作感を最優先にしている。設定は Ghostty のように config ファイル 1 枚。配布は無料の Apple ID の署名で、Mac が期限の前に自動で入れ直す（lfm3-vl-server と同じ作り）。

設計書（正本）: [`docs/design.md`](docs/design.md)

## 構成

| 場所 | 中身 |
|---|---|
| `ios/SplitTerm/` | アプリ（UIKit）。Metal の描画、分割キーボード、入力ルータ、安全（ロック・画面の保護） |
| `ios/TermKit/` | Swift パッケージ。`TermCore`（設定・レイアウト・キーの変換など、Mac で `swift test`）、`TermSession`（SSH・エミュレータ・キーチェーン）、`TermKana`（かな漢字変換、AzooKey） |
| `ios/SplitTerm/Resources/config.example` | config の見本（全項目の説明付き。値はすべて既定値） |
| `scripts/` | 配布（`ios_reinstall.sh`）、config を送る（`ios_push_config.sh`）、公開鍵を登録する（`ios_pubkey.sh`） |
| `launchd/com.dken.splitterm-ios.plist` | 1 時間ごとに期限を見て入れ直す |
| `tests/` | スクリプトとプロジェクトの設定のテスト（pytest） |

## 準備（1 回だけ）

前提: iPhone・iPad は iOS / iPadOS 17 以上。Mac に Xcode（Apple ID でサインイン済み）と jq。接続先の Mac に tmux（`brew install tmux`）。Tailscale などで iPhone から Mac の SSH（リモートログイン）に届くこと。

1. iPhone・iPad を USB でつないで「信頼」し、「設定 > プライバシーとセキュリティ > デベロッパモード」をオンにする
2. 入れる（初回は証明書・端末の登録・App ID・プロファイルが自動で作られる）

   ```bash
   scripts/ios_reinstall.sh
   ```

3. 端末の「設定 > 一般 > VPN とデバイス管理」で「Apple Development: …」を信頼してから、SplitTerm を開く
4. config を作って接続先（`host = …`）を書き、端末へ送る

   ```bash
   scripts/ios_push_config.sh --init
   ```

   ```bash
   scripts/ios_push_config.sh
   ```

5. SplitTerm の公開鍵（Secure Enclave の鍵。秘密鍵は端末から出ない）を、この Mac の `~/.ssh/authorized_keys` に足す

   ```bash
   scripts/ios_pubkey.sh
   ```

6. 自動の入れ直しを登録する（リポジトリを `~/Mobile-SSH-Client---Split-Keyboard` 以外に置いたら、plist の 3 か所のパスを直す）

   ```bash
   cp launchd/com.dken.splitterm-ios.plist ~/Library/LaunchAgents/
   ```

   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dken.splitterm-ios.plist
   ```

初めて接続すると、ホスト鍵の指紋を確かめる画面が出る。Mac の指紋は次で見られる。

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

## ふだん

| すること | コマンド・操作 |
|---|---|
| コードを変えたので入れ直す | `scripts/ios_reinstall.sh` |
| 設定を変える（Mac で） | `~/.config/splitterm/config` を直して `scripts/ios_push_config.sh`。開いているアプリにもすぐ効く |
| 設定を変える（端末で） | ＋ →「設定を編集」、または「ファイル」アプリ > この iPhone 内 > SplitTerm > config |
| 画面に頼らない部分のテスト（Mac） | `(cd ios/TermKit && swift test)` |
| スクリプトのテスト | `python3 -m pytest tests` |
| Xcode で開く | 先に `ios/Config/Local.xcconfig` を作る（`Local.xcconfig.example`）。`open ios/SplitTerm.xcodeproj` |
| アイコンを作り直す | `python3 scripts/gen_icon.py`（Pillow が要る） |

### 環境変数

| 変数 | 既定 | 用途 |
|---|---|---|
| `SPLITTERM_CONFIG` | `~/.config/splitterm/config` | `ios_push_config.sh` が送る config |
| `SPLITTERM_IOS_DEVICE` | Mac と対になった端末が 1 台ならそれ | 入れる・送る端末の UDID |
| `SPLITTERM_IOS_TEAM` | Xcode の設定の無料の Team | 署名する Team ID |
| `SPLITTERM_IOS_RENEW_H` | `48` | 期限の残りがこれ（時間）を切ったら入れ直す。168（7 日）未満 |
| `SPLITTERM_IOS_URGENT_H` | `12` | 残りがこれを切ったら、端末のロックを待たない |
| `SPLITTERM_IOS_DIR` / `SPLITTERM_IOS_LOG_DIR` | `tmp/ios` / `logs` | 記録とビルドの置き場所 / ログの置き場所 |

`ios_reinstall.sh` の終了コード: 0 = 入れ直した・まだ要らない・ほかの実行中 / 1 = 失敗 / 2 = 引数誤り / 3 = メモリに余裕が無く見送った / 5 = 端末に届かず見送った / 6 = SplitTerm が使われているので見送った

## 使い方の要点

- **キーボード**: US（Mac 配列の分割。caps lock の位置が control、esc は左下）とかなフリック（12 キー × 左右、AzooKey でかな漢字変換）。環境バーの「US / かな」で切り替え
- **修飾キー**: 押しながらでも、タップしてワンショットでも効く。command はアプリ内（⌘C コピー、⌘V ペースト、⌘− / ⌘= 倍率）
- **シェル**: 縦ドラッグでスクロールバック、長押し→ドラッグで選択、ダブルタップで単語、2 本指タップでメニュー、ピンチで倍率（85% / 100%）。vim・tmux・htop がマウスを求めたらマウスとして送る
- **切れたら**: 前面に戻った・回線が変わった・通信が切れたときに自動で繋ぎ直し、tmux のセッションに戻る。シェルを exit したタブは、タップで繋ぎ直す
- **iPad**: ハードウェアキーボードをつなぐと画面のキーボードが消え、シェルが全面になる

## 状態

設計書の段階 1〜4（接続と表示、横持ちのキーボード、タッチ操作、安全）を実装した。開発に使った環境（Linux）では Swift と Xcode が使えないため、**まだビルドも実機での確認もしていない**。最初に Mac で `swift test` とビルドを通す（設計書「未決事項」）。
