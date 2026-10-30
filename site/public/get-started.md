# はじめる（Get Started）

Mac の Xcode でソースからビルドし、無料の Apple ID の署名で iPhone・iPad に入れる。続けて config に接続先を書いて送り、公開鍵を Mac に登録し、7 日ごとの入れ直しを launchd に任せる。費用は 0 円。

この手順はエージェント（Claude Code など）がそのまま実行できる。人に渡すなら、Mac のエージェントに次の 1 行を渡せばよい。

```text
https://mobile-ssh-client---split-keyboard.pages.dev/get-started.md を読んで、この Mac と iPhone に Mobile-SSH-Client---Split-Keyboard を入れて設定して
```

## この手順の読み方

- 各段は「実行する」「成功の確かめ方」の順に書いてある。コマンドはリポジトリの最上位（`~/Mobile-SSH-Client---Split-Keyboard`）で実行する
- 「**人の手が要る（HUMAN-ONLY）**」の段は、エージェントは実行しない。人に頼み、終わったと言われてから「成功の確かめ方」で確かめる
- 失敗したら次の段へ進まない。出力をそのまま人に見せ、「うまくいかないとき」を見る
- エージェントへ: 鍵の指紋は推測しない、作らない。必ず人がアプリの画面から読んだものを使う。鍵やパスワードを config に書かない。`sudo` が要る操作は人に頼む

## 前提

| もの | 条件 |
| --- | --- |
| iPhone・iPad | iOS / iPadOS 17 以上。iPhone XS・XR・SE（第 2 世代）以降、iPad（第 6 世代）以降 |
| Mac | Xcode、jq（無ければ Homebrew で入れる） |
| 接続先 | SSH（macOS ならリモートログイン）と tmux。ふつうは同じ Mac |
| 届く道 | iPhone・iPad から接続先の SSH に届くこと（同じ Wi-Fi、または Tailscale など） |
| Apple ID | 無料のものでよい。有料の Apple Developer Program は要らない |
| 初回だけ | 端末と Mac をつなぐ USB ケーブル |

## 1. リポジトリを取ってくる

実行する:

```bash
git clone https://github.com/DKen-DevCat/Mobile-SSH-Client---Split-Keyboard ~/Mobile-SSH-Client---Split-Keyboard
cd ~/Mobile-SSH-Client---Split-Keyboard
```

成功の確かめ方: `ls scripts/ios_reinstall.sh` がファイルの名前を出す。もう取ってあるなら、`git pull` で新しくする。

## 2. Xcode と道具を確かめる

実行する:

```bash
xcodebuild -version
jq --version
tmux -V
nc -z 127.0.0.1 22 && echo "SSH OK"
```

成功の確かめ方: 4 つとも版か `SSH OK` を出す。

足りないとき:

- jq・tmux: `brew install jq tmux`
- `xcodebuild` が無い、または「requires Xcode」と出る: **人の手が要る（HUMAN-ONLY）**。App Store から Xcode を入れて一度開く。そのあと `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` を人が実行する
- `SSH OK` が出ない: **人の手が要る（HUMAN-ONLY）**。「システム設定 > 一般 > 共有 > リモートログイン」をオンにする

## 3. splitterm コマンドを作る

エージェントが config を扱うための、Mac で動くコマンド（MCP サーバーにもなる）。外の依存は無い。

実行する:

```bash
swift build -c release --package-path ios/TermCore
ios/TermCore/.build/release/splitterm doctor
```

成功の確かめ方: ビルドが `Build complete!` で終わり、`doctor` が調べた結果と、足りないものの直し方を出す。この時点では Team・端末・アプリが足りないと出てよい（以降の段で埋まる）。

