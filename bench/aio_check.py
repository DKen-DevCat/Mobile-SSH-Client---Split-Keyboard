#!/usr/bin/env python3
"""公開サイト（site/public）を、AI のクローラとエージェントが正しく読める形かで確かめる
（ベンチマーク A。docs/proposal-2026-10-30.md「3」、docs/site.md）。Python の標準ライブラリだけで動く。

site/build.py とは別に書いた読み取りで確かめる（作る側の誤りを、同じ誤りで見逃さないため）。
使い方: python3 bench/aio_check.py [--public DIR]
        python3 bench/aio_check.py --online [URL]
  --public  確かめる場所（既定 site/public）
  --online  公開中のサイトを、AI のクローラの名乗り（User-Agent）ごとに取得して HTTP の状態を出す。
            URL を省くと site/site.json の base_url。ネットに出るので CI では動かさない
終了コード: 0 = すべて合格 / 1 = 不合格がある / 2 = 引数誤り
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import urllib.error
import urllib.request
import urllib.robotparser
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent
sys.path.insert(0, str(BENCH))
import configspec  # noqa: E402

SITE_JSON = ROOT / "site/site.json"
PUBLIC = ROOT / "site/public"
XCCONFIG = ROOT / "ios/Config/Base.xcconfig"

AI_BOTS = ("GPTBot", "OAI-SearchBot", "ChatGPT-User", "ClaudeBot", "Claude-SearchBot", "Claude-User",
           "PerplexityBot", "Google-Extended", "Applebot-Extended")
MCP_TOOLS = ("doctor", "config_show", "config_check", "config_set", "host_add", "host_remove", "config_push",
             "pubkey_install", "app_install", "app_status", "inbox_list", "inbox_clean")
OLD_NAMES = ("SplitTerm", "splitterm.pages.dev")
CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'none'; "
       "frame-ancestors 'none'")
REQUIRED = ("index.html", "get-started.html", "config.html", "mcp.html", "media.html", "faq.html",
            "en/index.html", "en/get-started.html", "404.html", "llms.txt", "en/llms.txt", "llms-full.txt",
            "robots.txt", "sitemap.xml", "_headers")
JSONLD_TYPES = {"index.html": "SoftwareApplication", "en/index.html": "SoftwareApplication",
                "get-started.html": "HowTo", "en/get-started.html": "HowTo", "faq.html": "FAQPage"}
# Get Started で人の手が要る（HUMAN-ONLY）と書くべき所。日本語と英語の言い方のどれか
HUMAN_STEPS = {
    "Apple ID のサインイン": ("Apple ID",),
    "USB でつないで信頼": ("USB",),
    "デベロッパモード": ("デベロッパモード", "Developer Mode"),
    "開発元の信頼": ("VPN とデバイス管理", "VPN & Device Management"),
    "指紋の見比べ": ("指紋", "fingerprint"),
}
LLMS_FULL_MAX_TOKENS = 40_000
# 本文の文字を拾うとき、ここで区切る（セルや段落の文字がつながって、別の語に見えないように）
BLOCK_TAGS = {"p", "li", "td", "th", "tr", "h1", "h2", "h3", "h4", "pre", "div", "blockquote", "table", "br"}
MIN_IOS = re.compile(r"(?:iOS|iPadOS)(?:\s*/\s*iPadOS)?\s*(\d+)(?:\.\d+)?\s*(?:以上|以降|or later|and later|\+)")


# ─── 読み取り ────────────────────────────────────────────

class Doc(HTMLParser):
    """1 枚の HTML から、確かめるのに要るものだけを拾う"""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.lang = ""
        self.in_main = False
        self.main_text: list[str] = []
        self.links: list[dict] = []  # <a> と <link>（属性と tag）
        self.metas: list[dict] = []
        self.scripts: list[list] = []  # [type, 中身]
        self.ids: set[str] = set()
        self.problems: list[str] = []  # on* 属性・style など、あってはいけないもの
        self.stylesheets: list[str] = []
        self.tables: list[list[list[str]]] = []
        self.h2: list[str] = []
        self.human: list[str] = []  # <blockquote class="human"> の文字
        self._script: list | None = None
        self._table: list | None = None
        self._row: list | None = None
        self._cell: list | None = None
        self._h2: list | None = None
        self._human: list | None = None

    def handle_starttag(self, tag: str, attrs: list) -> None:
        a = {k: (v or "") for k, v in attrs}
        if "id" in a:
            self.ids.add(a["id"])
        for k, v in a.items():
            if k.startswith("on"):
                self.problems.append(f"<{tag} {k}=…>（JavaScript）")
            if k == "style":
                self.problems.append(f"<{tag} style=…>（CSP で止まる）")
            if k in ("href", "src") and v.strip().lower().startswith("javascript:"):
                self.problems.append(f"<{tag} {k}=javascript:…>")
        if tag in BLOCK_TAGS and self.in_main:
            self.main_text.append("\n")
        if tag == "html":
            self.lang = a.get("lang", "")
        elif tag == "main":
            self.in_main = True
        elif tag == "style":
            self.problems.append("<style>（CSP で止まる）")
        elif tag == "script":
            self._script = [a.get("type", ""), ""]
            if "src" in a:
                self.problems.append(f"<script src={a['src']}>")
        elif tag in ("a", "link"):
            self.links.append({"tag": tag, **a})
            if tag == "link" and a.get("rel") == "stylesheet":
                self.stylesheets.append(a.get("href", ""))
        elif tag == "meta":
            self.metas.append(a)
        if not self.in_main:
            return
        if tag == "table":
            self._table = []
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = [tag, ""]
        elif tag == "h2":
            self._h2 = [""]
        elif tag == "blockquote" and "human" in a.get("class", "").split():
            self._human = [""]

    def handle_endtag(self, tag: str) -> None:
        if tag in BLOCK_TAGS and self.in_main:
            self.main_text.append("\n")
        if tag == "main":
            self.in_main = False
        elif tag == "script" and self._script is not None:
            self.scripts.append(self._script)
            self._script = None
        elif tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(self._cell[1].strip())
            self._cell = None
        elif tag == "tr" and self._row is not None and self._table is not None:
            self._table.append(self._row)
            self._row = None
        elif tag == "table" and self._table is not None:
            self.tables.append(self._table)
            self._table = None
        elif tag == "h2" and self._h2 is not None:
            self.h2.append(self._h2[0].strip())
            self._h2 = None
        elif tag == "blockquote" and self._human is not None:
            self.human.append(self._human[0])
            self._human = None

    def handle_data(self, data: str) -> None:
        if self._script is not None:
            self._script[1] += data
            return
        if not self.in_main:
            return
        self.main_text.append(data)
        for buf in (self._cell, self._h2, self._human):
            if buf is not None:
                buf[-1] += data

    @property
    def text(self) -> str:
        return "".join(self.main_text)

    def head_links(self, rel: str) -> list[dict]:
        return [link for link in self.links if link["tag"] == "link" and link.get("rel") == rel]

    def meta(self, prop: str) -> str | None:
        for m in self.metas:
            if m.get("property") == prop or m.get("name") == prop:
                return m.get("content")
        return None


def parse_html(text: str) -> Doc:
    d = Doc()
    d.feed(text)
    d.close()
    return d


def md_text(md: str) -> str:
    """Markdown から、表示される文字だけを残す（記号の多くは normalize で消える）"""
    out = []
    fence = False
    for line in md.splitlines():
        if line.startswith("```"):
            fence = not fence
            continue
        if fence:
            out.append(line)
            continue
        if re.fullmatch(r"\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*", line):
            continue  # 表の区切り
        if re.match(r"^#{1,6}\s", line):
            line = re.sub(r"^#{1,6}\s+", "", line)
        else:
            line = re.sub(r"^(\s*>\s?)+", "", line)
            line = re.sub(r"^\s*([-*]|\d+\.)\s+", "", line)
        line = re.sub(r"\[([^\]]*)\]\([^)\s]*\)", r"\1", line)
        out.append(line)
    return "\n".join(out)


def normalize(text: str) -> str:
    """文字と数字だけを残す（空白・記号・Markdown の飾りを比べない）"""
    return re.sub(r"[\W_]+", "", text)


def first_diff(a: str, b: str) -> str:
    i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
    return f"HTML「…{a[max(0, i - 20):i + 20]}…」/ Markdown「…{b[max(0, i - 20):i + 20]}…」"


# ─── サイト ───────────────────────────────────────────────

class Site:
    def __init__(self, public: Path, base: str):
        self.public = public
        self.base = base.rstrip("/")
        self.files = sorted(p.relative_to(public).as_posix() for p in public.rglob("*") if p.is_file())
        self.html = {f: parse_html(self.read(f)) for f in self.files if f.endswith(".html")}

    def read(self, rel: str) -> str:
        return (self.public / rel).read_text(encoding="utf-8")

    def exists(self, rel: str) -> bool:
        return (self.public / rel).is_file()

    def indexable(self) -> list[str]:
        return [f for f, d in self.html.items()
                if "noindex" not in (d.meta("robots") or "")]

    @staticmethod
    def clean_path(html_file: str) -> str:
        """index.html → /、en/index.html → /en/、get-started.html → /get-started"""
        if html_file == "index.html":
            return "/"
        if html_file.endswith("/index.html"):
            return "/" + html_file[: -len("index.html")]
        return "/" + html_file[: -len(".html")]

    @staticmethod
    def twin(html_file: str) -> str:
        return html_file[: -len(".html")] + ".md"

    def resolve(self, url: str) -> tuple[str | None, str, str | None]:
        """リンクを（公開のファイル、#の後、だめな理由）に。サイトの外は（None, "", None）"""
        if url.startswith(self.base + "/") or url == self.base:
            path = url[len(self.base):] or "/"
        elif url.startswith("/") and not url.startswith("//"):
            path = url
        elif re.match(r"^[a-z][a-z0-9+.-]*:", url) or url.startswith("//"):
            return None, "", None
        else:
            return None, "", "サイトの中は / で始まるリンクにする"
        path, _, frag = path.partition("#")
        path = path.split("?", 1)[0]
        if path.endswith(".html"):
            return None, frag, ".html を付けない URL にする（Cloudflare Pages は付けると転送する）"
        rel = path.lstrip("/")
        for cand in ([rel + "index.html"] if path.endswith("/") else [rel, rel + ".html"]):
            if cand and self.exists(cand):
                return cand, frag, None
        return None, frag, "ファイルがありません"


