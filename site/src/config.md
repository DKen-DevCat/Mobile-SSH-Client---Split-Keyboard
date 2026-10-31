---
title: config（設定ファイルの全項目） | Mobile-SSH-Client---Split-Keyboard
description: Mobile-SSH-Client---Split-Keyboard の設定ファイル（config）の置き場所・書き方・全項目・既定値・説明。リポジトリの config.example から自動で作っている。
updated: 2026-10-31
---

# config（設定ファイルの全項目）

設定は config ファイル 1 枚で決める（Ghostty と同じ形）。設定画面は無い。このページの項目の表は、リポジトリの見本 `config.example` から自動で作っている（手で写していない）。

## 置き場所 {#location}

| どこ | 場所 | 使い方 |
| --- | --- | --- |
| Mac | `~/.config/splitterm/config`（環境変数 `SPLITTERM_CONFIG` で変えられる） | 直してから `scripts/ios_push_config.sh`（または `splitterm push`）で端末へ送る。開いているアプリにもすぐ効く |
| iPhone・iPad | 「ファイル」アプリ > この iPhone 内 > Mobile-SSH-Client---Split-Keyboard > config | アプリの ＋ を長押し →「設定を編集」でも直せる。保存した瞬間に読み直して効く |

Mac で初めて作るときは、見本から作る: `splitterm config init`（または `scripts/ios_push_config.sh --init`）。

## 書き方 {#syntax}

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

## 色を Mac の Ghostty にそろえる {#colors}

PC の Ghostty で見る色と同じにするには、Mac で `splitterm theme import` を実行する。Ghostty が使っている値（`background`・`foreground`・`cursor-color`・`selection-background`・`palette` の 0〜15・`minimum-contrast`・`bold-is-bright`・`font-thicken`、`window-colorspace` → `color-space`）を、コメントと並びを残して config に書く。

```bash
splitterm theme import --dry-run   # 書き換える内容と警告を出すだけ（何も書かない）
splitterm theme import             # config に書く
splitterm push                     # 端末へ送る
```

- 読み方は、まず `ghostty +show-config`、読めなければ Ghostty の config ファイルとテーマのファイル。明暗 2 つのテーマは暗い方。色の名前は書かずに警告。`palette` の 16〜255 は取り込まず、標準と違えば警告だけ
- `minimum-contrast` の既定は 1（補正しない。Ghostty と同じ）。`bold-is-bright` は太字の 0〜7 の色を 8〜15 にする。`font-thicken` は文字の輪郭を細い線でなぞって太らせる（どちらも既定 false）
- `color-space` は Ghostty の既定（`srgb`）だと、`display-p3` より少し落ち着いた、PC と同じ色になる
- tmux の中を true color にするには、動いているセッションを 1 度作り直す。[Get Started](/get-started#colors) にある

## 確かめ方 {#check}

```bash
splitterm config check
splitterm config check --file path/to/config
```

読めない行があれば `N 行目: 理由` の形で出て、終了コードが 1 になる。読み取りの規則はアプリと同じコード（TermCore）なので、ここで通ればアプリでも通る。`splitterm` の作り方は [MCP](/mcp) にある。

{{config_reference}}
