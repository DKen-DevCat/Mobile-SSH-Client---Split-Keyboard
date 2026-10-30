# 公開サイトと AIO のベンチマーク

`docs/proposal-2026-10-30.md` の「1. Get Started」「2. 0 円の運用」「3. AIO とベンチマーク」を実装したもの。Cloudflare の設定と更新の手順は `site/README.md`。

## 結論

- サイトは `site/src` の Markdown から `site/build.py`（Python の標準ライブラリだけ）で `site/public` に作り、生成物も git に入れる。Cloudflare Pages はビルドせず、`site/public` をそのまま配る
- すべての HTML に、同じ中身の Markdown（`<パス>.md`）を置く。エージェントは `llms.txt` → 各 `.md` を読む
- ずれやすいものは手で書かない: `/config` の表は `config.example` から、最低 OS は `Base.xcconfig` から、ベースの URL は `site/site.json` から作る
- 検査は 3 段: A（`bench/aio_check.py`、CI で毎回）、B（`bench/agent_bench.py`、手元の `claude -p` で月 1 回）、C（`bench/visibility.md`、手で月 1 回）

## 置き場所

| 場所 | 中身 |
| --- | --- |
| `site/site.json` | ベースの URL・アプリの名前・リポジトリの URL。URL はここ 1 か所だけ |
| `site/src/*.md`・`site/src/en/*.md` | ページ。先頭に front matter（下） |
| `site/src/llms.txt`・`site/src/en/llms.txt` | llms.txt（llmstxt.org の形） |
| `site/src/style.css` | 見た目（利用者のデザイン「05-A Mono Landscape」。トップのメインビジュアル `.hero` もここ） |
| `site/src/hero.html`・`site/src/en/hero.html` | トップのメインビジュアル（デザイン 1600×900 が土台。寸法は `style.css` の `calc(N * var(--u))`） |
| `site/src/favicon.svg`・`favicon.ico`・`apple-touch-icon.png`・`assets/og.png` | `node scripts/gen_brand.cjs --og` が `brand/` から作る（手で直さない） |
| `site/src/assets/fonts/` | JetBrains Mono（OFL、ラテン文字だけ）と `OFL.txt` |
| `site/src/assets/` | 画像など。そのまま `/assets/` に配る（無ければ何もしない） |
| `site/build.py` | 生成 |
| `site/public/` | 生成物（手で直さない） |
| `site/serve.py` | 手元で見るためのサーバー（Cloudflare Pages と同じ URL とヘッダー） |
| `bench/aio_check.py` | ベンチマーク A |
| `bench/agent_bench.py`・`bench/tasks.json` | ベンチマーク B |
| `bench/configspec.py` | config.example の読み取りと、config の簡易な検査（splitterm が無いときのフォールバック） |
| `bench/visibility.md` | ベンチマーク C の手順と記録の形 |
| `bench/results/` | B・C の結果（`<日付>-site.json`・`<日付>-baseline.json`・`visibility-YYYY-MM.md`） |

## site/build.py

```bash
python3 site/build.py            # site/public を作り直す
python3 site/build.py --check    # site/public が最新か（違えば 1。CI）
python3 site/build.py --out DIR  # 別の場所（無いか空のフォルダ）に作る（テスト用）
```

出力は毎回同じ（日時を埋め込まない。`lastmod` は front matter の `updated`）。

## 手元で見る（site/serve.py）

```bash
python3 site/serve.py                # 作り直してから http://127.0.0.1:8788/ で配る（英語は /en/）
python3 site/serve.py --no-build     # 作り直さずに配る
python3 site/serve.py --port 9000    # 別のポートで
```

標準ライブラリだけで動く。Cloudflare Pages と同じに見えるよう、拡張子の無い URL（`/get-started` → `get-started.html`）、`_headers` のヘッダー（CSP など）、無いページの `404.html` を再現する。既定では自分の Mac からしか見えない（`127.0.0.1`）。`python3 -m http.server` では拡張子の無いリンクが切れるので使わない。

