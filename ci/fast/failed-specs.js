// Print the spec files with a failed test or hook in a mochawesome JSON report, one per line.
// Exit code 2 when the failures cannot all be attached to spec files: rerun the whole campaign.
// That is the case when the report is missing or unreadable (mocha crashed), when a test or hook of
// the root suite failed (utils/setup.ts hooks, top-level hooks or tests of a spec file, uncaught
// errors outside a test), or when fewer failures are found in the files than mocha counted.
const fs = require('fs');

const isFailed = (t) => t.fail || t.state === 'failed';
const own = (suite) => [...(suite.tests || []), ...(suite.beforeHooks || []), ...(suite.afterHooks || [])];

// -> {files: failed spec files in report order, whole: reason to rerun everything, or null}
const analyse = (data) => {
  if (!data || !Array.isArray(data.results) || !data.results.length) {
    return { files: [], whole: 'no readable report' };
  }
  const files = [];
  let found = 0;
  let rootFailures = 0;
  // Mochawesome wraps the spec files in a root suite, and copies the file of the root's only child
  // suite onto the root itself: the root is recognised by its flag, not by an empty file.
  const walk = (suite, file) => {
    const failures = own(suite).filter(isFailed).length;
    let current = file;
    if (suite.root) {
      rootFailures += failures;
    } else {
      current = suite.fullFile || file;
      found += failures;
      if (failures && !current) {
        rootFailures += failures;
      } else if (failures && !files.includes(current)) {
        files.push(current);
      }
    }
    (suite.suites || []).forEach((s) => walk(s, current));
  };
  data.results.forEach((r) => walk(r, ''));
  const counted = (data.stats && data.stats.failures) || 0;
  if (rootFailures) {
    return { files, whole: `${rootFailures} failure(s) in the root suite (global hook, top-level test or hook, uncaught error)` };
  }
  if (found < counted) {
    return { files, whole: `${found} failure(s) found in spec files for ${counted} counted by mocha` };
  }
  if (!files.length) {
    return { files, whole: 'no failure attached to a spec file' };
  }
  return { files, whole: null };
};

const readReport = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    return null;
  }
};

module.exports = { analyse, readReport };

if (require.main === module) {
  const result = analyse(readReport(process.argv[2]));
  if (result.whole) {
    console.error(`failed-specs: ${result.whole}`);
    process.exit(2);
  }
  process.stdout.write(result.files.map((f) => `${f}\n`).join(''));
}
