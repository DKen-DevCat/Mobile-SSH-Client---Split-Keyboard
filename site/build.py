#!/usr/bin/env python3
"""公開サイト（Get Started・AIO）を site/src の Markdown から作る（docs/proposal-2026-10-30.md「1」「3」、docs/site.md）。

Python の標準ライブラリだけで動く。Cloudflare Pages ではビルドしない（生成物の site/public も git に入れ、そのまま配る）。
使い方: python3 site/build.py [--out DIR] [--check]
  引数なし  site/public を作り直す
  --out     ほかの場所（無いか空のフォルダ）に作る。テスト用
  --check   作り直した結果が site/public と同じかを確かめる。違えば 1（CI で使う。直すには引数なしで動かして入れる）
入力: site/site.json（URL・名前。URL はここ 1 か所だけ）、site/src（ページ）、
      config.example（/config の表）、Base.xcconfig（最低 OS）
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
SRC = SITE / "src"
PUBLIC = SITE / "public"
CONFIG_EXAMPLE = ROOT / "ios/SplitTerm/Resources/config.example"
XCCONFIG = ROOT / "ios/Config/Base.xcconfig"

# robots.txt で名前を挙げて許すクローラ（AI の学習・検索・ユーザーの代わりの取得）。* も許す
AI_BOTS = (
    "GPTBot", "OAI-SearchBot", "ChatGPT-User",
    "ClaudeBot", "Claude-SearchBot", "Claude-User",
    "PerplexityBot", "Google-Extended", "Applebot-Extended",
)

# サイトのフォント（JetBrains Mono、OFL。site/src/assets/fonts/）と OGP の画像
FONT = "/assets/fonts/jetbrains-mono-latin.woff2"
OG_IMAGE = "/assets/og.png"
CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'none'; "
       "frame-ancestors 'none'")


@dataclass(frozen=True)
class Page:
    src: str  # site/src からの場所
    path: str  # 公開の URL のパス（/、/get-started、/en/）
    lang: str
    nav: str  # ナビに出す名前
    alt: str | None = None  # 別の言語の同じページ
    schema: str = "TechArticle"  # JSON-LD の @type

    def file(self, ext: str) -> str:
        """公開のファイルの場所（/ → index.html、/get-started → get-started.html）"""
        p = self.path.lstrip("/")
        return f"{p}index.{ext}" if p == "" or p.endswith("/") else f"{p}.{ext}"


# 並びはナビと llms-full.txt の順
PAGES = (
    Page("index.md", "/", "ja", "ホーム", alt="/en/", schema="SoftwareApplication"),
    Page("get-started.md", "/get-started", "ja", "はじめる", alt="/en/get-started", schema="HowTo"),
    Page("config.md", "/config", "ja", "config"),
    Page("mcp.md", "/mcp", "ja", "MCP"),
    Page("media.md", "/media", "ja", "メディア"),
    Page("faq.md", "/faq", "ja", "よくある質問", schema="FAQPage"),
    Page("en/index.md", "/en/", "en", "Home", alt="/", schema="SoftwareApplication"),
    Page("en/get-started.md", "/en/get-started", "en", "Get Started", alt="/get-started", schema="HowTo"),
)
PAGE_BY_PATH = {p.path: p for p in PAGES}


class BuildError(Exception):
    pass


# ─── 入力 ────────────────────────────────────────────────

def load_site() -> dict:
    site = json.loads((SITE / "site.json").read_text(encoding="utf-8"))
    for k in ("base_url", "name", "repo_url"):
        if not site.get(k):
            raise BuildError(f"site/site.json に {k} がありません")
    site["base_url"] = site["base_url"].rstrip("/")
    return site


def min_ios() -> str:
    """Base.xcconfig の IPHONEOS_DEPLOYMENT_TARGET の大きい数（17.0 → 17）"""
    m = re.search(r"^IPHONEOS_DEPLOYMENT_TARGET\s*=\s*(\d+)(?:\.\d+)*\s*$",
                  XCCONFIG.read_text(encoding="utf-8"), re.M)
    if not m:
        raise BuildError(f"{XCCONFIG} に IPHONEOS_DEPLOYMENT_TARGET がありません")
    return m.group(1)


def split_front_matter(text: str, name: str) -> tuple[dict, str]:
    if not text.startswith("---\n"):
        raise BuildError(f"{name}: 先頭に front matter（---）がありません")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise BuildError(f"{name}: front matter が閉じていません")
    meta = {}
    for line in text[4:end].splitlines():
        k, sep, v = line.partition(":")
        if not sep:
            raise BuildError(f"{name}: front matter の行 `{line}` は `key: value` の形ではありません")
        meta[k.strip()] = v.strip()
    unknown = sorted(set(meta) - {"title", "description", "updated", "hero"})
    if unknown:
        raise BuildError(f"{name}: front matter の知らない項目 {unknown}（title・description・updated・hero）")
    for k in ("title", "description", "updated"):
        if not meta.get(k):
            raise BuildError(f"{name}: front matter に {k} がありません")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", meta["updated"]):
        raise BuildError(f"{name}: updated は YYYY-MM-DD で書きます")
    return meta, text[end + 5:]


PLACEHOLDER = re.compile(r"\{\{([a-z_]+)\}\}")


def fill(text: str, values: dict, name: str) -> str:
    """{{base}} などを置き換える（1 回だけ。置き換えた中身はもう見ない）"""
    def repl(m: re.Match) -> str:
        if m.group(1) not in values:
            raise BuildError(f"{name}: 知らない置き換え {m.group(0)}")
        return values[m.group(1)]
    return PLACEHOLDER.sub(repl, text)


# ─── config.example から /config の表を作る ─────────────────────

SECTION_LINE = re.compile(r"^#\s*─+\s*(.+?)\s*─+\s*$")
KEY_LINE = re.compile(r"^# ([a-z][a-z0-9-]*) =(?: (.*))?$")
SECTION_IDS = {"接続": "connection", "表示": "display", "キーボード": "keyboard", "操作": "touch",
               "メディア": "media", "安全": "security"}
# 見本に書いてある値が既定値ではなく例のもの（書かなければ 1 つも無い）
EXAMPLE_ONLY = {"host"}


def parse_config_example(text: str) -> list[dict]:
    """区分ごとに {name, intro, groups: [{desc, keys: [(key, value)]}]}。
    説明の行（# …）の後に続く `# key = value` の行が 1 つの組。空行で組が終わる。項目の無い説明は区分の前書き"""
    sections: list[dict] = []
    desc: list[str] = []
    group = None
    for no, line in enumerate(text.splitlines(), 1):
        m = SECTION_LINE.match(line)
        if m:
            sections.append({"name": m.group(1), "intro": [], "groups": []})
            desc, group = [], None
            continue
        if not sections:
            continue  # 先頭の書き方の説明は、/config では手で書く
        if not line.strip():
            if group is None and desc:
                sections[-1]["intro"] += desc
            desc, group = [], None
            continue
        km = KEY_LINE.match(line)
        if km:
            if group is None:
                group = {"desc": desc, "keys": []}
                sections[-1]["groups"].append(group)
                desc = []
            group["keys"].append((km.group(1), (km.group(2) or "").strip()))
            continue
        if not line.startswith("#"):
            raise BuildError(f"config.example の {no} 行目: 見本の行はすべて # で始まるはずです")
        group = None
        desc.append(line[1:])
    if not sections:
        raise BuildError("config.example に区分（# ─── … ───）がありません")
    return sections


