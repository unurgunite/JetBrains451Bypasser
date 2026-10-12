// Unit tests for redirect_on_451.user.js — no dependencies, runs on node:test.
//
// The userscript exposes its pure helpers via `globalThis.__jb451` when
// loaded outside a browser. Browser globals are stubbed before require;
// per-case behavior (fetch status, DOM markers, redirects) is driven
// through those stubs.
import {describe, it, beforeEach} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = fs.readFileSync(path.join(__dirname, 'redirect_on_451.user.js'), 'utf8');

// Fresh browser stub per test. Returns the sandbox globals.
function makeSandbox({href, fetchStatus, fetchRejects = false, title = '', bodyText = ''}) {
  const store = {};
  const redirected = [];
  const listeners = {};

  globalThis.sessionStorage = {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
  };
  globalThis.window = {
    location: {
      href,
      replace: (url) => { redirected.push(url); },
    },
  };
  globalThis.document = {
    readyState: 'complete',
    title,
    body: {innerText: bodyText},
    addEventListener: (ev, fn) => { listeners[ev] = fn; },
  };
  globalThis.fetch = fetchRejects
    ? () => Promise.reject(new Error('CORS blocked'))
    : () => Promise.resolve({status: fetchStatus});
  // Silence userscript logging.
  globalThis.console = {log: () => {}, warn: () => {}, error: () => {}};

  // Load the userscript fresh (check() runs synchronously on 'complete').
  delete globalThis.__jb451;
  eval(SCRIPT);

  return {store, redirected, listeners};
}

function teardownSandbox() {
  delete globalThis.sessionStorage;
  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.fetch;
  delete globalThis.console;
  delete globalThis.__jb451;
}

// Flush pending fetch .then/.catch chains.
const flush = () => new Promise((resolve) => setTimeout(resolve, 10));

describe('header', () => {
  it('declares updateURL/downloadURL for auto-updates', () => {
    assert.match(SCRIPT, /@updateURL\s+https:\/\/github\.com\/unurgunite\/JetBrains451Bypasser\/raw/);
    assert.match(SCRIPT, /@downloadURL\s+https:\/\/github\.com\/unurgunite\/JetBrains451Bypasser\/raw/);
  });

  it('matches both origin and mirror hosts', () => {
    for (const host of [
      'download.jetbrains.com',
      'download-cdn.jetbrains.com',
      'plugins.jetbrains.com',
      'downloads.marketplace.jetbrains.com',
    ]) {
      assert.match(SCRIPT, new RegExp(`@match\\s+https://${host.replace(/\./g, '\\.')}/`));
    }
  });
});

describe('rewrite()', () => {
  beforeEach(teardownSandbox);

  it('rewrites plugins host to marketplace mirror', () => {
    makeSandbox({href: 'https://plugins.jetbrains.com/plugin/164', fetchStatus: 200});
    assert.equal(
      globalThis.__jb451.rewrite('https://plugins.jetbrains.com/plugin/download?pluginId=x'),
      'https://downloads.marketplace.jetbrains.com/plugin/download?pluginId=x'
    );
  });

  it('rewrites download host to CDN mirror', () => {
    makeSandbox({href: 'https://download.jetbrains.com/a', fetchStatus: 200});
    assert.equal(
      globalThis.__jb451.rewrite('https://download.jetbrains.com/ruby/RM.dmg'),
      'https://download-cdn.jetbrains.com/ruby/RM.dmg'
    );
  });

  it('returns null for unknown hosts', () => {
    makeSandbox({href: 'https://example.com/', fetchStatus: 200});
    assert.equal(globalThis.__jb451.rewrite('https://example.com/file.zip'), null);
  });
});

describe('alreadyOnFinalHost()', () => {
  beforeEach(teardownSandbox);

  it('detects CDN hosts', () => {
    makeSandbox({href: 'https://download-cdn.jetbrains.com/x', fetchStatus: 200});
    assert.equal(globalThis.__jb451.alreadyOnFinalHost('https://download-cdn.jetbrains.com/x'), true);
    assert.equal(globalThis.__jb451.alreadyOnFinalHost('https://downloads.marketplace.jetbrains.com/y'), true);
  });

  it('rejects origin hosts', () => {
    makeSandbox({href: 'https://download.jetbrains.com/x', fetchStatus: 200});
    assert.equal(globalThis.__jb451.alreadyOnFinalHost('https://download.jetbrains.com/x'), false);
    assert.equal(globalThis.__jb451.alreadyOnFinalHost('https://plugins.jetbrains.com/x'), false);
  });
});

describe('check() flow', () => {
  beforeEach(teardownSandbox);

  it('redirects on HTTP 451', async () => {
    const {redirected} = makeSandbox({
      href: 'https://download.jetbrains.com/ruby/RM.dmg',
      fetchStatus: 451,
    });
    await flush();
    assert.deepEqual(redirected, ['https://download-cdn.jetbrains.com/ruby/RM.dmg']);
  });

  it('stays on HTTP 200', async () => {
    const {redirected} = makeSandbox({
      href: 'https://download.jetbrains.com/ruby/RM.dmg',
      fetchStatus: 200,
    });
    await flush();
    assert.deepEqual(redirected, []);
  });

  it('stays when already on the mirror host', async () => {
    const {redirected} = makeSandbox({
      href: 'https://download-cdn.jetbrains.com/ruby/RM.dmg',
      fetchStatus: 451,
    });
    await flush();
    assert.deepEqual(redirected, []);
  });

  it('falls back to DOM 451 marker when HEAD is CORS-blocked', async () => {
    const {redirected} = makeSandbox({
      href: 'https://plugins.jetbrains.com/plugin/164',
      fetchRejects: true,
      title: '451 Unavailable For Legal Reasons',
      bodyText: 'blocked',
    });
    await flush();
    assert.deepEqual(redirected, ['https://downloads.marketplace.jetbrains.com/plugin/164']);
  });

  it('stays when CORS-blocked and no DOM marker', async () => {
    const {redirected} = makeSandbox({
      href: 'https://plugins.jetbrains.com/plugin/164',
      fetchRejects: true,
      title: 'Some Plugin',
      bodyText: 'a nice plugin page',
    });
    await flush();
    assert.deepEqual(redirected, []);
  });

  it('does not loop when the mirror URL was already tried', async () => {
    // Prime sessionStorage BEFORE the script loads, simulating a prior attempt.
    const store = {'jb451_retried': JSON.stringify(['https://download-cdn.jetbrains.com/ruby/RM.dmg'])};
    const redirected = [];
    globalThis.sessionStorage = {
      getItem: (k) => (k in store ? store[k] : null),
      setItem: (k, v) => { store[k] = String(v); },
    };
    globalThis.window = {
      location: {
        href: 'https://download.jetbrains.com/ruby/RM.dmg',
        replace: (url) => { redirected.push(url); },
      },
    };
    globalThis.document = {
      readyState: 'complete', title: '', body: {innerText: ''},
      addEventListener: () => {},
    };
    globalThis.fetch = () => Promise.resolve({status: 451});
    globalThis.console = {log: () => {}, warn: () => {}, error: () => {}};
    delete globalThis.__jb451;
    eval(SCRIPT);
    await flush();
    assert.deepEqual(redirected, []);
  });
});