# ─── 検査 ───────────────────────────────────────────────
# どれも、だめな所の一覧を返す（空なら合格）

def check_files(s: Site) -> list[str]:
    bad = [f"{f} がありません" for f in REQUIRED if not s.exists(f)]
    bad += [f"JavaScript のファイルがあります: {f}" for f in s.files if f.endswith((".js", ".mjs"))]
    return bad


LLMS_ITEM = re.compile(r"^- \[([^\]]+)\]\((\S+)\)(?::\s+\S.*)?$")


def check_llms(s: Site) -> list[str]:
    bad = []
    for name in ("llms.txt", "en/llms.txt"):
        if not s.exists(name):
            continue
        lines = s.read(name).splitlines()
        if not lines or not lines[0].startswith("# "):
            bad.append(f"{name}: 1 行目が「# 名前」ではありません")
            continue
        if sum(1 for line in lines if line.startswith("# ")) != 1:
            bad.append(f"{name}: # の見出しは 1 つだけにします")
        rest = [line for line in lines[1:] if line.strip()]
        if not rest or not rest[0].startswith("> "):
            bad.append(f"{name}: 見出しの次に > の要約がありません")
        h2 = [i for i, line in enumerate(lines) if line.startswith("## ")]
        if not h2:
            bad.append(f"{name}: ## の節がありません")
        items = 0
        for line in lines[h2[0] if h2 else len(lines):]:
            if not line.strip() or line.startswith("## "):
                continue
            m = LLMS_ITEM.match(line)
            if not m:
                bad.append(f"{name}: 節の中は「- [名前](URL): 説明」の行だけにします: {line}")
                continue
            items += 1
            if not m.group(2).startswith(s.base + "/"):
                bad.append(f"{name}: リンクはサイトの絶対 URL にします: {m.group(2)}")
        if items < 3:
            bad.append(f"{name}: リンクが少なすぎます（{items} 本）")
    return bad