def describe(lines: list[str]) -> str:
    parts = []
    for raw in lines:
        s = raw[1:] if raw.startswith(" ") else raw
        m = re.match(r"^\s{2,}(\S+)\s{2,}(.+)$", s)
        if m:  # 選べる値の説明（`  auto    接続先が…`）
            parts.append(f"・`{m.group(1)}`: {m.group(2).strip()}")
        elif s.strip():
            parts.append(s.strip())
    return " ".join(parts).replace("|", "\\|")


def format_default(key: str, values: list[str]) -> str:
    if key in EXAMPLE_ONLY:
        return "なし（何度でも書ける）"
    if len(values) > 1:
        return " ".join(f"`{v}`" for v in values) + "（番号ごとに上書きできる）"
    return f"`{values[0]}`" if values[0] else "空"


def config_reference(example: str) -> str:
    out = []
    for sec in parse_config_example(example):
        sid = next((v for k, v in SECTION_IDS.items() if sec["name"].startswith(k)), None)
        if sid is None:
            raise BuildError(f"config.example の区分「{sec['name']}」の id を SECTION_IDS に足してください")
        out.append(f"## {sec['name']} {{#{sid}}}")
        if sec["intro"]:
            out.append(describe(sec["intro"]))
        rows = ["| 項目 | 既定値 | 説明 |", "| --- | --- | --- |"]
        for g in sec["groups"]:
            text = describe(g["desc"])
            keys = list(dict.fromkeys(k for k, _ in g["keys"]))
            for key in keys:
                values = [v for k, v in g["keys"] if k == key]
                rows.append(f"| `{key}` | {format_default(key, values)} | {text} |")
        out.append("\n".join(rows))
    return "\n\n".join(out)


