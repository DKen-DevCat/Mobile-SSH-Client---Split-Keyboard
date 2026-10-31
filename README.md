# Mobile-SSH-Client---Split-Keyboard

iPhone と iPad を横持ちにして、左右に分けたキーボードでシェルを挟む SSH ターミナル。縦持ちでは Mac の JIS 配列のキーボードを下に置き、シェルの面をトラックパッドにして Mac と同じ手つきで操作する。自分の Mac の tmux（と Claude Code）を操作するためのフロントエンドで、通信の速さと操作感を最優先にしている。設定は Ghostty のように config ファイル 1 枚。配布は無料の Apple ID の署名で、Mac が期限の前に自動で入れ直す（lfm3-vl-server と同じ作り）。

設計書（正本）: [`docs/design.md`](docs/design.md)

## 構成

| 場所 | 中身 |
|---|---|
| `ios/SplitTerm/` | アプリ（UIKit）。Metal の描画、分割キーボード、入力ルータ、安全（ロック・画面の保護） |
| `ios/TermCore/` | 依存の無い Swift パッケージ。`TermCore`（設定・レイアウト・キーの変換・色を決める規則・Ghostty の配色の読み取りなど）と、Mac で動く `splitterm` コマンド・MCP サーバー |
| `ios/TermKit/` | 外の依存を持つ Swift パッケージ。`TermSession`（SSH・エミュレータ・キーチェーン）、`TermKana`（かな漢字変換、AzooKey） |
| `ios/SplitTerm/Resources/config.example` | config の見本（全項目の説明付き。値はすべて既定値） |
| `scripts/` | 配布（`ios_reinstall.sh`）、config を送る（`ios_push_config.sh`）、公開鍵を登録する（`ios_pubkey.sh`）、色の見比べ用の見本（`colortest.sh`） |
| `launchd/com.dken.splitterm-ios.plist` | 1 時間ごとに期限を見て入れ直す |
| `tests/` | スクリプトとプロジェクトの設定のテスト（pytest） |
| `site/` | 公開サイト（Get Started・llms.txt）。`site/src` の Markdown から `site/build.py` で `site/public` を作り、Cloudflare Pages が配る（`site/README.md`・`docs/site.md`） |
| `bench/` | AIO のベンチマーク。静的な検査（`aio_check.py`、CI）、エージェントの課題（`agent_bench.py`、手元の `claude -p`）、AI 検索の見え方（`visibility.md`） |
| `.github/workflows/ci.yml` | push のたびに、Linux でサイトの検査とテスト、Mac で `TermCore`・`splitterm` のテストとアプリ全体のビルド（Release、シミュレータ向け）。公開リポジトリなので無料 |

## 準備（1 回だけ）

前提: iPhone・iPad は iOS / iPadOS 17 以上。Mac に Xcode（Apple ID でサインイン済み）と jq。接続先の Mac に tmux（`brew install tmux`）。Tailscale などで iPhone から Mac の SSH（リモートログイン）に届くこと。

1. iPhone・iPad を USB でつないで「信頼」し、「設定 > プライバシーとセキュリティ > デベロッパモード」をオンにする
2. 入れる（初回は証明書・端末の登録・App ID・プロファイルが自動で作られる）

   ```bash
   scripts/ios_reinstall.sh
   ```

3. 端末の「設定 > 一般 > VPN とデバイス管理」で「Apple Development: …」を信頼してから、Mobile-SSH-Client---Split-Keyboard を開く
4. config を作って接続先（`host = …`）を書き、端末へ送る

   ```bash
   scripts/ios_push_config.sh --init
   ```

   ```bash
   scripts/ios_push_config.sh
   ```

5. Mobile-SSH-Client---Split-Keyboard の公開鍵（Secure Enclave の鍵。秘密鍵は端末から出ない）を、この Mac の `~/.ssh/authorized_keys` に足す。指紋が出るので、アプリの ＋ を長押し →「公開鍵をコピー」に出た指紋と同じなら `y`（足す行には `restrict,pty` が付く）

   ```bash
   scripts/ios_pubkey.sh
   ```

6. 自動の入れ直しを登録する（リポジトリを `~/Mobile-SSH-Client---Split-Keyboard` 以外に置いたら、plist の 4 か所のパスを直す）

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
| 設定を変える（端末で） | ＋ を長押し →「設定を編集」、または「ファイル」アプリ > この iPhone 内 > Mobile-SSH-Client---Split-Keyboard > config |
| 画面に頼らない部分のテスト（Mac） | `(cd ios/TermCore && swift test)` |
| `splitterm` を作る（Mac） | `swift build -c release --package-path ios/TermCore`（できるのは `ios/TermCore/.build/release/splitterm`） |
| エージェントに MCP を足す | `claude mcp add splitterm -- "$PWD/ios/TermCore/.build/release/splitterm" mcp` |
| 色を Mac の Ghostty にそろえる | `splitterm theme import --dry-run`（内容だけ確かめる）→ `splitterm theme import` → `splitterm push`。tmux の中を true color にするには、動いているセッションを 1 度作り直す（`tmux kill-session -t main`。中のプロセスは終わる） |
| 色を Ghostty と見比べる | 同じ見本を Ghostty と、アプリ（tmux の外と中）で流す: `scripts/colortest.sh`（16 色・256 色・true color・Claude Code の色・太字） |
| スクリプトのテスト | `python3 -m pytest tests` |
| Xcode で開く | 先に `ios/Config/Local.xcconfig` を作る（`Local.xcconfig.example`）。`open ios/SplitTerm.xcodeproj` |
| アイコン・favicon を作り直す | `node scripts/gen_brand.cjs`（Playwright が要る。元の絵は `brand/`。`--og` で OGP 画像も） |
| 公開サイトを作り直す・確かめる | `python3 site/build.py` と `python3 bench/aio_check.py`（`site/src` と `site/public` を一緒に入れる） |
| 公開サイトを手元で見る | `python3 site/serve.py` → http://127.0.0.1:8788/（英語は /en/。作り直してから配る） |

