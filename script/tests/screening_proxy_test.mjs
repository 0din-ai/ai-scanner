// Integration and parser-hardening tests for the browser screening proxy.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import dns from 'node:dns/promises';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { EventEmitter, once } from 'node:events';
import { createRequire } from 'node:module';
import { after, before, test } from 'node:test';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RUNNER_PATH = path.join(__dirname, '..', '..', 'app', 'services', 'browser_automation', 'screening_proxy_runner.cjs');
let chromium;
let playwrightUnavailable;
try {
  ({ chromium } = require('playwright'));
  if (!fs.existsSync(chromium.executablePath())) {
    playwrightUnavailable = `Chromium executable is absent at ${chromium.executablePath()}`;
    chromium = undefined;
  }
} catch (error) {
  playwrightUnavailable = error.message;
}

let proxyApi;
function screeningProxyApi() {
  proxyApi ||= require('../../app/services/browser_automation/screening_proxy_runner.cjs');
  return proxyApi;
}

function createBlockCollector(options) {
  return screeningProxyApi().createBlockCollector(options);
}

function createScreeningProxy(options) {
  return screeningProxyApi().createScreeningProxy(options);
}

function withScreeningProxy(options, callback) {
  return screeningProxyApi().withScreeningProxy(options, callback);
}

const BLOCKED_CIDRS = [
  '127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
  '169.254.0.0/16', '0.0.0.0/8', '::1/128', 'fc00::/7', 'fe80::/10',
  '100.64.0.0/10', '240.0.0.0/4', '224.0.0.0/4', '255.255.255.255/32',
  '::/128', 'ff00::/8'
];
const ALLOWED_INTERNAL_HOSTS = ['chat.allowed.test', 'dual.allowed.test'];
const CHROMIUM_ARGS = [
  '--no-sandbox',
  '--disable-setuid-sandbox',
  '--disable-dev-shm-usage',
  '--disable-gpu'
];
const observed = {};
const targetSockets = new Set();
const chatRequestUrls = [];
const chatUpgradeRequests = [];

let certDir;
let chatServer;
let blockedHttpServer;
let blockedWssServer;
let chatPort;
let blockedHttpPort;
let blockedWssPort;
let hangStartedResolve;
let hangStarted;

const counters = {
  chatConnections: 0,
  chatRequests: 0,
  chatUpgrades: 0,
  blockedHttpConnections: 0,
  blockedHttpRequests: 0,
  blockedHttpUpgrades: 0,
  blockedWssConnections: 0,
  blockedWssUpgrades: 0
};

function listen(server, host = '127.0.0.1', port = 0) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => resolve(server.address().port));
  });
}

function closeServer(server) {
  return new Promise((resolve) => {
    targetSockets.forEach((socket) => socket.destroy());
    server.closeAllConnections?.();
    server.close(() => resolve());
  });
}

function trackTargetSocket(socket) {
  targetSockets.add(socket);
  socket.once('close', () => targetSockets.delete(socket));
}

function websocketAccept(request) {
  return crypto
    .createHash('sha1')
    .update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest('base64');
}