# ─── Markdown → HTML（このサイトで使う分だけ） ─────────────────────

HEADING = re.compile(r"^(#{1,4})\s+(.+?)(?:\s+\{#([a-z0-9][a-z0-9-]*)\})?\s*$")
LIST_ITEM = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")
FENCE = re.compile(r"^```\s*([\w+-]*)\s*$")
TABLE_SEP = re.compile(r"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$")
INLINE = re.compile(r"`([^`]+)`|<(https?://[^>\s]+)>|\[([^\]]+)\]\(([^)\s]+)\)|\*\*(.+?)\*\*")


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def inline(text: str) -> str:
    out, pos = [], 0
    for m in INLINE.finditer(text):
        out.append(esc(text[pos:m.start()]))
        code, auto, label, href, strong = m.groups()
        if code is not None:
            out.append(f"<code>{esc(code)}</code>")
        elif auto is not None:
            out.append(f'<a href="{esc(auto)}">{esc(auto)}</a>')
        elif label is not None:
            out.append(f'<a href="{esc(href)}">{inline(label)}</a>')
        else:
            out.append(f"<strong>{inline(strong)}</strong>")
        pos = m.end()
    out.append(esc(text[pos:]))
    return "".join(out)


def plain_inline(text: str) -> str:
    """飾りを外した文字（JSON-LD・見出しの id 用）"""
    text = re.sub(r"\[([^\]]+)\]\([^)\s]+\)", r"\1", text)
    text = re.sub(r"<(https?://[^>\s]+)>", r"\1", text)
    return text.replace("**", "").replace("`", "").replace("\\|", "|")


def split_row(row: str) -> list[str]:
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", row)]


def starts_block(line: str) -> bool:
    return bool(FENCE.match(line) or HEADING.match(line) or LIST_ITEM.match(line)
                or line.startswith(">") or line.lstrip().startswith("|"))


