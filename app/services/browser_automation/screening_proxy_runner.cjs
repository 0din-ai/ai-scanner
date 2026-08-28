'use strict';

// Per-browser screening proxy for browser-driven scans.
//
// The browser keeps the original hostname so TLS SNI, cookies, and storage
// origins remain correct. The proxy resolves every HTTP/CONNECT/Upgrade
// authority, validates every returned address, and starts only those validated
// IPs in resolver order with a short stagger, using the first one that connects.
// Invalid input, failed DNS, blocked ranges, and exhausted transport attempts
// fail closed. Block reporting is bounded for safe serialization back to Rails.

const dns = require('dns').promises;
const http = require('http');
const net = require('net');

class ScreeningError extends Error {
  constructor(reason, statusCode, details = {}) {
    super(reason);
    this.name = 'ScreeningError';
    this.reason = reason;
    this.statusCode = statusCode;
    this.details = details;
  }
}

function createBlockCollector({ limit = 50, maxUrlLength = 512 } = {}) {
  if (!Number.isInteger(limit) || limit < 0) throw new TypeError('limit must be a non-negative integer');
  if (!Number.isInteger(maxUrlLength) || maxUrlLength < 1) {
    throw new TypeError('maxUrlLength must be a positive integer');
  }
  const samples = [];
  let total = 0;
  return {
    record(value) {
      total += 1;
      if (samples.length < limit) samples.push(String(value).slice(0, maxUrlLength));
    },
    samples: () => samples.slice(),
    count: () => total
  };
}

function ipv4ToBytes(ip) {
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  const bytes = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const value = Number(part);
    if (value > 255) return null;
    bytes.push(value);
  }
  return bytes;
}

function ipToBytes(ip) {
  if (typeof ip !== 'string' || ip.length === 0) return null;
  const address = ip.replace(/^\[|\]$/g, '').split('%')[0];
  if (net.isIPv4(address)) {
    const bytes = ipv4ToBytes(address);
    return bytes ? { bytes, family: 4 } : null;
  }
  if (!net.isIPv6(address)) return null;

  let head = address;
  let tail = [];
  const lastColon = address.lastIndexOf(':');
  const suffix = address.slice(lastColon + 1);
  if (suffix.includes('.')) {
    const v4 = ipv4ToBytes(suffix);
    if (!v4) return null;
    tail = v4;
    head = address.slice(0, lastColon);
  }

  const halves = head.split('::');
  if (halves.length > 2) return null;
  const groupsFor = (part) => part ? part.split(':').filter(Boolean) : [];
  const left = groupsFor(halves[0]);
  const right = halves.length === 2 ? groupsFor(halves[1]) : [];
  const groupCount = 8 - (tail.length ? 2 : 0);
  const missing = groupCount - left.length - right.length;
  if (halves.length === 1 && missing !== 0) return null;
  if (missing < 0) return null;
  const groups = [...left, ...Array(halves.length === 2 ? missing : 0).fill('0'), ...right];
  const bytes = [];
  for (const group of groups) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(group)) return null;
    const value = Number.parseInt(group, 16);
    bytes.push((value >> 8) & 0xff, value & 0xff);
  }
  bytes.push(...tail);
  return bytes.length === 16 ? { bytes, family: 6 } : null;
}

function normalizeIp(parsed) {
  if (!parsed) return null;
  if (parsed.family === 4) return parsed;
  const bytes = parsed.bytes;
  const mapped = bytes.slice(0, 10).every((value) => value === 0) &&
    bytes[10] === 0xff && bytes[11] === 0xff;
  return mapped ? { bytes: bytes.slice(12), family: 4 } : parsed;
}

function sameAddress(left, right) {
  return left.family === right.family &&
    left.bytes.length === right.bytes.length &&
    left.bytes.every((byte, index) => byte === right.bytes[index]);
}

