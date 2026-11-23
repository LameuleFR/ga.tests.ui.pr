// Mocha root hooks, loaded with --file on the first run of a campaign.
// The steps of a spec file depend on each other: after a failed step the next ones fail too,
// each one after its own timeout. Skip them instead: the whole file is rerun anyway.
const failedFiles = new Set();

afterEach(function () {
  if (this.currentTest && this.currentTest.state === 'failed' && this.currentTest.file) {
    failedFiles.add(this.currentTest.file);
  }
});

beforeEach(function () {
  if (this.currentTest && failedFiles.has(this.currentTest.file)) {
    this.skip();
  }
});