class Renderer:
    def __init__(self, name: str):
        self.name = name
        self.ids: set[str] = set()

    def heading_id(self, text: str, explicit: str | None) -> str:
        if explicit:
            if explicit in self.ids:
                raise BuildError(f"{self.name}: 見出しの id `{explicit}` が重なっています")
            self.ids.add(explicit)
            return explicit
        base = re.sub(r"[^a-z0-9]+", "-", plain_inline(text).lower()).strip("-") or f"h{len(self.ids) + 1}"
        hid, n = base, 2
        while hid in self.ids:
            hid, n = f"{base}-{n}", n + 1
        self.ids.add(hid)
        return hid

    def blocks(self, lines: list[str]) -> str:
        out: list[str] = []
        i, n = 0, len(lines)
        while i < n:
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            m = FENCE.match(line)
            if m:
                j = i + 1
                while j < n and not lines[j].startswith("```"):
                    j += 1
                if j >= n:
                    raise BuildError(f"{self.name}: ``` が閉じていません")
                cls = f' class="language-{m.group(1)}"' if m.group(1) else ""
                code = esc("\n".join(lines[i + 1:j]))
                out.append(f'<pre tabindex="0"><code{cls}>{code}</code></pre>')
                i = j + 1
                continue
            m = HEADING.match(line)
            if m:
                level, text = len(m.group(1)), m.group(2)
                out.append(f'<h{level} id="{self.heading_id(text, m.group(3))}">{inline(text)}</h{level}>')
                i += 1
                continue
            if line.lstrip().startswith("|") and i + 1 < n and TABLE_SEP.match(lines[i + 1].strip()):
                j = i + 2
                while j < n and lines[j].lstrip().startswith("|"):
                    j += 1
                out.append(self.table(lines[i], lines[i + 2:j]))
                i = j
                continue
            if line.startswith(">"):
                j = i
                while j < n and lines[j].startswith(">"):
                    j += 1
                inner = [re.sub(r"^> ?", "", s) for s in lines[i:j]]
                cls = ' class="human"' if any("HUMAN-ONLY" in s for s in inner) else ""
                out.append(f"<blockquote{cls}>\n{self.blocks(inner)}\n</blockquote>")
                i = j
                continue
            if LIST_ITEM.match(line):
                items: list[list] = []
                j = i
                while j < n and lines[j].strip():
                    lm = LIST_ITEM.match(lines[j])
                    if lm:
                        items.append([len(lm.group(1)), lm.group(2)[0].isdigit(), lm.group(3)])
                    elif lines[j].startswith((" ", "\t")):
                        items[-1][2] += " " + lines[j].strip()
                    else:
                        break
                    j += 1
                out.append(self.list(items, 0)[0])
                i = j
                continue
            j = i + 1
            while j < n and lines[j].strip() and not starts_block(lines[j]):
                j += 1
            out.append(f"<p>{inline(' '.join(s.strip() for s in lines[i:j]))}</p>")
            i = j
        return "\n".join(out)

    def list(self, items: list[list], start: int) -> tuple[str, int]:
        indent, ordered = items[start][0], items[start][1]
        tag = "ol" if ordered else "ul"
        parts = [f"<{tag}>"]
        i = start
        while i < len(items) and items[i][0] == indent:
            parts.append(f"<li>{inline(items[i][2])}")
            i += 1
            if i < len(items) and items[i][0] > indent:
                sub, i = self.list(items, i)
                parts.append(sub)
            parts.append("</li>")
        if i < len(items) and items[i][0] > indent:
            raise BuildError(f"{self.name}: リストの字下げがそろっていません")
        parts.append(f"</{tag}>")
        return "".join(parts), i

    def table(self, header: str, rows: list[str]) -> str:
        head = split_row(header)
        body = []
        for r in rows:
            cells = split_row(r)
            if len(cells) != len(head):
                raise BuildError(f"{self.name}: 表の列の数が見出しと違います: {r}")
            body.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in cells) + "</tr>")
        label = esc("表: " + "・".join(plain_inline(h) for h in head))
        ths = "".join(f'<th scope="col">{inline(h)}</th>' for h in head)
        return (f'<div class="scroll" role="region" tabindex="0" aria-label="{label}"><table>'
                f"<thead><tr>{ths}</tr></thead><tbody>{''.join(body)}</tbody></table></div>")


def plain_block(lines: list[str], lang: str = "ja") -> str:
    """Markdown の行を、飾りを外した 1 つの文に（JSON-LD 用）。リストの項目は句点で区切る"""
    out = []
    for line in lines:
        s = line.strip()
        if not s or FENCE.match(s) or TABLE_SEP.match(s):
            continue
        s = re.sub(r"^(>\s?)+", "", s)
        item = bool(LIST_ITEM.match(s))
        s = re.sub(r"^(#{1,4}\s+|[-*]\s+|\d+\.\s+)", "", s)
        s = re.sub(r"\s+\{#[a-z0-9-]+\}$", "", s)
        if s.startswith("|"):
            s = " / ".join(split_row(s))
        s = plain_inline(s)
        if item and s and not s.endswith(tuple("。.!?！？:：")):
            s += "。" if lang == "ja" else "."
        out.append(s)
    return " ".join(x for x in out if x)


def h2_sections(body: str) -> list[tuple[str, str | None, list[str]]]:
    """## の見出しごとに（見出しの文字、id、中身の行）。``` の中は見ない"""
    secs: list[tuple[str, str | None, list[str]]] = []
    fence = False
    for line in body.splitlines():
        if line.startswith("```"):
            fence = not fence
        m = None if fence else HEADING.match(line)
        if m and len(m.group(1)) == 2:
            secs.append((m.group(2), m.group(3), []))
        elif secs:
            secs[-1][2].append(line)
    return secs


# ─── ページ ──────────────────────────────────────────────

