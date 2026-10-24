// Walks the two Woods Map design-study scenarios in a real browser by
// clicking only (woods-testbed#38, the woods-map M1 exit criterion), once with
// JavaScript on and once with it off, and runs axe-core at 1440 and 390 on
// every page a click lands on. The steps are scripts/support/woods_map_walks.json,
// the same file scripts/woods_map_walk_smoke.rb follows in CI without a browser.
//
// Usage (a variant must be up, extracted and serving the engine):
//   npm install playwright@1 axe-core@4   # once, anywhere on NODE_PATH
//   npx playwright install chromium
//   node scripts/tools/woods_map_click_walk.cjs http://localhost:3010 [--token=<WOODS_MAP_TOKEN>] [--out=dir]
//
// Each step looks for a visible link to the step's href outside the file-tree
// sheet, clicks it, and checks that the browser lands on that URL with a 200,
// the expected heading and text. With JavaScript off, axe runs on the same
// server-rendered HTML with its scripts removed, in a scripted copy of the page.
// Exit status is the number of failed steps and pages with axe violations.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const args = process.argv.slice(2);
const base = (args.find((a) => !a.startsWith('--')) || 'http://localhost:3010').replace(/\/$/, '');
const option = (name) => (args.find((a) => a.startsWith(`--${name}=`)) || '').split('=').slice(1).join('=');
const token = option('token') || process.env.WOODS_MAP_TOKEN || '';
const out = option('out');
const axeSource = fs.readFileSync(process.env.AXE_PATH || require.resolve('axe-core/axe.min.js'), 'utf8');
const walks = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'support', 'woods_map_walks.json'), 'utf8'));
const WIDTHS = [1440, 390];
const RULES = { runOnly: ['wcag2a', 'wcag2aa', 'wcag21aa', 'best-practice'] };

const strip = (html) => html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
const wanted = (href) => new URL(href.split('#')[0], base);

async function axeOn(browser, url, html, js) {
  const results = {};
  for (const width of WIDTHS) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, bypassCSP: true,
                                               extraHTTPHeaders: token ? { Authorization: `Bearer ${token}` } : {} });
    const page = await context.newPage();
    if (js) {
      await page.goto(url, { waitUntil: 'networkidle' });
    } else {
      await page.route(url, (route) => route.fulfill({ status: 200, contentType: 'text/html', body: strip(html) }));
      await page.goto(url, { waitUntil: 'networkidle' });
    }
    await page.addScriptTag({ content: axeSource });
    const run = await page.evaluate(async (rules) => (await window.axe.run(document, rules)).violations
      .map((v) => `${v.id} x${v.nodes.length}`), RULES);
    results[width] = run;
    await context.close();
  }
  return results;
}

async function walk(browser, scenario, js) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, javaScriptEnabled: js,
                                             extraHTTPHeaders: token ? { Authorization: `Bearer ${token}` } : {} });
  const page = await context.newPage();
  const lines = [];
  let failures = 0;
  for (const step of scenario.steps) {
    const label = `step ${step.step}`;
    let href = step.start || step.click;
    let response;
    if (step.start) {
      response = await page.goto(base + href, { waitUntil: 'load' });
    } else {
      const links = page.locator('a[href]').filter({ hasNot: page.locator('xpath=ancestor::*[contains(@class,"sheet")]') });
      let candidates;
      if (step.click_prefix) {
        candidates = page.locator(`a[href^="${step.click_prefix}"]:visible`);
        if (await candidates.count() === 0) { lines.push(`  SKIP  ${label}: no link starting ${step.click_prefix} (${step.optional})`); continue; }
        href = await candidates.first().getAttribute('href');
      } else {
        candidates = page.locator(`a[href="${href}"]:visible`);
      }
      const outside = [];
      for (let i = 0; i < await candidates.count(); i += 1) {
        const inSheet = await candidates.nth(i).evaluate((a) => !!a.closest('.sheet'));
        if (!inSheet) outside.push(candidates.nth(i));
      }
      void links;
      if (outside.length === 0) {
        failures += 1; lines.push(`  FAIL  ${label}: no visible link to ${href} on ${page.url()}`); break;
      }
      [response] = await Promise.all([page.waitForNavigation({ waitUntil: 'load' }), outside[0].click()]);
    }
    const landed = new URL(page.url());
    const expected = wanted(href);
    const heading = ((await page.locator('h1').first().textContent().catch(() => '')) || '').replace(/\s+/g, ' ');
    const text = (await page.evaluate(() => {
      const copy = document.body.cloneNode(true);
      copy.querySelectorAll('.sheet, script, style, template').forEach((n) => n.remove());
      return copy.textContent;
    })).replace(/\s+/g, ' ');
    const problems = [];
    if (!response || response.status() !== 200) problems.push(`answered ${response && response.status()}`);
    if (landed.pathname + landed.search !== expected.pathname + expected.search) problems.push(`landed on ${landed.pathname}${landed.search}`);
    if (step.h1 && !heading.includes(step.h1)) problems.push(`h1 ${JSON.stringify(heading)} lacks ${JSON.stringify(step.h1)}`);
    const missing = (step.text || []).filter((needle) => !text.includes(needle));
    if (missing.length) problems.push(`missing ${missing.join(', ')}`);
    if (problems.length) { failures += 1; lines.push(`  FAIL  ${label}: ${href}: ${problems.join('; ')}`); break; }
    const axe = await axeOn(browser, page.url(), js ? null : await page.content(), js);
    const dirty = Object.entries(axe).filter(([, v]) => v.length);
    if (dirty.length) failures += 1;
    if (out) await page.screenshot({ path: path.join(out, `s${scenario.id}-${js ? 'js' : 'nojs'}-${lines.length}.png`) });
    lines.push(`  ${dirty.length ? 'AXE ' : 'PASS'}  ${label}: ${step.start ? 'open' : 'click'} ${href}  axe ${WIDTHS.map((w) => `${w}:${axe[w].length ? axe[w].join(' ') : 0}`).join(' ')}`);
  }
  (scenario.not_walked || []).forEach((note) => lines.push(`  NOTE  ${note}`));
  await context.close();
  return { lines, failures };
}

(async () => {
  if (out) fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  let failures = 0;
  for (const js of [true, false]) {
    for (const scenario of walks.scenarios) {
      console.log(`--- Scenario ${scenario.id} (${scenario.title}), JavaScript ${js ? 'on' : 'off'}`);
      const result = await walk(browser, scenario, js);
      result.lines.forEach((line) => console.log(line));
      failures += result.failures;
    }
  }
  await browser.close();
  console.log(`\n${failures} failures`);
  process.exit(failures);
})();
