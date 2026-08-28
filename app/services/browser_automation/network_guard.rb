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
  # This layer SCREENS AND REPORTS. It does not enforce.
  #
  # Enforcement belongs to the screening proxy every browser connection is routed
  # through: the proxy resolves each host itself, screens every DNS answer, and
  # connects to the validated numeric address, so it also covers what route() never
  # sees -- WebSocket upgrades, Server-Sent Event redirects, and service-worker
  # traffic. Anything this handler allowed and the proxy disagrees with is stopped
  # at the socket.
  #
  # So the handler screens the visible URL, records what it would have refused, and
  # hands the request straight back to Chromium. It deliberately does NOT walk
  # redirect chains any more. Doing that meant re-issuing the request itself with
  # `route.fetch`, which defaults to the ORIGINAL request's method, headers and post
  # data -- so a 303 from an authenticated origin to a third party replayed the body
  # and credentials that a native browser redirect would have stripped, and the final
  # response was fulfilled into the first request's route, running that content under
  # the wrong origin. It also buffered every non-streaming response. Chromium's own
  # redirect handling gets all of that right, and the proxy screens each new hop.
  #
  # Known limit, deliberately not papered over: a host this layer allows may resolve
  # differently by the time Chromium connects. That is not a hole, because the proxy
  # re-resolves and screens for the connection it actually opens; it only means this
  # layer's REPORT can name a host the proxy later refuses.
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

    # Configuration for the screening proxy each guarded browser launches behind.
    #
    # The route guard screens the URLs it is handed, but it cannot reach three
    # things: the browser resolves each host again, independently of the lookup
    # just validated, so a name answering publicly for us and privately for the
    # browser walks past the check; a redirect hop the browser follows internally
    # never reaches a route handler; and WebSocket traffic is not intercepted at
    # all, including a socket opened from a Worker.
    #
    # The proxy sits below all of it. It resolves each authority once, validates
    # every answer against the same blocklist, and connects to the address it
    # approved -- while the hostname stays in the CONNECT authority, so TLS still
    # verifies strictly against the real host.
    def proxy_payload(allow_localhost: nil, allowed_addresses: [])
      allow = allow_localhost.nil? ? UrlSafetyValidator.allow_localhost? : allow_localhost
      cidrs = UrlSafetyValidator.blocked_cidrs
      cidrs = cidrs.reject { |cidr| loopback_cidr?(cidr) } if allow

      {
        "modulePath" => Rails.root.join("app", "services", "browser_automation", "screening_proxy_runner.cjs").to_s,
        "blockedCidrs" => cidrs,
        # Scoped to this launch: an address approved for this navigation does not
        # stay approved for whatever DNS returns later.
        "allowedAddresses" => Array(allowed_addresses).compact.map(&:to_s)
      }
    end

    # The proxy takes no allow-loopback flag, so permitting loopback means
    # omitting those ranges from the blocklist it screens against.
    #
    # Compared semantically, not by string: blocked_cidrs renders IPv6 in full
    # canonical form, so "::1/128" never matches "0000:...:0001/128" and IPv6
    # loopback would stay blocked while IPv4 loopback was allowed. localhost
    # resolves to both, and the proxy refuses if ANY answer is blocked, so the
    # mismatch denies localhost outright.
    LOOPBACK_RANGES = [ IPAddr.new("127.0.0.0/8"), IPAddr.new("::1/128") ].freeze

    def loopback_cidr?(cidr)
      address = IPAddr.new(cidr)
      LOOPBACK_RANGES.any? { |range| range.include?(address) && range.prefix == address.prefix }
    rescue IPAddr::Error
      false
    end

    # Defines __installNetworkGuard(context, guard). Returns a handle whose
    # .blocked() lists what was aborted, for the caller to report back to Rails.
    #
    # Fails closed: a missing, empty, or unparsable blocklist raises before any
    # navigation happens, rather than silently running an unguarded browser.
    GUARD_JS = <<~JS
      const __dnsPromises = require('dns').promises;

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
        let blockedCount = 0;

        // No decision cache. Python keeps none either, and with the proxy enforcing,
        // a cached verdict cannot make an unsafe request safe -- it can only make this
        // layer's report describe a host by a verdict it no longer holds.
        const hostAllowed = async (host) => {
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

        // Bounded, like Python's report_limit: a page that hammers a blocked host must
        // not grow this array without limit for the lifetime of the browser.
        const REPORT_LIMIT = 50;

        const deny = (route, url, reason) => {
          blockedCount += 1;
          if (blocked.length < REPORT_LIMIT) {
            blocked.push({ url: String(url).slice(0, 200), reason });
          }
          return route.abort('blockedbyclient');
        };

        await context.route('**/*', async (route) => {
          const request = route.request();
          const url = request.url();

          // data:/blob:/about: never leave the renderer, so they need no screening.
          if (/^(data|blob|about):/.test(url)) return route.continue();

          const reason = await screen(url);
          if (reason) return deny(route, url, reason);

          // Straight back to Chromium. The proxy screens the connection this
          // becomes, and every hop of any redirect it follows, so there is nothing
          // for this layer to add by re-issuing the request itself -- and doing so
          // replayed the original method, headers and body across redirects and
          // fulfilled a third party's response under the first origin.
          return route.continue();
        });

        return { blocked: () => blocked };
      }
    JS
  end
end