### 環境変数

| 変数 | 既定 | 用途 |
|---|---|---|
| `SPLITTERM_CONFIG` | `~/.config/splitterm/config` | `ios_push_config.sh` が送る config |
| `SPLITTERM_IOS_DEVICE` | Mac と対になった端末が 1 台ならそれ | 入れる・送る端末の UDID |
| `SPLITTERM_IOS_TEAM` | Xcode の設定の無料の Team | 署名する Team ID |
| `SPLITTERM_IOS_RENEW_H` | `48` | 期限の残りがこれ（時間）を切ったら入れ直す。168（7 日）未満 |
| `SPLITTERM_IOS_URGENT_H` | `12` | 残りがこれを切ったら、端末のロックを待たない |
| `SPLITTERM_IOS_DIR` / `SPLITTERM_IOS_LOG_DIR` | `tmp/ios` / `logs` | 記録とビルドの置き場所 / ログの置き場所 |

`ios_reinstall.sh` の終了コード: 0 = 入れ直した・まだ要らない・ほかの実行中 / 1 = 失敗 / 2 = 引数誤り / 3 = メモリに余裕が無く見送った / 5 = 端末に届かず見送った / 6 = Mobile-SSH-Client---Split-Keyboard が使われているので見送った

## 使い方の要点

- **画面**: シェルは画面の上端から下端まで。その上に 2 行が重なる。1 行目は時計・通信・電池・表示倍率、2 行目はタブと ＋（タップで新しいタブ、長押しで接続先の一覧と道具）。キーボード選択はシェルの右下
- **キーボード**: 5 つ（分割ローマ字・分割英語・日本語フリック・英語フリックのローマ字・英語）。分割は Mac の JIS 配列を実物の比率で（日本語の刻印なし、6・Y・H・N は左右の両方）。🌐 のタップで前のキーボード、長押しで選ぶ（シェルの右下のボタンからも）。左下の 📎 のキーで、写真・動画・音声・ファイルを送るメニューが出る（画面のキーボードを出している間は、シェルの左下の 📎 は隠れる）
- **修飾キー**: Mac と同じく押している間だけ効く。command はアプリ内（⌘C コピー、⌘V ペースト、⌘− / ⌘= 倍率、⌘T・⌘W・⌘1〜9 タブ）
- **ポインタ**（横持ち）: 左右の空白キー（小さな赤い丸つき）が空白とポインタを兼ねる。動かさずに離せば空白。動かせば、トラックパッドのように指の動いた分だけポインタが動き、速いほど遠くへ届く。動かした指を離して 1 秒以内に、動かさずに離すと左クリック（続けて叩けばダブルクリック）。左右を同時に押すと右クリック。シェルと上の 2 行（タブ・＋・倍率）をクリックできる。フリックの「空白」を 0.5 秒長押しすると、キーボード全体がトラックパッドになる（その間の別の指のタップが左クリック）
- **シェル**（横持ち）: 縦ドラッグでスクロールバック（指を離したら止まる）、長押し→ドラッグで選択、ダブルタップで空白で区切ったひとかたまり（URL・パスなど。折り返しもつなぐ）を選択、2 本指タップでメニュー、ピンチで倍率（85% / 100%）。選んだ文字は自動でクリップボードへ（表示は出さない。アプリを離れてから `clipboard-clear` で消える）。vim・tmux・htop がマウスを求めたらマウスとして送る（ダブルタップは選択のまま）
- **切れたら**: 前面に戻った・回線が変わった・通信が切れたときに自動で繋ぎ直し、tmux のセッションに戻る（tmux は `/opt/homebrew/bin` などの決まった場所も探す）。裏に回っても約 30 秒は繋いだままで、それを過ぎる前に自分で閉じ、戻るとすぐ繋ぎ直す。タブごとに別のセッション（`main`・`main-2`…）で、タブを閉じても tmux は残る。シェルを exit したタブは、タップで繋ぎ直す
- **色**: 手本は Mac の Ghostty。tmux の起動で `COLORTERM=truecolor` を渡して true color を tmux の中まで届け（tmux 3.2 以上は `-T RGB` も）、読みやすさの補正 `minimum-contrast` の既定は 1（補正しない）。`bold-is-bright`・`font-thicken`（どちらも既定 false）と `color-space` を足し、`splitterm theme import` で Ghostty の配色を config に取り込む
- **iPad**: ハードウェアキーボードをつなぐと画面のキーボードが消え、シェルが全面になる
- **縦持ち**: 上から iOS の状態バー・タブの 1 行（右端に 📎・倍率）・シェル・キーボード。キーボードは Mac の JIS 配列そのまま（分割しない。英数・かなを元の位置に戻し、空白はただの空白）で、キーは画面の幅 ÷ 14.5 の正方形（実物の比）。シェルの面はトラックパッドで、指で直接触る操作は無い: 1 本指でポインタ、タップでクリック、続けてダブルクリック（つながった文字列を選んでコピー）、タップしてすぐ触れ直して動かすとドラッグで選択、2 本指でスクロール、2 本指のタップで右クリック（メニュー）、ピンチで倍率。英数・かな・🌐 で英語とローマ字を切り替える（フリックは横持ちだけ）

## 状態

設計書の段階 1〜4（接続と表示、横持ちのキーボード、タッチ操作、安全）を実装した。開発に使った環境（Linux）では Swift と Xcode が使えないため、**まだビルドも実機での確認もしていない**。最初に Mac で `swift test` とビルドを通す（設計書「未決事項」）。
