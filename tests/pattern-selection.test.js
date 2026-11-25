// Exercise the actual MQL decision tree with simulated pattern detectors.
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

function extract(source, name) {
  const start = source.search(new RegExp("\\bbool " + name + "\\("));
  assert(start >= 0, name + " missing");
  const open = source.indexOf("{", start);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === "{") depth++;
    if (source[end] === "}") depth--;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}

for (const path of [
  "MQL5/Indicators/Forex/silentwolfforex.mq5",
  "MQL5/Indicators/SyntheticIndices/silentwolfindices.mq5",
]) {
  const source = fs.readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  assert(!/\bInpFallbackToSinglePin\b|\bInpEnableUnclassifiedFusion\b|\bInpEnableInsideBar\b|\bInpInsideBarUseForExit\b|\bInpInsideBarRequireFusedPin\b/.test(source));
  let code = extract(source, "FindConfirmedSignal");
  const substitutions = [
    [/bool FindConfirmedSignal\([\s\S]*?\)\n\{/, "function FindConfirmedSignal(confirmationIndex, rates_total, time, open, high, low, close, requireZone, applyStopCheck, allowInsideBar, direction, signalPatternIndex, patternLength, patternName, stopPrice)\n{"],
    [/FindPattern\(patternIndex, rates_total, open, high, low,\s*close, allowInsideBar,\s*direction, patternLength, patternName\)/, '((direction = 1, patternLength = 2, patternName = "merged"), cfg.merged)'],
    [/FindPatternSwingDirection\(patternIndex, patternLength, rates_total,\s*high, low, patternSwingDirection\)/, "((patternSwingDirection = 1), cfg.swingOk)"],
    [/FindSinglePinBar\(patternIndex, rates_total, open, high, low, close,\s*direction, patternName\)/, '((direction = 1, patternName = "single"), cfg.single)'],
    [/FindPattern\(patternIndex, rates_total, open, high, low, close, true,\s*recognizedDirection, recognizedLength, recognizedName\)/, "cfg.recognized"],
    [/FindPatternSwingDirection\(patternIndex, patternLength, rates_total,\s*high, low, direction\)/, "((direction = 1), cfg.swingOk)"],
    [/IsConfirmedSignalCandidate\(confirmationIndex, rates_total, time,\s*open, high, low, close, requireZone,\s*applyStopCheck, patternIndex,\s*patternLength,\s*direction, patternName,\s*(?:fusedShape|pinShape|unclassifiedShape), stopPrice\)/g, "candidate(patternName, patternLength)"],
  ];
  for (const [pattern, replacement] of substitutions) {
    assert(pattern.test(code), `substitution missing: ${pattern}`);
    code = code.replace(pattern, replacement);
  }
  code = code.replace(/\b(?:bool|int|string|double)\s+/g, "let ");
  const context = {
    EMPTY_VALUE: Infinity, REJECT_SWING: 1, CandidateRejection: 0,
    CandidatePatternFound: false, cfg: {}, calls: [],
    IsInsideBarName: name => name.startsWith("Inside bar"),
    IsInsideBar: () => context.cfg.inside,
    candidate: (name, length) => {
      context.calls.push([name, length]);
      return context.cfg.accepted.includes(name);
    },
  };
  vm.createContext(context);
  vm.runInContext(code, context);
  const run = (cfg, entry = true, count = 10) => {
    context.cfg = { merged: false, single: false, recognized: false, inside: false,
      swingOk: true, accepted: [], ...cfg };
    context.calls = [];
    context.CandidatePatternFound = false;
    const high = context.cfg.inside ? [0, 0, 9, 10] : [0, 0, 10, 9];
    const low = context.cfg.inside ? [0, 0, 2, 0] : [0, 0, 0, 2];
    return context.FindConfirmedSignal(1, count, [], [], high, low, [], true,
      entry, entry, 0, 0, 0, "", 0);
  };
  assert.equal(run({ merged: true, accepted: ["merged"] }), true);
  assert.deepEqual(context.calls, [["merged", 2]]);
  assert.equal(run({ merged: true, single: true, accepted: ["single"] }), true);
  assert.deepEqual(context.calls, [["merged", 2], ["single", 1]]);
  assert.equal(run({ accepted: ["Fusion sans pattern"] }), true);
  assert.deepEqual(context.calls, [["Fusion sans pattern", 2]]);
  assert.equal(run({ recognized: true, accepted: ["Fusion sans pattern"] }), false);
  assert.equal(run({ accepted: ["Fusion sans pattern"] }, false), false);
  assert.equal(run({ accepted: ["Fusion sans pattern"] }, true, 3), false);
  assert.equal(run({ inside: true, merged: true, single: true,
    accepted: ["merged", "single"] }, false), false);
  assert.deepEqual(context.calls, []);
  assert.equal(run({ inside: true, merged: true, accepted: ["merged"] }), true);
  assert.deepEqual(context.calls, [["merged", 2]]);
  assert.equal(run({ inside: true, merged: true, single: true, accepted: ["single"] }), false);
  assert.deepEqual(context.calls, [["merged", 2]]);

  let patternCode = extract(source, "FindPattern")
    .replace(/bool FindPattern\([\s\S]*?\)\n\{/,
      "function FindPattern(i, rates_total, open, high, low, close, allowInsideBar, direction, patternLength, patternName)\n{");
  vm.runInNewContext(patternCode + `
    if (!FindPattern(1, 3, [], [], [], [], true, 0, 0, "")) throw new Error("inside bar not recognized");
  `, {
    IsInsideBar: () => true,
    IsHaramiCross: () => { throw new Error("inside bar must take priority over harami"); },
  });

  let pinCode = extract(source, "IsConfirmedPinBar")
    .replace(/bool IsConfirmedPinBar\([\s\S]*?\)\n\{/,
      "function IsConfirmedPinBar(i, patternLength, direction, pinShape, open, high, low, close)\n{")
    .replace("PatternExtremes(i, first, high, low, fusedHigh, fusedLow);",
      "fusedHigh = Math.max(...high.slice(i, first + 1)); fusedLow = Math.min(...low.slice(i, first + 1));")
    .replace(/\b(?:bool|int|string|double)\s+/g, "let ");
  assert(!pinCode.includes("PatternExtremes("));
  Object.assign(context, {
    InpAllowZeroBody: false, InpWickBodyRatio: 2,
    MathAbs: Math.abs, MathMin: Math.min, MathMax: Math.max,
    PassesWickGeometry: () => true,
  });
  vm.runInContext(pinCode, context);
  assert.equal(context.IsConfirmedPinBar(1, 2, 1, "",
    [0, 9.5, 9.6], [0, 9.8, 10], [0, 2, 0], [0, 9.5, 9.8]), true);
  assert.equal(context.IsConfirmedPinBar(1, 2, -1, "",
    [0, 0.5, 0.4], [0, 8, 10], [0, 0.2, 0], [0, 0.5, 0.2]), true);
  assert.equal(context.IsConfirmedPinBar(1, 2, 1, "",
    [0, 5, 5], [0, 8, 10], [0, 2, 0], [0, 6, 8]), false);
  const candidateCode = extract(source, "IsConfirmedSignalCandidate");
  assert.match(candidateCode, /if\s*\(\s*!IsConfirmedPinBar\(/);
  assert(!candidateCode.includes("IsInsideBarName("));
  console.log(path + ": pattern selection cases passed");
}