function acceptChatWebSocket(request, socket) {
  counters.chatUpgrades += 1;
  chatUpgradeRequests.push({ url: request.url, rawHeaders: request.rawHeaders.slice() });
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${websocketAccept(request)}\r\n\r\n`
  );
  const payload = Buffer.from('chat-ok');
  socket.write(Buffer.concat([Buffer.from([0x81, payload.length]), payload]));
  socket.write(Buffer.from([0x88, 0x02, 0x03, 0xe8]));
  setTimeout(() => socket.end(), 100);
}

function workerPage() {
  return `<!doctype html><script>
    const params = new URLSearchParams(location.search);
    window.workerDone = false;
    const worker = new Worker('/worker.js?ws=' + encodeURIComponent(params.get('ws')) +
      '&wss=' + encodeURIComponent(params.get('wss')));
    worker.onmessage = (event) => { window.workerResult = event.data; window.workerDone = true; worker.terminate(); };
    worker.onerror = (event) => { window.workerResult = { error: event.message }; window.workerDone = true; };
  </script>`;
}

function workerScript() {
  return `
    function attempt(url) {
      return new Promise((resolve) => {
        const result = { url, opened: false, error: null, closeCode: null };
        const socket = new WebSocket(url);
        const timer = setTimeout(() => { result.error = 'timeout'; socket.close(); resolve(result); }, 5000);
        socket.onopen = () => { result.opened = true; };
        socket.onerror = () => { result.error = 'websocket-error'; };
        socket.onclose = (event) => { clearTimeout(timer); result.closeCode = event.code; resolve(result); };
      });
    }
    const params = new URLSearchParams(location.search);
    (async () => postMessage({ ws: await attempt(params.get('ws')), wss: await attempt(params.get('wss')) }))();
  `;
}

async function defaultResolver(host) {
  if (host === 'chat.allowed.test') return ['127.0.0.1'];
  if (host === 'dual.allowed.test') return ['2001:db8::1', '127.0.0.1'];
  if (host === 'rebind.test') return ['127.0.0.1'];
  if (host === 'mixed.test') return ['93.184.216.34', '127.0.0.1'];
  return (await dns.lookup(host, { all: true, family: 4 })).map((entry) => entry.address);
}

function requireOutboundHttps() {
  return new Promise((resolve, reject) => {
    const request = https.get('https://example.com/', { timeout: 5000 }, (response) => {
      response.resume();
      response.once('end', resolve);
    });
    request.once('timeout', () => request.destroy(new Error('outbound HTTPS preflight timed out')));
    request.once('error', reject);
  });
}

function proxyOptions(overrides = {}) {
  return {
    blockedCidrs: BLOCKED_CIDRS,
    allowedInternalHosts: ALLOWED_INTERNAL_HOSTS,
    allowedAddresses: ['127.0.0.1'],
    resolve: defaultResolver,
    connectTimeoutMs: 5000,
    ...overrides
  };
}

function requireChromium(t) {
  if (chromium) return true;
  observed.chromium = { skipped: true, reason: playwrightUnavailable };
  t.skip(`Playwright Chromium unavailable: ${playwrightUnavailable}`);
  return false;
}

async function launchChromium(proxy) {
  return chromium.launch({
    headless: true,
    proxy: { server: proxy.url() },
    args: CHROMIUM_ARGS
  });
}

async function withBrowser(options, callback) {
  return withScreeningProxy(options, async (proxy) => {
    const browser = await launchChromium(proxy);
    try {
      return await callback({ proxy, browser });
    } finally {
      await browser.close();
    }
  });
}

function proxyHttpGet(proxy, absoluteUrl, hostHeader) {
  return new Promise((resolve, reject) => {
    const request = http.get({
      hostname: '127.0.0.1',
      port: proxy.address().port,
      path: absoluteUrl,
      headers: { host: hostHeader, connection: 'close' },
      agent: false
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        body: Buffer.concat(chunks).toString('utf8')
      }));
    });
    request.on('error', reject);
  });
}

function socketCanConnect(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    socket.once('connect', () => { socket.destroy(); resolve(true); });
    socket.once('error', () => resolve(false));
  });
}

async function unusedLoopbackPort() {
  const server = http.createServer();
  const port = await listen(server);
  await closeServer(server);
  return port;
}

function rawProxyExchange(proxy, payload, timeoutMs = 1000) {
  return new Promise((resolve) => {
    const chunks = [];
    const socket = net.connect({ host: '127.0.0.1', port: proxy.address().port }, () => socket.write(payload));
    const finish = () => {
      socket.destroy();
      resolve(Buffer.concat(chunks).toString('latin1'));
    };
    const timer = setTimeout(finish, timeoutMs);
    socket.on('data', (chunk) => {
      chunks.push(chunk);
      if (Buffer.concat(chunks).includes('\r\n\r\n')) {
        clearTimeout(timer);
        finish();
      }
    });
    socket.on('error', () => { clearTimeout(timer); finish(); });
    socket.on('end', () => { clearTimeout(timer); finish(); });
  });
}

function nextChildLine(lines, child, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer);
      lines.off('line', onLine);
      child.off('exit', onExit);
    };
    const onLine = (line) => { cleanup(); resolve(line); };
    const onExit = (code, signal) => {
      cleanup();
      reject(new Error(`runner exited before replying (code=${code}, signal=${signal})`));
    };
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('runner did not reply before timeout'));
    }, timeoutMs);
    lines.once('line', onLine);
    child.once('exit', onExit);
  });
}

before(async () => {
  certDir = fs.mkdtempSync(path.join(os.tmpdir(), 'screening-proxy-test-'));
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', path.join(certDir, 'key.pem'),
    '-out', path.join(certDir, 'cert.pem'),
    '-days', '1', '-subj', '/CN=127.0.0.1',
    '-addext', 'subjectAltName=IP:127.0.0.1'
  ], { stdio: 'ignore' });

  chatServer = http.createServer((request, response) => {
    counters.chatRequests += 1;
    chatRequestUrls.push(request.url);
    if (request.url.startsWith('/plain')) {
      response.writeHead(200, { 'content-type': 'text/plain', connection: 'close' });
      response.end('plain-http-ok');
    } else if (request.url.startsWith('/worker-page')) {
      response.writeHead(200, { 'content-type': 'text/html', connection: 'close' });
      response.end(workerPage());
    } else if (request.url.startsWith('/worker.js')) {
      response.writeHead(200, { 'content-type': 'application/javascript', connection: 'close' });
      response.end(workerScript());
    } else if (request.url.startsWith('/redirect-to-blocked')) {
      response.writeHead(302, {
        location: `http://127.0.0.1:${blockedHttpPort}/redirected`,
        connection: 'close'
      });
      response.end();
    } else if (request.url.startsWith('/hang')) {
      hangStartedResolve?.();
      // Deliberately never respond; proxy teardown must destroy this path.
    } else {
      response.writeHead(404, { connection: 'close' }).end();
    }
  });
  chatServer.on('connection', (socket) => { counters.chatConnections += 1; trackTargetSocket(socket); });
  chatServer.on('upgrade', acceptChatWebSocket);
  chatPort = await listen(chatServer);

  blockedHttpServer = http.createServer((_request, response) => {
    counters.blockedHttpRequests += 1;
    response.writeHead(200).end('should-not-arrive');
  });
  blockedHttpServer.on('connection', (socket) => {
    counters.blockedHttpConnections += 1;
    trackTargetSocket(socket);
  });
  blockedHttpServer.on('upgrade', (_request, socket) => {
    counters.blockedHttpUpgrades += 1;
    socket.destroy();
  });
  blockedHttpPort = await listen(blockedHttpServer);

  blockedWssServer = https.createServer({
    key: fs.readFileSync(path.join(certDir, 'key.pem')),
    cert: fs.readFileSync(path.join(certDir, 'cert.pem'))
  });
  blockedWssServer.on('connection', (socket) => {
    counters.blockedWssConnections += 1;
    trackTargetSocket(socket);
  });
  blockedWssServer.on('upgrade', (_request, socket) => {
    counters.blockedWssUpgrades += 1;
    socket.destroy();
  });
  blockedWssPort = await listen(blockedWssServer);
});