function parseCidr(value) {
  if (typeof value !== 'string' || !value.length) return null;
  const pieces = value.split('/');
  if (pieces.length > 2) return null;
  const address = normalizeIp(ipToBytes(pieces[0]));
  if (!address) return null;
  const maximum = address.family === 4 ? 32 : 128;
  const prefix = pieces.length === 1 ? maximum : Number(pieces[1]);
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > maximum) return null;
  return { ...address, prefix };
}

function withinCidr(address, cidr) {
  if (address.family !== cidr.family) return false;
  let remaining = cidr.prefix;
  for (let index = 0; index < address.bytes.length && remaining > 0; index += 1) {
    const bits = Math.min(8, remaining);
    const mask = (0xff << (8 - bits)) & 0xff;
    if ((address.bytes[index] & mask) !== (cidr.bytes[index] & mask)) return false;
    remaining -= bits;
  }
  return true;
}

function canonicalHostname(value) {
  if (typeof value !== 'string' || value.length === 0 || /[\\%\x00-\x20\x7f]/.test(value)) {
    throw new ScreeningError('invalid-authority', 400);
  }
  let hostname = value;
  if (hostname.startsWith('[') && hostname.endsWith(']')) hostname = hostname.slice(1, -1);
  hostname = hostname.toLowerCase().replace(/\.$/, '');
  if (!hostname) throw new ScreeningError('invalid-authority', 400);

  const ipVersion = net.isIP(hostname);
  if (ipVersion === 4) return hostname;
  if (ipVersion === 6) return new URL(`http://[${hostname}]/`).hostname.slice(1, -1);
  if (/^[0-9.]+$/.test(hostname)) throw new ScreeningError('invalid-authority', 400);

  let ascii;
  try {
    ascii = new URL(`http://${hostname}/`).hostname.toLowerCase().replace(/\.$/, '');
  } catch (_) {
    throw new ScreeningError('invalid-authority', 400);
  }
  const labels = ascii.split('.');
  const valid = ascii.length <= 253 && labels.every((label) =>
    label.length >= 1 && label.length <= 63 &&
    /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)
  );
  if (!valid) throw new ScreeningError('invalid-authority', 400);
  return ascii;
}

function formatAuthority(hostname, port, defaultPort = null) {
  const host = net.isIPv6(hostname) ? `[${hostname}]` : hostname;
  return defaultPort !== null && port === defaultPort ? host : `${host}:${port}`;
}

function parseAuthority(value, defaultPort, requirePort = false) {
  if (typeof value !== 'string' || !value.length || /[\\\/@?#\x00-\x20\x7f]/.test(value)) {
    throw new ScreeningError('invalid-authority', 400);
  }
  let hostnameText;
  let portText = null;
  if (value.startsWith('[')) {
    const closing = value.indexOf(']');
    if (closing < 0) throw new ScreeningError('invalid-authority', 400);
    hostnameText = value.slice(1, closing);
    const remainder = value.slice(closing + 1);
    if (remainder) {
      if (!remainder.startsWith(':')) throw new ScreeningError('invalid-authority', 400);
      portText = remainder.slice(1);
    }
  } else {
    const firstColon = value.indexOf(':');
    const lastColon = value.lastIndexOf(':');
    if (firstColon !== lastColon) throw new ScreeningError('invalid-authority', 400);
    if (lastColon >= 0) {
      hostnameText = value.slice(0, lastColon);
      portText = value.slice(lastColon + 1);
    } else {
      hostnameText = value;
    }
  }
  if (requirePort && portText === null) throw new ScreeningError('invalid-authority', 400);
  const port = portText === null ? defaultPort : Number(portText);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || (portText !== null && !/^\d+$/.test(portText))) {
    throw new ScreeningError('invalid-authority', 400);
  }
  const hostname = canonicalHostname(hostnameText);
  return { hostname, port, authority: formatAuthority(hostname, port, defaultPort) };
}

function rawHeaderValues(request, lowerName) {
  const values = [];
  for (let index = 0; index < request.rawHeaders.length; index += 2) {
    if (request.rawHeaders[index].toLowerCase() === lowerName) values.push(request.rawHeaders[index + 1]);
  }
  return values;
}

