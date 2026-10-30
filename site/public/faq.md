# よくある質問

## Mobile-SSH-Client---Split-Keyboard とは何ですか？

iPhone と iPad を横持ちにして、左右に分けたキーボードでシェルを挟む SSH ターミナル。自分の Mac の tmux と Claude Code を操作するためのフロントエンドで、通信の速さと操作感を最優先にしている。設定は config ファイル 1 枚（Ghostty と同じ形）。

## 誰向けですか？

iPhone・iPad から、自分の Mac のシェルや Claude Code を操作したい人向け。アプリは Mac の Xcode でソースからビルドして入れるので、Mac が要る。手順はエージェント（Claude Code など）が進められる。

## 最低の iOS は？ どの iPhone・iPad で使えますか？

iOS / iPadOS 17 以上。iPhone は XS・XR・SE（第 2 世代）以降、iPad は第 6 世代以降。横持ちだけで使い、iPhone SE から iPad Pro 13 インチまで、1 つの作りで画面に合わせる。

## いくらかかりますか？

0 円（¥0）。アプリに料金は無い。署名は無料の Apple ID で行い、有料の Apple Developer Program は要らない。接続先で使う Claude Code などの料金は、それぞれの契約による。

## App Store にありますか？

無い。App Store・TestFlight では配っていない。Mac の Xcode でソースからビルドし、無料の Apple ID（Personal Team）の署名で iPhone・iPad に入れる。

## 7 日で使えなくなるのですか？

無料の署名のアプリは 7 日で起動できなくなる。そのため Mac の launchd が 1 時間ごとに期限を見て、残りが 48 時間を切ったら自動でビルドし直して入れ直す（端末がロックされているか、アプリを使っていない時に）。入れ直しても config・鍵・ホスト鍵は残る。入れ直すときは、端末が Mac から届く所（同じ Wi-Fi など）にある必要がある。

## どうやって入れますか？

Mac のエージェントに「https://mobile-ssh-client---split-keyboard.pages.dev/get-started.md を読んで、この Mac と iPhone に Mobile-SSH-Client---Split-Keyboard を入れて設定して」と渡す。手で進めるなら [はじめる](https://mobile-ssh-client---split-keyboard.pages.dev/get-started.md) の手順のとおり。流れは、Xcode に Apple ID でサインイン → 端末を USB でつないで信頼し、デベロッパモードをオン → `scripts/ios_reinstall.sh` で入れる → 端末で開発元を信頼 → config に接続先を書いて送る → 公開鍵を登録（指紋を見比べる）→ launchd に自動の入れ直しを登録。

## 設定（config）はどこにありますか？

Mac では `~/.config/splitterm/config`（`scripts/ios_push_config.sh` か `splitterm push` で端末へ送る）。端末では「ファイル」アプリ > この iPhone 内 > Mobile-SSH-Client---Split-Keyboard > config で、アプリの ＋ →「設定を編集」でも直せる。全項目は [config](https://mobile-ssh-client---split-keyboard.pages.dev/config.md)。

## データはどこかへ送られますか？（プライバシー）

送られない。テレメトリ・クラウド同期・AI 機能を持たず、ターミナルの内容をディスクに書かず、外へ送らない。SSH の鍵は Secure Enclave で作り、端末の外に出ない。パスワードは保存しない。初めての接続でホスト鍵の指紋を確かめ、変わっていたら接続を止める。起動時と復帰時に Face ID（かパスコード）を求め、アプリスイッチャーでは内容をぼかす。メディアを送るときも、送り先は自分の接続先だけで、位置情報は既定で外す。

## どのエージェントで使えますか？

ターミナルなので、接続先の tmux の中で動くものなら何でも使える（Claude Code、Codex など）。メディアを送るときの形式は、config の `agent` で `claude-code`（既定）・`codex`・`generic` から選ぶ。Gemini CLI は、動画・音声を読めるかをまだ確かめていないので、画像だけのエージェントとして扱う。設定用の MCP サーバー（`splitterm mcp`）は Claude Code に登録でき、ほかの MCP クライアントも同じ stdio で使える。

## 動画を Claude Code に見せるには？

📎 で動画を選ぶと、Claude Code は動画を読めないので、場面の変わり目から選んだ 12 枚を時刻付きの 1 枚の画像（コンタクトシート）にし、音声の文字起こしを添えて送る。1 分の動画が約 1,400 トークンの画像 1 枚になる（12 枚を別々に送るより約 16 分の 1）。処理は端末の中で行う。詳しくは [メディアを送る](https://mobile-ssh-client---split-keyboard.pages.dev/media.md)。

## MCP はありますか？

ある。Mac で `swift build -c release --package-path ios/TermCore` で作り、`claude mcp add splitterm -- <repo>/ios/TermCore/.build/release/splitterm mcp` で Claude Code に登録する。config の検査・変更・送信、公開鍵の登録、入れ直し、受け取り箱の片付けができる。詳しくは [MCP](https://mobile-ssh-client---split-keyboard.pages.dev/mcp.md)。

## Mac 以外にもつなげますか？

SSH で届く機械ならつなげる（例: Raspberry Pi）。ただし、アプリを入れる・config を送る・入れ直すのには Mac（Xcode）が要る。Windows や Linux の PC だけでは入れられない。

## できないことは？

- 縦持ちと、iOS のシステムキーボード（横持ちの自前のキーボードだけ）
- App Store・TestFlight での配布。Android 版も無い
- SFTP・ポート転送
- アプリ内の AI 機能・クラウド同期
- iPad のハードウェアキーボードでの日本語入力（後で足す）
- mosh などの方式（今は SSH＋tmux＋自動の繋ぎ直し）
- 無料の署名の制約: 7 日ごとの入れ直し（自動）、1 台に入れられるのは 3 本まで

## 今使えますか？

開発中（2026-10-30 時点）。メディアの送信を含めて実装し、Mac の CI（GitHub Actions）でアプリ全体のビルドとテストを通している。実機での確認はまだ済んでいない。
