// Scriptlet runtime for e05's built-in content blocker.
// Independent reimplementation of uBlock Origin / AdGuard scriptlet
// semantics from their documented behaviour — no code is lifted from
// their repositories.
// Bundled at build time via Package.swift `resources:` and loaded
// through Bundle.module by ScriptletEngine.swift, which wraps this
// file together with two baked JS consts:
//   __E05_SCRIPTLET_INDEX__     host → [[name, arg…], …]
//   __E05_SCRIPTLET_WHITELIST__ [host, …]
// inside one enclosing IIFE, so neither const leaks into the page's
// global scope. The combined script runs in the page world at
// document start: scriptlets patch page globals (JSON.parse,
// ytInitialPlayerResponse, …) and must win the race against the
// page's own inline scripts, which rules out any async IPC lookup.

(() => {
  const index =
    typeof __E05_SCRIPTLET_INDEX__ === "undefined"
      ? null
      : __E05_SCRIPTLET_INDEX__;
  const whitelist =
    typeof __E05_SCRIPTLET_WHITELIST__ === "undefined"
      ? []
      : __E05_SCRIPTLET_WHITELIST__;
  if (!index) return;

  // Re-injection guard. WKUserScript can re-run on the same realm
  // (observed with the cosmetic runtime on SPA navigations); running
  // the traps twice would stack duplicate watchers and re-wrap
  // JSON.parse. Non-enumerable so casual `for...in` sweeps over
  // `window` do not surface it.
  const GUARD = "__e05ScriptletsApplied";
  if (window[GUARD]) return;
  try {
    Object.defineProperty(window, GUARD, {
      value: true,
      enumerable: false,
      configurable: false,
      writable: false,
    });
  } catch (_) {
    window[GUARD] = true;
  }

  // ---- hostname scoping -------------------------------------------------

  // Mirror the Swift side's `parentHostnames`: the full hostname plus
  // each parent up toward the registrable domain, never yielding a bare
  // TLD ("a.b.com" → ["a.b.com", "b.com"]). The full host is always
  // included first, so a single-label host ("localhost") still yields
  // ["localhost"] rather than [] — keeping the whitelist and index
  // lookups consistent with the cosmetic / declarative layers.
  function hostnameChain(host) {
    const h = String(host).toLowerCase();
    if (!h) return [];
    const parts = h.split(".");
    const out = [h];
    for (let i = 1; i < parts.length - 1; i++) {
      out.push(parts.slice(i).join("."));
    }
    return out;
  }

  // Entity candidates for `example.*` matching: each hostname-chain
  // entry with its public-suffix label dropped ("www.youtube.com" →
  // ["www.youtube", "youtube"], matching the `youtube` entity). Without
  // the public suffix list this approximates uBO's entity matching — it
  // covers single-label suffixes (.com/.de/.fr) but not multi-label
  // ones (.co.uk), which are rare among entity rules.
  function entityChain(host) {
    return hostnameChain(host).map((h) => h.replace(/\.[^.]+$/, ""));
  }

  const chain = hostnameChain(location.hostname);
  const entities = entityChain(location.hostname);
  // Whitelist matches the host or any parent domain, so whitelisting
  // "youtube.com" also exempts "www.youtube.com" — same parent walk the
  // cosmetic / declarative layers use (`chain` excludes the bare TLD, so
  // a stray "com" entry can't blanket every site).
  const whitelisted = new Set(whitelist.map((h) => String(h).toLowerCase()));
  if (chain.some((h) => whitelisted.has(h))) return;

  // ---- set-constant -----------------------------------------------------

  // Value tokens accepted by set-constant, per the documented uBO
  // surface. Unknown tokens make the invocation a no-op rather than
  // guessing at semantics.
  function parseValueToken(token) {
    switch (token) {
      case "undefined":
        return { ok: true, value: undefined };
      case "null":
        return { ok: true, value: null };
      case "true":
        return { ok: true, value: true };
      case "false":
        return { ok: true, value: false };
      case "":
      case "''":
        return { ok: true, value: "" };
      case "noopFunc":
        return { ok: true, value: function () {} };
      case "trueFunc":
        return { ok: true, value: function () { return true; } };
      case "falseFunc":
        return { ok: true, value: function () { return false; } };
      case "[]":
      case "emptyArr":
        return { ok: true, value: [] };
      case "{}":
      case "emptyObj":
        return { ok: true, value: {} };
      default: {
        const n = Number(token);
        // uBO caps numeric constants; anything outside the cap is
        // far more likely a typo'd path than an intended constant.
        if (Number.isFinite(n) && Math.abs(n) <= 32767) {
          return { ok: true, value: n };
        }
        return { ok: false, value: undefined };
      }
    }
  }

  // Assignment watchers, composable across multiple rules that share
  // a path prefix (YT pins three leaves under ytInitialPlayerResponse).
  // A naive defineProperty per rule would clobber the previous rule's
  // accessor; the registry funnels every rule through one accessor
  // per (owner, prop) and fans out to all watchers.
  const trapRegistry = new WeakMap();

  function watchAssign(owner, prop, watcher) {
    let propMap = trapRegistry.get(owner);
    if (!propMap) {
      propMap = new Map();
      trapRegistry.set(owner, propMap);
    }
    let entry = propMap.get(prop);
    if (entry) {
      entry.watchers.push(watcher);
      if (entry.current !== undefined) watcher(entry.current);
      return;
    }
    entry = { current: owner[prop], watchers: [watcher] };
    propMap.set(prop, entry);
    try {
      Object.defineProperty(owner, prop, {
        configurable: true,
        get() {
          return entry.current;
        },
        set(v) {
          entry.current = v;
          for (const w of entry.watchers) {
            try {
              w(v);
            } catch (_) {
              // A throwing watcher must not break the page's own
              // assignment, nor starve sibling watchers.
            }
          }
        },
      });
    } catch (_) {
      // Non-configurable property — the page got there first with a
      // sealed descriptor. Nothing to do; the rule silently loses,
      // matching how scriptlet engines degrade on hostile pages.
      return;
    }
    if (entry.current !== undefined) watcher(entry.current);
  }

  function pinLeaf(owner, prop, value) {
    try {
      Object.defineProperty(owner, prop, {
        configurable: true,
        get() {
          return value;
        },
        set() {
          // Swallow writes: the point of set-constant is that the
          // page can never restore the original value.
        },
      });
    } catch (_) {}
  }

  function trapPath(owner, parts, value) {
    const prop = parts[0];
    if (parts.length === 1) {
      pinLeaf(owner, prop, value);
      return;
    }
    const rest = parts.slice(1);
    watchAssign(owner, prop, (v) => {
      if (v !== null && (typeof v === "object" || typeof v === "function")) {
        trapPath(v, rest, value);
      }
    });
  }

  function setConstant(path, valueToken) {
    // A value argument is required. `##+js(set, path)` with no value is
    // a different uBO operation (it dumps the value, it does not pin
    // one), so no-op rather than coercing the missing arg into the
    // string "undefined".
    if (!path || valueToken === undefined) return;
    const parsed = parseValueToken(String(valueToken));
    if (!parsed.ok) return;
    trapPath(window, String(path).split("."), parsed.value);
  }

  // ---- json-prune -------------------------------------------------------

  function splitPaths(raw) {
    return String(raw || "")
      .split(/\s+/)
      .filter(Boolean);
  }

  function hasPath(root, path) {
    let node = root;
    for (const key of path.split(".")) {
      if (node === null || typeof node !== "object" || !(key in node)) {
        return false;
      }
      node = node[key];
    }
    return true;
  }

  function prunePath(root, path) {
    const keys = path.split(".");
    let node = root;
    for (let i = 0; i < keys.length - 1; i++) {
      if (node === null || typeof node !== "object") return;
      node = node[keys[i]];
    }
    if (node !== null && typeof node === "object") {
      delete node[keys[keys.length - 1]];
    }
  }

  function pruneObject(root, paths, required) {
    if (root === null || typeof root !== "object") return;
    if (required.length && !required.every((p) => hasPath(root, p))) return;
    for (const p of paths) prunePath(root, p);
  }

  // Each json-prune rule wraps JSON.parse in its own Proxy; multiple
  // rules on one host stack the wrappers, so every JSON.parse call pays
  // one prune pass per rule. Hosts here carry only a handful of rules,
  // so the layering cost stays negligible; collapsing all paths into a
  // single Proxy would be the move if that ever stops holding.
  function jsonPrune(rawPaths, rawRequired) {
    const paths = splitPaths(rawPaths);
    const required = splitPaths(rawRequired);
    if (!paths.length) return;
    JSON.parse = new Proxy(JSON.parse, {
      apply(target, thisArg, args) {
        const result = Reflect.apply(target, thisArg, args);
        try {
          pruneObject(result, paths, required);
        } catch (_) {
          // Pruning must never turn a parseable payload into a page
          // error; on any miss the original object passes through.
        }
        return result;
      },
    });
  }

  // ---- json-prune-fetch-response / json-prune-xhr-response --------------

  // Trailing `name, value` pairs of the *-response scriptlets (e.g.
  // `propsToMatch, /player`). Only the keys this engine acts on are
  // read; unknown options are ignored rather than rejected so a rule
  // carrying an option we have not implemented still prunes.
  function parseExtraOptions(args) {
    const opts = {};
    for (let i = 0; i + 1 < args.length; i += 2) {
      opts[String(args[i])] = String(args[i + 1]);
    }
    return opts;
  }

  // Build a URL predicate from a `propsToMatch`-style needle: a
  // `/regex/` literal compiles to a RegExp, anything else is a plain
  // substring, and an empty needle matches every request. A bad regex
  // matches nothing so a malformed rule cannot accidentally prune
  // every response on the page.
  //
  // Only the single-URL-needle form is supported. uBO also allows a
  // space-separated `url:… method:…` map; a rule using that form fails
  // to match here (the whole string is searched as a URL substring) and
  // so under-prunes — it leaves ads in, never breaks an unrelated
  // response. The shipped YouTube rules use the single-needle form.
  function urlMatcher(needle) {
    if (!needle) return () => true;
    if (needle.length > 2 && needle[0] === "/" && needle[needle.length - 1] === "/") {
      let re;
      try {
        re = new RegExp(needle.slice(1, -1));
      } catch (_) {
        return () => false;
      }
      return (url) => re.test(url);
    }
    return (url) => url.indexOf(needle) !== -1;
  }

  function jsonPruneFetchResponse(rawPaths, rawRequired, ...extra) {
    const paths = splitPaths(rawPaths);
    const required = splitPaths(rawRequired);
    if (!paths.length) return;
    const matchUrl = urlMatcher(parseExtraOptions(extra).propsToMatch || "");
    const realFetch = window.fetch;
    if (typeof realFetch !== "function") return;
    window.fetch = new Proxy(realFetch, {
      async apply(target, thisArg, args) {
        const response = await Reflect.apply(target, thisArg, args);
        try {
          const url = (response && response.url) || "";
          if (!matchUrl(url)) return response;
          const text = await response.clone().text();
          let data;
          try {
            data = JSON.parse(text);
          } catch (_) {
            // Not JSON (or already consumed) — hand back the
            // untouched response so non-JSON requests are unaffected.
            return response;
          }
          pruneObject(data, paths, required);
          // Content-Length no longer matches the rewritten body; drop
          // it so the consumer reads the pruned payload to completion.
          const headers = new Headers(response.headers);
          headers.delete("content-length");
          return new Response(JSON.stringify(data), {
            status: response.status,
            statusText: response.statusText,
            headers,
          });
        } catch (_) {
          return response;
        }
      },
    });
  }

  // XHR interception is best-effort: only `responseType` of "" or
  // "text" exposes a readable `responseText` to prune. "json"/"blob"
  // responses are left untouched — YouTube's player request uses
  // fetch, which the handler above covers fully. The readystatechange
  // listener is registered inside the patched `send`, so it runs
  // before page listeners added after `send`, and the pruned getters
  // are installed before readyState 4 propagates to them.
  function jsonPruneXhrResponse(rawPaths, rawRequired, ...extra) {
    const paths = splitPaths(rawPaths);
    const required = splitPaths(rawRequired);
    if (!paths.length) return;
    const matchUrl = urlMatcher(parseExtraOptions(extra).propsToMatch || "");
    const XHR = window.XMLHttpRequest;
    if (typeof XHR !== "function") return;
    const realOpen = XHR.prototype.open;
    const realSend = XHR.prototype.send;
    XHR.prototype.open = function (method, url) {
      this.__e05PruneUrl = String(url || "");
      return realOpen.apply(this, arguments);
    };
    XHR.prototype.send = function () {
      const xhr = this;
      if (!matchUrl(xhr.__e05PruneUrl || "")) {
        return realSend.apply(xhr, arguments);
      }
      xhr.addEventListener("readystatechange", function () {
        if (xhr.readyState !== 4 || xhr.__e05Pruned) return;
        const rt = xhr.responseType;
        if (rt !== "" && rt !== "text") return;
        let text;
        try {
          text = xhr.responseText;
        } catch (_) {
          return;
        }
        let data;
        try {
          data = JSON.parse(text);
        } catch (_) {
          return;
        }
        pruneObject(data, paths, required);
        const pruned = JSON.stringify(data);
        xhr.__e05Pruned = true;
        try {
          Object.defineProperty(xhr, "responseText", { get: () => pruned });
          Object.defineProperty(xhr, "response", { get: () => pruned });
        } catch (_) {}
      });
      return realSend.apply(xhr, arguments);
    };
  }

  // ---- dispatch ---------------------------------------------------------

  const registry = {
    "set-constant": setConstant,
    set: setConstant,
    "json-prune": jsonPrune,
    "json-prune-fetch-response": jsonPruneFetchResponse,
    "json-prune-xhr-response": jsonPruneXhrResponse,
  };

  // A rule applies unless the page hostname (or one of its parent
  // domains) is in the rule's negation list.
  function ruleApplies(rule) {
    if (rule.not && rule.not.length) {
      if (rule.not.some((n) => chain.includes(n))) return false;
    }
    return true;
  }

  function runRule(rule) {
    const invocation = rule.a;
    if (!Array.isArray(invocation) || invocation.length === 0) return;
    const fn = registry[invocation[0]];
    if (!fn) return;
    try {
      fn(...invocation.slice(1));
    } catch (_) {
      // One bad invocation must not block the rest of the host's
      // scriptlets.
    }
  }

  function runRules(rules) {
    if (!Array.isArray(rules)) return;
    for (const rule of rules) {
      if (rule && ruleApplies(rule)) runRule(rule);
    }
  }

  const hostRules = index.hosts || {};
  for (const host of chain) runRules(hostRules[host]);
  const entityRules = index.entities || {};
  for (const entity of entities) runRules(entityRules[entity]);
})();
