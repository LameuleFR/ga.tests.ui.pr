// Print the failed tests of a mochawesome JSON report: "<spec file> | <test> | <first line of the error>".
const fs = require('fs');
const path = require('path');

let data;
try {
  data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
} catch (e) {
  console.log('  (no readable report)');
  process.exit(0);
}

const lines = [];
const walk = (suite, file) => {
  const current = suite.fullFile || file;
  [...(suite.tests || []), ...(suite.beforeHooks || []), ...(suite.afterHooks || [])].forEach((t) => {
    if (t.fail) {
      const error = ((t.err && t.err.message) || '').split('\n')[0];
      lines.push(`  ${path.basename(current || '?')} | ${t.title} | ${error}`.slice(0, 300));
    }
  });
  (suite.suites || []).forEach((s) => walk(s, current));
};
(data.results || []).forEach((r) => walk(r, ''));
lines.slice(0, 15).forEach((l) => console.log(l));
if (lines.length > 15) {
  console.log(`  ... and ${lines.length - 15} more`);
}