def md_links(text: str) -> list[str]:
    fence = False
    urls = []
    for line in text.splitlines():
        if line.startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        line = re.sub(r"`[^`]*`", "", line)
        urls += re.findall(r"\]\((\S+?)\)", line) + re.findall(r"<(https?://[^>\s]+)>", line)
    return urls


def check_links(s: Site) -> tuple[list[str], int]:
    bad, count = [], 0

    def check(src: str, url: str) -> None:
        nonlocal count
        if url.startswith("#"):  # 同じページの中
            count += 1
            if src in s.html and url[1:] not in s.html[src].ids:
                bad.append(f"{src}: {url}（このページにありません）")
            return
        target, frag, why = s.resolve(url)
        if why:
            bad.append(f"{src}: {url}（{why}）")
            return
        if target is None:
            return
        count += 1
        if frag:
            html = target if target.endswith(".html") else (target[: -len(".md")] + ".html")
            if html in s.html and frag not in s.html[html].ids:
                bad.append(f"{src}: {url}（#{frag} が {html} にありません）")

    for f, d in s.html.items():
        for link in d.links:
            if link.get("href"):
                check(f, link["href"])
    for f in s.files:
        if f.endswith(".md") or f.endswith(".txt"):
            for url in md_links(s.read(f)):
                check(f, url)
    return bad, count


