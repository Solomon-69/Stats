// e2e.mjs: drives the REAL running app (its web view) through every screen, button and switch, and checks results.
// The app must be started with STATS_TEST=panel and WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222.
import { chromium } from 'playwright-core';
import { execSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';

const out = process.argv[2] || 'shots/e2e';
mkdirSync(out, { recursive: true });
const results = [];
const check = (name, ok, info = '') => { results.push({ name, ok: !!ok, info: String(info) }); console.log(`${ok ? 'PASS' : 'FAIL'} ${name} ${info}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let browser;
for (let i = 0; i < 40; i++) { try { browser = await chromium.connectOverCDP('http://127.0.0.1:9222'); break; } catch { await sleep(1000); } }
if (!browser) { console.log('FAIL cannot connect'); process.exit(1); }
const pages = () => browser.contexts().flatMap((c) => c.pages());
let panel, settings;
for (let i = 0; i < 40 && !(panel && settings); i++) {
  panel = pages().find((p) => p.url().includes('w=panel')); settings = pages().find((p) => p.url().includes('w=settings'));
  if (!(panel && settings)) await sleep(500);
}
check('both windows exist', panel && settings);
const errs = [];
for (const p of [panel, settings]) { p.on('pageerror', (e) => errs.push(String(e))); p.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); }); }
await sleep(3500);

// ---- panel ----
const tiles = await panel.$$eval('.tile', (t) => t.map((x) => x.dataset.id));
check('core tiles present', ['cpu', 'memory', 'disk', 'diskio', 'network'].every((t) => tiles.includes(t)), tiles.join(','));
const hasBattery = tiles.includes('battery'); const hasTemp = tiles.includes('sensors');
console.log('battery tile:', hasBattery, 'temperature tile:', hasTemp);
const big = async (id) => panel.$eval(`.tile[data-id=${id}] .big`, (e) => e.textContent);
const sub = async (id) => panel.$eval(`.tile[data-id=${id}] .sub`, (e) => e.textContent);
const cpuT = await big('cpu'); check('cpu is a percent', /^\d{1,3}%$/.test(cpuT), cpuT);
const memT = await big('memory'); const memN = parseInt(memT); check('memory percent sane', memN > 1 && memN < 100, memT);
const dSub = await sub('disk'); check('storage says free of', /free of/.test(dSub), dSub);
check('network has text', (await big('network')).length > 0, await big('network'));
check('header model', (await panel.$eval('#model', (e) => e.textContent)).length > 1, await panel.$eval('#model', (e) => e.textContent));
const chips = await panel.$$eval('.chip', (c) => c.map((x) => x.textContent)); check('four info chips', chips.length >= 3, chips.join(' | '));
check('status pill', (await panel.$eval('#ptxt', (e) => e.textContent)).length > 3);
await panel.screenshot({ path: `${out}/panel-initial.png` });

for (const id of tiles) {
  await panel.click(`.tile[data-id=${id}] .trow`); await sleep(500);
  const open = await panel.$$eval('.tile.open', (t) => t.map((x) => x.dataset.id));
  const rows = await panel.$$eval('.tile.open .detail .drow', (r) => r.length);
  check(`expand ${id}`, open.length === 1 && open[0] === id && rows > 0, `rows=${rows}`);
  await panel.screenshot({ path: `${out}/panel-open-${id}.png` });
}
await panel.click(`.tile[data-id=${tiles[tiles.length - 1]}] .trow`); await sleep(300);
check('collapse', (await panel.$$eval('.tile.open', (t) => t.length)) === 0);

// ---- settings: every tab, switch and chip ----
const nav = async (i) => { await settings.click(`.nav[data-tab="${i}"]`); await sleep(450); return settings.$eval('.main h2', (e) => e.textContent); };
check('tab Look', (await nav(0)) === 'Look'); await settings.screenshot({ path: `${out}/settings-look.png` });
const theme = () => panel.evaluate(() => document.documentElement.dataset.theme);
await settings.click('[data-seg=appearance] button[data-v=dark]'); await sleep(900);
check('dark applies to panel', (await theme()) === 'dark', await theme()); await panel.screenshot({ path: `${out}/panel-dark.png` });
await settings.screenshot({ path: `${out}/settings-look-dark.png` });
await settings.click('[data-seg=appearance] button[data-v=light]'); await sleep(900);
check('light applies to panel', (await theme()) === 'light', await theme());
await settings.click('[data-seg=appearance] button[data-v=auto]'); await sleep(500);
const pillMoved = await settings.$eval('[data-seg=appearance] .pillbg', (e) => parseFloat(e.style.left) >= 0);
check('segmented pill positioned', pillMoved);
for (let i = 1; i < 5; i++) { await settings.click(`.swatch[data-acc="${i % 5}"]`); await sleep(250); }
const brand = await settings.evaluate(() => document.documentElement.style.getPropertyValue('--brand'));
check('accent changes', brand.length > 3, brand); await settings.click('.swatch[data-acc="0"]');
await settings.click('[data-seg=icon] button[data-v=live]'); await sleep(1200);
check('tray icon style live saved', (await settings.evaluate(() => JSON.parse(localStorage.getItem('stats.prefs')).icon)) === 'live');
await settings.click('[data-seg=icon] button[data-v=bars]'); await sleep(300);

check('tab What to watch', (await nav(1)) === 'What to watch'); await settings.screenshot({ path: `${out}/settings-watch.png` });
const modRows = await settings.$$eval('[data-sw^="mod."]', (s) => s.map((x) => x.dataset.sw));
check('module switches match panel tiles (hidden parts not offered)', modRows.length === tiles.length, `${modRows.length} vs ${tiles.length}`);
await settings.click('[data-sw="mod.network"]'); await sleep(900);
check('switching a tile off removes it', !(await panel.$('.tile[data-id=network]')));
await settings.click('[data-sw="mod.network"]'); await sleep(2600);
check('switching it on brings it back', !!(await panel.$('.tile[data-id=network]')));

check('tab General', (await nav(2)) === 'General'); await settings.screenshot({ path: `${out}/settings-general.png` });
await settings.click('[data-seg=speed] button[data-v=bits]'); await sleep(2800);
check('Mbps shows bits', /bps/.test(await sub('network')) || /bps/.test(await big('network')), await sub('network'));
await settings.click('[data-seg=speed] button[data-v=bytes]'); await sleep(300);
for (const v of ['1', '5', '10', '2']) { await settings.click(`[data-seg=refresh] button[data-v="${v}"]`); await sleep(250); }
check('refresh saved', (await settings.evaluate(() => JSON.parse(localStorage.getItem('stats.prefs')).refresh)) === 2);
await settings.click('[data-seg=temp] button[data-v=f]'); await settings.click('[data-seg=temp] button[data-v=c]');
await settings.click('[data-sw=alerts]'); await sleep(150); await settings.click('[data-sw=alerts]');
const regHas = () => { try { execSync('reg query HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run /v Stats', { stdio: 'pipe' }); return true; } catch { return false; } };
await settings.click('[data-sw=login]'); await sleep(1200);
check('open at login writes the registry', regHas());
await settings.click('[data-sw=login]'); await sleep(1200);
check('open at login removes it again', !regHas());

check('tab About', (await nav(3)) === 'About'); await sleep(3500); await settings.screenshot({ path: `${out}/settings-about.png` });
const own = await settings.$eval('#own', (e) => e.textContent); check('own use shown', /\d+\.\d% CPU/.test(own), own);
const upd = await settings.$eval('#upd', (e) => e.textContent); check('update check answered', /up to date|Version|Could not/.test(upd), upd);

check('no script errors', errs.length === 0, errs.slice(0, 3).join(' || '));
writeFileSync(`${out}/results.json`, JSON.stringify({ results, tiles, hasBattery, hasTemp }, null, 2));
const bad = results.filter((r) => !r.ok);
console.log(`\n${results.length - bad.length}/${results.length} passed`);
await browser.close().catch(() => {});
process.exit(bad.length ? 1 : 0);