after(async () => {
  await closeServer(chatServer);
  await closeServer(blockedHttpServer);
  await closeServer(blockedWssServer);
  fs.rmSync(certDir, { recursive: true, force: true });
  console.log(`OBSERVED_OUTPUT ${JSON.stringify(observed, null, 2)}`);
});

test('strict public HTTPS preserves hostname/SNI while proxy pins the connection', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  try {
    await requireOutboundHttps();
  } catch (error) {
    observed.https = { skipped: true, reason: error.message };
    t.skip(`outbound HTTPS unavailable: ${error.message}`);
    return;
  }
  await withBrowser(proxyOptions(), async ({ proxy, browser }) => {
    const context = await browser.newContext({ ignoreHTTPSErrors: false });
    const page = await context.newPage();
    const response = await page.goto('https://example.com/', { waitUntil: 'domcontentloaded', timeout: 15000 });
    observed.https = {
      status: response.status(),
      title: await page.title(),
      finalUrl: page.url(),
      report: proxy.getBlockReport()
    };
    assert.equal(response.status(), 200);
    assert.equal(await page.title(), 'Example Domain');
    assert.equal(page.url(), 'https://example.com/');
    await context.close();
  });
});

test('repeated strict HTTPS navigations survive CONNECT teardown races', {
  concurrency: false,
  timeout: 60000
}, async (t) => {
  if (!requireChromium(t)) return;
  try {
    await requireOutboundHttps();
  } catch (error) {
    t.skip(`outbound HTTPS unavailable: ${error.message}`);
    return;
  }

  const statuses = [];
  for (let attempt = 0; attempt < 10; attempt += 1) {
    await withBrowser(proxyOptions(), async ({ browser }) => {
      const context = await browser.newContext({ ignoreHTTPSErrors: false });
      await context.route('**/*', async (route) => {
        const fetched = await route.fetch({ maxRedirects: 0 });
        await route.fulfill({ response: fetched });
      });
      const page = await context.newPage();
      const response = await page.goto('https://example.com/', {
        waitUntil: 'domcontentloaded',
        timeout: 15000
      });
      statuses.push(response.status());
      await page.screenshot({ type: 'png' });
      await context.close();
    });
  }

  observed.repeatedHttps = { attempts: statuses.length, statuses };
  assert.deepEqual(statuses, new Array(10).fill(200));
});

test('plain HTTP allowed target works through the proxy', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  const beforeRequests = chatRequestUrls.length;
  await withBrowser(proxyOptions(), async ({ proxy, browser }) => {
    const page = await browser.newPage();
    const response = await page.goto(`http://chat.allowed.test:${chatPort}/plain`, { waitUntil: 'domcontentloaded' });
    observed.http = {
      status: response.status(),
      body: await response.text(),
      finalUrl: page.url(),
      listener: proxy.address(),
      targetRequests: chatRequestUrls.slice(beforeRequests)
    };
    assert.equal(response.status(), 200);
    assert.equal(observed.http.body, 'plain-http-ok');
    assert.equal(proxy.address().address, '127.0.0.1');
  });
  assert.equal(chatRequestUrls.slice(beforeRequests).some((url) => url.startsWith('/plain')), true);
});

test('allowlisted hostname is exempt only for launch-approved internal addresses', { concurrency: false }, async () => {
  let currentAnswer = '127.0.0.1';
  const allowedHost = 'scoped.allowed.test';
  await withScreeningProxy(proxyOptions({
    allowedInternalHosts: [allowedHost],
    allowedAddresses: ['127.0.0.1'],
    resolve: async (host) => host === allowedHost ? [currentAnswer] : defaultResolver(host)
  }), async (proxy) => {
    const approved = await proxyHttpGet(
      proxy,
      `http://${allowedHost}:${chatPort}/plain`,
      `${allowedHost}:${chatPort}`
    );
    currentAnswer = '127.0.0.2';
    const changed = await proxyHttpGet(
      proxy,
      `http://${allowedHost}:${chatPort}/plain`,
      `${allowedHost}:${chatPort}`
    );
    observed.scopedAllowlist = {
      approvedStatus: approved.status,
      changedStatus: changed.status,
      allowedAddresses: ['127.0.0.1'],
      changedAnswer: currentAnswer,
      detailed: proxy.blockedEvents()
    };
    assert.equal(approved.status, 200);
    assert.equal(changed.status, 403);
    assert.equal(proxy.blockedEvents()[0].reason, 'blocked-address');
    assert.deepEqual(proxy.blockedEvents()[0].blockedAddresses, ['127.0.0.2']);
  });
});

