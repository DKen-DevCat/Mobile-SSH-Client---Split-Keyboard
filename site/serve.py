#!/usr/bin/env python3
"""公開サイト（site/public）を手元で見る（docs/site.md「手元で見る」）。標準ライブラリだけ。

Cloudflare Pages と同じに見えるようにする:
- 拡張子の無い URL（/get-started → get-started.html、/en/ → en/index.html）
- site/public/_headers のヘッダー（CSP・Content-Type など）
- 無いページは 404.html（状態 404）

使い方:
  python3 site/serve.py                 作り直してから http://127.0.0.1:8788/ で配る
  python3 site/serve.py --no-build      作り直さずに配る
  python3 site/serve.py --port 9000
既定では自分の Mac からしか見えない（127.0.0.1）。止めるのは Ctrl-C
"""
from __future__ import annotations

import argparse
import fnmatch
import mimetypes
import subprocess
import sys
from functools import partial
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
PUBLIC = ROOT / "site/public"

TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
    ".txt": "text/plain; charset=utf-8",
    ".xml": "application/xml; charset=utf-8",
    ".md": "text/markdown; charset=utf-8",
}


def parse_headers(text: str) -> list[tuple[str, list[tuple[str, str]]]]:
    """_headers を（パスの形、[(名前, 値)]）の並びに。# の行と空行は飛ばす"""
    rules: list[tuple[str, list[tuple[str, str]]]] = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw[0].isspace():
            rules.append((raw.strip(), []))
        elif rules and ":" in raw:
            name, _, value = raw.strip().partition(":")
            rules[-1][1].append((name.strip(), value.strip()))
    return rules


def headers_for(path: str, rules: list[tuple[str, list[tuple[str, str]]]]) -> dict[str, str]:
    """そのパスに当たるヘッダー（後に書いた規則が勝つ）。/* は何にでも、/*.md は .md に当たる"""
    out: dict[str, str] = {}
    for pattern, values in rules:
        if fnmatch.fnmatchcase(path, pattern):
            for name, value in values:
                out[name] = value
    return out


def resolve(public: Path, url_path: str) -> tuple[Path | None, str | None]:
    """URL のパスから配るファイル。（ファイル, None）か、ディレクトリに / を足す先（None, 行き先）か、（None, None）で無い"""
    path = unquote(urlsplit(url_path).path)
    if "\x00" in path or not path.startswith("/"):
        return None, None
    rel = path.lstrip("/")
    base = public.resolve()
    target = (public / rel).resolve()
    if target != base and base not in target.parents:
        return None, None  # site/public の外は配らない
    if target.is_dir():
        if not path.endswith("/"):
            return None, path + "/"
        index = target / "index.html"
        return (index, None) if index.is_file() else (None, None)
    if target.is_file():
        return target, None
    html = target.with_name(target.name + ".html")
    if not path.endswith("/") and html.is_file():
        return html, None
    return None, None


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, public: Path, rules, **kwargs):
        self.public = public
        self.rules = rules
        super().__init__(*args, directory=str(public), **kwargs)

    def do_HEAD(self):
        self.respond(body=False)

    def do_GET(self):
        self.respond(body=True)

    def respond(self, body: bool):
        file, redirect = resolve(self.public, self.path)
        if redirect:
            self.send_response(HTTPStatus.MOVED_PERMANENTLY)
            self.send_header("Location", redirect)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        status = HTTPStatus.OK
        if file is None:
            status, file = HTTPStatus.NOT_FOUND, self.public / "404.html"
        data = file.read_bytes() if file.is_file() else b"not found\n"
        url_path = "/" + file.relative_to(self.public).as_posix() if file.is_file() else self.path
        headers = {"Content-Type": TYPES.get(file.suffix) or mimetypes.guess_type(file.name)[0] or "application/octet-stream",
                   "Cache-Control": "no-store"}
        headers.update(headers_for(url_path, self.rules))
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if body:
            self.wfile.write(data)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="公開サイト（site/public）を手元で見る")
    ap.add_argument("--port", type=int, default=8788)
    ap.add_argument("--host", default="127.0.0.1", help="既定は自分の Mac だけ（127.0.0.1）")
    ap.add_argument("--no-build", action="store_true", help="site/build.py で作り直さない")
    args = ap.parse_args(argv)
    if not args.no_build:
        r = subprocess.run([sys.executable, str(ROOT / "site/build.py")])
        if r.returncode != 0:
            return r.returncode
    rules = parse_headers((PUBLIC / "_headers").read_text(encoding="utf-8"))
    server = ThreadingHTTPServer((args.host, args.port), partial(Handler, public=PUBLIC, rules=rules))
    print(f"http://{args.host}:{args.port}/ で配っています（英語は /en/。止めるのは Ctrl-C）")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
