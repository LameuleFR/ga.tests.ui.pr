// Spec files of a campaign, as the campaign's command really loads them.
//
//   campaign-specs.js <tests/UI dir> <campaigns.json> <campaign> <actual out> <intended out>
//
// actual:   the files `TEST_PATH=<glob> npm run test:specific` loads, in mocha's load order: the
//           word campaigns/$TEST_PATH goes unquoted through /bin/sh (as npm runs the script), then
//           every resulting word through mocha's own file lookup (lib/cli/lookup-files.js of the
//           installed mocha, with the .mocharc extensions and recursive flag).
// intended: for a part of a split campaign, the files of the original campaign that the part glob
//           matches with real glob semantics (minimatch, recursive **); else the same as actual.
// One path per line, relative to tests/UI. Exit 1 when the commands are not in the expected form.
// Test hooks: CI_FAST_SH (shell command, default sh), CI_FAST_MOCHA_DIR (mocha package).
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const [ui, confFile, campaign, actualOut, intendedOut] = process.argv.slice(2);
const die = (msg) => {
  console.error(`campaign-specs: ${msg}`);
  process.exit(1);
};
const uiDir = path.resolve(ui);
const conf = JSON.parse(fs.readFileSync(confFile, 'utf8'));
const pkg = JSON.parse(fs.readFileSync(path.join(uiDir, 'package.json'), 'utf8'));
const specific = 'ts-mocha $EXTRA_TEST_PARAMS --file utils/setup.ts campaigns/$TEST_PATH';
if (pkg.scripts['test:specific'] !== specific) {
  die(`unexpected test:specific script: ${pkg.scripts['test:specific']}`);
}
const scriptGlob = (name) => {
  const m = /^TEST_PATH='([^']+)' npm run test:specific$/.exec((pkg.scripts[`test:${name}`] || '').trim());
  return m ? m[1] : die(`unexpected or missing script test:${name}: ${pkg.scripts[`test:${name}`]}`);
};

const rcFile = path.join(uiDir, '.mocharc.json');
const otherRc = ['.mocharc.js', '.mocharc.cjs', '.mocharc.yml', '.mocharc.yaml', '.mocharc.jsonc']
  .filter((f) => fs.existsSync(path.join(uiDir, f)));
if (!fs.existsSync(rcFile) || otherRc.length || pkg.mocha) {
  die('mocha configuration is not a single .mocharc.json');
}
const rc = JSON.parse(fs.readFileSync(rcFile, 'utf8'));
['spec', 'ignore', 'sort', 'file'].forEach((k) => rc[k] !== undefined && die(`.mocharc.json sets ${k}`));

const mochaDir = process.env.CI_FAST_MOCHA_DIR || path.join(uiDir, 'node_modules', 'mocha');
const lookupFiles = require(path.join(mochaDir, 'lib', 'cli', 'lookup-files.js'));
const defaults = JSON.parse(fs.readFileSync(path.join(mochaDir, 'lib', 'mocharc.json'), 'utf8'));
// yargs combine-arrays: mocha's default extensions are kept next to the .mocharc ones.
const extensions = [...new Set([...(defaults.extension || []), ...[].concat(rc.extension || [])])];
const recursive = rc.recursive === true;
const mm = require(require.resolve('minimatch', { paths: [mochaDir] }));
const minimatch = typeof mm === 'function' ? mm : mm.minimatch;

process.chdir(uiDir);
const rel = (f) => path.relative(uiDir, path.resolve(f)).split(path.sep).join('/');

const loaded = (testPath) => {
  // npm runs scripts with `sh` from the PATH (dash on Ubuntu).
  const sh = (process.env.CI_FAST_SH || 'sh').split(' ');
  const out = execFileSync(sh[0], [...sh.slice(1), '-c', 'for a in campaigns/$TEST_PATH; do printf "%s\\n" "$a"; done'], {
    env: { ...process.env, TEST_PATH: testPath },
    encoding: 'utf8',
  });
  // mocha makes the positional arguments unique, then loads them in order.
  const words = [...new Set(out.split('\n').map((w) => w.replace(/\r$/, '')).filter(Boolean))];
  const files = [];
  words.forEach((w) => {
    try {
      files.push(...[].concat(lookupFiles(w, extensions, recursive)).map(rel));
    } catch (e) {
      if (e.code !== 'ERR_MOCHA_NO_FILES_MATCH_PATTERN') {
        throw e;
      }
      console.error(`campaign-specs: no file for ${w}`);
    }
  });
  // A file listed twice is required once: the first position is the load order.
  return { words, files: [...new Set(files)], duplicates: files.length - new Set(files).size };
};

let original = null;
let part = null;
Object.entries(conf.splits || {}).forEach(([o, parts]) => {
  if (parts[campaign] !== undefined) {
    original = o;
    part = parts[campaign];
  }
});

const actual = loaded(part !== null ? part : scriptGlob(campaign));
let intended = actual.files;
if (part !== null) {
  const pattern = `campaigns/${part}`;
  intended = loaded(scriptGlob(original)).files.filter((f) => minimatch(f, pattern, { windowsPathsNoEscape: true }));
}
const write = (f, list) => fs.writeFileSync(f, list.map((x) => `${x}\n`).join(''));
write(actualOut, actual.files);
write(intendedOut, intended);
console.error(`campaign-specs: ${campaign}: ${actual.words.length} word(s) after /bin/sh, ${actual.files.length} files`
  + `${actual.duplicates ? ` (${actual.duplicates} listed twice)` : ''}, intended ${intended.length}`
  + `${original ? ` (part of ${original})` : ''}`);