function framingValid(request, expected, { upgrade = false } = {}) {
  const hosts = rawHeaderValues(request, 'host');
  if (hosts.length !== 1) return false;
  let supplied;
  try {
    supplied = parseAuthority(hosts[0], expected.defaultPort, false);
  } catch (_) {
    return false;
  }
  if (supplied.hostname !== expected.hostname || supplied.port !== expected.port) return false;
  const contentLengths = rawHeaderValues(request, 'content-length');
  const transferEncodings = rawHeaderValues(request, 'transfer-encoding');
  if (contentLengths.length > 1 || transferEncodings.length > 1) return false;
  if (contentLengths.length && transferEncodings.length) return false;
  if (upgrade) {
    if (contentLengths.length || transferEncodings.length) return false;
    const connections = rawHeaderValues(request, 'connection');
    const upgrades = rawHeaderValues(request, 'upgrade');
    const versions = rawHeaderValues(request, 'sec-websocket-version');
    const keys = rawHeaderValues(request, 'sec-websocket-key');
    if (connections.length !== 1 || upgrades.length !== 1 || versions.length !== 1 || keys.length !== 1) {
      return false;
    }
    const connectionTokens = connections[0].split(',').map((token) => token.trim().toLowerCase()).filter(Boolean);
    if (connectionTokens.length !== 1 || connectionTokens[0] !== 'upgrade') return false;
    if (upgrades[0].trim().toLowerCase() !== 'websocket') return false;
    if (versions[0].trim() !== '13' || !keys[0].trim()) return false;
  } else if (rawHeaderValues(request, 'upgrade').length) {
    return false;
  }
  return true;
}

function parseHttpRequest(request) {
  let url;
  try { url = new URL(request.url); }
  catch (_) { throw new ScreeningError('invalid-url', 400); }
  if (url.protocol !== 'http:' || url.username || url.password || url.hash) {
    throw new ScreeningError('invalid-url', 400);
  }
  const hostname = canonicalHostname(url.hostname);
  const port = url.port ? Number(url.port) : 80;
  const target = {
    kind: 'http', hostname, port, defaultPort: 80,
    authority: formatAuthority(hostname, port, 80),
    display: url.href,
    path: url.pathname + url.search
  };
  if (!framingValid(request, target)) throw new ScreeningError('invalid-framing', 400);
  return target;
}

function parseConnectRequest(request) {
  const parsed = parseAuthority(request.url, 443, true);
  return {
    kind: 'connect', ...parsed, defaultPort: null,
    authority: formatAuthority(parsed.hostname, parsed.port, null),
    display: `https://${formatAuthority(parsed.hostname, parsed.port, 443)}/`
  };
}

function connectFramingValid(request, target, head) {
  if (request.method !== 'CONNECT' || (head && head.length)) return false;
  const hosts = rawHeaderValues(request, 'host');
  if (hosts.length !== 1) return false;
  let supplied;
  try {
    supplied = parseAuthority(hosts[0], target.port, true);
  } catch (_) {
    return false;
  }
  if (supplied.hostname !== target.hostname || supplied.port !== target.port) return false;
  if (rawHeaderValues(request, 'content-length').length) return false;
  if (rawHeaderValues(request, 'transfer-encoding').length) return false;
  if (rawHeaderValues(request, 'upgrade').length) return false;
  return rawHeaderValues(request, 'connection').length <= 1;
}

function parseUpgradeRequest(request) {
  if (request.method !== 'GET') throw new ScreeningError('invalid-framing', 400);
  let url;
  try { url = new URL(request.url); }
  catch (_) { throw new ScreeningError('invalid-url', 400); }
  if (url.protocol !== 'ws:' || url.username || url.password || url.hash) {
    throw new ScreeningError('invalid-url', 400);
  }
  const hostname = canonicalHostname(url.hostname);
  const port = url.port ? Number(url.port) : 80;
  const target = {
    kind: 'upgrade', hostname, port, defaultPort: 80,
    authority: formatAuthority(hostname, port, 80),
    display: url.href,
    path: url.pathname + url.search
  };
  if (!framingValid(request, target, { upgrade: true })) {
    throw new ScreeningError('invalid-framing', 400);
  }
  return target;
}