- MCP で使うなら、ここで登録する: `claude mcp add splitterm -- "$PWD/ios/TermCore/.build/release/splitterm" mcp`（詳しくは [MCP](https://mobile-ssh-client---split-keyboard.pages.dev/mcp.md)）
- `ios/TermCore` が無い版のリポジトリなら、この段を飛ばす。以降の段は `scripts/` のコマンドで進められる

## 4. Xcode に Apple ID でサインインする

> **人の手が要る（HUMAN-ONLY）**: Xcode を開き、「Xcode > Settings… > Accounts」の ＋ から Apple ID でサインインする。無料の Apple ID でよい（Personal Team ができる）。Apple ID のパスワードと確認コードはエージェントに渡さない。

成功の確かめ方（エージェントが実行する）:

```bash
defaults export com.apple.dt.Xcode - | plutil -extract IDEProvisioningTeamByIdentifier json -o - - | jq -r '[.[][] | select(.isFreeProvisioningTeam == true) | .teamID] | unique | .[]'
```

英数 10 文字の Team ID が 1 行出れば成功。何も出なければサインインがまだ。2 行以上出たら、使う方を `export SPLITTERM_IOS_TEAM=<Team ID>` で選ぶ。

## 5. 端末を USB でつないで信頼する

> **人の手が要る（HUMAN-ONLY）**: iPhone・iPad を USB で Mac につなぐ。端末に「このコンピュータを信頼しますか？」が出たら「信頼」を選び、パスコードを入れる。

成功の確かめ方（エージェントが実行する）:

```bash
xcrun devicectl list devices
```

端末の名前が一覧に出て、状態が `unavailable` でなければ成功。Mac と対になった端末が 2 台以上あるときは、使う端末の UDID を `export SPLITTERM_IOS_DEVICE=<UDID>` で選ぶ。

## 6. デベロッパモードをオンにする

> **人の手が要る（HUMAN-ONLY）**: 端末の「設定 > プライバシーとセキュリティ > デベロッパモード」をオンにする。再起動を求められるので再起動し、ロックを解いたあとに出る確認で「オンにする」を選ぶ。項目が見当たらなければ、USB でつないだまま Xcode を一度開くと出る。

成功の確かめ方: 人が端末の同じ画面でオンになっているのを見る。次の段（7）が通れば確か。

## 7. アプリを入れる

初回は、署名の証明書・端末の登録・App ID・プロファイルが自動で作られる。

実行する:

```bash
scripts/ios_reinstall.sh
```

成功の確かめ方: 終了コードが 0 で、最後に `入れ直しました（ビルド …）。次の期限は …` と出る。

- `splitterm` を作ったなら `ios/TermCore/.build/release/splitterm install` でも同じ。MCP なら `app_install`
- 終了コード 1: 出たメッセージとログ（`logs/ios_build.log`・`logs/ios_install.log`）を見る。「無料の Team が分かりません」なら段 4 へ戻る
- 終了コード 3: Mac のメモリに余裕が無い。ほかのアプリを閉じるか、`scripts/ios_reinstall.sh --force`
- 終了コード 5: 端末に届かない。USB でつなぎ直し、ロックを解く

## 8. 端末で開発元を信頼する

> **人の手が要る（HUMAN-ONLY）**: 端末の「設定 > 一般 > VPN とデバイス管理」で「Apple Development: （Apple ID）」を選び、「信頼」する。そのあと Mobile-SSH-Client---Split-Keyboard を開き、Face ID かパスコードでロックを解く。

アプリを一度開くと、アプリの書類フォルダに公開鍵（`splitterm.pub`）と config の見本ができる。

成功の確かめ方（エージェントが実行する）:

```bash
scripts/ios_pubkey.sh --print
```

`ecdsa-sha2-nistp256 … splitterm` の行と `指紋: SHA256:…` の行が出れば成功（表示するだけで、まだ登録しない）。「公開鍵を取れませんでした」なら、アプリをもう一度開いてから試す。

## 9. config を作って接続先を書く

Mac の config は `~/.config/splitterm/config`。見本から作り、接続先（`host`）を 1 行足す。

まず、接続先のユーザー名とアドレスを調べる:

```bash
whoami
scutil --get LocalHostName
```

アドレスは、同じ Wi-Fi なら `<LocalHostName>.local`、Tailscale なら `tailscale status` に出るこの Mac の名前（例 `mac.tail1234.ts.net`）。どちらを使うかは人に聞く。

実行する（`<ユーザー>` と `<アドレス>` を置き換える）:

```bash
ios/TermCore/.build/release/splitterm config init
ios/TermCore/.build/release/splitterm host add mac <ユーザー>@<アドレス> --tmux main
ios/TermCore/.build/release/splitterm config check
```

成功の確かめ方: `config check` の終了コードが 0。読めない行があれば `N 行目: 理由` の形で出る。

`splitterm` が無いときは、次で同じことをする:

```bash
scripts/ios_push_config.sh --init
printf 'host = mac %s@%s tmux=main\n' "<ユーザー>" "<アドレス>" >> ~/.config/splitterm/config
grep '^host' ~/.config/splitterm/config
```

項目の全体は [config](https://mobile-ssh-client---split-keyboard.pages.dev/config.md) にある。

## 10. config を端末へ送る

実行する:

```bash
scripts/ios_push_config.sh
```

成功の確かめ方: `送りました: … → <UDID>` と出る。開いているアプリにもすぐ効く。`splitterm push`（MCP なら `config_push`）でも同じ。

## 11. 公開鍵を Mac に登録する

アプリの公開鍵を、この Mac の `~/.ssh/authorized_keys` に足す。端末の公開鍵のファイルは「ファイル」アプリから書き換えられるので、足す前に指紋をアプリの画面と見比べる。

> **人の手が要る（HUMAN-ONLY）**: アプリの ＋ を長押し →「公開鍵をコピー」を押し、画面に出た指紋（`SHA256:` で始まる）をエージェントに伝える。エージェントは指紋を推測しない。段 8 の `--print` で出た指紋を代わりに使わない（それでは確かめにならない）。

実行する（人から聞いた指紋を入れる）:

```bash
scripts/ios_pubkey.sh --fingerprint 'SHA256:<アプリに出た指紋>'
```

成功の確かめ方: `足しました: …/.ssh/authorized_keys` か `もう登録してあります` と出る。`指紋がアプリの表示（…）と違います` と出たら止まり、人に知らせる。足す行には `restrict,pty` が付く（端末だけを許し、ポート転送などを止める）。

人が自分の端末（ターミナル）で `scripts/ios_pubkey.sh` を実行し、指紋を見比べて `y` を押してもよい。

## 12. 自動の入れ直しを登録する

無料の署名のアプリは 7 日で起動できなくなる。launchd が 1 時間ごとに期限を見て、残りが 48 時間を切ったら入れ直す（端末がロックされているか、アプリを使っていない時に）。

実行する（plist の中のリポジトリのパスを、この場所に直してから登録する）:

```bash
mkdir -p ~/Library/LaunchAgents logs
sed -E "s#/Users/[^/]+/Mobile-SSH-Client---Split-Keyboard#$PWD#g" launchd/com.dken.splitterm-ios.plist > ~/Library/LaunchAgents/com.dken.splitterm-ios.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dken.splitterm-ios.plist
```

成功の確かめ方: `launchctl list | grep com.dken.splitterm-ios` が 1 行出る。登録した直後に 1 回動くので、`tail -n 3 logs/ios_reinstall.log` に `期限まで … 時間です。まだ入れ直しません` のような行が出る。

もう登録してあって bootstrap が失敗したら、`launchctl bootout gui/$(id -u)/com.dken.splitterm-ios` してからもう一度登録する。

## 13. 初めてつなぐ

まず、接続先の Mac のホスト鍵の指紋を出す（エージェントが実行して、人に見せる）:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

> **人の手が要る（HUMAN-ONLY）**: アプリを開く（起動時に最初の `host` へつなぐ。＋ を長押しして出る一覧から選んでもよい）。ホスト鍵の指紋の確認が出たら、上のコマンドの `SHA256:…` と同じときだけ受け入れる。違うときは受け入れずに止める。

成功の確かめ方: アプリに tmux の画面（セッション `main`）が出る。これで準備は終わり。

## ふだんの操作

| すること | コマンド・操作 |
| --- | --- |
| 設定を変える（Mac で） | `~/.config/splitterm/config` を直して `scripts/ios_push_config.sh`。または `splitterm config set <項目> <値>` と `splitterm push` |
| 設定を変える（端末で） | アプリの ＋ を長押し →「設定を編集」、または「ファイル」アプリ > この iPhone 内 > Mobile-SSH-Client---Split-Keyboard > config |
| 接続先を足す | `splitterm host add <名前> <ユーザー>@<アドレス>` と `splitterm push` |
| 期限を見る | `splitterm status`（MCP なら `app_status`） |
| すぐに入れ直す | `scripts/ios_reinstall.sh` |
| 写真・動画を送る | [メディアを送る](https://mobile-ssh-client---split-keyboard.pages.dev/media.md) |

## うまくいかないとき

| 出たもの | すること |
| --- | --- |
| 「無料の Team が分かりません」 | 段 4 のサインインをやり直す。Team が 2 つ以上なら `SPLITTERM_IOS_TEAM` を指定する |
| 「Mac と対になった iPhone がありません」 | 段 5 をやり直す（USB でつなぎ、端末で「信頼」） |
| 「端末が 2 台以上あります」 | `SPLITTERM_IOS_DEVICE` に UDID を入れる |
| アプリが開かない（「信頼されていない開発元」） | 段 8 をやり直す |
| 7 日たってアプリが開かない | `scripts/ios_reinstall.sh` で入れ直す。launchd の登録（段 12）とログ（`logs/ios_reinstall.log`）を見る |
| 「公開鍵を取れませんでした」「送れませんでした」 | アプリを一度開いてから、もう一度試す |
| 接続でホスト鍵が違うと出る | 受け入れる道は無い。本当に鍵を変えたときだけ、アプリの ＋ を長押し →「このタブのホスト鍵を忘れる」 |
| config の ⚠ | `splitterm config check` で行番号と理由を見て直す |
| アプリで「認証に失敗しました」 | 公開鍵を登録したか確かめる: `grep -c splitterm ~/.ssh/authorized_keys` が 0 なら段 11。登録済みなら、システム設定 > 一般 > 共有 > リモートログイン の「アクセスを許可」に自分が入っているか、`~/.ssh` の権限（`chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`）を見る。理由は `log show --last 10m --style compact --predicate 'process BEGINSWITH "sshd"'` に出る |
| ビルドが「Validate plug-in “SwiftTermBuildInfoPlugin”」で止まる | 初回だけ人の手: `open ios/*.xcodeproj` で Xcode を開き、実行先を「Any iOS Simulator Device」にして ⌘B、出てきた「Trust & Enable」を押す（Xcode でビルドするには先に `ios/Config/Local.xcconfig` に `DEVELOPMENT_TEAM` を書く）。そのあと段 7 をやり直す |