test('blocked-range authority is refused before target TCP', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  const beforeConnections = counters.blockedHttpConnections;
  await withBrowser(proxyOptions(), async ({ proxy, browser }) => {
    const page = await browser.newPage();
    let error;
    let responseStatus;
    try {
      const response = await page.goto(`http://127.0.0.1:${blockedHttpPort}/blocked`, { timeout: 10000 });
      responseStatus = response.status();
    } catch (caught) {
      error = caught.message;
    }
    observed.blockedAuthority = {
      navigationError: error,
      responseStatus,
      targetTcpDelta: counters.blockedHttpConnections - beforeConnections,
      report: proxy.getBlockReport(),
      detailed: proxy.blockedEvents()
    };
    assert.equal(responseStatus, 403);
    assert.equal(counters.blockedHttpConnections, beforeConnections);
    assert.equal(proxy.blocked.count(), 1);
    assert.deepEqual(proxy.blockedEvents()[0].resolvedAddresses, ['127.0.0.1']);
    assert.deepEqual(proxy.blockedEvents()[0].blockedAddresses, ['127.0.0.1']);
  });
});

test('one blocked address rejects a mixed DNS answer before any TCP', { concurrency: false }, async () => {
  const beforeConnections = counters.blockedHttpConnections;
  await withScreeningProxy(proxyOptions(), async (proxy) => {
    const response = await proxyHttpGet(
      proxy,
      `http://mixed.test:${blockedHttpPort}/mixed`,
      `mixed.test:${blockedHttpPort}`
    );
    observed.mixedDnsAnswers = {
      response,
      targetTcpDelta: counters.blockedHttpConnections - beforeConnections,
      detailed: proxy.blockedEvents()
    };
    assert.equal(response.status, 403);
    assert.equal(counters.blockedHttpConnections, beforeConnections);
    assert.deepEqual(proxy.blockedEvents()[0].resolvedAddresses, ['93.184.216.34', '127.0.0.1']);
    assert.deepEqual(proxy.blockedEvents()[0].blockedAddresses, ['127.0.0.1']);
  });
});

test('detailed block reports bound DNS answer lists and return defensive copies', { concurrency: false }, async () => {
  const answers = [
    ...Array.from({ length: 40 }, (_value, index) => `11.0.0.${index + 1}`),
    '127.0.0.1'
  ];
  await withScreeningProxy(proxyOptions({
    maxReportedAddresses: 8,
    resolve: async (host) => host === 'large-answer.test' ? answers : defaultResolver(host)
  }), async (proxy) => {
    const response = await proxyHttpGet(
      proxy,
      `http://large-answer.test:${blockedHttpPort}/large`,
      `large-answer.test:${blockedHttpPort}`
    );
    const firstRead = proxy.blockedEvents();
    firstRead[0].resolvedAddresses.push('mutated-by-caller');
    const secondRead = proxy.blockedEvents();
    observed.boundedDetails = {
      status: response.status,
      resolvedAddressSamples: secondRead[0].resolvedAddresses,
      resolvedAddressesTruncated: secondRead[0].resolvedAddressesTruncated,
      blockedAddressSamples: secondRead[0].blockedAddresses
    };
    assert.equal(response.status, 403);
    assert.equal(secondRead[0].resolvedAddresses.length, 8);
    assert.equal(secondRead[0].resolvedAddresses.includes('mutated-by-caller'), false);
    assert.equal(secondRead[0].resolvedAddressesTruncated, answers.length - 8);
    assert.deepEqual(secondRead[0].blockedAddresses, ['127.0.0.1']);
  });
});

test('proxy-owned DNS blocks split-horizon rebinding before browser transport', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  const guardSideAnswer = '93.184.216.34';
  const proxyLookups = [];
  const beforeConnections = counters.blockedHttpConnections;
  await withBrowser(proxyOptions({
    resolve: async (host) => {
      proxyLookups.push(host);
      if (host === 'rebind.test') return ['127.0.0.1'];
      return defaultResolver(host);
    }
  }), async ({ proxy, browser }) => {
    const page = await browser.newPage();
    let error;
    try {
      await page.goto(`http://rebind.test:${blockedHttpPort}/pivot`, { timeout: 10000 });
    } catch (caught) {
      error = caught.message;
    }
    observed.rebinding = {
      simulatedEarlierGuardAnswer: guardSideAnswer,
      proxyAnswer: '127.0.0.1',
      proxyLookups,
      navigationError: error,
      targetTcpDelta: counters.blockedHttpConnections - beforeConnections,
      report: proxy.getBlockReport()
    };
    assert.equal(proxyLookups.includes('rebind.test'), true);
    assert.equal(counters.blockedHttpConnections, beforeConnections);
    assert.equal(proxy.blocked.count(), 1);
  });
});

test('browser-followed redirect to a blocked address is refused by the proxy', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  const beforeConnections = counters.blockedHttpConnections;
  await withBrowser(proxyOptions(), async ({ proxy, browser }) => {
    const page = await browser.newPage();
    let error;
    let responseStatus;
    try {
      const response = await page.goto(
        `http://chat.allowed.test:${chatPort}/redirect-to-blocked`,
        { timeout: 10000 }
      );
      responseStatus = response.status();
    } catch (caught) {
      error = caught.message;
    }
    observed.redirect = {
      navigationError: error,
      responseStatus,
      targetTcpDelta: counters.blockedHttpConnections - beforeConnections,
      report: proxy.getBlockReport(),
      detailed: proxy.blockedEvents()
    };
    assert.equal(responseStatus, 403);
    assert.equal(counters.blockedHttpConnections, beforeConnections);
    assert.equal(proxy.blocked.count(), 1);
    assert.equal(proxy.blockedEvents()[0].reason, 'blocked-address');
  });
});