def twin_markdown(body: str, base: str) -> str:
    """HTML の双子の Markdown。見出しの {#id} を外し、サイトの中のリンクは Markdown の版の絶対 URL にする"""
    out = []
    fence = False
    for line in body.splitlines():
        if line.startswith("```"):
            fence = not fence
        if not fence:
            line = re.sub(r"^(#{1,4}\s+.+?)\s+\{#[a-z0-9-]+\}\s*$", r"\1", line)
            line = re.sub(r"\]\((/[^)\s]*)\)", lambda m: "](" + md_url(m.group(1), base) + ")", line)
        out.append(line)
    return "\n".join(out).strip("\n") + "\n"


def md_url(target: str, base: str) -> str:
    path, _, frag = target.partition("#")
    page = PAGE_BY_PATH.get(path)
    url = base + ("/" + page.file("md") if page else path)
    return url + ("#" + frag if frag else "")


def json_ld(page: Page, meta: dict, body: str, site: dict, ios: str) -> dict:
    base, name = site["base_url"], site["name"]
    url = base + page.path
    if page.schema == "SoftwareApplication":
        ja = page.lang == "ja"
        return {
            "@context": "https://schema.org",
            "@type": "SoftwareApplication",
            "name": name,
            "description": meta["description"],
            "url": url,
            "inLanguage": page.lang,
            "applicationCategory": "DeveloperApplication",
            "applicationSubCategory": "SSH ターミナル" if ja else "SSH terminal",
            "operatingSystem": f"iOS {ios} 以降、iPadOS {ios} 以降" if ja else f"iOS {ios} or later, iPadOS {ios} or later",
            "softwareRequirements": ("Mac（Xcode）と無料の Apple ID。App Store では配っていない" if ja
                                     else "A Mac with Xcode and a free Apple ID. Not distributed on the App Store"),
            "isAccessibleForFree": True,
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "JPY"},
            "sameAs": [site["repo_url"]],
            "dateModified": meta["updated"],
        }
    if page.schema == "HowTo":
        steps = []
        for title, hid, lines in h2_sections(body):
            m = re.match(r"^(\d+)\.\s+(.+)$", title)
            if not m:
                continue
            if not hid:
                raise BuildError(f"{page.src}: 手順の見出し「{title}」に {{#id}} を付けてください")
            steps.append({"@type": "HowToStep", "position": int(m.group(1)), "name": plain_inline(m.group(2)),
                          "text": plain_block(lines, page.lang), "url": f"{url}#{hid}"})
        if not steps:
            raise BuildError(f"{page.src}: 手順（## 1. …）がありません")
        return {
            "@context": "https://schema.org",
            "@type": "HowTo",
            "name": plain_inline(meta["h1"]),
            "description": meta["description"],
            "inLanguage": page.lang,
            "url": url,
            "estimatedCost": {"@type": "MonetaryAmount", "currency": "JPY", "value": "0"},
            "tool": [{"@type": "HowToTool", "name": t} for t in (
                ("Mac", "Xcode", f"iPhone か iPad（iOS / iPadOS {ios} 以上）", "USB ケーブル") if page.lang == "ja"
                else ("Mac", "Xcode", f"iPhone or iPad (iOS / iPadOS {ios} or later)", "USB cable"))],
            "step": steps,
            "dateModified": meta["updated"],
        }
    if page.schema == "FAQPage":
        qs = [{"@type": "Question", "name": plain_inline(title),
               "acceptedAnswer": {"@type": "Answer", "text": plain_block(lines, page.lang)}}
              for title, _, lines in h2_sections(body)]
        return {"@context": "https://schema.org", "@type": "FAQPage", "inLanguage": page.lang,
                "url": url, "mainEntity": qs, "dateModified": meta["updated"]}
    return {
        "@context": "https://schema.org",
        "@type": page.schema,
        "headline": plain_inline(meta["h1"]),
        "description": meta["description"],
        "inLanguage": page.lang,
        "url": url,
        "dateModified": meta["updated"],
        "about": {"@type": "SoftwareApplication", "name": name, "url": base + "/"},
    }


UI = {
    "ja": {"skip": "本文へ", "nav": "サイト", "md": "このページの Markdown", "src": "ソースコード（GitHub）",
           "updated": "更新", "locale": "ja_JP"},
    "en": {"skip": "Skip to content", "nav": "Site", "md": "This page in Markdown", "src": "Source code (GitHub)",
           "updated": "Updated", "locale": "en_US"},
}
NAV = {
    "ja": ("/", "/get-started", "/config", "/mcp", "/media", "/faq"),
    "en": ("/en/", "/en/get-started"),
}