def check_twins(s: Site) -> list[str]:
    bad = []
    for f in s.indexable():
        twin = Site.twin(f)
        if not s.exists(twin):
            bad.append(f"{f}: Markdown の双子 {twin} がありません")
            continue
        alt = [link.get("href") for link in s.html[f].head_links("alternate")
               if link.get("type") == "text/markdown"]
        if alt != ["/" + twin]:
            bad.append(f"{f}: <link rel=alternate type=text/markdown> が /{twin} を指していません（{alt}）")
        a, b = normalize(s.html[f].text), normalize(md_text(s.read(twin)))
        if a != b:
            bad.append(f"{f} と {twin} の中身が違います: {first_diff(a, b)}")
    return bad


def check_jsonld(s: Site, ios: str) -> list[str]:
    bad = []
    for f in s.indexable():
        d = s.html[f]
        blocks = [t for typ, t in d.scripts if typ == "application/ld+json"]
        if not blocks:
            bad.append(f"{f}: JSON-LD がありません")
            continue
        try:
            data = [json.loads(t) for t in blocks]
        except json.JSONDecodeError as e:
            bad.append(f"{f}: JSON-LD が読めません（{e}）")
            continue
        types = [x.get("@type") for x in data]
        for x in data:
            if x.get("@context") not in ("https://schema.org", "https://schema.org/", "http://schema.org"):
                bad.append(f"{f}: JSON-LD の @context が schema.org ではありません")
            if "url" in x and x["url"] != s.base + Site.clean_path(f):
                bad.append(f"{f}: JSON-LD の url が正規の URL と違います（{x['url']}）")
        want = JSONLD_TYPES.get(f)
        if want and want not in types:
            bad.append(f"{f}: JSON-LD の @type に {want} がありません（{types}）")
        for x in data:
            t = x.get("@type")
            if t == "SoftwareApplication":
                if str(x.get("offers", {}).get("price")) != "0":
                    bad.append(f"{f}: SoftwareApplication の offers.price が 0 ではありません")
                if f"iOS {ios}" not in x.get("operatingSystem", ""):
                    bad.append(f"{f}: SoftwareApplication の operatingSystem に iOS {ios} がありません")
                if "aggregateRating" in x or "review" in x:
                    bad.append(f"{f}: 評価やレビューを書かない（実在しない）")
            elif t == "HowTo":
                steps = x.get("step", [])
                if len(steps) < 5 or not all(st.get("name") and st.get("text") for st in steps):
                    bad.append(f"{f}: HowTo の step が足りないか、name・text が空です")
            elif t == "FAQPage":
                qs = x.get("mainEntity", [])
                if len(qs) != len(d.h2):
                    bad.append(f"{f}: FAQPage の質問の数（{len(qs)}）が ## の数（{len(d.h2)}）と違います")
                for q in qs:
                    if q.get("@type") != "Question" or not q.get("acceptedAnswer", {}).get("text"):
                        bad.append(f"{f}: FAQPage に答えの無い質問があります: {q.get('name')}")
    return bad