test('Worker ws and wss to blocked addresses never reach target TCP', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  const beforeWs = counters.blockedHttpConnections;
  const beforeWss = counters.blockedWssConnections;
  await withBrowser(proxyOptions(), async ({ proxy, browser }) => {
    const page = await browser.newPage();
    const wsUrl = `ws://127.0.0.1:${blockedHttpPort}/worker`;
    const wssUrl = `wss://127.0.0.1:${blockedWssPort}/worker`;
    await page.goto(
      `http://chat.allowed.test:${chatPort}/worker-page?ws=${encodeURIComponent(wsUrl)}&wss=${encodeURIComponent(wssUrl)}`,
      { waitUntil: 'domcontentloaded' }
    );
    await page.waitForFunction(() => window.workerDone === true, null, { timeout: 15000 });
    const result = await page.evaluate(() => window.workerResult);
    observed.workerWebSockets = {
      result,
      wsTargetTcpDelta: counters.blockedHttpConnections - beforeWs,
      wssTargetTcpDelta: counters.blockedWssConnections - beforeWss,
      report: proxy.getBlockReport()
    };
    assert.equal(result.ws.opened, false);
    assert.equal(result.wss.opened, false);
    assert.equal(counters.blockedHttpConnections, beforeWs);
    assert.equal(counters.blockedWssConnections, beforeWss);
    assert.equal(proxy.blocked.count(), 2);
  });
});

test('allowlisted target chat WebSocket still works', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  const beforeUpgrades = counters.chatUpgrades;
  await withBrowser(proxyOptions(), async ({ proxy, browser }) => {
    const page = await browser.newPage();
    await page.goto(`http://chat.allowed.test:${chatPort}/plain`);
    const result = await page.evaluate((url) => new Promise((resolve) => {
      const socket = new WebSocket(url);
      const state = { opened: false, message: null, error: null };
      socket.onopen = () => { state.opened = true; };
      socket.onmessage = (event) => { state.message = event.data; };
      socket.onerror = () => { state.error = 'websocket-error'; };
      socket.onclose = () => resolve(state);
    }), `ws://chat.allowed.test:${chatPort}/socket`);
    observed.chatWebSocket = {
      result,
      targetUpgradeDelta: counters.chatUpgrades - beforeUpgrades,
      report: proxy.getBlockReport()
    };
    assert.deepEqual(result, { opened: true, message: 'chat-ok', error: null });
    assert.equal(counters.chatUpgrades, beforeUpgrades + 1);
    assert.equal(proxy.blocked.count(), 0);
  });
});

test('malformed Upgrade framing is rejected without forwarding smuggling headers', { concurrency: false }, async () => {
  const beforeUpgrades = counters.chatUpgrades;
  const beforeRequests = chatUpgradeRequests.length;
  await withScreeningProxy(proxyOptions(), async (proxy) => {
    const response = await rawProxyExchange(proxy,
      `GET ws://chat.allowed.test:${chatPort}/socket HTTP/1.1\r\n` +
      `Host: chat.allowed.test:${chatPort}\r\n` +
      'Connection: keep-alive, Upgrade, x-smuggle\r\n' +
      'Upgrade: websocket\r\n' +
      'Transfer-Encoding: chunked\r\n' +
      'X-Smuggle: yes\r\n' +
      'Sec-WebSocket-Version: 13\r\n' +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n' +
      '0\r\n\r\n');
    observed.malformedUpgrade = {
      responseLine: response.split('\r\n')[0],
      targetUpgradeDelta: counters.chatUpgrades - beforeUpgrades,
      forwardedUpgradeRequests: chatUpgradeRequests.slice(beforeRequests),
      report: proxy.getBlockReport()
    };
    assert.match(response, /^HTTP\/1\.1 400 /);
    assert.equal(counters.chatUpgrades, beforeUpgrades);
    assert.equal(chatUpgradeRequests.length, beforeRequests);
  });
});

test('malformed CONNECT framing is rejected before opening the tunnel', { concurrency: false }, async () => {
  const beforeConnections = counters.chatConnections;
  await withScreeningProxy(proxyOptions(), async (proxy) => {
    const response = await rawProxyExchange(proxy,
      `CONNECT chat.allowed.test:${chatPort} HTTP/1.1\r\n` +
      `Host: wrong.test:${chatPort}\r\n` +
      `Host: chat.allowed.test:${chatPort}\r\n` +
      'Content-Length: 4\r\n\r\n' +
      'evil');
    observed.malformedConnect = {
      responseLine: response.split('\r\n')[0],
      targetTcpDelta: counters.chatConnections - beforeConnections,
      report: proxy.getBlockReport()
    };
    assert.match(response, /^HTTP\/1\.1 400 /);
    assert.equal(counters.chatConnections, beforeConnections);
  });
});

