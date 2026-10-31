# config（設定ファイルの全項目）

設定は config ファイル 1 枚で決める（Ghostty と同じ形）。設定画面は無い。このページの項目の表は、リポジトリの見本 `config.example` から自動で作っている（手で写していない）。

## 置き場所

| どこ | 場所 | 使い方 |
| --- | --- | --- |
| Mac | `~/.config/splitterm/config`（環境変数 `SPLITTERM_CONFIG` で変えられる） | 直してから `scripts/ios_push_config.sh`（または `splitterm push`）で端末へ送る。開いているアプリにもすぐ効く |
| iPhone・iPad | 「ファイル」アプリ > この iPhone 内 > Mobile-SSH-Client---Split-Keyboard > config | アプリの ＋ を長押し →「設定を編集」でも直せる。保存した瞬間に読み直して効く |

Mac で初めて作るときは、見本から作る: `splitterm config init`（または `scripts/ios_push_config.sh --init`）。

## 書き方

- 1 行に `key = value`。`#` で始まる行と空行は読み飛ばす
- 値の前後の空白は除く。空白を残したい値は `"..."` で囲む
- 値を空にする（`key =`）と既定値に戻る
- `palette` と `host` は何度でも書ける。`palette` は番号ごとに上書きし、`host` は書いた順に足す
- 読めない行は飛ばし、ほかの行は使う。読めなかった行は画面の ⚠ と、編集画面の下に行番号付きで出る
- 鍵やパスワードは書かない。鍵は Secure Enclave、ホスト鍵はキーチェーンに置き、パスワードは毎回聞く
- 書かなかった項目は既定値になる。下の表の「既定値」がそれ

例:

```text
host = mac me@mac.example.ts.net tmux=main
host = pi pi@192.168.1.20:2222 tmux=none
font-size = 12
keyboard = kana
clipboard-clear = 30s
```

`host` の形は `host = 名前 ユーザー@アドレス[:ポート] [tmux=セッション名|none] [auth=key|password]`。`tmux` を書かなければ、接続時に `main` のセッションへ戻る。タブごとに別のセッションに入る（1 つ目は `main`、2 つ目から `main-2`・`main-3`…）。タブを閉じても tmux のセッションは残り、次に開いたタブが同じ番号なら戻る。tmux は `/opt/homebrew/bin` や `/usr/local/bin` などの決まった場所を順に探し、見つからなければ知らせて素のシェルを開く。`tmux=none` なら素のシェル。

## 色を Mac の Ghostty にそろえる

PC の Ghostty で見る色と同じにするには、Mac で `splitterm theme import` を実行する。Ghostty が使っている値（`background`・`foreground`・`cursor-color`・`selection-background`・`palette` の 0〜15・`minimum-contrast`・`bold-is-bright`・`font-thicken`、`window-colorspace` → `color-space`）を、コメントと並びを残して config に書く。

```bash
splitterm theme import --dry-run   # 書き換える内容と警告を出すだけ（何も書かない）
splitterm theme import             # config に書く
splitterm push                     # 端末へ送る
```

