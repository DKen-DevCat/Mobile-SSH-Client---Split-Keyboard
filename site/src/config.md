---
title: config（設定ファイルの全項目） | Mobile-SSH-Client---Split-Keyboard
description: Mobile-SSH-Client---Split-Keyboard の設定ファイル（config）の置き場所・書き方・全項目・既定値・説明。リポジトリの config.example から自動で作っている。
updated: 2026-10-30
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

`host` の形は `host = 名前 ユーザー@アドレス[:ポート] [tmux=セッション名|none] [auth=key|password]`。`tmux` を書かなければ、接続時に `main` のセッションへ戻る。

## 確かめ方 {#check}

```bash
splitterm config check
splitterm config check --file path/to/config
```

読めない行があれば `N 行目: 理由` の形で出て、終了コードが 1 になる。読み取りの規則はアプリと同じコード（TermCore）なので、ここで通ればアプリでも通る。`splitterm` の作り方は [MCP](/mcp) にある。

{{config_reference}}
