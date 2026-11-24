// Uses of the spec file list of a campaign (campaign-specs.js) after its first run.
//
//   spec-order.js prefix   <report> <actual list> <tests/UI dir> [<files json>]
//   spec-order.js coverage <report> <actual list> <intended list> <tests/UI dir> [<files json>]
//
// prefix: the spec files to rerun for the verdict: every file from the first one of the campaign
//   up to the last failed one, in the order of the first run, so that a failure that depends on what
//   the previous files left in the shop shows again. Exit 2 (rerun the whole campaign) whenever the
//   failed files or their order are not certain: failures outside spec files (failed-specs.js),
//   failed or reported files not in the list, report order or loaded order (record-files.js)
//   different from the list.
// coverage: fail (exit 1) when the first run did not load every spec file of the campaign: the
//   campaign command loads other files than the campaign means (split glob expanded by /bin/sh), or
//   mocha did not load a listed file. Without the loaded files of the run, files missing from the
//   report can only be warned about (exit 3): a file may legitimately register no test.
// <files json> is the record of record-files.js; paths are compared relative to tests/UI.
const fs = require('fs');
const path = require('path');
const { analyse, readReport } = require('./failed-specs');

const readList = (f) => {
  try {
    return fs.readFileSync(f, 'utf8').split('\n').map((l) => l.replace(/\r$/, '')).filter(Boolean);
  } catch (e) {
    return null;
  }
};
const readJson = (f) => {
  try {
    return f ? JSON.parse(fs.readFileSync(f, 'utf8')) : null;
  } catch (e) {
    return null;
  }
};

// Spec files in the order of their first suite in the report (the load order of the files).
const reportFiles = (data) => {
  const out = [];
  const walk = (suite) => {
    if (!suite.root && suite.fullFile && !out.includes(suite.fullFile)) {
      out.push(suite.fullFile);
    }
    (suite.suites || []).forEach(walk);
  };
  ((data && data.results) || []).forEach(walk);
  return out;
};

// True when every item of `sub` is in `list`, in the same relative order.
const inOrder = (sub, list) => {
  const index = new Map(list.map((f, i) => [f, i]));
  let last = -1;
  return sub.every((f) => {
    const i = index.get(f);
    if (i === undefined || i < last) {
      return false;
    }
    last = i;
    return true;
  });
};

const prefix = (reportFile, listFile, uiDir, filesJson) => {
  const rel = (f) => path.relative(path.resolve(uiDir), path.resolve(uiDir, f)).split(path.sep).join('/');
  const data = readReport(reportFile);
  const result = analyse(data);
  if (result.whole) {
    return { whole: result.whole };
  }
  const list = readList(listFile);
  if (!list || !list.length) {
    return { whole: 'no spec file list for the campaign' };
  }
  const failed = result.files.map(rel);
  const unknown = failed.filter((f) => !list.includes(f));
  if (unknown.length) {
    return { whole: `failed file(s) not in the campaign list: ${unknown.join(' ')}` };
  }
  if (!inOrder(reportFiles(data).map(rel), list)) {
    return { whole: 'the files of the report are not in the order of the campaign list' };
  }
  const record = readJson(filesJson);
  if (record && record.loaded && record.loaded.length && !inOrder(list, record.loaded)) {
    return { whole: 'mocha did not load the files of the campaign list in this order' };
  }
  const last = Math.max(...failed.map((f) => list.indexOf(f)));
  return { files: list.slice(0, last + 1), total: list.length, failed };
};

const coverage = (reportFile, actualFile, intendedFile, uiDir, filesJson) => {
  const rel = (f) => path.relative(path.resolve(uiDir), path.resolve(uiDir, f)).split(path.sep).join('/');
  const actual = readList(actualFile);
  const intended = readList(intendedFile);
  const errors = [];
  const warnings = [];
  const notes = [];
  if (!actual || !intended) {
    return { errors, warnings: ['no spec file list for the campaign, coverage not checked'], notes };
  }
  intended.filter((f) => !actual.includes(f)).forEach((f) => errors.push(`not loaded by the campaign command: ${f}`));
  actual.filter((f) => !intended.includes(f)).forEach((f) => errors.push(`loaded but not part of the campaign: ${f}`));
  const record = readJson(filesJson);
  const seen = new Set([...reportFiles(readReport(reportFile)).map(rel), ...((record && record.registered) || [])]);
  if (record && record.loaded && record.loaded.length) {
    const loaded = new Set(record.loaded);
    actual.filter((f) => !loaded.has(f)).forEach((f) => errors.push(`not loaded by mocha: ${f}`));
    actual.filter((f) => loaded.has(f) && !seen.has(f)).forEach((f) => notes.push(`loaded, registered no test: ${f}`));
  } else {
    actual.filter((f) => !seen.has(f)).forEach((f) => warnings.push(`no test of this file in the run (dropped, or registers none): ${f}`));
    if (!record) {
      warnings.push('no record of the loaded files, coverage checked against the report only');
    }
  }
  return { errors, warnings, notes, expected: actual.length, seen: actual.filter((f) => seen.has(f)).length };
};

module.exports = { prefix, coverage, reportFiles, inOrder };

if (require.main === module) {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'prefix') {
    const r = prefix(...args);
    if (r.whole) {
      console.error(`spec-order: whole campaign: ${r.whole}`);
      process.exit(2);
    }
    console.error(`spec-order: ${r.files.length}/${r.total} files, up to ${r.files[r.files.length - 1]}`
      + ` (failed: ${r.failed.map((f) => path.basename(f)).join(', ')})`);
    process.stdout.write(r.files.map((f) => `${f}\n`).join(''));
  } else if (cmd === 'coverage') {
    const r = coverage(...args);
    r.errors.forEach((l) => console.log(`coverage error: ${l}`));
    r.warnings.forEach((l) => console.log(`coverage warning: ${l}`));
    r.notes.forEach((l) => console.log(`coverage note: ${l}`));
    if (r.expected !== undefined) {
      console.log(`coverage: ${r.expected} spec files expected, ${r.seen} with tests in the run`);
    }
    process.exit(r.errors.length ? 1 : r.warnings.length ? 3 : 0);
  } else {
    console.error('usage: spec-order.js prefix|coverage ...');
    process.exit(64);
  }
}