### ページの書き方

```markdown
---
title: <title> と og:title（トップ以外は「… | Mobile-SSH-Client---Split-Keyboard」）
description: meta description・og:description・JSON-LD の description
updated: 2026-10-30
hero: hero/index.html
---

# 見出し（1 つだけ）

## 節 {#ascii-id}
```

- front matter は `title`・`description`・`updated`（必須）と `hero`（任意）だけ。知らない項目は止める
- 置き換え: `{{base}}`（site.json の base_url）、`{{repo}}`、`{{min_ios}}`（Base.xcconfig）、`{{config_reference}}`（config.example から作る表）。知らない `{{…}}` は止める
- 使える Markdown: 見出し（`{#id}` で id を決める）、段落、`-` と `1.` のリスト（字下げで入れ子）、表（セルの中の `|` は `\|`）、`>` の引用（「HUMAN-ONLY」を含むと人の手が要る段の色になる）、``` のコード、`` `コード` ``、`**太字**`、`[文字](/パス)`、`<https://…>`
- サイトの中のリンクは `/get-started` の形（`.html` を付けない）。Markdown の双子では `https://…/get-started.md` に書き換わる
- Get Started の手順は `## 1. … {#id}` の形にする（JSON-LD の HowTo の段になる）。FAQ は `##` の 1 つが 1 問（FAQPage になる）

### 1 ページの HTML の作り（`page_html`）

```text
<head>  title・description・canonical・hreflang（ja・en・x-default）・Markdown と llms.txt への alternate・
        OpenGraph・JSON-LD（トップ SoftwareApplication、Get Started HowTo、FAQ FAQPage、ほか TechArticle）
<body>
  <a class="skip">            本文へ飛ぶ
  <header>                    サイトの名前とナビ
  （hero）                    front matter の hero の HTML の断片（無ければ何も出さない）
  <main id="main">            Markdown から作った本文。Markdown の双子と同じ中身（aio_check が比べる）
  <footer>                    Markdown 版・llms.txt・GitHub・更新日
```

- hero は `<main>` の外に入るので、Markdown の双子と比べる対象にならない。断片の中でも `{{base}}` などが使える。CSP のため、`<script>`・`style="…"`・外のサイトの画像は使えない（画像は `site/src/assets/` に置いて `/assets/…` で参照する）
- ほかに作るもの: `llms-full.txt`（日本語の全ページの Markdown をつないだもの）、`robots.txt`、`sitemap.xml`、`_headers`（CSP・nosniff・Referrer-Policy・Permissions-Policy、`.md` と `llms*.txt` の Content-Type）、`404.html`（noindex。無いと Cloudflare Pages はトップを返す）

## ベンチマーク

| 段 | 動かし方 | 合格の線 |
| --- | --- | --- |
| A | `python3 bench/aio_check.py`（`--online` は公開後に手で） | すべて合格（CI） |
| B | `python3 bench/agent_bench.py`（採点の確認だけなら `--dry-run`） | site の腕で、答える課題 90% 以上・config の課題 100%（`tasks.json` の thresholds） |
| C | `bench/visibility.md` | 記録して推移を見る |

- B は手元の `claude -p`（サブスクリプションの枠）だけを使い、有料の API は呼ばない。空の一時フォルダで動かし、Read・Bash などを止め、MCP を読ませない（リポジトリや手元の splitterm から答えを拾わせない）。site の腕はサイトのドメインの WebFetch だけを許し、baseline は WebFetch も止める。手元の `~/.claude/CLAUDE.md` とメモリは読まれる（`--bare` は API キーが要るので使わない）
- B の config の課題は、`ios/TermCore/.build/release/splitterm` があれば `splitterm config check --file` で、無ければ `bench/configspec.py` のフォールバック（書き方と知らない項目はアプリと同じに見るが、選べる値と範囲は見ない）で検査する。結果の JSON の `validator` にどちらを使ったかが残る