def nav_html(page: Page) -> str:
    items = []
    for path in NAV[page.lang]:
        p = PAGE_BY_PATH[path]
        cur = ' aria-current="page"' if p is page else ""
        items.append(f'<li><a href="{p.path}"{cur}>{esc(p.nav)}</a></li>')
    if page.lang == "ja":
        items.append('<li><a href="/en/" hreflang="en" lang="en">English</a></li>')
    else:
        items.append('<li><a href="/" hreflang="ja" lang="ja">日本語</a></li>')
    return "<ul>" + "".join(items) + "</ul>"


def head_common(title: str, description: str) -> list[str]:
    return [
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        '<meta name="color-scheme" content="dark">',
        '<meta name="theme-color" content="#0b0b0b">',
        f"<title>{esc(title)}</title>",
        f'<meta name="description" content="{esc(description)}">',
        f'<link rel="preload" href="{FONT}" as="font" type="font/woff2" crossorigin>',
        '<link rel="stylesheet" href="/style.css">',
        '<link rel="icon" href="/favicon.ico" sizes="32x32">',
        '<link rel="icon" href="/favicon.svg" type="image/svg+xml">',
        '<link rel="apple-touch-icon" href="/apple-touch-icon.png">',
    ]


def page_html(page: Page, meta: dict, main: str, site: dict, ld: dict, hero: str = "") -> str:
    """1 ページの HTML。hero（front matter の hero で指定した HTML の断片）は、ヘッダーと本文（<main>）の間に入る。
    本文の外なので、Markdown の双子と比べる対象にはならない"""
    base, ui = site["base_url"], UI[page.lang]
    canonical = base + page.path
    head = head_common(meta["title"], meta["description"])
    head.append(f'<link rel="canonical" href="{canonical}">')
    head.append(f'<link rel="alternate" hreflang="{page.lang}" href="{canonical}">')
    ja_path = page.path if page.lang == "ja" else page.alt
    if page.alt:
        alt = PAGE_BY_PATH[page.alt]
        head.append(f'<link rel="alternate" hreflang="{alt.lang}" href="{base + alt.path}">')
    if ja_path:
        head.append(f'<link rel="alternate" hreflang="x-default" href="{base + ja_path}">')
    head.append(f'<link rel="alternate" type="text/markdown" href="/{page.file("md")}" title="Markdown">')
    llms = "/llms.txt" if page.lang == "ja" else "/en/llms.txt"
    head.append(f'<link rel="alternate" type="text/plain" href="{llms}" title="llms.txt">')
    og = [
        ("og:type", "website" if page.schema == "SoftwareApplication" else "article"),
        ("og:site_name", site["name"]),
        ("og:title", meta["title"]),
        ("og:description", meta["description"]),
        ("og:url", canonical),
        ("og:locale", ui["locale"]),
    ]
    if page.alt:
        og.append(("og:locale:alternate", UI[PAGE_BY_PATH[page.alt].lang]["locale"]))
    if (SRC / OG_IMAGE.lstrip("/")).is_file():  # scripts/gen_brand.cjs --og が作る
        og += [("og:image", base + OG_IMAGE), ("og:image:width", "1200"), ("og:image:height", "630"),
               ("og:image:alt", meta["h1"])]
    head += [f'<meta property="{k}" content="{esc(v)}">' for k, v in og]
    card = "summary_large_image" if (SRC / OG_IMAGE.lstrip("/")).is_file() else "summary"
    head.append(f'<meta name="twitter:card" content="{card}">')
    ld_text = json.dumps(ld, ensure_ascii=False, indent=1).replace("</", "<\\/")
    head.append(f'<script type="application/ld+json">\n{ld_text}\n</script>')
    md = "/" + page.file("md")
    footer = (f'<p>{ui["md"]}: <a href="{md}" type="text/markdown">{md}</a> · '
              f'<a href="{llms}" type="text/plain">{llms.lstrip("/")}</a> · '
              f'<a href="{esc(site["repo_url"])}">{ui["src"]}</a></p>'
              f'<p>{ui["updated"]}: <time datetime="{meta["updated"]}">{meta["updated"]}</time></p>')
    return "\n".join([
        "<!doctype html>",
        f'<html lang="{page.lang}">',
        "<head>", *head, "</head>",
        '<body class="has-hero">' if hero.strip() else "<body>",
        f'<a class="skip" href="#main">{ui["skip"]}</a>',
        f'<header><p class="brand"><a href="{NAV[page.lang][0]}">{esc(site["name"])}</a></p>'
        f'<nav aria-label="{ui["nav"]}">{nav_html(page)}</nav></header>',
        *([hero.strip("\n")] if hero.strip() else []),
        f'<main id="main">\n{main}\n</main>',
        f"<footer>{footer}</footer>",
        "</body>",
        "</html>",
        "",
    ])


