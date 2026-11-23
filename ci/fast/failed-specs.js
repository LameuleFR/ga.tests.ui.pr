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
const isFailed = (t) => t.fail || t.state === 'failed';
const hasFailure = (suite) => [...(suite.tests || []), ...(suite.beforeHooks || []), ...(suite.afterHooks || [])].some(isFailed)
  || (suite.failures || []).length > 0
  || (suite.suites || []).some(hasFailure);

// Mochawesome wraps the spec files in a root suite without a file: the file is on its child suites.
const collect = (suite) => {
  if (suite.fullFile) {
    if (hasFailure(suite)) {
      failed.add(suite.fullFile);
    }
    return;
  }
  (suite.suites || []).forEach(collect);
};
(data.results || []).forEach(collect);
// A failure the report cannot attach to a file (e.g. global hook): rerun everything.
if (failed.size === 0 && (data.stats?.failures ?? 0) > 0) {
  process.exit(2);
}
process.stdout.write([...failed].join('\n') + (failed.size ? '\n' : ''));
