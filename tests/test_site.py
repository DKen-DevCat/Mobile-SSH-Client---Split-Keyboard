"""公開サイトの生成（site/build.py）と、AIO の静的な検査（bench/aio_check.py）（docs/site.md）。
Python の標準ライブラリと pytest だけで動く。Linux でも通る。"""

from __future__ import annotations

import importlib.util
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "site/build.py"
CHECK = ROOT / "bench/aio_check.py"
BASE = json.loads((ROOT / "site/site.json").read_text())["base_url"]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod  # dataclass が自分のモジュールを引くため
    spec.loader.exec_module(mod)
    return mod


build = load("site_build", BUILD)


def run(*args) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True, cwd=ROOT)


def files(d: Path) -> dict[str, bytes]:
    return {p.relative_to(d).as_posix(): p.read_bytes() for p in sorted(d.rglob("*")) if p.is_file()}


@pytest.fixture(scope="module")
def built(tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("site") / "public"
    r = run(BUILD, "--out", out)
    assert r.returncode == 0, r.stderr
    return out


@pytest.fixture
def copy(built: Path, tmp_path: Path) -> Path:
    dest = tmp_path / "public"
    shutil.copytree(built, dest)
    return dest


# ─── 作り ────────────────────────────────────────────────

def test_build_is_deterministic(built: Path, tmp_path: Path):
    r = run(BUILD, "--out", tmp_path / "again")
    assert r.returncode == 0, r.stderr
    assert files(tmp_path / "again") == files(built)


def test_committed_public_is_up_to_date():
    # site/src・config.example・Base.xcconfig を変えたら、site/public も作り直して一緒に入れる
    r = run(BUILD, "--check")
    assert r.returncode == 0, r.stderr


def test_out_must_be_empty(tmp_path: Path):
    (tmp_path / "keep.txt").write_text("消してはいけない")
    r = run(BUILD, "--out", tmp_path)
    assert r.returncode == 1
    assert (tmp_path / "keep.txt").exists()


def test_every_page_has_html_and_markdown(built: Path):
    for page in build.PAGES:
        assert (built / page.file("html")).is_file()
        assert (built / page.file("md")).is_file()


def test_base_url_lives_only_in_site_json():
    # URL は変わりうる（Cloudflare が --- を拒んだら mobile-ssh-client-split-keyboard）。ソースとコードには書かない
    places = [*sorted((ROOT / "site/src").rglob("*")), BUILD, *sorted((ROOT / "bench").glob("*.py"))]
    for p in places:
        if p.is_file():
            assert BASE.split("//")[1] not in p.read_text(encoding="utf-8", errors="ignore"), p


def test_no_javascript_and_one_stylesheet(built: Path):
    assert not [f for f in files(built) if f.endswith(".js")]
    for f in built.rglob("*.html"):
        html = f.read_text()
        assert re.findall(r"<script(?![^>]*application/ld\+json)", html) == [], f
        assert html.count('rel="stylesheet"') == 1


def test_config_page_is_generated_from_the_example(built: Path):
    md = (built / "config.md").read_text()
    example = (ROOT / "ios/SplitTerm/Resources/config.example").read_text()
    for key in re.findall(r"^# ([a-z][a-z0-9-]*) =", example, re.M):
        assert f"| `{key}` |" in md
    # host の見本の値（例の接続先）は既定値ではないので、表には載せない。既定値は「なし」
    row = next(line for line in md.splitlines() if line.startswith("| `host` |"))
    assert row.startswith("| `host` | なし（何度でも書ける） |")
    for value in re.findall(r"^# host = \S+ (\S+)", example, re.M):
        assert value not in row


def test_min_ios_comes_from_the_xcconfig(built: Path):
    target = re.search(r"IPHONEOS_DEPLOYMENT_TARGET = (\d+)", (ROOT / "ios/Config/Base.xcconfig").read_text())[1]
    assert f"iOS / iPadOS {target} 以上" in (built / "index.html").read_text()


# ─── Markdown の読み方 ────────────────────────────────────────

def test_renderer_handles_tables_lists_and_human_steps():
    r = build.Renderer("t")
    html = r.blocks([
        "## 手順 {#step}",
        "",
        "| 項目 | 形 |",
        "| --- | --- |",
        "| `host` | `a\\|b` |",
        "",
        "- 外",
        "  - 中",
        "",
        "> **人の手が要る（HUMAN-ONLY）**: 信頼する",
        "",
        "```bash",
        "echo '<x>'",
        "```",
    ])
    assert '<h2 id="step">手順</h2>' in html
    assert "<td><code>a|b</code></td>" in html
    assert "<ul><li>外<ul><li>中</li></ul></li></ul>" in html
    assert '<blockquote class="human">' in html
    assert "echo &#x27;&lt;x&gt;&#x27;" in html


def test_twin_links_point_at_markdown():
    md = build.twin_markdown("## 見出し {#x}\n\n[config](/config#media) と [llms](/llms.txt)\n", "https://e.example")
    assert md == "## 見出し\n\n[config](https://e.example/config.md#media) と [llms](https://e.example/llms.txt)\n"


def test_front_matter_rejects_unknown_keys():
    with pytest.raises(build.BuildError):
        build.split_front_matter("---\ntitle: a\ndescription: b\nupdated: 2026-10-30\nheroo: x\n---\n# a\n", "t")


def test_hero_goes_between_header_and_main():
    page = build.PAGE_BY_PATH["/"]
    meta = {"title": "t", "description": "d", "updated": "2026-10-30", "h1": "t"}
    site = {"base_url": "https://e.example", "name": "n", "repo_url": "https://github.com/x/y"}
    html = build.page_html(page, meta, "<h1>t</h1>", site, {}, hero='<section class="hero">大きな区画</section>')
    assert re.search(r"</header>\n<section class=\"hero\">大きな区画</section>\n<main id=\"main\">", html)
    assert "hero" not in build.page_html(page, meta, "<h1>t</h1>", site, {})
    # メインビジュアルが上の帯を兼ねるので、そのページの印を付ける（CSS で共通のヘッダーを隠す）
    assert '<body class="has-hero">' in html


def test_head_has_icons_font_and_og_image(built: Path):
    html = (built / "index.html").read_text(encoding="utf-8")
    for tag in ('<link rel="icon" href="/favicon.ico" sizes="32x32">',
                '<link rel="icon" href="/favicon.svg" type="image/svg+xml">',
                '<link rel="apple-touch-icon" href="/apple-touch-icon.png">',
                f'<link rel="preload" href="{build.FONT}" as="font" type="font/woff2" crossorigin>',
                '<meta name="twitter:card" content="summary_large_image">'):
        assert tag in html
    assert re.search(r'<meta property="og:image" content="https://[^"]+/assets/og\.png">', html)
    for f in ("favicon.ico", "apple-touch-icon.png", "assets/og.png", build.FONT.lstrip("/"), "assets/fonts/OFL.txt"):
        assert (built / f).is_file(), f


def test_config_example_parser_groups_descriptions():
    secs = build.parse_config_example(
        "# 前書き\n#   key = value\n\n# ─── 表示 ───\n# 大きさ\n# font-size = 10\n\n"
        "# 色\n# background = #000000\n# foreground = #FFFFFF\n")
    assert [s["name"] for s in secs] == ["表示"]
    assert secs[0]["groups"][0] == {"desc": [" 大きさ"], "keys": [("font-size", "10")]}
    assert [k for k, _ in secs[0]["groups"][1]["keys"]] == ["background", "foreground"]


# ─── AIO の静的な検査 ────────────────────────────────────────

def test_aio_check_passes_on_a_fresh_build(built: Path):
    r = run(CHECK, "--public", built)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "✗" not in r.stdout


def edit(path: Path, old: str, new: str, count: int = 1) -> None:
    text = path.read_text()
    assert old in text, (path, old)
    path.write_text(text.replace(old, new, count))


def drop_config_row(p: Path) -> None:
    html = p / "config.html"
    text, n = re.subn(r"<tr><td><code>haptics</code></td>.*?</tr>", "", html.read_text())
    assert n == 1
    html.write_text(text)


BREAKS = {
    "Markdown の双子が無い": (lambda p: (p / "faq.md").unlink(), "Markdown の双子 faq.md がありません"),
    "双子の中身が違う": (lambda p: edit(p / "get-started.md", "## 1. ", "## 1. 書き足した "), "の中身が違います"),
    "古い名前": (lambda p: edit(p / "llms.txt", "> ", "> SplitTerm は "), "古い名前「SplitTerm」"),
    "切れたリンク": (lambda p: edit(p / "index.html", 'href="/config"', 'href="/nope"'), "/nope（ファイルがありません）"),
    "クローラを許していない": (lambda p: edit(p / "robots.txt", "User-agent: PerplexityBot\n", ""),
                    "User-agent: PerplexityBot の組がありません"),
    "Disallow がある": (lambda p: edit(p / "robots.txt", "User-agent: ClaudeBot\nAllow: /", "User-agent: ClaudeBot\nDisallow: /"),
                      "ClaudeBot"),
    "最低 OS が違う": (lambda p: edit(p / "faq.md", "iOS / iPadOS 17 以上", "iOS / iPadOS 16 以上"), "最低 OS"),
    "MCP の道具が無い": (lambda p: (edit(p / "mcp.html", "inbox_clean", "inbox_purge", 99),
                               edit(p / "mcp.md", "inbox_clean", "inbox_purge", 99)), "inbox_clean がありません"),
    "CSP が違う": (lambda p: edit(p / "_headers", "script-src 'none'", "script-src 'self'"), "Content-Security-Policy"),
    "Markdown の Content-Type が無い": (lambda p: edit(p / "_headers", "/*.md\n", "/*.markdown\n"), "/*.md に Content-Type"),
    "config の項目が無い": (drop_config_row, "/config に config.example の haptics がありません"),
    "JavaScript": (lambda p: edit(p / "index.html", "</main>", "<script>alert(1)</script></main>"), "<script type=''>"),
    "JSON-LD の型": (lambda p: edit(p / "faq.html", '"@type": "FAQPage"', '"@type": "WebPage"'), "FAQPage がありません"),
    "sitemap に無い": (lambda p: edit(p / "sitemap.xml",
                                    f"  <url>\n    <loc>{BASE}/mcp</loc>",
                                    f"  <url>\n    <loc>{BASE}/media</loc>"),
                      f"sitemap.xml に {BASE}/mcp がありません"),
    "llms.txt の要約が無い": (lambda p: edit(p / "llms.txt", "\n> ", "\n"), "> の要約がありません"),
    "llms-full.txt が大きすぎる": (lambda p: (p / "llms-full.txt").write_text("あ" * 90_000), "llms-full.txt が大きすぎます"),
    "人の手が要る段が無い": (lambda p: edit(p / "get-started.html", "VPN とデバイス管理", "設定", 99),
                      "「開発元の信頼」が人の手が要る（HUMAN-ONLY）段"),
    "canonical が違う": (lambda p: edit(p / "mcp.html", f'rel="canonical" href="{BASE}/mcp"',
                                      f'rel="canonical" href="{BASE}/"'),
                        "canonical が"),
}


@pytest.mark.parametrize("name", BREAKS)
def test_aio_check_catches(copy: Path, name: str):
    breaker, expect = BREAKS[name]
    breaker(copy)
    r = run(CHECK, "--public", copy)
    assert r.returncode == 1, r.stdout
    assert expect in r.stdout, r.stdout


def test_aio_check_needs_the_public_dir(tmp_path: Path):
    assert run(CHECK, "--public", tmp_path / "none").returncode == 2


# ── 手元で見るためのサーバー（site/serve.py） ─────────────────────────────

serve = load("site_serve", ROOT / "site/serve.py")


def test_serve_resolves_clean_urls_like_cloudflare(built: Path):
    def r(p):
        f, redirect = serve.resolve(built, p)
        return (f.relative_to(built).as_posix() if f else None), redirect

    assert r("/") == ("index.html", None)
    assert r("/en/") == ("en/index.html", None)
    assert r("/en") == (None, "/en/")
    assert r("/get-started") == ("get-started.html", None)
    assert r("/get-started.md") == ("get-started.md", None)
    assert r("/nope") == (None, None)
    # site/public の外は配らない
    for outside in ("/../site.json", "/%2e%2e/site.json", "/assets/../../build.py", "relative"):
        assert r(outside) == (None, None), outside


def test_serve_applies_the_headers_file(built: Path):
    rules = serve.parse_headers((built / "_headers").read_text(encoding="utf-8"))
    h = serve.headers_for("/en/index.md", rules)
    assert h["Content-Type"].startswith("text/markdown")
    assert "script-src 'none'" in h["Content-Security-Policy"]
    assert serve.headers_for("/llms.txt", rules)["Content-Type"].startswith("text/plain")


def test_serve_answers_over_http(built: Path):
    import threading
    import urllib.error
    import urllib.request
    from functools import partial

    rules = serve.parse_headers((built / "_headers").read_text(encoding="utf-8"))
    server = serve.ThreadingHTTPServer(("127.0.0.1", 0), partial(serve.Handler, public=built, rules=rules))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        with urllib.request.urlopen(base + "/get-started") as res:
            assert res.status == 200
            assert "nosniff" in res.headers["X-Content-Type-Options"]
            assert "<html" in res.read().decode("utf-8")
        with pytest.raises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(base + "/no-such-page")
        assert e.value.code == 404
    finally:
        server.shutdown()
        server.server_close()