def not_found_html(site: dict) -> str:
    head = head_common(f"ページが見つかりません | {site['name']}", "ページが見つかりません。")
    head.append('<meta name="robots" content="noindex">')
    main = ('<h1>ページが見つかりません</h1>\n<p>URL を確かめてください。'
            '<a href="/">トップ</a>・<a href="/get-started">はじめる</a>・<a href="/llms.txt">llms.txt</a></p>\n'
            '<p lang="en">Page not found. <a href="/en/">English</a></p>')
    return "\n".join(["<!doctype html>", '<html lang="ja">', "<head>", *head, "</head>", "<body>",
                      f'<main id="main">\n{main}\n</main>', "</body>", "</html>", ""])


# ─── サイト全体のファイル ─────────────────────────────────────

def robots(base: str) -> str:
    lines = ["# AI の検索・学習・ユーザーの代わりの取得を含め、すべてのクローラに全ページを許す（site/build.py が作る）", ""]
    for bot in (*AI_BOTS, "*"):
        lines += [f"User-agent: {bot}", "Allow: /", ""]
    lines.append(f"Sitemap: {base}/sitemap.xml")
    return "\n".join(lines) + "\n"


def sitemap(base: str, updated: dict) -> str:
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for p in PAGES:
        out.append("  <url>")
        out.append(f"    <loc>{base}{p.path}</loc>")
        out.append(f"    <lastmod>{updated[p.path]}</lastmod>")
        if p.alt:
            ja, en = (p, PAGE_BY_PATH[p.alt]) if p.lang == "ja" else (PAGE_BY_PATH[p.alt], p)
            for lang, q in (("ja", ja), ("en", en), ("x-default", ja)):
                out.append(f'    <xhtml:link rel="alternate" hreflang="{lang}" href="{base}{q.path}"/>')
        out.append("  </url>")
    out.append("</urlset>")
    return "\n".join(out) + "\n"


def headers() -> str:
    lines = [
        "# Cloudflare Pages のヘッダー（site/build.py が作る。手で直さない）",
        "/*",
        f"  Content-Security-Policy: {CSP}",
        "  X-Content-Type-Options: nosniff",
        "  Referrer-Policy: strict-origin-when-cross-origin",
        "  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()",
        "",
        "/*.md",
        "  Content-Type: text/markdown; charset=utf-8",
    ]
    for p in ("/llms.txt", "/llms-full.txt", "/en/llms.txt"):
        lines += ["", p, "  Content-Type: text/plain; charset=utf-8"]
    return "\n".join(lines) + "\n"


def llms_full(site: dict, twins: dict) -> str:
    base = site["base_url"]
    parts = [f"# {site['name']}（日本語の全ページ）\n\n"
             f"> {base} の日本語のページの Markdown を 1 つにつないだもの。各ページの元の URL は source の行にある。\n"]
    for p in PAGES:
        if p.lang == "ja":
            parts.append(f"<!-- source: {base}/{p.file('md')} -->\n\n{twins[p.path]}")
    return "\n---\n\n".join(parts)


