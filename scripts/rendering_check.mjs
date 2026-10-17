// Self-check of the pure helpers in devtools.js «Рендеринг» (media rewriting, time zones).
// Run: node scripts/rendering_check.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../UniBrowser/Resources/devtools.js', import.meta.url), 'utf8');
const pure = source.slice(source.indexOf('/* pure:start'), source.indexOf('/* pure:end */'));
const R = new Function(pure + '\nreturn renderingPure(Date, Intl.DateTimeFormat);')();

const T = '(min-width: 0px)';
const F = '(min-width: 1000000px)';
const m = (text, media) => R.rewriteMedia(text, media);

// Features
assert.equal(m('(prefers-reduced-motion: reduce)', { 'prefers-reduced-motion': 'reduce' }), T);
assert.equal(m('(prefers-reduced-motion: no-preference)', { 'prefers-reduced-motion': 'reduce' }), F);
assert.equal(m('(prefers-reduced-motion)', { 'prefers-reduced-motion': 'no-preference' }), F);
assert.equal(m('screen and (prefers-contrast:more)', { 'prefers-contrast': 'more' }), 'screen and ' + T);
assert.equal(m('(prefers-contrast: less)', { 'prefers-contrast': 'more' }), F);
assert.equal(m('(prefers-contrast: more)', {}), '(prefers-contrast: more)');
// Types under print
const P = { print: true };
assert.equal(m('print', P), 'all and ' + T);
assert.equal(m('only screen and (min-width: 600px)', P), 'only all and ' + F + ' and (min-width: 600px)');
assert.equal(m('not print', P), 'not all and ' + T);
assert.equal(m('screen, print', P), 'all and ' + F + ', all and ' + T);
assert.equal(m('(display-mode: print)', P), '(display-mode: print)'); // inside parentheses: not a type
assert.equal(m('print', {}), 'print');

// Time zones (Node has full ICU)
const H = 3600e3;
assert.equal(R.zoneOffset('Europe/Moscow', Date.UTC(2026, 0, 1)), 3 * H);
assert.equal(R.zoneOffset('America/New_York', Date.UTC(2026, 0, 15)), -5 * H);
assert.equal(R.zoneOffset('America/New_York', Date.UTC(2026, 6, 15)), -4 * H);
assert.equal(R.zoneOffset('Asia/Kolkata', Date.UTC(2026, 6, 15)), 5.5 * H);
const ancient = new Date(0);
ancient.setUTCFullYear(50, 0, 1); // years 0–99 must not turn into 19xx
assert.equal(R.zoneOffset('UTC', ancient.getTime()), 0);
// Wall clock 12:00 on 1 July in New York is 16:00 UTC; around the spring-forward change too.
assert.equal(R.toUTC('America/New_York', Date.UTC(2026, 6, 1, 12)), Date.UTC(2026, 6, 1, 16));
assert.equal(R.toUTC('America/New_York', Date.UTC(2026, 2, 8, 1, 30)), Date.UTC(2026, 2, 8, 6, 30));
assert.equal(R.toUTC('America/New_York', Date.UTC(2026, 2, 8, 3, 30)), Date.UTC(2026, 2, 8, 7, 30));
assert.equal(R.toUTC('Asia/Tokyo', Date.UTC(2026, 9, 18, 9)), Date.UTC(2026, 9, 18, 0));
// toString shape
assert.equal(R.dateString('Asia/Tokyo', Date.UTC(2026, 9, 18, 0, 5, 7)), 'Sun Oct 18 2026 09:05:07 GMT+0900 (Japan Standard Time)');
assert.equal(R.dateString('America/New_York', Date.UTC(2026, 0, 1, 3), 'date'), 'Wed Dec 31 2025');
assert.equal(R.dateString('Asia/Kolkata', Date.UTC(2026, 0, 1), 'time'), '05:30:00 GMT+0530 (India Standard Time)');
assert.equal(R.dateString('UTC', NaN), 'Invalid Date');

console.log('rendering_check: ok');
