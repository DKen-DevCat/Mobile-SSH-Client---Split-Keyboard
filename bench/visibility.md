# AI 検索での見え方（ベンチマーク C、手で月 1 回）

AI の検索（Perplexity・ChatGPT 検索・Gemini など）に決まった質問をし、このサイトが引用されるか、答えが正しいかを記録する。自動化はしない（有料の API と各サービスの利用規約のため）。ベンチマーク A（`bench/aio_check.py`、CI）と B（`bench/agent_bench.py`、手元）の後に行う。設計は `docs/proposal-2026-10-30.md`「3」。

## いつ

- 公開した後、毎月 1 回（月初）
- サイトを大きく変えた後、2〜4 週間たってから（クローラが読み直すのを待つ）

## 準備（5 分）

1. 公開中のサイトがクローラに取れることを確かめる: `python3 bench/aio_check.py --online`（すべて 200 でなければ、`site/README.md`「AI のクローラを確かめる」）
2. 各サービスはログアウトした状態か、履歴と個人設定（メモリ）を切った状態で聞く。前の会話の影響を避けるため、質問ごとに新しい会話にする
3. 記録のファイルを作る: `bench/results/visibility-YYYY-MM.md`（下の「記録の形」を写す）

## 聞く所

| サービス | 聞き方 | 引用の見方 |
| --- | --- | --- |
| Perplexity | 既定のモード | 答えの下の出典 |
| ChatGPT | 検索をオンにする | 答えの中の出典のリンク |
| Gemini | 既定 | 「関連するリンク」や出典 |
| Claude | ウェブ検索をオンにする | 出典のリンク |
| Google 検索 | 通常の検索（AI による概要が出たら、それも見る） | 概要の出典と、検索結果の順位 |

## 質問（毎回同じ文で聞く）

日本語:

1. Mobile-SSH-Client---Split-Keyboard とは何？ 誰向け？
2. Mobile-SSH-Client---Split-Keyboard の最低 iOS は？
3. Mobile-SSH-Client---Split-Keyboard はいくら？ App Store にある？
4. Mobile-SSH-Client---Split-Keyboard を iPhone に入れる方法は？
5. iPhone から Mac の Claude Code を横持ちの分割キーボードで操作できる SSH アプリは？
6. iPhone で撮った動画を Claude Code に見せるには？（Mobile-SSH-Client---Split-Keyboard）
7. Mobile-SSH-Client---Split-Keyboard の設定ファイルはどこ？
8. Mobile-SSH-Client---Split-Keyboard の MCP サーバーの登録方法は？

English:

1. What is Mobile-SSH-Client---Split-Keyboard?
2. What iOS version does Mobile-SSH-Client---Split-Keyboard require?
3. Is Mobile-SSH-Client---Split-Keyboard on the App Store? How much does it cost?
4. How do I install Mobile-SSH-Client---Split-Keyboard on my iPhone?
5. iPhone SSH terminal with a split keyboard in landscape for Claude Code on a Mac

質問 5（ja・en）は名前を出さない質問。名前を知らない人に見つけてもらえるかを見る。

## 正しい答え（照らし合わせる）

| 事柄 | 正しい | よくある誤り |
| --- | --- | --- |
| 何か | iPhone・iPad を横持ちで使う、分割キーボードの SSH ターミナル。自分の Mac の tmux と Claude Code を操作する | 物のキーボード、ほかの SSH アプリとの取り違え |
| 最低 OS | iOS / iPadOS 17 以上（`ios/Config/Base.xcconfig` の IPHONEOS_DEPLOYMENT_TARGET） | 16 以下、「すべての iPhone」 |
| 料金 | 0 円。無料の Apple ID で署名する | 有料、Apple Developer Program が要る |
| 配布 | App Store・TestFlight には無い。Mac の Xcode でソースからビルドし、launchd が 7 日ごとに入れ直す | App Store にある |
| 動画 | 12 枚を 1 枚の画像（コンタクトシート）にし、文字起こしを添える | 動画のまま Claude Code が読める |
| config | Mac は `~/.config/splitterm/config`、端末は「ファイル」アプリ | 設定画面がある |
| MCP | `claude mcp add splitterm -- <repo>/ios/TermCore/.build/release/splitterm mcp` | npm のパッケージがある |
| 名前 | Mobile-SSH-Client---Split-Keyboard | 古い名前（SplitTerm）や、ほかのアプリの名前 |

## 記録の形

`bench/results/visibility-YYYY-MM.md` に、質問ごとに 1 行。

```text
# AI 検索での見え方 YYYY-MM-DD

aio_check --online: すべて 200 / （200 でなかったもの）

| サービス | 言語 | 質問 | 引用された URL（無ければ –） | 正しさ（○・△・✕） | 誤り・気づき |
| --- | --- | --- | --- | --- | --- |
| Perplexity | ja | 1 | /faq | ○ | |
| ChatGPT | en | 2 | – | ✕ | iOS 15 と答えた |
```

- 正しさ: ○ = 上の表と合う / △ = 一部だけ・古い / ✕ = 誤り・見つからない
- 引用された URL は、このサイトのパス（`/faq` など）か、ほかのサイトの URL をそのまま書く
- 最後に 3 行で前回と比べる: 引用された数・○の数・新しく出た誤り

## 誤りを見つけたら

1. 誤りの元を探す（このサイトの書き方か、ほかのサイトか、古い情報か）
2. このサイトが元なら、`site/src` を直し、`python3 site/build.py` と `python3 bench/aio_check.py` を通して入れる。同じ誤りを `bench/tasks.json` の課題（forbidden）に足す
3. 直した日を記録に書き、翌月に同じ質問で確かめる
