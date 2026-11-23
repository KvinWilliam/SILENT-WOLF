// Exercise the shared, self-contained MQL expressions without a running terminal.
// MetaEditor compilation is still required to validate the complete indicators.
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const paths = [
  "MQL5/Indicators/Forex/silentwolfforex.mq5",
  "MQL5/Indicators/SyntheticIndices/silentwolfindices.mq5",
];

function extract(source, name) {
  const start = source.search(new RegExp("\\b(?:string|bool|int) " + name + "\\("));
  assert(start >= 0, name + " missing");
  const open = source.indexOf("{", start);
  let depth = 1;
  let end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === "{") depth++;
    if (source[end] === "}") depth--;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}

function translate(code) {
  return code
    .replace(/\b(?:string|bool|int)\s+(\w+)\(([^)]*)\)/,
      (_, name, args) => "function " + name + "(" +
        args.replace(/\bconst\s+/g, "")
          .replace(/\b(?:int|double|string|datetime)\s*&?\s*/g, "")
          .replace(/\[\]/g, "") + ")")
    .replace(/\b(?:bool|string|int|double)\s+/g, "let ")
    .replace(/TargetPrice\(entry, stop, direction, adr, 1, tp1\)/g,
      "((tp1 = target1), target1 !== null)")
    .replace(/TargetPrice\(entry, stop, direction, adr, 2, tp2\)/g,
      "((tp2 = target2), target2 !== null)")
    .replace(/FindConfirmedSignal\(bar,[\s\S]*?patternName, stop\)/,
      "((exitDirection = exits[bar] || 0), exitDirection !== 0)");
}

let baseline;
for (const path of paths) {
  const source = fs.readFileSync(path, "utf8");
  const bodies = ["SignalStatus", "SignalIsActive", "SwInterpretation",
    "HasOppositeExit", "TableFieldForRow"].map(name => extract(source, name));
  if (baseline) assert.deepEqual(bodies, baseline);
  else baseline = bodies;

  const context = {
    EMPTY_VALUE: Infinity,
    StringFind: (text, part) => text.indexOf(part),
    MathIsValidNumber: Number.isFinite,
    EffectiveMaxSignalAgeBars: () => context.maxAge,
    maxAge: 6,
    target1: 110,
    target2: 130,
    exits: {},
  };
  vm.createContext(context);
  vm.runInContext(bodies.map(translate).join("\n"), context);

  const interpretation = context.SwInterpretation;
  assert.equal(interpretation(0, "HAUSS.", "HAUSS."), "--");
  assert.equal(interpretation(1, "HAUSS.", "AUCUNE"), "CONCORDANTE");
  assert.equal(interpretation(-1, "HAUSS.", "AUCUNE"), "OPPOSEE");
  assert.equal(interpretation(-1, "BAISS.", "AUCUNE"), "CONCORDANTE");
  assert.equal(interpretation(1, "HAUSS.", "BAISS."), "MIXTE");
  assert.equal(interpretation(1, "HAUSS.+BAISS.", "AUCUNE"), "MIXTE");
  assert.equal(interpretation(1, "AUCUNE", "AUCUNE"), "AUCUNE");
  assert.equal(interpretation(1, "n/d", "AUCUNE"), "n/d");
  assert.equal(interpretation(1, "HAUSS.", "n/d"), "CONCORDANTE (partiel)");
  assert.equal(interpretation(-1, "HAUSS. (partiel)", "AUCUNE"), "OPPOSEE (partiel)");
  assert.equal(interpretation(1, "HAUSS. (partiel)", "BAISS."), "MIXTE (partiel)");

  const status = (high, low, index = 1) =>
    context.SignalStatus(index, 1, 100, 90, 10, high, low);
  assert.equal(status([105], [95]), "ACTIF");
  assert.equal(status([110], [95]), "TP1 ATTEINT");
  assert.equal(status([130], [95]), "TP2 ATTEINT");
  assert.equal(status([105], [90]), "STOP TOUCHÉ");
  assert.equal(status([130], [90]), "ORDRE INTRABAR INCONNU");
  assert.equal(context.SignalIsActive("TP1 ATTEINT"), true);
  assert.equal(context.SignalIsActive("ORDRE INTRABAR INCONNU"), false);
  context.target1 = context.target2 = null;
  assert.equal(status([105], [95]), "ACTIF (TP n/d)");
  assert.equal(context.SignalIsActive(status([105], [95])), true);
  context.target1 = 110;
  context.target2 = 130;
  context.maxAge = 1;
  assert.equal(status([105, 105], [95, 95], 2), "ACTIF");
  assert.equal(status([105, 105, 105], [95, 95, 95], 3), "PÉRIMÉ");
  context.target1 = 90;
  context.target2 = 70;
  assert.equal(context.SignalStatus(1, -1, 100, 110, 10, [105], [90]), "TP1 ATTEINT");
  assert.equal(context.SignalStatus(1, -1, 100, 110, 10, [110], [70]), "ORDRE INTRABAR INCONNU");

  context.exits = { 2: 1 };
  assert.equal(context.HasOppositeExit(4, 1), false);
  context.exits = { 2: -1 };
  assert.equal(context.HasOppositeExit(4, 1), true);
  assert.equal(context.HasOppositeExit(2, 1), false);

  assert.deepEqual(Array.from({ length: 12 }, (_, i) => context.TableFieldForRow(i + 1)),
    [0, 1, 2, 11, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.equal((source.match(/BullishBuffer\[latestSignalIndex\] =/g) || []).length, 1);
  assert.equal((source.match(/BearishBuffer\[latestSignalIndex\] =/g) || []).length, 1);
  assert(!/SwStats|SwSweep|SwAction|TAUX DE REUSSITE|SWEEP DU JOUR|ACTIONS/.test(source));
  console.log(path + ": signal and interpretation cases passed");
}
