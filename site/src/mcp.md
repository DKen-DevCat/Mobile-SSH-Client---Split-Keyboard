---
title: MCP（splitterm コマンド） | Mobile-SSH-Client---Split-Keyboard
description: Mac で動く splitterm コマンドの MCP サーバーの作り方・Claude Code への登録・道具の一覧（doctor・config_check・config_push・theme_import・pubkey_install・app_install・inbox_list など）。stdio だけで動き、ネットに出ない。
updated: 2026-10-31
---

# MCP（splitterm コマンド）

Mobile-SSH-Client---Split-Keyboard の設定と運用のために、Mac で動く `splitterm` コマンドがある。MCP サーバー（stdio）にもなる。Claude Code に登録すると、エージェントが config の検査・変更・送信、Ghostty の配色の取り込み、公開鍵の登録、アプリの入れ直し、受け取り箱の片付けを実行できる。ネットには出ない。

- config の読み取りは、アプリと同じ Swift のコード（TermCore）を使う。アプリと規則がずれない
- 端末に触る操作（config を送る・入れ直す・公開鍵を取る）は Mac の devicectl を使うので、MCP サーバーは Mac の中で動く
- 状態: 実装済み（Mac の CI でビルドとテストを通している）。`ios/TermCore` が無い版では、[Get Started](/get-started) の `scripts/` の手順で同じことができる

## 作る {#build}

リポジトリの最上位で実行する。要るのは Mac の Xcode（Swift）だけで、外の依存は無い。

```bash
swift build -c release --package-path ios/TermCore
```

成功の確かめ方: `ios/TermCore/.build/release/splitterm` ができ、`ios/TermCore/.build/release/splitterm doctor` が結果を出す。

## Claude Code に登録する {#register}

```bash
claude mcp add splitterm -- <repo>/ios/TermCore/.build/release/splitterm mcp
```

`<repo>` はリポジトリの絶対パス。リポジトリの最上位にいるなら次でよい:

```bash
claude mcp add splitterm -- "$PWD/ios/TermCore/.build/release/splitterm" mcp
```

成功の確かめ方: `claude mcp list` に `splitterm` が出る。

Claude Code 以外の MCP クライアントも、同じ stdio のサーバーとして登録できる（設定の形はクライアントによる）:

```json
{"mcpServers": {"splitterm": {"command": "/絶対パス/ios/TermCore/.build/release/splitterm", "args": ["mcp"]}}}
```

## 道具 {#tools}

| 道具 | すること | 人の手 |
| --- | --- | --- |
| `doctor` | Xcode・無料の Team・jq・tmux・リモートログイン・端末の対・アプリの期限を調べ、足りないものと直し方を返す | – |
| `config_show` | config を見せる | – |
| `config_check` | config を検査し、読めない行を行番号付きで返す | – |
| `config_set` | 1 項目を書き換える。コメントと並びを残し、書いた後に検査して、だめなら元に戻す | – |
| `host_add` | 接続先（`host`）を足す | – |
| `host_remove` | 接続先を消す | – |
| `config_push` | config を端末へ送る（`scripts/ios_push_config.sh`） | – |
| `pubkey_install` | 端末の公開鍵を Mac の `~/.ssh/authorized_keys` に足す（`scripts/ios_pubkey.sh`）。アプリに出た指紋が要る | 指紋を人がアプリの画面から読む |
| `app_install` | アプリを作り直して端末に入れる（`scripts/ios_reinstall.sh`） | 初回だけ、端末で開発元を信頼 |
| `app_status` | 入れたアプリの期限とビルドを見る | – |
| `inbox_list` | 端末から届いたメディアの一覧（新しい順、種類、元の動画との対応） | – |
| `inbox_clean` | 受け取り箱の古いもの（アプリが付けた名前のものだけ）を消す | – |
| `theme_import` | Mac の Ghostty が使っている配色（背景・文字・カーソル・選択・パレット 0〜15・`minimum-contrast`・`bold-is-bright`・`font-thicken`・色空間）を config に書く。引数 `dry_run` が true なら、書き換える内容と警告を出すだけ。明暗 2 つのテーマは暗い方。端末へは `config_push` で送る | – |

道具が触る config は決まった 1 つ（`SPLITTERM_CONFIG`、無ければ `~/.config/splitterm/config`）だけで、ファイルの場所は受け取らない。`theme_import` が読む Ghostty の実行ファイルと設定ファイルも、決まった場所だけ。守りを弱める変更（`app-lock`・`privacy-blur`・`media-strip-location` を false に）は、端末へ送っても、端末で本人が確かめるまで効かない。

## 人の手が要る所 {#needs-human}

人の手が要る段に来ると、道具は `needs_human` と手順を返す。エージェントはそれを人に頼み、終わったと言われてから続ける。

- Xcode に Apple ID でサインインする
- 端末を USB でつないで「信頼」し、デベロッパモードをオンにする
- 端末の「設定 > 一般 > VPN とデバイス管理」で開発元を信頼する
- アプリの ＋ を長押し →「公開鍵をコピー」に出た指紋を読み、`pubkey_install` に渡す

## pubkey_install と指紋 {#pubkey}

- 端末の公開鍵のファイル（`splitterm.pub`）は「ファイル」アプリから書き換えられる。だから、アプリの画面に出た指紋と一致したときだけ足す
- エージェントは指紋を推測しない。ファイルから計算した指紋を渡さない（それでは確かめにならない）
- 指紋が違えば、足さずに止まる
- 足す行には `restrict,pty` が付く。端末だけを許し、ポート転送・エージェント転送などを止める

## 安全 {#safety}

- stdio だけで動き、ネットに出ない
- 実行するのは決まったスクリプトだけ。引数は検査してから渡し、シェルを通さない
- 秘密（鍵・パスワード）を返さない

## コマンドとして使う {#cli}

MCP と同じことを、コマンドでも実行できる。

| コマンド | すること |
| --- | --- |
| `splitterm config path` | config の場所を出す（既定 `~/.config/splitterm/config`。`SPLITTERM_CONFIG` で変わる） |
| `splitterm config init` | 見本から config を作る |
| `splitterm config check [--file F]` | 検査する。読めない行は `N 行目: 理由` で出て、終了コードは 1 |
| `splitterm config show [--file F]` | config を見せる |
| `splitterm config set KEY VALUE [--file F]` | 1 項目を書き換える |
| `splitterm host add NAME USER@ADDR[:PORT] [--tmux NAME\|none] [--auth key\|password]` | 接続先を足す |
| `splitterm host remove NAME` | 接続先を消す |
| `splitterm push` | config を端末へ送る |
| `splitterm pubkey --fingerprint SHA256:...` | 指紋が一致したら、公開鍵を authorized_keys に足す |
| `splitterm theme import [--dry-run]` | Mac の Ghostty の配色を config に取り込む。`--dry-run` は書き換える内容を出すだけ |
| `splitterm install [--force]` | アプリを作り直して入れる |
| `splitterm status` | 入れたアプリの期限とビルドを見る |
| `splitterm doctor` | 足りないものと直し方を出す |
| `splitterm inbox list` | 受け取り箱の一覧 |
| `splitterm inbox clean [--days N]` | 受け取り箱の古いものを消す |
| `splitterm mcp` | MCP サーバー（stdio）として動く |
