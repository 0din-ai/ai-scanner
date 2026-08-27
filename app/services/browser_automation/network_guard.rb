# frozen_string_literal: true

module BrowserAutomation
  # Keeps UrlSafetyValidator's blocklist in force for a browser's whole navigation
  # lifetime, not just the URL we hand to page.goto().
  #
  # PlaywrightService validates the initial URL, but nothing re-checks where the
  # browser ends up afterwards: an HTTP redirect from the target, or JavaScript on
  # the target's own page (fetch/XHR/window.location/iframes/sub-resources), can
  # steer it to a destination that was never screened. Since the browser runs in
  # the same container as Rails, that reaches whatever the container can reach.
  #
  # This module emits a `context.route()` handler that re-resolves and re-screens
  # the host of every request the browser makes, against the CIDR list that
  # UrlSafetyValidator already owns. Requests to a blocked address are aborted.
  #
  # Screening the request URL alone is NOT enough: Chromium follows 3xx responses
  # internally and does not re-invoke route handlers for the redirected hop, for
  # navigations and sub-resources alike. So the handler also walks the redirect
  # chain itself (route.fetch with maxRedirects: 0), screens every hop, and only
  # then hands the final response to the browser.
  #
  # Known limits, deliberately not papered over:
  #   * TOCTOU remains. The guard resolves the host and Chromium resolves it
  #     again for the connection it actually opens; a DNS record that flips
  #     between the two can still slip past. This narrows the window from
  #     "once per scan" to "once per request", which is the most an app-layer
  #     check can do. Network-level egress control is the real fix.
  #   * WebSocket handshakes are not intercepted by route(), so ws:// and wss://
  #     are not covered here.
  #   * Server-Sent Events are host-screened but not redirect-screened: buffering
  #     them through route.fetch() would hold the stream open forever and hang
  #     any chat target that streams tokens.
  module NetworkGuard
    module_function

    # Payload consumed by GUARD_JS. Passed through the data file rather than
    # interpolated into the script, like every other value in these scripts.
    def payload(allow_localhost: nil)
      allow = allow_localhost.nil? ? UrlSafetyValidator.allow_localhost? : allow_localhost
      {
        "blocked_cidrs" => UrlSafetyValidator.blocked_cidrs,
        "allow_loopback" => !!allow
      }
    end

    # Defines __installNetworkGuard(context, guard). Returns a handle whose
    # .blocked() lists what was aborted, for the caller to report back to Rails.
    #
    # Fails closed: a missing, empty, or unparsable blocklist raises before any
    # navigation happens, rather than silently running an unguarded browser.
    GUARD_JS = <<~JS
      const __dnsPromises = require('dns').promises;

      const MAX_REDIRECTS = 20;

      const __netGuard = {
        parseIp(input) {
          let s = String(input == null ? '' : input).trim();
          if (s.startsWith('[') && s.endsWith(']')) s = s.slice(1, -1);
          const zone = s.indexOf('%');
          if (zone !== -1) s = s.slice(0, zone);
          if (s.length === 0) return null;
          return s.includes(':') ? __netGuard.parseIpv6(s) : __netGuard.parseIpv4(s);
        },

        parseIpv4(s) {
          const parts = s.split('.');
          if (parts.length !== 4) return null;
          let n = 0n;
          for (const part of parts) {
            if (!/^[0-9]{1,3}$/.test(part)) return null;
            const value = Number(part);
            if (value > 255) return null;
            n = (n << 8n) | BigInt(value);
          }
          return { version: 4, value: n };
        },

        parseIpv6(s) {
          // Split an embedded IPv4 tail (::ffff:127.0.0.1) into two more groups.
          let tail = [];
          const lastColon = s.lastIndexOf(':');
          const suffix = s.slice(lastColon + 1);
          if (suffix.includes('.')) {
            const v4 = __netGuard.parseIpv4(suffix);
            if (!v4) return null;
            tail = [ Number((v4.value >> 16n) & 0xffffn), Number(v4.value & 0xffffn) ];
            s = s.slice(0, lastColon + 1) + '0:0';
          }

          const halves = s.split('::');
          if (halves.length > 2) return null;

          const toGroups = (text) => {
            if (text === '') return [];
            const out = [];
            for (const group of text.split(':')) {
              if (!/^[0-9a-fA-F]{1,4}$/.test(group)) return null;
              out.push(parseInt(group, 16));
            }
            return out;
          };

          let head = toGroups(halves[0]);
          let rest = halves.length === 2 ? toGroups(halves[1]) : [];
          if (head === null || rest === null) return null;
          if (tail.length) {
            // The '0:0' placeholder stood in for the IPv4 tail; drop it and append.
            const target = halves.length === 2 ? rest : head;
            target.splice(target.length - 2, 2, tail[0], tail[1]);
          }

          let groups;
          if (halves.length === 2) {
            const fill = 8 - head.length - rest.length;
            if (fill < 0) return null;
            groups = head.concat(new Array(fill).fill(0), rest);
          } else {
            groups = head;
          }
          if (groups.length !== 8) return null;

          let n = 0n;
          for (const group of groups) n = (n << 16n) | BigInt(group);

          // Normalize IPv4-mapped/compatible to v4 so ::ffff:10.0.0.1 is screened
          // against the IPv4 ranges rather than sailing past them.
          const high = n >> 32n;
          const low = n & 0xffffffffn;
          // ::ffff:a.b.c.d is always a mapped v4. ::a.b.c.d is the deprecated
          // compat form, but :: and ::1 are v6 addresses in their own right.
          if (high === 0xffffn) return { version: 4, value: low };
          if (high === 0n && low !== 0n && low !== 1n) return { version: 4, value: low };
          return { version: 6, value: n };
        },

        parseCidr(text) {
          const slash = String(text).lastIndexOf('/');
          if (slash === -1) return null;
          const base = __netGuard.parseIp(String(text).slice(0, slash));
          const prefix = Number(String(text).slice(slash + 1));
          if (!base || !Number.isInteger(prefix) || prefix < 0) return null;
          const width = base.version === 4 ? 32 : 128;
          if (prefix > width) return null;
          const shift = BigInt(width - prefix);
          return { version: base.version, network: base.value >> shift, shift };
        },

        contains(range, ip) {
          if (range.version !== ip.version) return false;
          return (ip.value >> range.shift) === range.network;
        }
      };

      async function __installNetworkGuard(context, guard) {
        const cidrs = (guard && guard.blocked_cidrs) || [];
        if (!Array.isArray(cidrs) || cidrs.length === 0) {
          throw new Error('network guard: blocklist missing - refusing to browse unguarded');
        }
        const ranges = cidrs.map(__netGuard.parseCidr);
        const badIndex = ranges.findIndex((range) => range === null);
        if (badIndex !== -1) {
          throw new Error('network guard: unparsable CIDR ' + cidrs[badIndex]);
        }

        const loopback = [ '127.0.0.0/8', '::1/128' ].map(__netGuard.parseCidr);
        const allowLoopback = guard.allow_loopback === true;
        const blocked = [];
        const decisions = new Map();

        const hostAllowed = async (host) => {
          if (decisions.has(host)) return decisions.get(host);

          const verdict = await (async () => {
            let addresses;
            const literal = __netGuard.parseIp(host);
            if (literal) {
              addresses = [ literal ];
            } else {
              let looked;
              try {
                looked = await __dnsPromises.lookup(host, { all: true, verbatim: true });
              } catch (error) {
                return { allowed: false, reason: 'could not resolve ' + host };
              }
              addresses = looked.map((entry) => __netGuard.parseIp(entry.address)).filter(Boolean);
            }
            // No usable address is a fail-closed case, same as the Ruby validator.
            if (!addresses.length) return { allowed: false, reason: 'could not resolve ' + host };

            for (const address of addresses) {
              for (const range of ranges) {
                if (!__netGuard.contains(range, address)) continue;
                if (allowLoopback && loopback.some((lo) => __netGuard.contains(lo, address))) continue;
                return { allowed: false, reason: 'blocked internal address' };
              }
            }
            return { allowed: true };
          })();

          decisions.set(host, verdict);
          return verdict;
        };

        // Screen one URL. Returns null when allowed, or a rejection reason.
        const screen = async (url) => {
          let parsed;
          try {
            parsed = new URL(url);
          } catch (error) {
            return 'unparsable URL';
          }
          if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
            return 'scheme ' + parsed.protocol;
          }
          const verdict = await hostAllowed(parsed.hostname);
          return verdict.allowed ? null : verdict.reason;
        };

        const deny = (route, url, reason) => {
          blocked.push({ url: String(url).slice(0, 200), reason });
          return route.abort('blockedbyclient');
        };

        await context.route('**/*', async (route) => {
          const request = route.request();
          const url = request.url();

          // data:/blob:/about: never leave the renderer, so they need no screening.
          if (/^(data|blob|about):/.test(url)) return route.continue();

          const reason = await screen(url);
          if (reason) return deny(route, url, reason);

          // Server-Sent Events must stay streaming; route.fetch() would buffer the
          // response and hang the connection open forever. Host-screened only.
          const accept = (request.headers()['accept'] || '').toLowerCase();
          if (accept.includes('text/event-stream')) return route.continue();

          // Chromium follows 3xx internally and does NOT re-invoke route handlers
          // for the redirected hop (verified on Playwright 1.59 for both navigation
          // and sub-resource requests), so screening only the request URL leaves the
          // redirect pivot wide open. Walk the chain here instead, screening every
          // hop, and hand the browser the final response.
          let current = url;
          let response;
          try {
            response = await route.fetch({ maxRedirects: 0 });
            for (let hop = 0; hop < MAX_REDIRECTS; hop++) {
              const status = response.status();
              if (status < 300 || status > 399) break;

              const location = response.headers()['location'];
              if (!location) break;

              const next = new URL(location, current).toString();
              const nextReason = await screen(next);
              if (nextReason) return deny(route, next, 'redirect to ' + nextReason);

              current = next;
              response = await route.fetch({ url: next, maxRedirects: 0 });
              if (hop === MAX_REDIRECTS - 1) return deny(route, next, 'too many redirects');
            }
          } catch (error) {
            return route.abort('failed');
          }

          return route.fulfill({ response });
        });

        return { blocked: () => blocked };
      }
    JS
  end
end