def check_head(s: Site) -> list[str]:
    bad = []
    alternates: dict[str, dict[str, str]] = {}
    for f in s.indexable():
        d = s.html[f]
        url = s.base + Site.clean_path(f)
        if d.lang not in ("ja", "en"):
            bad.append(f"{f}: <html lang> が ja か en ではありません")
        canon = [link.get("href") for link in d.head_links("canonical")]
        if canon != [url]:
            bad.append(f"{f}: canonical が {url} ではありません（{canon}）")
        if d.meta("og:url") != url:
            bad.append(f"{f}: og:url が canonical と違います")
        for prop in ("og:title", "og:description", "og:type", "description"):
            if not d.meta(prop):
                bad.append(f"{f}: {prop} がありません")
        hl = {link.get("hreflang"): link.get("href") for link in d.head_links("alternate") if link.get("hreflang")}
        if hl.get(d.lang) != url:
            bad.append(f"{f}: 自分の言語（{d.lang}）の hreflang がありません")
        if "x-default" not in hl:
            bad.append(f"{f}: hreflang x-default がありません")
        for lang, href in hl.items():
            target, _, why = s.resolve(href or "")
            if why or target is None:
                bad.append(f"{f}: hreflang={lang} の {href} がありません")
        alternates[url] = hl
    for url, hl in alternates.items():
        for lang, href in hl.items():
            if lang != "x-default" and href != url and alternates.get(href, {}).get(lang) != href:
                bad.append(f"{url} → {href}（{lang}）: 向こうから戻る hreflang がありません")
            if lang != "x-default" and href != url and url not in alternates.get(href, {}).values():
                bad.append(f"{href} に {url} への hreflang がありません")
    return bad


def check_robots(s: Site) -> list[str]:
    if not s.exists("robots.txt"):
        return []
    text = s.read("robots.txt")
    bad = []
    groups: dict[str, list[str]] = {}
    agents: list[str] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        k, _, v = line.partition(":")
        k, v = k.strip().lower(), v.strip()
        if k == "user-agent":
            if agents and groups.get(agents[-1]):
                agents = []
            agents.append(v.lower())
            groups.setdefault(v.lower(), [])
        elif k in ("allow", "disallow"):
            for a in agents:
                groups[a].append(f"{k}:{v}")
    for bot in (*AI_BOTS, "*"):
        rules = groups.get(bot.lower())
        if rules is None:
            bad.append(f"robots.txt に User-agent: {bot} の組がありません")
        elif "allow:/" not in rules or any(r.startswith("disallow:") and r != "disallow:" for r in rules):
            bad.append(f"robots.txt の {bot} が Allow: / ではないか、Disallow があります（{rules}）")
    rp = urllib.robotparser.RobotFileParser()
    rp.parse(text.splitlines())
    for bot in AI_BOTS:
        for f in s.indexable():
            if not rp.can_fetch(bot, s.base + Site.clean_path(f)):
                bad.append(f"robots.txt が {bot} に {Site.clean_path(f)} を許していません")
    if f"Sitemap: {s.base}/sitemap.xml" not in text.splitlines():
        bad.append("robots.txt に Sitemap の行がありません")
    return bad


def check_sitemap(s: Site) -> list[str]:
    if not s.exists("sitemap.xml"):
        return []
    try:
        root = ET.fromstring(s.read("sitemap.xml"))
    except ET.ParseError as e:
        return [f"sitemap.xml が読めません（{e}）"]
    ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    bad, locs = [], []
    for u in root.findall("s:url", ns):
        loc = (u.findtext("s:loc", default="", namespaces=ns) or "").strip()
        lastmod = (u.findtext("s:lastmod", default="", namespaces=ns) or "").strip()
        locs.append(loc)
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", lastmod):
            bad.append(f"sitemap.xml: {loc} の lastmod が YYYY-MM-DD ではありません（{lastmod!r}）")
        target, _, why = s.resolve(loc)
        if why or target is None or not target.endswith(".html"):
            bad.append(f"sitemap.xml: {loc} のページがありません")
    want = {s.base + Site.clean_path(f) for f in s.indexable()}
    for url in sorted(want - set(locs)):
        bad.append(f"sitemap.xml に {url} がありません")
    for url in sorted(set(locs) - want):
        bad.append(f"sitemap.xml に載せてはいけない {url} があります")
    if len(locs) != len(set(locs)):
        bad.append("sitemap.xml に同じ URL が 2 回あります")
    return bad


def check_llms_full(s: Site) -> list[str]:
    if not s.exists("llms-full.txt"):
        return []
    text = s.read("llms-full.txt")
    tokens = math.ceil(len(text) / 2)
    bad = []
    if tokens > LLMS_FULL_MAX_TOKENS:
        bad.append(f"llms-full.txt が大きすぎます（約 {tokens:,} トークン > {LLMS_FULL_MAX_TOKENS:,}）")
    for f, d in s.html.items():
        if d.lang == "ja" and f in s.indexable():
            h1 = s.read(Site.twin(f)).splitlines()[0] if s.exists(Site.twin(f)) else ""
            if h1 and h1 not in text:
                bad.append(f"llms-full.txt に {Site.twin(f)} が入っていません")
    return bad


