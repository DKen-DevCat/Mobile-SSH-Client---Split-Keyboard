#!/usr/bin/env node
// アイコン・favicon・OGP の画像を brand/ の SVG から作る（Chromium で描く。Playwright が要る）。
// 使い方: node scripts/gen_brand.cjs          アイコンと favicon
//         node scripts/gen_brand.cjs --og     加えてトップのメインビジュアルから OGP 画像（先に python3 site/build.py、後でもう一度）
// 元の絵は brand/app-icon.svg と brand/favicon.svg（利用者のデザイン。アイコンの文字は輪郭にしてある）
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const brand = (f) => path.join(ROOT, 'brand', f);
const OUT = {
  appIcon: path.join(ROOT, 'ios/SplitTerm/Assets.xcassets/AppIcon.appiconset/AppIcon.png'),
  site: path.join(ROOT, 'site/src'),
};

// SVG を size×size の PNG にする。transparent なら角の外を透明のまま（favicon）
async function renderSVG(page, file, size, { transparent = false } = {}) {
  const svg = fs.readFileSync(file, 'utf8');
  await page.setViewportSize({ width: size, height: size });
  const bg = transparent ? 'transparent' : '#0b0b0b';
  await page.setContent(
    `<!doctype html><style>html,body{margin:0;background:${bg}}svg{display:block;width:${size}px;height:${size}px}</style>${svg}`,
  );
  return page.screenshot({ clip: { x: 0, y: 0, width: size, height: size }, omitBackground: transparent });
}

// 透明の層を外す（App Store の決まり。ImageMagick があるときだけ。無くても端末に入れるのには困らない）
function dropAlpha(file) {
  for (const cmd of [['magick', [file, '-alpha', 'off', file]], ['convert', [file, '-alpha', 'off', file]]]) {
    try {
      execFileSync(cmd[0], cmd[1], { stdio: 'ignore' });
      return true;
    } catch {}
  }
  return false;
}

// site/public を 127.0.0.1 で配る（/ → index.html、/a → a.html）
function serve(dir) {
  const http = require('http');
  const types = { '.html': 'text/html', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' };
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p.endsWith('/')) p += 'index.html';
    let file = path.join(dir, path.normalize(p));
    if (!file.startsWith(dir)) return res.writeHead(403).end();
    if (!path.extname(file)) file += '.html';
    fs.readFile(file, (err, data) => {
      if (err) return res.writeHead(404).end();
      res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' }).end(data);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// PNG をそのまま入れた ICO（16・32・48）
function ico(pngs) {
  const head = Buffer.alloc(6 + 16 * pngs.length);
  head.writeUInt16LE(0, 0);
  head.writeUInt16LE(1, 2);
  head.writeUInt16LE(pngs.length, 4);
  let offset = head.length;
  pngs.forEach(({ size, data }, i) => {
    const e = 6 + 16 * i;
    head.writeUInt8(size >= 256 ? 0 : size, e);
    head.writeUInt8(size >= 256 ? 0 : size, e + 1);
    head.writeUInt16LE(1, e + 4);
    head.writeUInt16LE(32, e + 6);
    head.writeUInt32LE(data.length, e + 8);
    head.writeUInt32LE(offset, e + 12);
    offset += data.length;
  });
  return Buffer.concat([head, ...pngs.map((p) => p.data)]);
}

(async () => {
  const og = process.argv.includes('--og');
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 1 });

  fs.writeFileSync(OUT.appIcon, await renderSVG(page, brand('app-icon.svg'), 1024));
  const opaque = dropAlpha(OUT.appIcon);
  console.log(`${path.relative(ROOT, OUT.appIcon)}${opaque ? '' : '（透明の層は残った。ImageMagick が無い）'}`);

  fs.mkdirSync(OUT.site, { recursive: true });
  fs.copyFileSync(brand('favicon.svg'), path.join(OUT.site, 'favicon.svg'));
  const sizes = [16, 32, 48];
  const pngs = [];
  for (const size of sizes) pngs.push({ size, data: await renderSVG(page, brand('favicon.svg'), size, { transparent: true }) });
  fs.writeFileSync(path.join(OUT.site, 'favicon.ico'), ico(pngs));
  fs.writeFileSync(path.join(OUT.site, 'apple-touch-icon.png'), await renderSVG(page, brand('app-icon.svg'), 180));
  console.log('site/src/favicon.svg, favicon.ico, apple-touch-icon.png');

  if (og) {
    // メインビジュアルを 1200×675 で描き、上から 630 を切り出す（OGP の 1.91:1）。site/public を手元で配って開く
    const server = await serve(path.join(ROOT, 'site/public'));
    const out = path.join(OUT.site, 'assets/og.png');
    fs.mkdirSync(path.dirname(out), { recursive: true });
    await page.setViewportSize({ width: 1200, height: 675 });
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.evaluate(() => document.fonts.ready);
    // 点滅するカーソルを点けたまま止める
    await page.addStyleTag({ content: '.hero .cur{animation:none!important}' });
    await page.screenshot({ path: out, clip: { x: 0, y: 0, width: 1200, height: 630 } });
    dropAlpha(out);
    server.close();
    console.log('site/src/assets/og.png（python3 site/build.py でもう一度作る）');
  }
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
