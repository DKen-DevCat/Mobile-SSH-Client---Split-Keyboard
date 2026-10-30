# 公開サイト（Get Started）

`https://mobile-ssh-client---split-keyboard.pages.dev` で配る静的なサイト。Cloudflare Pages の無料枠で、ドメインは取らない（`*.pages.dev`）。Cloudflare 側ではビルドせず、git に入れた `site/public` をそのまま配る。作りと検査は `docs/site.md`。

## 更新のしかた

1. `site/src` の Markdown を直す（日本語が正本。英語は `en/` のトップと Get Started だけ）
2. 作り直して、検査する

   ```bash
   python3 site/build.py
   ```

   ```bash
   python3 bench/aio_check.py
   ```

3. `site/src` と `site/public` を一緒にコミットして、`main` に入れる。Cloudflare が `site/public` を配る（数分）

`config.example`・`Base.xcconfig` を変えたときも、`/config` と最低 OS が変わるので作り直す（CI の `python3 site/build.py --check` が古さを見つける）。

## Cloudflare Pages の設定（1 回だけ、ダッシュボードで）

無料のプランのまま行う。費用は 0 円で、鍵や API トークンを GitHub に置かない。

1. Cloudflare にログインし、「Workers & Pages」→「Create」→「Pages」→「Import an existing Git repository」（Git に接続）
2. GitHub を認可して、`DKen-DevCat/Mobile-SSH-Client---Split-Keyboard` を選ぶ
3. 設定を入れて「Save and Deploy」

   | 項目 | 値 |
   | --- | --- |
   | Project name | `mobile-ssh-client---split-keyboard` |
   | Production branch | `main` |
   | Framework preset | None |
   | Build command | （空） |
   | Build output directory | `site/public` |
   | Root directory | （空。リポジトリの最上位） |

4. プロジェクトの「Settings」→「Build」→「Build watch paths」で、Include paths を `site/**` にする（Exclude paths は空）。`site/` が変わらない push ではデプロイしない（無料枠のビルド月 500 回を使わない）
5. 同じ画面の「Branch control」で、プレビューのデプロイを「None」にするか、使うブランチだけにする（任意。プレビューの URL には Cloudflare が `X-Robots-Tag: noindex` を付ける）
6. 配信されたら、下の「確かめる」を行う

項目の名前は Cloudflare の画面の変更で変わることがある。意味（ビルドしない・`site/public` を配る・`site/**` だけを見る）が同じになればよい。

### プロジェクト名が通らないとき

`---` を含む名前が拒まれたら、`mobile-ssh-client-split-keyboard` にする。URL は `site/site.json` の `base_url` の 1 か所だけにあるので、そこを `https://mobile-ssh-client-split-keyboard.pages.dev` に直し、`python3 site/build.py` で作り直してコミットする。このファイルの URL とコマンドも直す。

## wrangler で配る（Git 連携の代わり）

手元のエージェントや人が、ローカルから直接配るやり方。Cloudflare の無料のアカウントでよい。

```bash
npx wrangler login
```

```bash
npx wrangler pages deploy site/public --project-name mobile-ssh-client---split-keyboard --branch main
```

- Git 連携と混ぜない。wrangler（Direct Upload）で作ったプロジェクトは、後から Git 連携に切り替えられない。どちらかに決めてから作る
- `_headers` も一緒に送られ、効く

## 確かめる

公開した後に行う（ネットに出るので CI では動かさない）。

```bash
python3 bench/aio_check.py --online
```

- 各ページを、AI のクローラ（GPTBot・OAI-SearchBot・ChatGPT-User・ClaudeBot・Claude-SearchBot・Claude-User・PerplexityBot・Googlebot・Applebot）とブラウザの名乗りで取得し、HTTP の状態と Content-Type を出す。すべて 200 で、`.md` が `text/markdown`、`llms.txt` が `text/plain` なら合格
- ヘッダーを 1 つずつ見るなら `curl -sI https://mobile-ssh-client---split-keyboard.pages.dev/get-started.md`（`content-type: text/markdown; charset=utf-8` と `content-security-policy` が出る）

### AI のクローラを確かめる

- `robots.txt` はこのサイトのもの（`site/build.py` が作る。名前を挙げた AI のクローラと `*` を許す）が配られる。`curl -s https://mobile-ssh-client---split-keyboard.pages.dev/robots.txt` で、`User-agent: GPTBot` などが並ぶことを見る
- Cloudflare の「AI のクローラを止める」設定（AI Crawl Control・Block AI bots）と、Cloudflare が管理する robots.txt は、自分のドメイン（ゾーン）の設定。`*.pages.dev` は自分のゾーンではないので、こちらからは変えられず、効いてもいないはず
- `--online` で 403 などが出たら、Cloudflare が名乗りで止めている。ただし Cloudflare は本物のクローラを送り元の IP でも見分けるので、手元から名乗りだけを真似た取得が止められても、本物が止められているとは限らない（逆に 200 なら、名乗りでは止めていない）
- 止められているなら、GitHub の公開リポジトリ（README・`site/src`）を代わりの入口にする（`docs/proposal-2026-10-30.md` のセルフレビュー 8）
- その月の結果は `bench/visibility.md` の記録に書く