- 読み方は、まず `ghostty +show-config`、読めなければ Ghostty の config ファイルとテーマのファイル。明暗 2 つのテーマは暗い方。色の名前は書かずに警告。`palette` の 16〜255 は取り込まず、標準と違えば警告だけ
- `minimum-contrast` の既定は 1（補正しない。Ghostty と同じ）。`bold-is-bright` は太字の 0〜7 の色を 8〜15 にする。`font-thicken` は文字の輪郭を細い線でなぞって太らせる（どちらも既定 false）
- `color-space` は Ghostty の既定（`srgb`）だと、`display-p3` より少し落ち着いた、PC と同じ色になる
- tmux の中を true color にするには、動いているセッションを 1 度作り直す。[Get Started](https://mobile-ssh-client---split-keyboard.pages.dev/get-started.md#colors) にある

## 確かめ方

```bash
splitterm config check
splitterm config check --file path/to/config
```

読めない行があれば `N 行目: 理由` の形で出て、終了コードが 1 になる。読み取りの規則はアプリと同じコード（TermCore）なので、ここで通ればアプリでも通る。`splitterm` の作り方は [MCP](https://mobile-ssh-client---split-keyboard.pages.dev/mcp.md) にある。

## 接続

| 項目 | 既定値 | 説明 |
| --- | --- | --- |
| `host` | なし（何度でも書ける） | 形: host = 名前 ユーザー@アドレス[:ポート] [tmux=セッション名\|none] [auth=key\|password] tmux を指定すると、接続時に `tmux new-session -A -s <名前>` で続きに戻る（既定 main）。 タブごとに別のセッションに入る（1 つ目は main、2 つ目から main-2、main-3…）。タブを閉じても tmux は残る tmux=none なら素のシェル |
| `auto-connect` | 空 | 起動時につなぐ host の名前。空なら最初の host、none ならつながない |
| `term` | `xterm-256color` | 接続先に伝える端末の種類 |
| `keepalive` | `15s` | TCP の keepalive の間隔（切れた接続を早く見つける）。0 で使わない |
| `reconnect` | `true` | 切れたら自動で繋ぎ直す（バックグラウンドからの復帰・回線の切り替え） |
| `password-auth` | `false` | パスワード認証を許す（既定は公開鍵だけ。パスワードは毎回聞き、保存しない） |

## 表示

| 項目 | 既定値 | 説明 |
| --- | --- | --- |
| `font-family` | `system-mono` | 等幅の英字フォント。system-mono は iOS の SF Mono。Menlo・Courier New なども使える |
| `font-family-cjk` | `Hiragino Sans` | 日本語のフォールバック |
| `font-size` | `10` | 100% 表示のときの文字の大きさ（pt） |
| `zoom-steps` | `85, 100` | 表示倍率の段（%）。ピンチ・倍率ボタン・command + − / = はこの段で止まる。先頭が起動時 |
| `color-space` | `display-p3` | 色（#RRGGBB）。color-space が display-p3 なら Display P3 の値として描く（sRGB より鮮やか）。 Mac の Ghostty と同じ色にするには、Mac で splitterm theme import を実行する（color-space は Ghostty の window-colorspace、 既定の srgb になる） |
| `background` | `#07090D` | 色（#RRGGBB）。color-space が display-p3 なら Display P3 の値として描く（sRGB より鮮やか）。 Mac の Ghostty と同じ色にするには、Mac で splitterm theme import を実行する（color-space は Ghostty の window-colorspace、 既定の srgb になる） |
| `foreground` | `#E6EDF3` | 色（#RRGGBB）。color-space が display-p3 なら Display P3 の値として描く（sRGB より鮮やか）。 Mac の Ghostty と同じ色にするには、Mac で splitterm theme import を実行する（color-space は Ghostty の window-colorspace、 既定の srgb になる） |
| `cursor-color` | `#2F81F7` | 色（#RRGGBB）。color-space が display-p3 なら Display P3 の値として描く（sRGB より鮮やか）。 Mac の Ghostty と同じ色にするには、Mac で splitterm theme import を実行する（color-space は Ghostty の window-colorspace、 既定の srgb になる） |
| `accent` | `#2F81F7` | 色（#RRGGBB）。color-space が display-p3 なら Display P3 の値として描く（sRGB より鮮やか）。 Mac の Ghostty と同じ色にするには、Mac で splitterm theme import を実行する（color-space は Ghostty の window-colorspace、 既定の srgb になる） |
| `selection-background` | `#264F78` | 色（#RRGGBB）。color-space が display-p3 なら Display P3 の値として描く（sRGB より鮮やか）。 Mac の Ghostty と同じ色にするには、Mac で splitterm theme import を実行する（color-space は Ghostty の window-colorspace、 既定の srgb になる） |
| `palette` | `0=#1C2128` `1=#FF5F6D` `2=#3FE08A` `3=#FFB454` `4=#2F81F7` `5=#FF6AC1` `6=#5CE1E6` `7=#C9D1D9` `8=#545D68` `9=#FF8A94` `10=#7BF0B0` `11=#FFCC85` `12=#6CA6FF` `13=#FF9AD6` `14=#8EEFF2` `15=#FFFFFF`（番号ごとに上書きできる） | 16 色のパレット（番号=色） |
| `minimum-contrast` | `1` | 文字と背景のコントラスト比がこれを下回ると、文字色を白か黒の側へ寄せて補正する。1 で補正しない（Ghostty の既定と同じ）。 4.5 などにすると読みやすくなる代わりに、暗い色が白っぽくなって薄く見える |
| `bold-is-bright` | `false` | 太字の文字で、文字色がパレットの 0〜7 なら 8〜15 の色にする（true color と既定の文字色は変えない）。Ghostty の bold-is-bright |
| `font-thicken` | `false` | 文字の輪郭を細い線でなぞって、文字を少し太く描く（macOS の Ghostty の font-thicken の代わり） |
| `cursor-style` | `block` | カーソル: block / bar / underline |
| `cursor-blink` | `false` | カーソルを点滅させる |
| `scrollback-limit` | `10000` | スクロールバックの行数（メモリの上だけに置く） |

## キーボード

| 項目 | 既定値 | 説明 |
| --- | --- | --- |
| `keyboard` | `english` | 起動時のキーボード（🌐 の長押しでも選べる）: romaji（分割・ローマ字）/ english（分割・英語。Mac の JIS 配列）/ kana（日本語フリック分割）/ flick-romaji（英語フリック分割・ローマ字）/ flick-english（英語フリック分割・英語） |
| `keyboard-pitch` | `auto` | キー 1 つの大きさ u（pt。20〜80）。文字キーは u×u の正方形。 横持ちは左のキーボードが幅 8.25u、右が 9.5u、高さ 5.6u。auto は画面の短辺 × 0.064 を切り捨てて 24〜36（iPhone 13 mini で 24、iPad で 36）。 縦持ちは Mac の JIS 配列の一体型で幅 14.5u、高さ 5.6u。auto は画面の幅 ÷ 14.5（iPhone 13 mini で 25.86）。 大きすぎて収まらないときは、収まる大きさまで縮む |
| `key-repeat-delay` | `400ms` | ⌫ と矢印の長押しリピート |
| `key-repeat-interval` | `50ms` | ⌫ と矢印の長押しリピート |
| `option-as-meta` | `true` | option を meta（ESC を前に付ける）として送る（キーに刷ってある option の文字 € と # は、こちらより先に効く） |
| `haptics` | `true` | キーに触れたときの振動 |
| `newline` | `auto` | 改行キーが送るもの ・`auto`: 接続先が括弧付きペーストを有効にしていれば改行を貼り付けとして、無効なら ESC+CR ・`paste`: auto と同じ ・`esc-cr`: いつも ESC+CR（zsh・Claude Code の Option+Enter と同じ） ・`ctrl-j`: LF。bash・zsh では実行と同じ扱いになるので注意 |
| `soft-keyboard-with-hardware` | `false` | ハードウェアキーボードがつながっていても、画面のキーボードを出し続ける（iPad） |
| `echo-prediction` | `instant` | 先行表示（打った文字を、接続先の返事を待たずにカーソルの位置へ出す） ・`instant`: 押した瞬間に出す（iOS のキーボードと同じ速さ）。確かめる前は 1 行で最初の 1 文字だけ。外れたら、 返ってくるのを確かめるまで出さない。password・パスワード・token などの言葉がある行（前の行も見る）では 出さない。言葉に当たらない秘密の入力では、その行の最初の 1 文字が最大 1 秒出ることがある ・`confirmed`: 打った文字が返ってくるのを 1 度見てから出す（行が変わるたびに確かめ直す）。返らない入力では決して出ない ・`off`: 出さない |

## 操作

| 項目 | 既定値 | 説明 |
| --- | --- | --- |
| `mouse-reporting` | `true` | vim・tmux・htop などがマウスを求めたら、タップやスクロールをマウスとして送る |

## メディア（写真・動画・音声を送る）

📎 で選んだり撮ったりしたものを、SSH の同じ接続で接続先の受け取り箱へ原本のまま送り、パスを入力行に入れる。 エージェントが読めない形式のときだけ変換する（HEIC → JPEG、動画 → コンタクトシート、音声 → 文字起こし）

| 項目 | 既定値 | 説明 |
| --- | --- | --- |
| `agent` | `claude-code` | 送り先のエージェント: claude-code / codex / generic（画像は png・jpeg まで） |
| `agent-media` | 空 | エージェントが読める種類を上書きする（動画や音声を読めるエージェント用）。例: image,video,audio |
| `media-dir` | `~/.splitterm/inbox` | 接続先の受け取り箱（~/ か / で始まる専用のフォルダ。英数と . _ - / だけ。ホームや / そのものは不可） 古いものとして消すのは、アプリが付けた名前のファイルだけ。自分の持ち物でないフォルダには送らない |
| `media-retention` | `7d` | 受け取り箱に残す期間（7d・12h。0 で消さない） |
| `media-strip-location` | `true` | 写真・動画の位置情報を外す（再圧縮はしない。外せなければ送らない） false にする変更は、端末で本人の確認（Face ID かパスコード）の後で効く |
| `media-insert` | `"{paths} "` | 送った後に入力行へ入れる文字（{paths} が送ったファイルのパス。Enter は押さない） |
| `video-mode` | `auto` | 動画の送り方 ・`auto`: エージェントが動画を読めれば原本、読めなければコンタクトシート（＋文字起こし） ・`file`: いつも原本 / frames  いつもコンタクトシート / both  両方 |
| `video-frames` | `12` | コンタクトシートに並べる枚数（1〜24）と、シートの長い辺（px） |
| `video-sheet-size` | `1568` | コンタクトシートに並べる枚数（1〜24）と、シートの長い辺（px） |
| `video-transcribe` | `true` | 動画の音声を、端末の中で文字にして添える（端末にモデルが無ければ外へ送らずに飛ばす） |
| `audio-mode` | `auto` | 音声の送り方: auto（読めれば原本、だめなら文字起こし）/ file / transcript / both |

## 安全

| 項目 | 既定値 | 説明 |
| --- | --- | --- |
| `app-lock` | `true` | アプリを開くときに Face ID（かパスコード）を求める（いつ求めるかは app-lock-after） |
| `app-lock-after` | `15m` | アプリを開いていない時間がこれを超えたら、次に開くときに Face ID を求める（15m・1h・90s。0 で毎回） 長くする変更は、端末で本人の確認（Face ID かパスコード）の後で効く |
| `privacy-blur` | `true` | アプリスイッチャーでターミナルの内容をぼかす |
| `clipboard-clear` | `60s` | アプリからコピーした内容（シェルで選んだ文字。選ぶと自動でコピーされる）を、アプリを離れてから消すまでの時間。 前面にいる間は消さない。0 で消さない。他の端末へは渡さない |
