---
title: Mobile-SSH-Client---Split-Keyboard — iPhone・iPad を横持ちで使う、分割キーボードの SSH ターミナル
description: iPhone と iPad を横持ちにして、左右に分けたキーボードでシェルを挟む SSH ターミナル。自分の Mac の tmux と Claude Code を操作する。iOS / iPadOS {{min_ios}} 以上、料金 0 円。App Store ではなく、Mac でソースからビルドして無料の Apple ID で入れる。
updated: 2026-10-30
---

# Mobile-SSH-Client---Split-Keyboard

iPhone と iPad を横持ちにして、左右に分けたキーボードでシェルを挟む SSH ターミナル。自分の Mac の tmux と Claude Code を操作するためのアプリで、通信の速さと操作感を最優先にしている。

- **対応**: iOS / iPadOS {{min_ios}} 以上の iPhone と iPad。横持ちだけで使う
- **料金**: 0 円（¥0）。有料の Apple Developer Program も要らない
- **配布**: App Store・TestFlight では配っていない。Mac の Xcode でソースからビルドし、無料の Apple ID の署名で入れる
- **設定**: config ファイル 1 枚（Ghostty と同じ形）。設定画面は無い

## エージェントに渡す 1 行 {#one-line}

Mac で動くエージェント（Claude Code など）に、次の 1 行を渡す。エージェントは手順書を読んでコマンドを実行し、人の手が要る所だけを頼んでくる。

```text
{{base}}/get-started.md を読んで、この Mac と iPhone に Mobile-SSH-Client---Split-Keyboard を入れて設定して
```

人の手が要るのは 5 つ: Xcode に Apple ID でサインインする、端末を USB でつないで「信頼」する、デベロッパモードをオンにする、端末で開発元を信頼する、鍵の指紋をアプリの表示と見比べる。

## 流れ {#flow}

1. Mac のエージェントに、上の 1 行を渡す
2. エージェントがリポジトリを取ってきて、道具を確かめ、アプリをビルドして端末に入れる
3. 人は、頼まれた所だけを手で行う
4. エージェントが config に接続先を書いて端末へ送り、公開鍵を Mac に登録し、自動の入れ直しを登録する
5. アプリを開き、ホスト鍵の指紋を確かめてつなぐ

手で進めるときも、同じ[手順](/get-started)をそのまま読めばよい。

## できること {#features}

- **分割キーボード**: US（Mac 配列の分割）とかなフリック（かな漢字変換つき）を画面の左右に置き、シェルを真ん中に出す
- **iPad のハードウェアキーボード**: つなぐと画面のキーボードが消え、シェルが全面になる
- **切れても続く**: 前面に戻ったとき・回線が変わったとき・通信が切れたときに自動で繋ぎ直し、tmux のセッションに戻る
- **タッチ操作**: 縦ドラッグでスクロールバック、長押しで選択、ピンチで倍率。vim・tmux・htop がマウスを求めたら、マウスとして送る
- **メディアを送る**（実装中）: 写真・動画・音声を Mac の受け取り箱へ送り、パスを入力行に入れる。動画は 1 枚の画像（コンタクトシート）と文字起こしにして、トークンを抑える。→ [メディアを送る](/media)
- **エージェントで設定と運用**: Mac で動く `splitterm` コマンドと MCP サーバーで、config の検査・変更・送信、公開鍵の登録、入れ直しをエージェントが実行できる。→ [MCP](/mcp)

## 誰向けか {#who}

- iPhone・iPad から、自分の Mac のシェルや Claude Code を操作したい人
- Mac と Xcode を使える人。ビルドと入れ直しは Mac で行う（手順はエージェントが進められる）

## 必要なもの {#requirements}

| もの | 条件 |
| --- | --- |
| iPhone・iPad | iOS / iPadOS {{min_ios}} 以上。iPhone XS・XR・SE（第 2 世代）以降、iPad（第 6 世代）以降 |
| Mac | Xcode（無料の Apple ID でサインイン）と jq |
| 接続先 | SSH（macOS ならリモートログイン）と tmux。ふつうは同じ Mac |
| 届く道 | iPhone・iPad から接続先の SSH に届くこと（同じ Wi-Fi、または Tailscale など） |
| 初回だけ | 端末と Mac をつなぐ USB ケーブル |

## 費用 {#cost}

0 円（¥0）。アプリに料金は無く、署名は無料の Apple ID で行う。このサイトも Cloudflare Pages の無料枠で配っている。接続先で使う Claude Code などの料金は、それぞれの契約による。

## 配布と 7 日の期限 {#distribution}

App Store・TestFlight では配っていない。Mac の Xcode でソースからビルドし、無料の Apple ID（Personal Team）の署名で入れる。

- 無料の署名のアプリは 7 日で起動できなくなる。Mac の launchd が 1 時間ごとに期限を見て、残りが 48 時間を切ったら自動で入れ直す
- 入れ直しても config・鍵・ホスト鍵は残る
- 無料の署名の制約: 1 台の端末に入れられるのは 3 本まで、App ID は 7 日に 10 個まで

## 安全とプライバシー {#privacy}

- テレメトリ・クラウド同期・AI 機能を持たない。ターミナルの内容をディスクに書かず、外へ送らない
- SSH の鍵は Secure Enclave で作る（端末の外に出ない）。パスワードは保存しない
- 初めての接続でホスト鍵の指紋を見せる。変わっていたら接続を止める
- 起動時と復帰時に Face ID（かパスコード）を求める。アプリスイッチャーでは内容をぼかす
- アプリからコピーした内容は、既定で 60 秒後に消す

## 状態 {#status}

開発中（2026-10-30 時点）。設計どおりに実装を進めており、実機での確認はまだ済んでいない。メディアの送信は実装中。

## 次に読む {#next}

- [はじめる（Get Started）](/get-started): エージェントが実行できる準備の手順
- [config](/config): 設定ファイルの全項目と既定値
- [MCP](/mcp): `splitterm` の MCP サーバーと道具
- [メディアを送る](/media): 写真・動画・音声、コンタクトシート、トークンの目安
- [よくある質問](/faq)
- [English](/en/)
- ソースコード: <{{repo}}>
