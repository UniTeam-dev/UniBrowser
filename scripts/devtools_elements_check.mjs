// Self-check for the pure CSS helpers of devtools.js #region elements
// (between the /* elements:pure */ markers): node scripts/devtools_elements_check.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../UniBrowser/Resources/devtools.js', import.meta.url), 'utf8');
const pure = source.slice(source.indexOf('/* elements:pure */'), source.indexOf('/* elements:pure end */'));
const { splitTop, specificity, ruleOffset } = new Function(pure + 'return { splitTop, specificity, ruleOffset };')();

assert.deepEqual(splitTop('a, b:is(c, d), [x=","]', ','), ['a', 'b:is(c, d)', '[x=","]']);
assert.deepEqual(splitTop('color: red; background: url("a;b"); ', ';'), ['color: red', 'background: url("a;b")']);

const cases = {
  '*': [0, 0, 0],
  'div': [0, 0, 1],
  'ul li a': [0, 0, 3],
  '#nav .item > a:hover': [1, 2, 1],
  'a[href^="http"]::before': [0, 1, 2],
  'p:first-line': [0, 0, 2],
  ':where(#a, .b) span': [0, 0, 1],
  ':is(#a, .b) span': [1, 0, 1],
  'div:not(.a, .b.c)': [0, 2, 1],
  'li:nth-child(2n+1 of .x)': [0, 2, 1],
  'svg|rect': [0, 0, 1],
  '.a\\:b': [0, 1, 0],
  ':root': [0, 1, 0],
};
for (const [selector, expected] of Object.entries(cases)) assert.deepEqual(specificity(selector), expected, selector);

const css = '/* a */\n.a { color: red }\n\n.b,\n.c {}\n.a{margin:0}\n';
assert.equal(css.slice(0, ruleOffset(css, '.a', 0)).split('\n').length, 2);
assert.equal(css.slice(0, ruleOffset(css, '.b, .c', 0)).split('\n').length, 4);
assert.equal(css.slice(0, ruleOffset(css, '.a', 1)).split('\n').length, 6);
assert.equal(ruleOffset(css, '.missing', 0), -1);

console.log('PASS devtools elements helpers');
