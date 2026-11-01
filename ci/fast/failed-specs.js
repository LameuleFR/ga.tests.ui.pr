// Print the spec files with a failed test or hook in a mochawesome JSON report, one per line.
// Exit code 2 when the report is missing or unreadable (mocha crashed): rerun the whole campaign.
const fs = require('fs');

const report = process.argv[2];
let data;
try {
  data = JSON.parse(fs.readFileSync(report, 'utf8'));
} catch (e) {
  process.exit(2);
}

const failed = new Set();
const hasFailure = (suite) => (suite.tests || []).some((t) => t.fail || t.state === 'failed')
  || (suite.failures || []).length > 0
  || (suite.suites || []).some(hasFailure);

for (const root of data.results || []) {
  if (hasFailure(root) && root.fullFile) {
    failed.add(root.fullFile);
  }
}
// A failure the report cannot attach to a file (e.g. global hook): rerun everything.
if (failed.size === 0 && (data.stats?.failures ?? 0) > 0) {
  process.exit(2);
}
process.stdout.write([...failed].join('\n') + (failed.size ? '\n' : ''));