test('strictly framed plain WebSocket Upgrade is forwarded', { concurrency: false }, async () => {
  const beforeUpgrades = counters.chatUpgrades;
  await withScreeningProxy(proxyOptions(), async (proxy) => {
    const response = await rawProxyExchange(proxy,
      `GET ws://chat.allowed.test:${chatPort}/socket HTTP/1.1\r\n` +
      `Host: chat.allowed.test:${chatPort}\r\n` +
      'Connection: Upgrade\r\n' +
      'Upgrade: websocket\r\n' +
      'Sec-WebSocket-Version: 13\r\n' +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n');
    observed.validUpgrade = {
      responseLine: response.split('\r\n')[0],
      targetUpgradeDelta: counters.chatUpgrades - beforeUpgrades
    };
    assert.match(response, /^HTTP\/1\.1 101 /);
    assert.equal(counters.chatUpgrades, beforeUpgrades + 1);
  });
});

test('unresolvable and unparsable authorities fail closed and are reported', { concurrency: false }, async () => {
  await withScreeningProxy(proxyOptions({
    resolve: async (host) => {
      if (host === 'missing.test') throw new Error('ENOTFOUND');
      return defaultResolver(host);
    }
  }), async (proxy) => {
    const dnsFailure = await proxyHttpGet(
      proxy,
      `http://missing.test:${blockedHttpPort}/missing`,
      `missing.test:${blockedHttpPort}`
    );
    const invalidConnect = await rawProxyExchange(proxy,
      'CONNECT missing-port.test HTTP/1.1\r\n' +
      'Host: missing-port.test\r\n\r\n');
    observed.failClosedInputs = {
      dnsFailureStatus: dnsFailure.status,
      invalidConnectLine: invalidConnect.split('\r\n')[0],
      reasons: proxy.blockedEvents().map((event) => event.reason),
      report: proxy.getBlockReport()
    };
    assert.equal(dnsFailure.status, 502);
    assert.match(invalidConnect, /^HTTP\/1\.1 400 /);
    assert.deepEqual(observed.failClosedInputs.reasons, ['dns-failure', 'invalid-authority']);
  });
});

test('missing or empty block policy refuses to create a proxy', { concurrency: false }, () => {
  for (const options of [{}, { blockedCidrs: [] }, { blockedCidrs: null }]) {
    assert.throws(
      () => createScreeningProxy(options),
      /blockedCidrs must be a non-empty array/
    );
  }
});

test('plain HTTP retries the next validated address when the first is unreachable', { concurrency: false }, async () => {
  const beforeConnections = counters.chatConnections;
  await withScreeningProxy(proxyOptions(), async (proxy) => {
    const response = await proxyHttpGet(
      proxy,
      `http://dual.allowed.test:${chatPort}/plain`,
      `dual.allowed.test:${chatPort}`
    );
    observed.dualStack = {
      resolved: ['2001:db8::1', '127.0.0.1'],
      status: response.status,
      body: response.body,
      ipv4FallbackTargetTcpDelta: counters.chatConnections - beforeConnections
    };
    assert.equal(response.status, 200);
    assert.equal(response.body, 'plain-http-ok');
    assert.equal(counters.chatConnections, beforeConnections + 1);
    assert.equal(proxy.blocked.count(), 0);
  });
});

test('a hanging first address cannot consume the fallback connection budget', {
  concurrency: false,
  timeout: 3000
}, async () => {
  const firstAddress = '198.51.100.10';
  const targetHost = 'hanging-first.test';
  const originalConnect = net.connect;
  let hangingDestroyed = false;

  class HangingConnectSocket extends EventEmitter {
    constructor() {
      super();
      this.syntheticTimeout = setTimeout(
        () => this.destroy(new Error('synthetic connect timeout')),
        1000
      );
    }

    setTimeout() {
      return this;
    }

    destroy(error) {
      if (hangingDestroyed) return this;
      hangingDestroyed = true;
      clearTimeout(this.syntheticTimeout);
      queueMicrotask(() => {
        if (error) this.emit('error', error);
        this.emit('close');
      });
      return this;
    }
  }

  const hangingSocket = new HangingConnectSocket();
  const connect = (options) => options.host === firstAddress ? hangingSocket : originalConnect(options);
  net.connect = connect;
  try {
    const startedAt = Date.now();
    await withScreeningProxy(proxyOptions({
      allowedInternalHosts: [targetHost],
      allowedAddresses: ['127.0.0.1'],
      connect,
      connectAttemptDelayMs: 50,
      connectTimeoutMs: 1000,
      resolve: async (host) => {
        assert.equal(host, targetHost);
        return [firstAddress, '127.0.0.1'];
      }
    }), async (proxy) => {
      const response = await proxyHttpGet(
        proxy,
        `http://${targetHost}:${chatPort}/plain`,
        `${targetHost}:${chatPort}`
      );
      const elapsedMs = Date.now() - startedAt;
      observed.hangingFirstAddress = { response, elapsedMs, hangingDestroyed };
      assert.equal(response.status, 200);
      assert.equal(response.body, 'plain-http-ok');
      assert.ok(elapsedMs < 500, `fallback took ${elapsedMs}ms`);
      assert.equal(hangingDestroyed, true);
    });
  } finally {
    net.connect = originalConnect;
    hangingSocket.destroy();
  }
});

test('CONNECT retries the next validated address when the first is unreachable', { concurrency: false }, async () => {
  const beforeConnections = counters.chatConnections;
  await withScreeningProxy(proxyOptions(), async (proxy) => {
    const response = await rawProxyExchange(proxy,
      `CONNECT dual.allowed.test:${chatPort} HTTP/1.1\r\n` +
      `Host: dual.allowed.test:${chatPort}\r\n\r\n`);
    observed.dualStackConnect = {
      responseLine: response.split('\r\n')[0],
      targetTcpDelta: counters.chatConnections - beforeConnections
    };
    assert.match(response, /^HTTP\/1\.1 200 /);
    assert.equal(counters.chatConnections, beforeConnections + 1);
    assert.equal(proxy.blocked.count(), 0);
  });
});

test('WebSocket Upgrade retries the next validated address when the first is unreachable', { concurrency: false }, async () => {
  const beforeUpgrades = counters.chatUpgrades;
  await withScreeningProxy(proxyOptions(), async (proxy) => {
    const response = await rawProxyExchange(proxy,
      `GET ws://dual.allowed.test:${chatPort}/socket HTTP/1.1\r\n` +
      `Host: dual.allowed.test:${chatPort}\r\n` +
      'Connection: Upgrade\r\n' +
      'Upgrade: websocket\r\n' +
      'Sec-WebSocket-Version: 13\r\n' +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n');
    observed.dualStackUpgrade = {
      responseLine: response.split('\r\n')[0],
      targetUpgradeDelta: counters.chatUpgrades - beforeUpgrades
    };
    assert.match(response, /^HTTP\/1\.1 101 /);
    assert.equal(counters.chatUpgrades, beforeUpgrades + 1);
    assert.equal(proxy.blocked.count(), 0);
  });
});

test('exhausting every validated address fails closed with one bounded report', { concurrency: false }, async () => {
  const unusedPort = await unusedLoopbackPort();
  let lookups = 0;
  await withScreeningProxy(proxyOptions({
    blockedCidrs: ['10.0.0.0/8'],
    allowedInternalHosts: [],
    allowedAddresses: [],
    connectTimeoutMs: 100,
    resolve: async (host) => {
      assert.equal(host, 'validated-unreachable.test');
      lookups += 1;
      return ['127.0.0.2', '127.0.0.3'];
    }
  }), async (proxy) => {
    const response = await proxyHttpGet(
      proxy,
      `http://validated-unreachable.test:${unusedPort}/resource`,
      `validated-unreachable.test:${unusedPort}`
    );
    observed.exhaustedAddresses = {
      status: response.status,
      lookups,
      report: proxy.getBlockReport(),
      detailed: proxy.blockedEvents()
    };
    assert.equal(response.status, 502);
    assert.equal(lookups, 1);
    assert.equal(proxy.blocked.count(), 1);
    assert.deepEqual(proxy.blockedEvents()[0].resolvedAddresses, ['127.0.0.2', '127.0.0.3']);
    assert.equal(proxy.blockedEvents()[0].reason, 'connection-failed');
  });
});

test('block collector keeps compatible bounded samples and full count', { concurrency: false }, () => {
  const collector = createBlockCollector({ limit: 2, maxUrlLength: 24 });
  for (let index = 0; index < 5; index += 1) {
    collector.record(`http://127.0.0.1/${'x'.repeat(40)}?i=${index}`);
  }
  observed.collector = { samples: collector.samples(), count: collector.count() };
  assert.equal(collector.count(), 5);
  assert.equal(collector.samples().length, 2);
  assert.equal(collector.samples().every((sample) => sample.length <= 24), true);
});

test('stdio runner starts the shared proxy and returns its bounded report before exit', { concurrency: false }, async () => {
  const child = spawn(process.execPath, [RUNNER_PATH], {
    stdio: ['pipe', 'pipe', 'pipe']
  });
  const lines = createInterface({ input: child.stdout });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  try {
    const readyLine = nextChildLine(lines, child);
    child.stdin.write(`${JSON.stringify({
      blockedCidrs: BLOCKED_CIDRS,
      reportLimit: 2,
      connectTimeoutMs: 1000
    })}\n`);
    const readyText = await readyLine;
    const ready = JSON.parse(readyText);
    assert.equal(ready.type, 'ready');
    assert.match(ready.proxyUrl, /^http:\/\/127\.0\.0\.1:\d+$/);

    const proxyPort = Number(new URL(ready.proxyUrl).port);
    const refused = await proxyHttpGet(
      { address: () => ({ port: proxyPort }) },
      `http://127.0.0.1:${blockedHttpPort}/runner-blocked`,
      `127.0.0.1:${blockedHttpPort}`
    );
    assert.equal(refused.status, 403);

    const closedLine = nextChildLine(lines, child);
    child.stdin.write('{"command":"close"}\n');
    const closedText = await closedLine;
    const closed = JSON.parse(closedText);
    assert.equal(closed.type, 'closed');
    assert.equal(closed.report.blocked_request_count, 1);
    assert.equal(closed.blocked_events.length, 1);
    assert.equal(closed.blocked_events[0].reason, 'blocked-address');

    const [exitCode, signal] = await once(child, 'exit');
    observed.runner = {
      ready,
      report: closed.report,
      blockedEvents: closed.blocked_events,
      exitCode,
      signal,
      stderr
    };
    assert.equal(exitCode, 0);
    assert.equal(signal, null);
    assert.equal(await socketCanConnect(proxyPort), false);
    assert.equal(stderr, '');
  } finally {
    lines.close();
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  }
});

test('stdio EOF during startup cannot leave the proxy listener behind', { concurrency: false }, async () => {
  const listenPort = await unusedLoopbackPort();
  const child = spawn(process.execPath, [RUNNER_PATH], {
    stdio: ['pipe', 'pipe', 'pipe']
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });

  child.stdin.end(`${JSON.stringify({
    blockedCidrs: BLOCKED_CIDRS,
    listenPort,
    connectTimeoutMs: 1000
  })}\n`);
  const [exitCode, signal] = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('runner did not exit after EOF')), 5000);
    child.once('exit', (code, childSignal) => {
      clearTimeout(timer);
      resolve([code, childSignal]);
    });
  });

  observed.runnerStartupEof = { listenPort, exitCode, signal, stdout, stderr };
  assert.equal(exitCode, 0);
  assert.equal(signal, null);
  assert.equal(await socketCanConnect(listenPort), false);
});