function connectionNamedHeaders(headers) {
  const names = new Set();
  for (const value of [].concat(headers.connection || [])) {
    for (const token of String(value).split(',')) {
      const name = token.trim().toLowerCase();
      if (name) names.add(name);
    }
  }
  return names;
}

function withoutHopByHopHeaders(headers) {
  const blocked = new Set([
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade'
  ]);
  connectionNamedHeaders(headers).forEach((name) => blocked.add(name));
  return Object.fromEntries(
    Object.entries(headers).filter(([name]) => !blocked.has(name.toLowerCase()))
  );
}

function upgradeHeaders(request, authority) {
  const connectionNames = new Set();
  for (const value of rawHeaderValues(request, 'connection')) {
    for (const token of value.split(',')) {
      const lower = token.trim().toLowerCase();
      if (lower) connectionNames.add(lower);
    }
  }
  const blocked = new Set([
    'host', 'connection', 'upgrade', 'content-length', 'transfer-encoding',
    'proxy-authorization', 'proxy-connection', 'keep-alive', 'te', 'trailer'
  ]);
  connectionNames.forEach((name) => blocked.add(name));
  const lines = [];
  for (let index = 0; index < request.rawHeaders.length; index += 2) {
    const name = request.rawHeaders[index];
    const lower = name.toLowerCase();
    if (blocked.has(lower)) continue;
    lines.push(`${name}: ${request.rawHeaders[index + 1]}`);
  }
  lines.push(`Host: ${authority}`);
  lines.push('Connection: Upgrade');
  lines.push('Upgrade: websocket');
  return lines;
}

