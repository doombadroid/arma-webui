// Reproduce the client's page swap offline: placeholder skin.html boots webui.js (A3API stub serves
// it), then WEBUI._serve(base64(JSON(markup))) exactly as webui_fnc_serve's ExecJS does. If the
// yellow verdict text appears, the swap works in a browser; if not, the fault is in the swap.
import { createRequire } from 'module'; import fs from 'fs'; import path from 'path';
const require = createRequire(import.meta.url);
const puppeteer = require('puppeteer');
const M = '<your mission>/';
const skin = process.argv[2] || 'neon_edge';
const markup = fs.readFileSync(`<server page root>/skins/${skin}.html`, 'utf8');
const webuijs = fs.readFileSync(M + 'webui/ui/webui.js', 'utf8');
const tex = 'data:image/png;base64,' + fs.readFileSync('./textures/hatchback_01_ext_base01_co.png').toString('base64');
const browser = await puppeteer.launch({ headless: true, args: ['--no-sandbox'] });
const page = await browser.newPage(); await page.setViewport({ width: 1024, height: 1024 });
const log = []; page.on('pageerror', e => log.push('PAGEERROR ' + e)); page.on('console', m => log.push('console ' + m.text()));
await page.evaluateOnNewDocument((js, tex) => {
  window.A3API = { RequestFile: (p) => Promise.resolve(js), RequestTexture: () => Promise.resolve(tex),
    SendAlert: (s) => { window.__alerts = (window.__alerts || []); window.__alerts.push(s); }, SendConfirm: () => Promise.resolve(false) };
}, webuijs, tex);
await page.goto('file://' + M + 'ui/html/skin.html');
await new Promise(r => setTimeout(r, 800));
const haveWEBUI = await page.evaluate(() => typeof window.WEBUI);
const b64 = Buffer.from(JSON.stringify(markup), 'utf8').toString('base64');
const ret = await page.evaluate((b) => window.WEBUI && WEBUI._serve(b), b64);
await new Promise(r => setTimeout(r, 2500));
const title = await page.evaluate(() => document.title);
const still = await page.evaluate(() => typeof window.WEBUI);
const alerts = await page.evaluate(() => (window.__alerts || []).map(a => a.slice(0, 160)));
await page.screenshot({ path: './out/swap_' + skin + '.png' });
console.log({ haveWEBUI, serveReturned: ret, titleAfter: title, WEBUIAfter: still, alerts, log: log.slice(0, 6) });
await browser.close();