def check_config(s: Site, spec: dict[str, list[str]]) -> list[str]:
    if "config.html" not in s.html:
        return []
    rows = []
    for t in s.html["config.html"].tables:
        if t and t[0][:3] == ["項目", "既定値", "説明"]:
            rows += t[1:]
    keys = [r[0] for r in rows]
    bad = [f"/config に {k} が 2 回あります" for k in sorted({k for k in keys if keys.count(k) > 1})]
    missing, extra = sorted(set(spec) - set(keys)), sorted(set(keys) - set(spec))
    bad += [f"/config に config.example の {k} がありません" for k in missing]
    bad += [f"/config に config.example に無い {k} があります" for k in extra]
    for r in rows:
        key, default = r[0], r[1]
        if key not in spec or key in configspec.EXAMPLE_ONLY:
            continue
        for v in spec[key]:
            if (v or "空") not in default:
                bad.append(f"/config の {key} の既定値に {v or '空'} がありません（{default}）")
    md = s.read("config.md") if s.exists("config.md") else ""
    bad += [f"config.md に {k} がありません" for k in spec if f"`{k}`" not in md]
    return bad


def check_min_ios(s: Site, ios: str) -> list[str]:
    bad = []
    for f in s.files:
        if not f.endswith((".html", ".md", ".txt")):
            continue
        text = s.html[f].text + " ".join(t for _, t in s.html[f].scripts) if f in s.html else s.read(f)
        for m in MIN_IOS.finditer(text):
            if m.group(1) != ios:
                bad.append(f"{f}: 「{m.group(0)}」が最低 OS（IPHONEOS_DEPLOYMENT_TARGET の {ios}）と違います")
    for f in ("index.html", "faq.html", "en/index.html", "llms.txt", "en/llms.txt"):
        if not s.exists(f):
            continue
        text = s.html[f].text if f in s.html else s.read(f)
        if not any(m.group(1) == ios for m in MIN_IOS.finditer(text)):
            bad.append(f"{f} に最低 OS（iOS {ios} 以上）が書いてありません")
    return bad


def check_mcp(s: Site) -> list[str]:
    bad = []
    for f in ("mcp.html", "mcp.md"):
        if not s.exists(f):
            continue
        text = s.html[f].text if f in s.html else s.read(f)
        for tool in MCP_TOOLS:
            if not re.search(rf"(?<![\w]){re.escape(tool)}(?![\w])", text):
                bad.append(f"{f} に MCP の道具 {tool} がありません")
        for cmd in ("claude mcp add splitterm --", "swift build -c release --package-path ios/TermCore"):
            if cmd not in text:
                bad.append(f"{f} に「{cmd}」がありません")
    return bad


def check_names(s: Site, name: str) -> list[str]:
    bad = []
    for f in s.files:
        # 人とエージェントが読む文書だけ（画像・フォント・CSS・ヘッダーは見ない）
        if not f.endswith((".html", ".md", ".txt", ".xml")):
            continue
        text = s.read(f)
        for old in OLD_NAMES:
            if old in text:
                bad.append(f"{f} に古い名前「{old}」があります")
    for f in s.indexable():
        if name not in s.html[f].text:
            bad.append(f"{f} の本文にアプリの名前「{name}」がありません")
    for f in ("llms.txt", "en/llms.txt", "llms-full.txt"):
        if s.exists(f) and name not in s.read(f):
            bad.append(f"{f} にアプリの名前がありません")
    return bad


def check_one_line(s: Site, name: str) -> list[str]:
    lines = {
        "index.html": f"{s.base}/get-started.md を読んで、この Mac と iPhone に {name} を入れて設定して",
        "en/index.html": f"Read {s.base}/en/get-started.md and install and set up {name} on this Mac and iPhone",
    }
    return [f"{f} にエージェントに渡す 1 行「{line}」がありません"
            for f, line in lines.items() if f in s.html and line not in s.html[f].text]


def check_human_steps(s: Site) -> list[str]:
    bad = []
    for f in ("get-started.html", "en/get-started.html"):
        if f not in s.html:
            continue
        blocks = s.html[f].human
        for label, words in HUMAN_STEPS.items():
            if not any(any(w in b for w in words) for b in blocks):
                bad.append(f"{f}: 「{label}」が人の手が要る（HUMAN-ONLY）段として書いてありません")
    return bad


