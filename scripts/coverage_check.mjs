// Self-check for the CSS coverage parser in devtools.js (region coverage, between the
// coverage:parser-start/end markers). Run: node scripts/coverage_check.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../UniBrowser/Resources/devtools.js', import.meta.url), 'utf8');
const part = source.slice(source.indexOf('// coverage:parser-start'), source.indexOf('// coverage:parser-end'));
const { parseCSS, matchable, lineRanges } = new Function(part + '; return { parseCSS, matchable, lineRanges };')();

const css = `/* head { } */
a, b { color: red; }
@media (min-width: 1px) {
  .x { content: "}" }
}
@font-face { font-family: f; src: url(a.woff); }
@keyframes k { from { opacity: 0 } to { opacity: 1 } }
.p {
  color: blue;
  & .c { color: green; }
  .d, .e { margin: 0; }
  @media print { &:hover { color: red; } }
}
`;
const rules = parseCSS(css);
const selectors = (list) => list.map((rule) => rule.selector);
assert.deepEqual(selectors(rules), ['a, b', '.x', '.p']);
assert.deepEqual(selectors(rules[2].children), [':is(.p) .c', ':is(.p) .d, :is(.p) .e', ':is(.p):hover']);
for (const rule of [...rules, ...rules[2].children]) {
  assert.equal(css.slice(rule.start, rule.start + 1), rule.selector.startsWith(':is') ? css[rule.start] : rule.selector[0]);
  assert.equal(css[rule.end - 1], '}');
}
assert.equal(css.slice(rules[0].start, rules[0].end), 'a, b { color: red; }');
assert.equal(css.slice(rules[1].start, rules[1].end), '.x { content: "}" }');

assert.equal(matchable('a::before'), 'a');
assert.equal(matchable('p:first-line, ::selection'), 'p, *');
assert.equal(matchable('ul > ::marker'), 'ul > *');
assert.equal(matchable('input::-webkit-input-placeholder:hover'), 'input:hover');

assert.deepEqual(lineRanges('a\nb\nc\nd', [[0, 1], [2, 3], [6, 7]]), [[1, 2], [4, 4]]);
assert.deepEqual(lineRanges('one line', [[0, 3], [4, 8]]), [[1, 1]]);

console.log('coverage_check: ok');
