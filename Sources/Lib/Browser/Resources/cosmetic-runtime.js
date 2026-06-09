// Cosmetic filter content-script runtime for e05.
// Independent reimplementation of uBlock Origin / AdGuard procedural
// selector semantics — no code is lifted from their repositories.
// Bundled at build time via Package.swift `resources:` and loaded
// through Bundle.module by CosmeticFilterEngine.swift.

(() => {
  if (window.__e05AdblockCosmetic) return;
  window.__e05AdblockCosmetic = true;

  const handler = window.webkit
    && window.webkit.messageHandlers
    && window.webkit.messageHandlers.e05cosmetic;
  if (!handler) return;

  const MAX_BATCH_SELECTORS = 4096;
  const seenClasses = new Set();
  const seenIds = new Set();
  const pendingClasses = new Set();
  const pendingIds = new Set();
  let flushScheduled = false;
  let injectedCount = 0;
  let injectedSheetCount = 0;
  let flushCount = 0;

  // Procedural runtime state. Everything is lazily initialised so
  // pages that receive zero procedural rules pay nothing beyond the
  // declaration cost of these bindings.
  const PROC_HIDDEN_CLASS = "e05-proc-hidden";
  const PROC_PER_RUN_LIMIT_MS = 200;     // soft ceiling per selector per pass
  const PROC_TOTAL_BUDGET_MS = 500;      // cumulative budget before disable
  const PROC_RECOVERY_INTERVAL_MS = 2000;
  const PROC_RECOVERY_AMOUNT_MS = 50;
  const PROC_MAX_CLIMB_DEPTH = 256;      // cap for `:upward(N)` numeric arg
  // Defensive caps against filterlist authors writing pathological
  // `:has-text(/.../)` patterns (e.g. nested quantifiers that
  // trigger catastrophic backtracking). The regex engine is not
  // sandboxed, and filter text comes from third-party maintainers,
  // so a single bad rule without these caps can freeze the UI.
  const PROC_PATTERN_MAX_LENGTH = 200;   // source length cap for `/regex/flags`
  const PROC_TEXT_SCAN_LIMIT = 10_000;   // max chars fed to the text matcher
  const proceduralFilters = [];          // array of parsed PSelector objects
  const proceduralBudgets = new Map();   // raw selector → {totalMs, disabled}
  const proceduralSeenBodies = new Set();// raw body strings already processed
  let proceduralEvalScheduled = false;
  let proceduralHiddenCount = 0;
  let proceduralRecoveryStarted = false;
  let proceduralStyleSheetInstalled = false;
  let proceduralPassCount = 0;

  function sendLog(level, message) {
    // Diagnostic channel — the Swift side routes this into os.Logger
    // so `log stream` shows a single interleaved timeline for both
    // sides of the IPC. The reply is discarded.
    try {
      handler.postMessage({ type: "log", level: level, message: message });
    } catch (_) { /* drop */ }
  }

  function injectCSS(selectors) {
    if (!selectors || selectors.length === 0) return;
    const unique = Array.from(new Set(selectors));
    // One sheet per injection; `adoptedStyleSheets` is append-only
    // in practice so an errant sheet does not invalidate siblings.
    const sheet = new CSSStyleSheet();
    const rule = unique.join(",") + "{display:none !important;}";
    try {
      sheet.replaceSync(rule);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      injectedCount += unique.length;
      injectedSheetCount += 1;
    } catch (e) {
      // A single invalid selector poisons the whole declaration —
      // fall back to per-selector sheets so the valid majority
      // still lands.
      let ok = 0;
      let fail = 0;
      for (const sel of unique) {
        try {
          const s = new CSSStyleSheet();
          s.replaceSync(sel + "{display:none !important;}");
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, s];
          ok += 1;
        } catch (_) { fail += 1; }
      }
      injectedCount += ok;
      injectedSheetCount += ok;
      sendLog("warn", `injectCSS bulk-rule failed, per-selector fallback ok=${ok} fail=${fail}`);
    }
  }

  // --- Procedural runtime ----------------------------------------

  // Supported procedural operator names. Looked up by direct string
  // comparison while scanning selector bodies; adding a new operator
  // is a two-step change (extend this list + implement the branch
  // in applyOperator).
  // Single source of truth for procedural operator dispatch.
  // Function declarations below are hoisted, so referencing them
  // here at the top of the IIFE is safe. Adding a new operator is
  // one entry here; `PROC_KNOWN_OPS` and `applyOperator` both
  // read from this table, so there is no chance of the parser
  // accepting a name the evaluator silently ignores.
  const PROC_OP_HANDLERS = {
    "has-text":        applyHasText,       // text matching (literal + regex)
    "contains":        applyHasText,       // alias of has-text
    "upward":          applyUpward,        // ancestor climb (numeric or selector)
    "nth-ancestor":    applyNthAncestor,   // numeric-only ancestor climb
    "matches-attr":    applyMatchesAttr,   // attribute name/value filter
    "matches-css":     applyMatchesCss,    // computed style filter
    "xpath":           applyXpath,         // XPath snapshot (replaces candidate set)
    "min-text-length": applyMinTextLength, // textContent length threshold
  };
  // `remove` is a terminal action resolved in `evalProcedural`
  // rather than a filter — it gets recognised by the parser but
  // is intentionally absent from the handler table.
  const PROC_KNOWN_OPS = Object.keys(PROC_OP_HANDLERS).concat(["remove"]);

  function installProceduralStyleSheet() {
    if (proceduralStyleSheetInstalled) return;
    proceduralStyleSheetInstalled = true;
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync("." + PROC_HIDDEN_CLASS + "{display:none !important;}");
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    } catch (e) {
      sendLog("error", `procedural stylesheet install failed: ${String(e)}`);
    }
  }

  function ensureProceduralRecovery() {
    if (proceduralRecoveryStarted) return;
    proceduralRecoveryStarted = true;
    // Every PROC_RECOVERY_INTERVAL_MS we credit each active budget
    // back by PROC_RECOVERY_AMOUNT_MS, so selectors that are
    // occasionally slow recover naturally. Disabled selectors stay
    // disabled — re-enabling after a hard trip would fight the
    // script that caused them to trip in the first place.
    setInterval(() => {
      for (const b of proceduralBudgets.values()) {
        if (b.disabled) continue;
        b.totalMs = Math.max(0, b.totalMs - PROC_RECOVERY_AMOUNT_MS);
      }
    }, PROC_RECOVERY_INTERVAL_MS);
  }

  // Parse a procedural selector body (the text after `#?#`) into a
  // { plain, ops, raw } record. `plain` is a standard CSS selector
  // suitable for querySelectorAll; `ops` is the ordered list of
  // procedural operators to filter those candidates through.
  // Returns null on structural failure (unbalanced parens etc.).
  function parseProcedural(raw) {
    const len = raw.length;
    let inBracket = 0;  // track [...] so a `:` inside attribute selectors is ignored
    let opStart = -1;
    for (let i = 0; i < len; i++) {
      const c = raw[i];
      if (c === "[") { inBracket++; continue; }
      if (c === "]") { inBracket--; continue; }
      if (inBracket !== 0 || c !== ":") continue;
      for (const name of PROC_KNOWN_OPS) {
        if (raw.substr(i + 1, name.length) === name && raw[i + 1 + name.length] === "(") {
          opStart = i;
          break;
        }
      }
      if (opStart >= 0) break;
    }
    if (opStart < 0) {
      // No procedural op present — caller should not reach this path
      // for such rules, but return a record that makes evalProcedural
      // a safe no-op.
      return { plain: raw.trim() || "*", ops: [], raw };
    }
    const plain = raw.slice(0, opStart).trim() || "*";
    const ops = [];
    let pos = opStart;
    while (pos < len) {
      if (raw[pos] !== ":") break;
      let foundOp = null;
      for (const name of PROC_KNOWN_OPS) {
        if (raw.substr(pos + 1, name.length) === name && raw[pos + 1 + name.length] === "(") {
          foundOp = name;
          break;
        }
      }
      if (!foundOp) return null;
      const argStart = pos + 1 + foundOp.length + 1;  // past "("
      let depth = 1;
      let cursor = argStart;
      while (cursor < len && depth > 0) {
        const ch = raw[cursor];
        if (ch === "(") depth++;
        else if (ch === ")") depth--;
        if (depth > 0) cursor++;
      }
      if (depth !== 0) return null;  // unbalanced
      ops.push({ kind: foundOp, arg: raw.slice(argStart, cursor) });
      pos = cursor + 1;
    }
    return { plain, ops, raw };
  }

  // Build a predicate for the argument to `:has-text()` /
  // `:contains()`. Accepts either a literal substring (case-
  // sensitive, matching uBO / AdGuard default) or the `/pattern/flags`
  // regex form. Returns null if the regex fails to compile, if the
  // argument is empty (a literal empty-string match would hide
  // every candidate), or if the regex source exceeds the length cap.
  function compileTextMatcher(arg) {
    const trimmed = arg.trim();
    if (trimmed.length === 0) return null;
    if (trimmed.length >= 2 && trimmed[0] === "/") {
      const lastSlash = trimmed.lastIndexOf("/");
      if (lastSlash > 0) {
        const pattern = trimmed.slice(1, lastSlash);
        const flags = trimmed.slice(lastSlash + 1);
        if (pattern.length > PROC_PATTERN_MAX_LENGTH) return null;
        try {
          const re = new RegExp(pattern, flags);
          return (text) => re.test(text);
        } catch (_) { return null; }
      }
    }
    return (text) => text.indexOf(trimmed) >= 0;
  }

  function applyHasText(candidates, arg) {
    const matcher = compileTextMatcher(arg);
    if (!matcher) return [];
    const out = [];
    for (const el of candidates) {
      // textContent includes descendants, which matches the uBO
      // behaviour: a label buried inside a child element still
      // qualifies the ancestor for the match. Slice at a hard cap
      // so a gigantic article page does not feed a MB-scale string
      // through a regex engine that cannot be interrupted.
      const full = el.textContent || "";
      const text = full.length > PROC_TEXT_SCAN_LIMIT
        ? full.slice(0, PROC_TEXT_SCAN_LIMIT)
        : full;
      if (matcher(text)) out.push(el);
    }
    return out;
  }

  function applyUpward(candidates, arg) {
    const trimmed = arg.trim();
    const asNum = parseInt(trimmed, 10);
    if (!isNaN(asNum) && String(asNum) === trimmed) {
      // uBO treats `:upward(0)` as self (noop); we return empty
      // because 0 has never been observed in shipped filterlists
      // and emptying is the safer default for an author typo.
      if (asNum < 1 || asNum > PROC_MAX_CLIMB_DEPTH) return [];
      const out = [];
      for (const el of candidates) {
        let cur = el;
        for (let k = 0; k < asNum && cur; k++) cur = cur.parentElement;
        if (cur) out.push(cur);
      }
      return out;
    }
    // Selector form: climb from the *parent* so we do not match the
    // candidate itself — :upward(X) is "nearest ancestor matching X",
    // not "self or ancestor".
    const out = [];
    for (const el of candidates) {
      const parent = el.parentElement;
      const hit = parent ? parent.closest(trimmed) : null;
      if (hit) out.push(hit);
    }
    return out;
  }

  function applyNthAncestor(candidates, arg) {
    // Numeric-only variant of `:upward(N)` — filter authors use
    // it when they mean "go up exactly N" and want the selector
    // form (`:upward(selector)`) disabled. Reject non-integer
    // arguments rather than silently accepting them.
    const trimmed = arg.trim();
    const asNum = parseInt(trimmed, 10);
    if (isNaN(asNum) || String(asNum) !== trimmed) return [];
    if (asNum < 1 || asNum > PROC_MAX_CLIMB_DEPTH) return [];
    const out = [];
    for (const el of candidates) {
      let cur = el;
      for (let k = 0; k < asNum && cur; k++) cur = cur.parentElement;
      if (cur) out.push(cur);
    }
    return out;
  }

  function applyMinTextLength(candidates, arg) {
    const n = parseInt(arg.trim(), 10);
    if (isNaN(n) || n < 0) return [];
    const out = [];
    for (const el of candidates) {
      if ((el.textContent || "").length >= n) out.push(el);
    }
    return out;
  }

  // Compile a string predicate used for `:matches-attr` name or
  // value matching, and for `:matches-css` value matching. Three
  // input shapes are accepted, checked in this order so a quoted
  // literal that happens to contain slashes is not misread as a
  // regex pattern:
  //
  //   "foo" / 'foo'       → literal (quotes stripped)
  //   /pattern/flags      → compiled RegExp
  //   foo                 → literal
  //
  // `substring` picks the matcher semantic for the literal paths:
  // true → substring test (value side), false → exact equality
  // (name side). Returns null if the input is empty or if regex
  // compilation fails.
  function compileProcMatcher(spec, substring) {
    const trimmed = spec.trim();
    if (trimmed.length === 0) return null;
    if (trimmed.length >= 2) {
      const first = trimmed[0];
      const last = trimmed[trimmed.length - 1];
      if ((first === "\"" || first === "'") && first === last) {
        const literal = trimmed.slice(1, -1);
        return substring
          ? (text) => (text || "").indexOf(literal) >= 0
          : (text) => (text || "") === literal;
      }
    }
    if (trimmed.length >= 2 && trimmed[0] === "/") {
      const lastSlash = trimmed.lastIndexOf("/");
      if (lastSlash > 0) {
        const pattern = trimmed.slice(1, lastSlash);
        const flags = trimmed.slice(lastSlash + 1);
        if (pattern.length > PROC_PATTERN_MAX_LENGTH) return null;
        try {
          const re = new RegExp(pattern, flags);
          return (text) => re.test(text || "");
        } catch (_) { return null; }
      }
    }
    return substring
      ? (text) => (text || "").indexOf(trimmed) >= 0
      : (text) => (text || "") === trimmed;
  }

  // Parse the `:matches-attr(...)` argument into name and value
  // predicates. Splits on the first top-level `=` that is not
  // inside a quoted string or `/regex/` literal — the same syntax
  // uBO / AdGuard accept.
  function parseAttrSpec(arg) {
    const trimmed = arg.trim();
    if (trimmed.length === 0) return null;
    let inStr = null;
    let inRegex = false;
    let prev = "";
    let eqPos = -1;
    for (let i = 0; i < trimmed.length; i++) {
      const c = trimmed[i];
      if (inStr) {
        if (c === inStr && prev !== "\\") inStr = null;
      } else if (inRegex) {
        if (c === "/" && prev !== "\\") inRegex = false;
      } else if (c === "\"" || c === "'") {
        inStr = c;
      } else if (c === "/") {
        inRegex = true;
      } else if (c === "=") {
        eqPos = i;
        break;
      }
      prev = c;
    }
    const namePart = eqPos < 0 ? trimmed : trimmed.slice(0, eqPos).trim();
    const valuePart = eqPos < 0 ? null : trimmed.slice(eqPos + 1).trim();
    // Attribute names are well-defined, so literal name match is
    // exact equality; attribute values can be substring-matched
    // which is what filter authors normally want ("title contains
    // 'Sponsored'" etc.).
    const nameMatcher = compileProcMatcher(namePart, false);
    if (!nameMatcher) return null;
    let valueMatcher = null;
    if (valuePart !== null) {
      valueMatcher = compileProcMatcher(valuePart, true);
      if (!valueMatcher) return null;
    }
    return { nameMatcher, valueMatcher };
  }

  function applyMatchesAttr(candidates, arg) {
    const parsed = parseAttrSpec(arg);
    if (!parsed) return [];
    const out = [];
    for (const el of candidates) {
      const attrs = el.attributes;
      if (!attrs || !attrs.length) continue;
      let hit = false;
      for (let i = 0; i < attrs.length; i++) {
        const a = attrs[i];
        if (!parsed.nameMatcher(a.name)) continue;
        if (parsed.valueMatcher && !parsed.valueMatcher(a.value)) continue;
        hit = true;
        break;
      }
      if (hit) out.push(el);
    }
    return out;
  }

  function applyMatchesCss(candidates, arg) {
    const trimmed = arg.trim();
    const colon = trimmed.indexOf(":");
    if (colon < 0) return [];
    const prop = trimmed.slice(0, colon).trim();
    const valSpec = trimmed.slice(colon + 1).trim();
    if (!prop || !valSpec) return [];
    const matcher = compileProcMatcher(valSpec, true);
    if (!matcher) return [];
    const out = [];
    for (const el of candidates) {
      let value = "";
      try { value = getComputedStyle(el).getPropertyValue(prop); } catch (_) {}
      if (matcher(value)) out.push(el);
    }
    return out;
  }

  function applyXpath(candidates, arg) {
    // XPath context is the document rather than each candidate —
    // uBO and AdGuard both discard the incoming candidate set
    // because filter authors write `*:xpath(//...)` expecting a
    // fresh document-wide match.
    const expr = arg.trim();
    if (!expr) return [];
    const out = [];
    const seen = new Set();
    try {
      const snap = document.evaluate(
        expr,
        document,
        null,
        XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
        null
      );
      for (let i = 0; i < snap.snapshotLength; i++) {
        const node = snap.snapshotItem(i);
        if (node && node.nodeType === 1 && !seen.has(node)) {
          seen.add(node);
          out.push(node);
        }
      }
    } catch (_) { /* invalid xpath — drop */ }
    return out;
  }

  function applyOperator(candidates, op) {
    // `:remove` is a terminal action hoisted by `evalProcedural`
    // into the action flag before this function is reached. Any
    // other unknown opcode returns `undefined` from the table and
    // yields an empty candidate set, dropping the chain.
    const fn = PROC_OP_HANDLERS[op.kind];
    return fn ? fn(candidates, op.arg) : [];
  }

  // Evaluate a parsed procedural filter against the live DOM.
  // Returns { elements: Element[], action: "hide" | "remove" };
  // an empty `elements` means no match this pass and the caller
  // can skip the hide/remove work entirely.
  function evalProcedural(pf) {
    let candidates;
    try {
      candidates = Array.from(document.querySelectorAll(pf.plain || "*"));
    } catch (_) { return { elements: [], action: "hide" }; }
    let action = "hide";
    for (const op of pf.ops) {
      if (op.kind === "remove") {
        // `:remove()` is a terminal action marker, not a filter.
        // Switch mode and let the remaining chain (if any) run —
        // uBO places it at the tail, but being permissive here
        // avoids throwing on an early `:remove()`.
        action = "remove";
        continue;
      }
      candidates = applyOperator(candidates, op);
      if (candidates.length === 0) return { elements: [], action };
    }
    // Dedupe — chained `:upward` on sibling candidates can converge
    // on the same ancestor and we only need to act on it once.
    if (candidates.length > 1) {
      const seen = new Set();
      const unique = [];
      for (const el of candidates) {
        if (seen.has(el)) continue;
        seen.add(el);
        unique.push(el);
      }
      return { elements: unique, action };
    }
    return { elements: candidates, action };
  }

  function execWithBudget(pf, fn) {
    const key = pf.raw;
    let b = proceduralBudgets.get(key);
    if (!b) { b = { totalMs: 0, disabled: false }; proceduralBudgets.set(key, b); }
    if (b.disabled) return 0;
    const start = performance.now();
    let hidden = 0;
    try {
      hidden = fn();
    } catch (e) {
      sendLog("error", `procedural exec threw for '${key}': ${String(e)}`);
    }
    const dt = performance.now() - start;
    b.totalMs += dt;
    if (dt > PROC_PER_RUN_LIMIT_MS) {
      sendLog(
        "warn",
        `procedural slow single-pass: '${key}' ${dt.toFixed(1)}ms ` +
        `(total=${b.totalMs.toFixed(1)}ms)`
      );
    }
    if (b.totalMs > PROC_TOTAL_BUDGET_MS && !b.disabled) {
      b.disabled = true;
      sendLog(
        "warn",
        `procedural selector disabled (budget exhausted): '${key}' ` +
        `totalMs=${b.totalMs.toFixed(1)}ms`
      );
    }
    return hidden;
  }

  function evaluateAllProcedural() {
    if (proceduralFilters.length === 0) return;
    proceduralPassCount += 1;
    let totalHidden = 0;
    let totalRemoved = 0;
    for (const pf of proceduralFilters) {
      execWithBudget(pf, () => {
        const result = evalProcedural(pf);
        let added = 0;
        if (result.action === "remove") {
          for (const el of result.elements) {
            // `el.remove()` is a no-op on an orphaned node; the
            // parent check short-circuits so a previous pass that
            // already removed this element does not inflate the
            // counter.
            if (el.parentNode) {
              el.remove();
              added++;
            }
          }
          totalRemoved += added;
        } else {
          for (const el of result.elements) {
            if (!el.classList.contains(PROC_HIDDEN_CLASS)) {
              el.classList.add(PROC_HIDDEN_CLASS);
              added++;
            }
          }
          totalHidden += added;
        }
        return added;
      });
    }
    if (totalHidden > 0 || totalRemoved > 0) {
      proceduralHiddenCount += totalHidden + totalRemoved;
      sendLog(
        "info",
        `procedural pass#${proceduralPassCount} hid=${totalHidden} removed=${totalRemoved} ` +
        `(cumulative=${proceduralHiddenCount})`
      );
    }
  }

  function scheduleProceduralEval() {
    if (proceduralEvalScheduled) return;
    if (proceduralFilters.length === 0) return;
    proceduralEvalScheduled = true;
    requestAnimationFrame(() => {
      proceduralEvalScheduled = false;
      evaluateAllProcedural();
    });
  }

  function applyProcedural(bodies) {
    if (!bodies || !bodies.length) return;
    installProceduralStyleSheet();
    ensureProceduralRecovery();
    let added = 0;
    let skippedPlain = 0;
    let skippedParse = 0;
    let skippedDup = 0;
    for (const body of bodies) {
      // A filter source may list the same selector under more than
      // one hostname scope — for example in the hostname index
      // under both `example.com` and `sub.example.com` — and the
      // hostname-parent walk then emits it twice. Dedup on the raw
      // body so `proceduralFilters` does not grow duplicates that
      // waste budget on identical `querySelectorAll` work.
      if (proceduralSeenBodies.has(body)) { skippedDup++; continue; }
      proceduralSeenBodies.add(body);
      const parsed = parseProcedural(body);
      if (!parsed) {
        skippedParse++;
        // Slice in the log to keep a pathological filter line
        // from flooding the diagnostic stream.
        sendLog(
          "debug",
          `procedural parse failed: '${body.slice(0, 120)}'`
        );
        continue;
      }
      // A body with no procedural op is a plain CSS selector that
      // the non-procedural pipeline already turned into CSS; drop
      // it here rather than double-hide.
      if (parsed.ops.length === 0) { skippedPlain++; continue; }
      proceduralFilters.push(parsed);
      added++;
    }
    sendLog(
      "info",
      `procedural activated: ${added} rules ` +
      `(total=${proceduralFilters.length}, skipped plain=${skippedPlain} ` +
      `parse=${skippedParse} dup=${skippedDup})`
    );
    if (added > 0) scheduleProceduralEval();
  }

  // Caps at 3 retries with 200/400/800 ms delays, covering the
  // ~800 ms index-build window observed on cold launch. If the
  // engine is still not ready after ~1.4 s the pane gives up — a
  // later navigation on the same pane will try again from scratch.
  const QUERY_HOSTNAME_MAX_RETRIES = 3;

  async function queryHostname(retriesLeft) {
    if (retriesLeft === undefined) retriesLeft = QUERY_HOSTNAME_MAX_RETRIES;
    try {
      const resp = await handler.postMessage({
        type: "queryHostname",
        hostname: location.hostname || ""
      });
      if (!resp) {
        sendLog("warn", "queryHostname reply was null");
        return;
      }
      if (resp.ready === false) {
        if (retriesLeft > 0) {
          const attempt = QUERY_HOSTNAME_MAX_RETRIES - retriesLeft + 1;
          const delay = 200 * Math.pow(2, attempt - 1);
          sendLog(
            "info",
            `queryHostname not-ready, retry#${attempt} in ${delay}ms (remaining=${retriesLeft - 1})`
          );
          setTimeout(() => queryHostname(retriesLeft - 1), delay);
        } else {
          sendLog("warn", "queryHostname gave up waiting for index build");
        }
        return;
      }
      const hide = (resp.hostnameHide && resp.hostnameHide.length) || 0;
      const misc = (resp.misc && resp.misc.length) || 0;
      const proc = (resp.procedural && resp.procedural.length) || 0;
      sendLog(
        "info",
        `queryHostname reply hide=${hide} misc=${misc} procedural=${proc} → injecting`
      );
      const all = [];
      if (resp.hostnameHide) all.push(...resp.hostnameHide);
      if (resp.misc) all.push(...resp.misc);
      injectCSS(all);
      if (resp.procedural) applyProcedural(resp.procedural);
    } catch (e) {
      sendLog("error", `queryHostname threw: ${String(e)}`);
    }
  }

  async function flushClassId() {
    flushScheduled = false;
    if (pendingClasses.size === 0 && pendingIds.size === 0) return;
    const classes = Array.from(pendingClasses);
    const ids = Array.from(pendingIds);
    pendingClasses.clear();
    pendingIds.clear();
    flushCount += 1;
    try {
      const resp = await handler.postMessage({
        type: "queryClassesAndIds",
        hostname: location.hostname || "",
        classes, ids
      });
      const hideLen = (resp && resp.hideSelectors && resp.hideSelectors.length) || 0;
      if (hideLen > 0) {
        const capped = resp.hideSelectors.length > MAX_BATCH_SELECTORS
          ? resp.hideSelectors.slice(0, MAX_BATCH_SELECTORS)
          : resp.hideSelectors;
        injectCSS(capped);
        sendLog(
          "debug",
          `flush#${flushCount} in classes=${classes.length} ids=${ids.length} → inject=${capped.length}`
        );
      }
    } catch (e) {
      sendLog("error", `flushClassId threw: ${String(e)}`);
    }
  }

  function scheduleFlush() {
    if (flushScheduled) return;
    flushScheduled = true;
    // rAF keeps bursts (common on SPA first-paint) collapsed into
    // one IPC per frame; Brave / uBO use the same pacing.
    requestAnimationFrame(flushClassId);
  }

  function harvestNode(node) {
    if (!node || node.nodeType !== 1) return;
    const cl = node.classList;
    if (cl && cl.length) {
      for (let i = 0; i < cl.length; i++) {
        const c = cl[i];
        if (!seenClasses.has(c)) {
          seenClasses.add(c);
          pendingClasses.add(c);
        }
      }
    }
    const id = node.id;
    if (id && !seenIds.has(id)) {
      seenIds.add(id);
      pendingIds.add(id);
    }
  }

  function harvestSubtree(root) {
    if (!root || root.nodeType !== 1) return;
    harvestNode(root);
    // Scope the descent to id/class-bearing elements and skip leaf
    // nodes. `querySelectorAll("*")` materialised the entire subtree on
    // every insertion — catastrophic on churny SPAs (YouTube et al.,
    // which wedged the page) — while `[id],[class]` is engine-indexed
    // and returns only what the surveyor can act on. uBO and Brave both
    // scope their survey to id/class elements for the same reason.
    if (root.firstElementChild && root.querySelectorAll) {
      const all = root.querySelectorAll("[id],[class]");
      for (let i = 0; i < all.length; i++) harvestNode(all[i]);
    }
  }

  // Added element nodes wait here for a time-sliced harvest rather than
  // being walked synchronously inside the observer callback — a single
  // large insertion would otherwise block the page's own main thread.
  let pendingNodes = [];
  let drainScheduled = false;
  const HARVEST_DEADLINE_MS = 4;  // per-drain wall-clock budget (uBO uses 4ms)

  function scheduleDrain() {
    if (drainScheduled) return;
    drainScheduled = true;
    requestAnimationFrame(drainHarvest);
  }

  function drainHarvest() {
    drainScheduled = false;
    if (pendingNodes.length === 0) return;
    const deadline = performance.now() + HARVEST_DEADLINE_MS;
    let i = 0;
    for (; i < pendingNodes.length; i++) {
      harvestSubtree(pendingNodes[i]);
      // Sample the clock every 64 nodes to keep performance.now() off
      // the hot path while still bounding the slice.
      if ((i & 63) === 63 && performance.now() >= deadline) { i++; break; }
    }
    pendingNodes = i >= pendingNodes.length ? [] : pendingNodes.slice(i);
    if (pendingNodes.length) scheduleDrain();  // resume next frame
    scheduleFlush();
    // Procedural rules can match on freshly inserted elements — piggy-
    // back on the same harvest pass rather than observe twice.
    scheduleProceduralEval();
  }

  // High-churn escape hatch. A page that mutates faster than the
  // surveyor can keep up (YouTube, infinite feeds) pins the main thread
  // if every batch triggers work. Past a per-second mutation threshold,
  // stop reacting to individual mutations and sample the document on a
  // fixed interval instead — Brave uses the same observer→polling
  // switch. Once switched, this page stays on polling until the next
  // navigation rebuilds the runtime.
  const CHURN_WINDOW_MS = 1000;
  const CHURN_THRESHOLD = 1000;
  const POLL_INTERVAL_MS = 500;
  let mutationScore = 0;
  let scoreWindowStart = 0;
  let polling = false;

  function noteMutations(count) {
    if (polling) return;
    const now = performance.now();
    if (now - scoreWindowStart > CHURN_WINDOW_MS) {
      mutationScore = 0;
      scoreWindowStart = now;
    }
    mutationScore += count;
    if (mutationScore > CHURN_THRESHOLD) startPolling();
  }

  // Full-document survey shared by the polling timer and the initial
  // switch, so nodes buffered up to the switch are re-harvested at once
  // rather than waiting a full poll interval.
  function pollSurvey() {
    harvestSubtree(document.documentElement);
    scheduleFlush();
    scheduleProceduralEval();
  }

  function startPolling() {
    if (polling) return;
    polling = true;
    observer.disconnect();
    pendingNodes = [];
    sendLog(
      "info",
      `high DOM churn (score=${mutationScore}/${CHURN_WINDOW_MS}ms) — ` +
      `cosmetic survey switched to ${POLL_INTERVAL_MS}ms polling`
    );
    // Survey once synchronously so the nodes discarded above aren't left
    // unstyled until the first interval fires (~500ms of ad exposure).
    pollSurvey();
    setInterval(pollSurvey, POLL_INTERVAL_MS);
  }

  const observer = new MutationObserver((mutations) => {
    let count = 0;
    for (const m of mutations) {
      if (m.type === "childList") {
        for (const node of m.addedNodes) {
          if (node.nodeType === 1) {
            pendingNodes.push(node);
            count++;
          }
        }
      } else if (m.type === "attributes") {
        // Attribute (class/id) changes are cheap to harvest inline.
        harvestNode(m.target);
        count++;
      }
    }
    if (count === 0) return;
    noteMutations(count);
    scheduleDrain();
    scheduleFlush();
    scheduleProceduralEval();
  });

  function boot() {
    if (!document.documentElement) {
      // `atDocumentStart` races the parser: the element can be nil
      // on the very first tick. Yielding once is enough.
      setTimeout(boot, 0);
      return;
    }
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["class", "id"]
    });
    harvestSubtree(document.documentElement);
    sendLog(
      "info",
      `boot hostname='${location.hostname || ""}' url='${(location.href || "").slice(0, 120)}' ` +
      `documentState=${document.readyState} initialHarvest classes=${pendingClasses.size} ids=${pendingIds.size}`
    );
    scheduleFlush();
    queryHostname();

    // Emit a once-off summary 5 s after boot so the user can tell
    // from `log stream` whether the engine produced any effect on
    // this page without opening Web Inspector.
    setTimeout(() => {
      // Count selectors that hit the budget ceiling so the summary
      // line surfaces broken filter authoring without needing to
      // grep the full log.
      let procDisabled = 0;
      for (const b of proceduralBudgets.values()) {
        if (b.disabled) procDisabled++;
      }
      sendLog(
        "info",
        `+5s summary seenClasses=${seenClasses.size} seenIds=${seenIds.size} ` +
        `flushes=${flushCount} injectedSheets=${injectedSheetCount} injectedSelectors=${injectedCount} ` +
        `proceduralRules=${proceduralFilters.length} proceduralPasses=${proceduralPassCount} ` +
        `proceduralHidden=${proceduralHiddenCount} proceduralDisabled=${procDisabled}`
      );
    }, 5000);
  }
  boot();
})();