def parse_headers(text: str) -> dict[str, list[tuple[str, str]]]:
    rules: dict[str, list[tuple[str, str]]] = {}
    current = None
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[0].isspace():
            current = raw.strip()
            rules.setdefault(current, [])
        elif current is not None:
            k, _, v = raw.strip().partition(":")
            rules[current].append((k.strip().lower(), v.strip()))
    return rules


def check_headers(s: Site) -> list[str]:
    if not s.exists("_headers"):
        return []
    rules = parse_headers(s.read("_headers"))
    bad = []

    def has(pattern: str, key: str, value: str | None) -> None:
        got = [v for k, v in rules.get(pattern, []) if k == key.lower()]
        if not got or (value is not None and value not in got):
            bad.append(f"_headers の {pattern} に {key}: {value or '…'} がありません（{got}）")

    has("/*", "Content-Security-Policy", CSP)
    has("/*", "X-Content-Type-Options", "nosniff")
    has("/*", "Referrer-Policy", "strict-origin-when-cross-origin")
    has("/*", "Permissions-Policy", None)
    has("/*.md", "Content-Type", "text/markdown; charset=utf-8")
    for f in s.files:
        if re.fullmatch(r"(en/)?llms(-full)?\.txt", f):
            has("/" + f, "Content-Type", "text/plain; charset=utf-8")
    return bad


def check_no_js(s: Site) -> list[str]:
    bad = []
    css = [f for f in s.files if f.endswith(".css")]
    if len(css) != 1:
        bad.append(f"CSS は 1 ファイルにします（{css}）")
    elif (s.public / css[0]).stat().st_size > 10_000:
        bad.append(f"{css[0]} が 10KB を超えています")
    for f, d in s.html.items():
        bad += [f"{f}: {p}" for p in d.problems]
        bad += [f"{f}: <script type={t!r}>（JSON-LD のほかは置かない）" for t, _ in d.scripts
                if t != "application/ld+json"]
        if len(d.stylesheets) != 1 or d.stylesheets[0] != "/" + (css[0] if css else ""):
            bad.append(f"{f}: スタイルシートの指定が 1 つではありません（{d.stylesheets}）")
    return bad


# ─── まとめ ──────────────────────────────────────────────

def load_site_json() -> dict:
    return json.loads(SITE_JSON.read_text(encoding="utf-8"))


def min_ios() -> str:
    m = re.search(r"^IPHONEOS_DEPLOYMENT_TARGET\s*=\s*(\d+)", XCCONFIG.read_text(encoding="utf-8"), re.M)
    if not m:
        raise SystemExit("Base.xcconfig に IPHONEOS_DEPLOYMENT_TARGET がありません")
    return m.group(1)


def run_checks(public: Path) -> list[tuple[str, list[str], str]]:
    """（項目、だめな所、合格のときに添える一言）の一覧"""
    meta = load_site_json()
    s = Site(public, meta["base_url"])
    ios = min_ios()
    spec = configspec.load_spec()
    links, n_links = check_links(s)
    return [
        ("必要なファイル", check_files(s), f"{len(s.files)} ファイル"),
        ("llms.txt の形（llmstxt.org）", check_llms(s), "llms.txt・en/llms.txt"),
        ("サイトの中のリンク", links, f"{n_links} 本"),
        ("HTML と Markdown の双子の中身", check_twins(s), f"{len(s.indexable())} ページ"),
        ("JSON-LD の型", check_jsonld(s, ios), "SoftwareApplication・HowTo・FAQPage"),
        ("canonical・hreflang・OpenGraph", check_head(s), ""),
        ("robots.txt が AI のクローラを許す", check_robots(s), f"{len(AI_BOTS)} の名前と *"),
        ("sitemap.xml", check_sitemap(s), ""),
        ("llms-full.txt の大きさ", check_llms_full(s), f"約 {math.ceil(len(s.read('llms-full.txt')) / 2):,} トークン"
         if s.exists("llms-full.txt") else ""),
        ("/config と config.example", check_config(s, spec), f"{len(spec)} 項目"),
        ("最低 OS と IPHONEOS_DEPLOYMENT_TARGET", check_min_ios(s, ios), f"iOS {ios}"),
        ("/mcp の道具", check_mcp(s), f"{len(MCP_TOOLS)} 個"),
        ("アプリの名前", check_names(s, meta["name"]), meta["name"]),
        ("エージェントに渡す 1 行", check_one_line(s, meta["name"]), "日本語・英語"),
        ("人の手が要る段（HUMAN-ONLY）", check_human_steps(s), f"{len(HUMAN_STEPS)} か所"),
        ("_headers（CSP・Content-Type）", check_headers(s), ""),
        ("JavaScript なし・CSS 1 つ", check_no_js(s), ""),
    ]