def build(site: dict | None = None) -> dict[str, bytes]:
    """公開するファイル（場所 → 中身）"""
    site = site or load_site()
    base = site["base_url"]
    ios = min_ios()
    values = {
        "base": base,
        "repo": site["repo_url"],
        "min_ios": ios,
        "config_reference": config_reference(CONFIG_EXAMPLE.read_text(encoding="utf-8")),
    }
    files: dict[str, str | bytes] = {}
    twins: dict[str, str] = {}
    updated: dict[str, str] = {}
    for page in PAGES:
        meta, body = split_front_matter(fill((SRC / page.src).read_text(encoding="utf-8"), values, page.src),
                                        page.src)
        h1 = [m.group(2) for m in map(HEADING.match, body.splitlines()) if m and len(m.group(1)) == 1]
        if len(h1) != 1:
            raise BuildError(f"{page.src}: # の見出しは 1 つだけにします")
        meta["h1"] = h1[0]
        main = Renderer(page.src).blocks(body.splitlines())
        hero = ""
        if meta.get("hero"):  # トップの大きな区画など。site/src からの場所の HTML の断片（{{base}} なども使える）
            src = SRC / meta["hero"]
            if not src.is_file() or SRC.resolve() not in src.resolve().parents:
                raise BuildError(f"{page.src}: hero の {meta['hero']} が site/src の中にありません")
            hero = fill(src.read_text(encoding="utf-8"), values, meta["hero"])
        files[page.file("html")] = page_html(page, meta, main, site, json_ld(page, meta, body, site, ios), hero)
        twins[page.path] = twin_markdown(body, base)
        files[page.file("md")] = twins[page.path]
        updated[page.path] = meta["updated"]
    for name in ("llms.txt", "en/llms.txt"):
        files[name] = fill((SRC / name).read_text(encoding="utf-8"), values, name)
    files["llms-full.txt"] = llms_full(site, twins)
    files["404.html"] = not_found_html(site)
    files["robots.txt"] = robots(base)
    files["sitemap.xml"] = sitemap(base, updated)
    files["_headers"] = headers()
    for name in ("style.css", "favicon.svg"):
        files[name] = (SRC / name).read_text(encoding="utf-8")
    # 決まった場所で探されるアイコン（scripts/gen_brand.cjs が作る）
    for name in ("favicon.ico", "apple-touch-icon.png"):
        files[name] = (SRC / name).read_bytes()
    # 画像などはそのまま配る（site/src/assets/ → /assets/）。CSP で同じサイトの画像だけが読める
    assets = SRC / "assets"
    if assets.is_dir():
        for f in sorted(assets.rglob("*")):
            if f.is_file() and not f.name.startswith("."):
                files[f.relative_to(SRC).as_posix()] = f.read_bytes()
    return {k: v if isinstance(v, bytes) else v.encode("utf-8") for k, v in sorted(files.items())}


def existing(out: Path) -> dict[str, bytes]:
    if not out.exists():
        return {}
    return {p.relative_to(out).as_posix(): p.read_bytes() for p in sorted(out.rglob("*")) if p.is_file()}


def write(files: dict[str, bytes], out: Path) -> None:
    if out.resolve() != PUBLIC.resolve() and out.exists() and any(out.iterdir()):
        raise BuildError(f"--out には、無いか空のフォルダを指定します: {out}")
    for rel in existing(out):
        if rel not in files:
            (out / rel).unlink()
    for rel, data in files.items():
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists() or dest.read_bytes() != data:
            dest.write_bytes(data)
    for d in sorted((p for p in out.rglob("*") if p.is_dir()), reverse=True):
        if not any(d.iterdir()):
            d.rmdir()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="site/src から公開サイト（site/public）を作る")
    ap.add_argument("--out", type=Path, default=PUBLIC, help="作る場所（既定 site/public）")
    ap.add_argument("--check", action="store_true", help="site/public が最新かを確かめるだけ（違えば 1）")
    args = ap.parse_args(argv)
    try:
        files = build()
        if args.check:
            have = existing(PUBLIC)
            stale = sorted(k for k in set(files) | set(have) if files.get(k) != have.get(k))
            if stale:
                print("site/public が site/src・config.example・Base.xcconfig と合っていません。"
                      "`python3 site/build.py` で作り直して、一緒に入れてください:", file=sys.stderr)
                for k in stale:
                    state = "無い" if k not in have else "余分" if k not in files else "違う"
                    print(f"  {state}: {k}", file=sys.stderr)
                return 1
            print(f"site/public は最新です（{len(files)} ファイル）")
            return 0
        write(files, args.out)
    except BuildError as e:
        print(f"作れませんでした: {e}", file=sys.stderr)
        return 1
    print(f"作りました: {args.out}（{len(files)} ファイル）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