function createScreeningProxy(options = {}) {
  const {
    blockedCidrs = [],
    allowedInternalHosts = [],
    allowedAddresses = [],
    resolve = async (host) => (await dns.lookup(host, { all: true })).map((entry) => entry.address),
    connect = (connectOptions) => net.connect(connectOptions),
    onBlock = null,
    connectTimeoutMs = 30000,
    connectAttemptDelayMs = 250,
    reportLimit = 50,
    maxUrlLength = 512,
    maxReportedAddresses = 16
  } = options;
  if (typeof resolve !== 'function') throw new TypeError('resolve must be a function');
  if (typeof connect !== 'function') throw new TypeError('connect must be a function');
  if (!Number.isInteger(connectTimeoutMs) || connectTimeoutMs < 1) {
    throw new TypeError('connectTimeoutMs must be a positive integer');
  }
  if (!Number.isInteger(connectAttemptDelayMs) || connectAttemptDelayMs < 0) {
    throw new TypeError('connectAttemptDelayMs must be a non-negative integer');
  }
  if (!Number.isInteger(maxReportedAddresses) || maxReportedAddresses < 1) {
    throw new TypeError('maxReportedAddresses must be a positive integer');
  }
  if (!Array.isArray(blockedCidrs) || blockedCidrs.length === 0) {
    throw new TypeError('blockedCidrs must be a non-empty array');
  }

  const cidrs = blockedCidrs.map((value) => {
    const parsed = parseCidr(value);
    if (!parsed) throw new TypeError(`invalid blocked CIDR: ${value}`);
    return parsed;
  });
  const allowedHosts = new Set(allowedInternalHosts.map(canonicalHostname));
  if (!Array.isArray(allowedAddresses)) throw new TypeError('allowedAddresses must be an array');
  const approvedAddresses = allowedAddresses.map((value) => {
    const parsed = normalizeIp(ipToBytes(value));
    if (!parsed) throw new TypeError(`invalid allowed address: ${value}`);
    return parsed;
  });
  const blocked = createBlockCollector({ limit: reportLimit, maxUrlLength });
  const detailSamples = [];
  const sockets = new Set();
  const pendingConnects = new Set();
  let lastAddress = null;
  let closed = false;
  let closing = false;

  function track(socket) {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
    return socket;
  }

  function recordBlock(target, reason, details = {}) {
    const display = target?.display || target?.authority || details.input || reason;
    blocked.record(display);
    const allResolvedAddresses = Array.isArray(details.resolvedAddresses) ?
      details.resolvedAddresses.slice() :
      (details.resolvedAddresses == null ? [] : [details.resolvedAddresses]);
    const allBlockedAddresses = Array.isArray(details.blockedAddresses) ?
      details.blockedAddresses.slice() :
      (details.blockedAddresses == null ? [] : [details.blockedAddresses]);
    const event = {
      target: String(display).slice(0, maxUrlLength),
      kind: target?.kind || details.kind || 'unknown',
      authority: target?.authority || null,
      reason,
      resolvedAddresses: allResolvedAddresses.slice(0, maxReportedAddresses),
      resolvedAddressesTruncated: Math.max(0, allResolvedAddresses.length - maxReportedAddresses),
      blockedAddresses: allBlockedAddresses.slice(0, maxReportedAddresses),
      blockedAddressesTruncated: Math.max(0, allBlockedAddresses.length - maxReportedAddresses),
      selectedAddress: details.selectedAddress || null
    };
    if (detailSamples.length < reportLimit) detailSamples.push(event);
    if (typeof onBlock === 'function') {
      try { onBlock(event); } catch (_) { /* Reporting must not alter enforcement. */ }
    }
    return event;
  }

  function blockedAddress(address) {
    const parsed = normalizeIp(ipToBytes(address));
    if (!parsed) return true;
    return cidrs.some((cidr) => withinCidr(parsed, cidr));
  }

  function ensureOpen() {
    if (closing || closed) throw new ScreeningError('proxy-closed', 502);
  }

  async function screen(target) {
    ensureOpen();
    const isLiteral = Boolean(net.isIP(target.hostname));
    let rawAddresses;
    if (isLiteral) {
      rawAddresses = [target.hostname];
    } else {
      try {
        rawAddresses = await resolve(target.hostname);
      } catch (error) {
        throw new ScreeningError('dns-failure', 502, { cause: error });
      }
    }
    // DNS is asynchronous and may finish after close() has already torn down
    // the listener. Never turn a stale answer into a post-shutdown connection.
    ensureOpen();
    if (!Array.isArray(rawAddresses) || rawAddresses.length === 0) {
      throw new ScreeningError('unresolvable-authority', 502);
    }
    const addresses = [];
    for (const value of rawAddresses) {
      if (typeof value !== 'string' || !normalizeIp(ipToBytes(value))) {
        throw new ScreeningError('invalid-dns-answer', 502, { resolvedAddresses: rawAddresses });
      }
      if (!addresses.includes(value)) addresses.push(value);
    }
    const hostApproved = !isLiteral && allowedHosts.has(target.hostname);
    const forbidden = addresses.filter((address) => {
      if (!blockedAddress(address)) return false;
      if (!hostApproved) return true;
      const parsed = normalizeIp(ipToBytes(address));
      return !approvedAddresses.some((approved) => sameAddress(parsed, approved));
    });
    if (forbidden.length) {
      throw new ScreeningError('blocked-address', 403, {
        resolvedAddresses: addresses,
        blockedAddresses: forbidden
      });
    }
    return {
      addresses,
      selectedAddress: addresses[0],
      family: net.isIP(addresses[0]),
      exempt: hostApproved && addresses.some(blockedAddress)
    };
  }

  function connectAddress(address, port) {
    const socket = track(connect({
        host: address,
        family: net.isIP(address),
        port
      }));
    const connected = new Promise((resolveConnect, rejectConnect) => {
      let settled = false;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        socket.setTimeout(0);
        socket.off('connect', onConnect);
        socket.off('error', onError);
        socket.off('close', onClose);
        callback(value);
      };
      const onConnect = () => finish(resolveConnect, socket);
      const onError = (error) => {
        socket.destroy();
        finish(rejectConnect, error);
      };
      const onClose = () => finish(rejectConnect, new Error('connection closed before connect'));
      socket.setTimeout(connectTimeoutMs, () => {
        socket.destroy(new Error('connect timeout'));
      });
      socket.once('connect', onConnect);
      socket.once('error', onError);
      socket.once('close', onClose);
    });
    return { socket, connected };
  }

  async function connectValidated(decision, port) {
    ensureOpen();
    return new Promise((resolveConnect, rejectConnect) => {
      const attempts = [];
      const timers = [];
      let failures = 0;
      let lastError = null;
      let settled = false;
      let operation;

      const clearPending = () => {
        timers.forEach(clearTimeout);
        if (operation) pendingConnects.delete(operation);
      };

      const cancel = () => {
        if (settled) return;
        settled = true;
        clearPending();
        attempts.forEach((attempt) => attempt.socket.destroy());
        rejectConnect(new ScreeningError('proxy-closed', 502));
      };

      operation = { cancel };
      pendingConnects.add(operation);

      const fail = (error) => {
        if (settled) return;
        failures += 1;
        lastError = error;
        if (failures !== decision.addresses.length) return;
        settled = true;
        clearPending();
        rejectConnect(new ScreeningError('connection-failed', 502, {
          resolvedAddresses: decision.addresses,
          cause: lastError
        }));
      };

      const succeed = (attempt, socket) => {
        if (settled) {
          socket.destroy();
          return;
        }
        settled = true;
        clearPending();
        attempts.forEach((candidate) => {
          if (candidate !== attempt) candidate.socket.destroy();
        });
        resolveConnect({ socket, selectedAddress: attempt.address });
      };

      decision.addresses.forEach((address, index) => {
        timers.push(setTimeout(() => {
          if (settled) return;
          if (closing || closed) {
            cancel();
            return;
          }
          let attempt;
          try {
            attempt = { address, ...connectAddress(address, port) };
          } catch (error) {
            fail(error);
            return;
          }
          attempts.push(attempt);
          attempt.connected.then(
            (socket) => succeed(attempt, socket),
            fail
          );
        }, index * connectAttemptDelayMs));
      });
    });
  }

  function screeningFailure(target, error) {
    const screeningError = error instanceof ScreeningError ? error :
      new ScreeningError('internal-proxy-error', 502, { cause: error });
    recordBlock(target, screeningError.reason, screeningError.details);
    return screeningError;
  }

  function rejectHttp(response, error) {
    if (!response.headersSent) {
      response.writeHead(error.statusCode, { connection: 'close', 'content-length': '0' });
    }
    response.end();
  }

  function rejectSocket(socket, error) {
    if (!socket.destroyed) {
      const reason = error.statusCode === 400 ? 'Bad Request' :
        error.statusCode === 403 ? 'Forbidden' : 'Bad Gateway';
      socket.end(`HTTP/1.1 ${error.statusCode} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    }
  }

  function pipeTunnel(clientSocket, upstream) {
    const destroy = (socket) => {
      if (!socket.destroyed) socket.destroy();
    };

    // An error belongs to the endpoint that emitted it. Passing that Error into
    // peer.destroy(error) makes the peer emit a second, potentially unhandled
    // error after it has already closed. Consume both sides and tear the peer
    // down without forwarding the Error object.
    clientSocket.on('error', () => destroy(upstream));
    upstream.on('error', () => destroy(clientSocket));

    // Preserve TCP half-close semantics: FIN in one direction ends the peer's
    // writable side while allowing already-buffered data in the other direction
    // to drain. A full close/error then tears down the remaining endpoint.
    clientSocket.once('end', () => {
      if (!upstream.destroyed && !upstream.writableEnded) upstream.end();
    });
    upstream.once('end', () => {
      if (!clientSocket.destroyed && !clientSocket.writableEnded) clientSocket.end();
    });
    clientSocket.once('close', () => destroy(upstream));
    upstream.once('close', () => destroy(clientSocket));

    clientSocket.pipe(upstream, { end: false });
    upstream.pipe(clientSocket, { end: false });
  }

  const server = http.createServer((request, response) => {
    (async () => {
      let target;
      try {
        target = parseHttpRequest(request);
        const decision = await screen(target);
        const connection = await connectValidated(decision, target.port);
        const headers = withoutHopByHopHeaders(request.headers);
        headers.host = target.authority;
        const agent = new http.Agent({ keepAlive: false, maxSockets: 1 });
        agent.createConnection = () => connection.socket;
        const upstream = http.request({
          hostname: connection.selectedAddress,
          family: net.isIP(connection.selectedAddress),
          port: target.port,
          method: request.method,
          path: target.path,
          headers,
          agent
        });
        let responseStarted = false;
        upstream.on('response', (upstreamResponse) => {
          responseStarted = true;
          response.writeHead(
            upstreamResponse.statusCode,
            withoutHopByHopHeaders(upstreamResponse.headers)
          );
          upstreamResponse.pipe(response);
        });
        upstream.once('error', (cause) => {
          if (responseStarted || response.destroyed) return;
          const error = screeningFailure(target, new ScreeningError('connection-failed', 502, {
            resolvedAddresses: decision.addresses,
            selectedAddress: connection.selectedAddress,
            cause
          }));
          rejectHttp(response, error);
        });
        upstream.once('close', () => agent.destroy());
        request.once('aborted', () => upstream.destroy());
        request.pipe(upstream);
      } catch (cause) {
        rejectHttp(response, screeningFailure(target, cause));
      }
    })();
  });

  server.on('connect', (request, clientSocket, head) => {
    track(clientSocket);
    (async () => {
      let target;
      try {
        target = parseConnectRequest(request);
        if (!connectFramingValid(request, target, head)) {
          throw new ScreeningError('invalid-framing', 400);
        }
        const decision = await screen(target);
        const connection = await connectValidated(decision, target.port);
        const upstream = connection.socket;
        pipeTunnel(clientSocket, upstream);
        clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        if (head.length) upstream.write(head);
      } catch (cause) {
        rejectSocket(clientSocket, screeningFailure(target, cause));
      }
    })();
  });

  server.on('upgrade', (request, clientSocket, head) => {
    track(clientSocket);
    (async () => {
      let target;
      try {
        target = parseUpgradeRequest(request);
        const decision = await screen(target);
        const connection = await connectValidated(decision, target.port);
        const upstream = connection.socket;
        pipeTunnel(clientSocket, upstream);
        upstream.write(
          `${request.method} ${target.path} HTTP/${request.httpVersion}\r\n` +
          `${upgradeHeaders(request, target.authority).join('\r\n')}\r\n\r\n`
        );
        if (head.length) upstream.write(head);
      } catch (cause) {
        rejectSocket(clientSocket, screeningFailure(target, cause));
      }
    })();
  });

  server.on('clientError', (_error, socket) => {
    recordBlock(null, 'invalid-client-request', { kind: 'client' });
    if (!socket.destroyed) {
      socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    }
  });
  server.on('connection', track);

  const controller = {
    server,
    blocked,
    async listen(port = 0) {
      if (closed || closing) throw new Error('proxy is closed');
      if (server.listening) throw new Error('proxy is already listening');
      await new Promise((resolveListen, rejectListen) => {
        const onError = (error) => { server.off('listening', onListening); rejectListen(error); };
        const onListening = () => { server.off('error', onError); resolveListen(); };
        server.once('error', onError);
        server.once('listening', onListening);
        server.listen(port, '127.0.0.1');
      });
      lastAddress = server.address();
      return controller;
    },
    address() {
      return server.address() || lastAddress;
    },
    url() {
      const address = controller.address();
      if (!address) throw new Error('proxy is not listening');
      return `http://127.0.0.1:${address.port}`;
    },
    getBlockReport() {
      return {
        blocked_requests: blocked.samples(),
        blocked_request_count: blocked.count()
      };
    },
    blockedEvents() {
      return detailSamples.map((event) => ({
        ...event,
        resolvedAddresses: event.resolvedAddresses.slice(),
        blockedAddresses: event.blockedAddresses.slice()
      }));
    },
    isClosed() {
      return closed;
    },
    async close() {
      if (closed) return;
      if (closing) {
        while (!closed) await new Promise((resolveWait) => setTimeout(resolveWait, 5));
        return;
      }
      closing = true;
      pendingConnects.forEach((operation) => operation.cancel());
      sockets.forEach((socket) => socket.destroy());
      await new Promise((resolveClose) => {
        if (!server.listening) {
          resolveClose();
          return;
        }
        server.close(() => resolveClose());
      });
      closed = true;
      closing = false;
    }
  };
  return controller;
}