def report(public: Path) -> int:
    results = run_checks(public)
    print(f"AIO の静的な検査: {public}")
    failed = 0
    for name, bad, note in results:
        if bad:
            failed += 1
            print(f"  ✗ {name}")
            for b in bad[:20]:
                print(f"      - {b}")
            if len(bad) > 20:
                print(f"      …ほか {len(bad) - 20} 件")
        else:
            print(f"  ✓ {name}" + (f"（{note}）" if note else ""))
    print(f"結果: {len(results)} 項目のうち {len(results) - failed} 項目が合格")
    return 1 if failed else 0


# ─── --online（公開中のサイトを各クローラの名乗りで取る） ──────────────────
# 名乗りは各社の公開している形に近づけたもの。Cloudflare は本物のクローラを IP でも見分けるので、
# ここで 403 が出ても本物が止められているとは限らない（逆に 200 なら名乗りでは止めていない）。
# Google-Extended と Applebot-Extended は robots.txt の上の名前で、取得は Googlebot と Applebot が行う
CRAWLERS = {
    "GPTBot": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.1; +https://openai.com/gptbot)",
    "OAI-SearchBot": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; OAI-SearchBot/1.0; "
                     "+https://openai.com/searchbot)",
    "ChatGPT-User": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; "
                    "+https://openai.com/bot",
    "ClaudeBot": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; "
                 "+claudebot@anthropic.com)",
    "Claude-SearchBot": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-SearchBot/1.0; "
                        "+https://www.anthropic.com)",
    "Claude-User": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; "
                   "+Claude-User@anthropic.com)",
    "PerplexityBot": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; PerplexityBot/1.0; "
                     "+https://perplexity.ai/perplexitybot)",
    "Google-Extended（Googlebot）": "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Applebot-Extended（Applebot）": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                                    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15 "
                                    "(Applebot/0.1; +http://www.apple.com/go/applebot)",
    "ブラウザ": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            "Version/18.0 Safari/605.1.15",
}
ONLINE_PATHS = ("/", "/get-started", "/get-started.md", "/en/", "/llms.txt", "/llms-full.txt", "/robots.txt",
                "/sitemap.xml")
WANT_TYPES = {".md": "text/markdown", ".txt": "text/plain", ".xml": "xml"}


def fetch(url: str, ua: str) -> tuple[int | str, str]:
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", "") if e.headers else ""
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return f"接続できない（{getattr(e, 'reason', e)}）", ""


def online(base: str) -> int:
    base = base.rstrip("/")
    print(f"公開中のサイトを各クローラの名乗りで取得: {base}")
    failed = 0
    for bot, ua in CRAWLERS.items():
        cells = []
        for path in ONLINE_PATHS:
            status, ctype = fetch(base + path, ua)
            ext = next((e for e in WANT_TYPES if path.endswith(e)), None)
            ok = status == 200 and (ext is None or WANT_TYPES[ext] in ctype)
            failed += not ok
            note = "" if ok or status != 200 else f" {ctype or '型なし'}"
            cells.append(f"{path} {status}{note}{'' if ok else ' ✗'}")
        print(f"  {bot}: " + "  ".join(cells))
    if failed:
        print(f"結果: 200 でないか、Content-Type が違うものが {failed} 件。site/README.md の「AI のクローラを確かめる」を見る")
        return 1
    print("結果: すべて 200（Content-Type も期待どおり）")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="公開サイトの AIO の静的な検査（ベンチマーク A）")
    ap.add_argument("--public", type=Path, default=PUBLIC, help="確かめる場所（既定 site/public）")
    ap.add_argument("--online", nargs="?", const="", metavar="URL",
                    help="公開中のサイトを各クローラの名乗りで取得する（既定は site.json の base_url）")
    args = ap.parse_args(argv)
    if args.online is not None:
        return online(args.online or load_site_json()["base_url"])
    if not args.public.is_dir():
        print(f"ありません: {args.public}（先に python3 site/build.py）", file=sys.stderr)
        return 2
    return report(args.public)


if __name__ == "__main__":
    sys.exit(main())
