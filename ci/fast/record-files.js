// Mocha root hook, loaded with --file on the first run of a campaign: records the spec files mocha
// loaded (require cache, in load order) and the files that registered tests or suites, next to the
// mochawesome report, for the coverage guard and the order of the rerun (spec-order.js).
// Never fails the run.
const fs = require('fs');
const path = require('path');

before(function () {
  try {
    const cwd = process.cwd();
    const rel = (f) => path.relative(cwd, f).split(path.sep).join('/');
    const loaded = Object.keys(require.cache).map(rel).filter((f) => f.startsWith('campaigns/'));
    let root = this.test.parent;
    while (root.parent) {
      root = root.parent;
    }
    const registered = [];
    const walk = (suite) => {
      [suite, ...suite.tests].forEach((r) => {
        if (r.file && !registered.includes(rel(r.file))) {
          registered.push(rel(r.file));
        }
      });
      suite.suites.forEach(walk);
    };
    walk(root);
    const dir = process.env.MOCHAWESOME_REPORTDIR || 'reports';
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, `${process.env.MOCHAWESOME_REPORTFILENAME || 'run'}-files.json`),
      JSON.stringify({ loaded, registered }, null, 1));
  } catch (e) {
    console.log(`record-files: ${e.message}`);
  }
});
