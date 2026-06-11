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

  // Mirror the Swift side's `parentHostnames`: walk from the full
  // hostname up toward the registrable domain, never yielding a bare
  // TLD ("a.b.com" → ["a.b.com", "b.com"]).
  function hostnameChain(host) {
    const parts = String(host).toLowerCase().split(".");
    const out = [];
    for (let i = 0; i < parts.length - 1; i++) {
      out.push(parts.slice(i).join("."));
    }
    return out;
  }

  const chain = hostnameChain(location.hostname);
  // Whitelist on the full host only, matching the cosmetic and
  // declarative layers (host keys are full hosts, not eTLD+1). A
  // parent-domain walk here would suppress scriptlets on a subdomain
  // the user never whitelisted, diverging from those layers.
  const whitelisted = new Set(whitelist.map((h) => String(h).toLowerCase()));
  if (whitelisted.has(location.hostname.toLowerCase())) return;

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

  // ---- dispatch ---------------------------------------------------------

  const registry = {
    "set-constant": setConstant,
    set: setConstant,
    "json-prune": jsonPrune,
  };

  for (const host of chain) {
    const invocations = index[host];
    if (!Array.isArray(invocations)) continue;
    for (const invocation of invocations) {
      if (!Array.isArray(invocation) || invocation.length === 0) continue;
      const fn = registry[invocation[0]];
      if (!fn) continue;
      try {
        fn(...invocation.slice(1));
      } catch (_) {
        // One bad invocation must not block the rest of the host's
        // scriptlets.
      }
    }
  }
})();