test('a DNS result released after close cannot start a connection', {
  concurrency: false,
  timeout: 3000
}, async () => {
  let releaseResolution;
  let markResolutionStarted;
  let connectAttempts = 0;
  const resolutionStarted = new Promise((resolve) => { markResolutionStarted = resolve; });
  const proxy = createScreeningProxy(proxyOptions({
    resolve: async () => {
      markResolutionStarted();
      return new Promise((resolve) => { releaseResolution = resolve; });
    },
    connect: () => {
      connectAttempts += 1;
      throw new Error('connect must not run after close');
    }
  }));
  await proxy.listen();

  const request = http.get({
    hostname: '127.0.0.1',
    port: proxy.address().port,
    path: 'http://delayed-resolution.test/resource',
    headers: { host: 'delayed-resolution.test', connection: 'close' },
    agent: false
  });
  request.on('error', () => {});
  await resolutionStarted;
  await proxy.close();
  releaseResolution(['93.184.216.34']);
  await new Promise((resolve) => setTimeout(resolve, 50));

  observed.delayedResolutionClose = { proxyClosed: proxy.isClosed(), connectAttempts };
  assert.equal(proxy.isClosed(), true);
  assert.equal(connectAttempts, 0);
});

test('close cancels staggered attempts before another socket starts', {
  concurrency: false,
  timeout: 3000
}, async () => {
  const attempts = [];
  const pendingSockets = [];
  let markFirstAttempt;
  const firstAttemptStarted = new Promise((resolve) => { markFirstAttempt = resolve; });

  class PendingConnectSocket extends EventEmitter {
    setTimeout() { return this; }

    destroy(error) {
      if (this.destroyed) return this;
      this.destroyed = true;
      queueMicrotask(() => {
        if (error) this.emit('error', error);
        this.emit('close');
      });
      return this;
    }
  }

  const proxy = createScreeningProxy(proxyOptions({
    connectAttemptDelayMs: 250,
    resolve: async () => ['198.51.100.10', '198.51.100.11'],
    connect: (options) => {
      attempts.push(options.host);
      if (attempts.length === 1) markFirstAttempt();
      const socket = new PendingConnectSocket();
      pendingSockets.push(socket);
      return socket;
    }
  }));
  await proxy.listen();

  const request = http.get({
    hostname: '127.0.0.1',
    port: proxy.address().port,
    path: 'http://stagger-close.test/resource',
    headers: { host: 'stagger-close.test', connection: 'close' },
    agent: false
  });
  request.on('error', () => {});
  await firstAttemptStarted;
  await proxy.close();
  await new Promise((resolve) => setTimeout(resolve, 350));

  observed.staggerClose = {
    proxyClosed: proxy.isClosed(),
    attempts,
    liveSockets: pendingSockets.filter((socket) => !socket.destroyed).length
  };
  assert.deepEqual(attempts, ['198.51.100.10']);
  assert.equal(pendingSockets.every((socket) => socket.destroyed), true);
});

test('withScreeningProxy tears down after a mid-navigation exception', { concurrency: false }, async (t) => {
  if (!requireChromium(t)) return;
  let capturedProxy;
  let browser;
  let navigation;
  hangStarted = new Promise((resolve) => { hangStartedResolve = resolve; });

  await assert.rejects(
    withScreeningProxy(proxyOptions(), async (proxy) => {
      capturedProxy = proxy;
      browser = await launchChromium(proxy);
      const page = await browser.newPage();
      navigation = page.goto(`http://chat.allowed.test:${chatPort}/hang`, { timeout: 30000 }).catch((error) => error);
      await hangStarted;
      throw new Error('forced-mid-navigation-timeout');
    }),
    /forced-mid-navigation-timeout/
  );

  const port = capturedProxy.address().port;
  const closedBeforeBrowser = capturedProxy.isClosed();
  const connectableAfterThrow = await socketCanConnect(port);
  const navigationResult = await navigation;
  await browser.close();
  observed.teardown = {
    closedBeforeBrowser,
    connectableAfterThrow,
    navigationResult: navigationResult.message || String(navigationResult)
  };
  assert.equal(closedBeforeBrowser, true);
  assert.equal(connectableAfterThrow, false);
  hangStartedResolve = null;
});