async function withScreeningProxy(options, callback) {
  if (typeof callback !== 'function') throw new TypeError('callback must be a function');
  const proxy = createScreeningProxy(options);
  await proxy.listen(options.listenPort || 0);
  try {
    return await callback(proxy);
  } finally {
    await proxy.close();
  }
}

module.exports = {
  createBlockCollector,
  createScreeningProxy,
  withScreeningProxy
};

if (require.main === module) {
  const readline = require('readline');
  const maximumInputBytes = 1024 * 1024;
  let controller = null;
  let configured = false;
  let shuttingDown = null;
  let inputBytes = 0;

  const input = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
    terminal: false
  });

  const emit = (message) => {
    process.stdout.write(`${JSON.stringify(message)}\n`);
  };

  const errorMessage = (error) =>
    String(error && error.message ? error.message : error).slice(0, 500);

  const shutdown = ({ report = false, exitCode = 0 } = {}) => {
    if (shuttingDown) return shuttingDown;
    shuttingDown = (async () => {
      let closeError = null;
      if (controller) {
        try {
          await controller.close();
        } catch (error) {
          closeError = error;
          exitCode = 1;
        }
      }
      if (report) {
        emit({
          type: closeError ? 'error' : 'closed',
          ...(closeError ? { error: errorMessage(closeError) } : {}),
          report: controller ? controller.getBlockReport() : {
            blocked_requests: [],
            blocked_request_count: 0
          },
          blocked_events: controller ? controller.blockedEvents() : []
        });
      }
      process.exitCode = exitCode;
      process.stdin.pause();
      input.close();
    })();
    return shuttingDown;
  };

  const fail = async (error) => {
    emit({ type: 'error', error: errorMessage(error) });
    await shutdown({ exitCode: 1 });
  };

  const configure = async (line) => {
    let options;
    try {
      options = JSON.parse(line);
    } catch (_error) {
      throw new Error('screening proxy configuration must be valid JSON');
    }
    if (!options || typeof options !== 'object' || Array.isArray(options)) {
      throw new Error('screening proxy configuration must be an object');
    }
    controller = createScreeningProxy(options);
    await controller.listen(options.listenPort || 0);
    configured = true;
    emit({ type: 'ready', proxyUrl: controller.url() });
  };

  const command = async (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch (_error) {
      throw new Error('screening proxy command must be valid JSON');
    }
    if (!message || message.command !== 'close') {
      throw new Error('unsupported screening proxy command');
    }
    await shutdown({ report: true });
  };

  input.on('line', (line) => {
    if (shuttingDown) return;
    inputBytes += Buffer.byteLength(line, 'utf8') + 1;
    if (inputBytes > maximumInputBytes) {
      void fail(new Error('screening proxy input exceeds the size limit'));
      return;
    }
    void (configured ? command(line) : configure(line)).catch(fail);
  });

  input.on('close', () => {
    if (!shuttingDown) void shutdown();
  });
  process.once('SIGINT', () => { void shutdown({ exitCode: 130 }); });
  process.once('SIGTERM', () => { void shutdown({ exitCode: 143 }); });
}
