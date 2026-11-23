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
  const start = source.search(new RegExp("\\b(?:string|bool|int|void) " + name + "\\("));
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
    .replace(/\b(?:string|bool|int|void)\s+(\w+)\(([^)]*)\)/,
      (_, name, args) => "function " + name + "(" +
        args.replace(/\bconst\s+/g, "")
          .replace(/\b(?:int|double|string|datetime)\s*&?\s*/g, "")
          .replace(/\[\]/g, "") + ")")
    .replace(/\b(?:bool|string|int|double|datetime)\s+/g, "let ")
    .replace(/TargetPrice\(entry, stop, direction, adr, 1, tp1\)/g,
      "((tp1 = target1), target1 !== null)")
    .replace(/TargetPrice\(entry, stop, direction, adr, 2, tp2\)/g,
      "((tp2 = target2), target2 !== null)")
    .replace(/FindConfirmedSignal\(bar,[\s\S]*?patternName, stop\)/,
      "((exitDirection = exits[bar] || 0), exitDirection !== 0)");
}

function runSelection(source, candidates, statuses, previousShift = -1, exits = {}) {
  const start = source.indexOf("   for(int i = oldestSignalIndex; i >= 1; --i)");
  const end = source.indexOf('   if(fullRecalculation)\n      PrintFormat("SilentWolf : patterns=', start);
  assert(start >= 0 && end > start);
  const selection = source.slice(start, end)
    .replace(/bool accepted = FindConfirmedSignal\(i,[\s\S]*?patternName, signalStopPrice\);/,
      `bool accepted = (([direction, patternIndex, patternLength, patternName, signalStopPrice] =
        candidates[i] || [0, 0, 0, "", 0]), !!candidates[i]);`)
    .replace(/\(int\)/g, "")
    .replace(/\b(?:ENUM_INDICATOR_READ|datetime|bool|string|int|double)\s+/g, "let ");
  const context = {
    candidates, statuses, exits, EMPTY_VALUE: Infinity,
    time: Array.from({ length: 20 }, (_, i) => 100 - i),
    open: [], high: [], low: [], close: Array(20).fill(100),
    InpSwingLookbackBars: 1, rates_total: 20, oldestSignalIndex: 4, previousShift,
    previousTime: previousShift < 0 ? 0 : 100 - previousShift,
    previousDirection: 1, previousName: "ancien",
    previousEntry: 100, previousRisk: 1, previousStop: 90,
    ActiveSignalTime: 0, ActiveSignalDirection: 0,
    PositionStateInitialized: true, REJECT_NONE: 0, INDICATOR_READ_PENDING: 1,
    IsConfirmedSwingPivot: () => true, EstimateLoss: () => 1,
    EffectiveMaxSignalAgeBars: () => 1,
    AdrAtSignal: () => 0, ReportDataIssue: () => {},
    SignalStatus: index => statuses[index],
    SignalIsActive: status => status === "ACTIF" || status === "TP1 ATTEINT",
    HasOppositeExit: index => !!exits[index],
  };
  vm.createContext(context);
  vm.runInContext(translate(extract(source, "DisplayedSignalIndex")), context);
  vm.runInContext(`
    let bullishSwingSignalUsed = false, bearishSwingSignalUsed = false;
    let lastBullishSignalTime = 0, lastBearishSignalTime = 0;
    let currentBarEntrySignal = false, currentBarEntryDirection = 0;
    let currentBarEntryName = "", currentBarEntryPatternIndex = -1;
    let trackedSignalFound = false, trackedSignalActive = false;
    let latestActiveTime = 0, latestActiveDirection = 0;
    let latestSignalIndex = -1, LatestSignalTime = 0, LatestSignalDirection = 0;
    let LatestEntry1Price = 0, LatestEntry1Risk = EMPTY_VALUE, LatestStopPrice = EMPTY_VALUE;
    let LatestSignalName = "", LatestSignalAdr = EMPTY_VALUE, LatestSignalStatus = "--";
    let CandidateRejection = 0, CandidatePatternFound = false, fullRecalculation = false;
    ${selection}
    result = { index: latestSignalIndex, time: LatestSignalTime,
               direction: LatestSignalDirection, status: LatestSignalStatus };
  `, context);
  return JSON.parse(JSON.stringify(context.result));
}

let baseline;
for (const path of paths) {
  const source = fs.readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  const bodies = ["SignalStatus", "SignalIsActive", "SwInterpretation",
    "HasOppositeExit", "DisplayedSignalIndex", "TableFieldForRow",
    "TableCellText", "SwRefreshInfo"].map(name => extract(source, name));
  if (baseline) assert.deepEqual(bodies, baseline);
  else baseline = bodies;

  const context = {
    EMPTY_VALUE: Infinity,
    StringFind: (text, part) => text.indexOf(part),
    MathIsValidNumber: Number.isFinite,
    EffectiveMaxSignalAgeBars: () => context.maxAge,
    LatestSignalTime: 0,
    LatestSignalDirection: 0,
    SwCurrentTrend: "n/d",
    SwLatestRsi: "n/d",
    SwLatestDivergence: "n/d",
    SwLatestDiv7: "n/d",
    SwLatestDiv14: "n/d",
    SwVolumePoc: 100,
    SwVolumeVah: 110,
    SwVolumeVal: 90,
    SwVolumeMessage: "n/d (volume reel)",
    TableLabelCellText: () => "LABEL",
    PriceText: value => value === Infinity ? "n/d" : String(value),
    SwTrendAt: shift => shift === 1 ? "HAUSSIERE" : "incorrect",
    iBarShift: () => -1,
    _Symbol: "TEST",
    _Period: 1,
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

  // Keep the previous signal past the rescan window, but replace it when a new one appears.
  assert.equal(context.DisplayedSignalIndex(-1, 20001, 20000), 20001);
  assert.equal(context.DisplayedSignalIndex(1, 20001, 20000), 1);
  assert.equal(context.DisplayedSignalIndex(-1, 100, 20000), -1);
  assert.equal(context.DisplayedSignalIndex(-1, -1, 20000), -1);
  const old = [1, 4, 1, "ancien", 90];
  const recent = [-1, 2, 1, "recent", 110];
  assert.deepEqual(runSelection(source, { 3: old, 1: recent },
    { 3: "ACTIF", 1: "STOP TOUCHÉ" }),
  { index: 1, time: 99, direction: -1, status: "STOP TOUCHÉ" });
  assert.deepEqual(runSelection(source, {}, { 10: "PÉRIMÉ" }, 10),
    { index: 10, time: 90, direction: 1, status: "PÉRIMÉ" });
  assert.deepEqual(runSelection(source, { 1: recent }, { 1: "ACTIF" }, 10),
    { index: 1, time: 99, direction: -1, status: "ACTIF" });
  assert.deepEqual(runSelection(source, { 1: recent }, { 1: "ACTIF" }, -1, { 1: true }),
    { index: 1, time: 99, direction: -1, status: "SORTIE CONTRAIRE" });
  assert.deepEqual(runSelection(source, {}, {}, -1),
    { index: -1, time: 0, direction: 0, status: "--" });
  assert.deepEqual(Array.from({ length: 16 }, (_, i) => context.TableFieldForRow(i + 1)),
    [0, 1, 2, 12, 11, 10, 13, 14, 15, 3, 4, 5, 6, 7, 8, 9]);
  context.SwRefreshInfo();
  assert.equal(context.TableCellText(0, 6, 1), "HAUSSIERE");
  assert.equal(context.TableCellText(0, 7, 1), "100");
  assert.equal(context.TableCellText(0, 8, 1), "110");
  assert.equal(context.TableCellText(0, 9, 1), "90");
  assert.equal(context.TableCellText(0, 1, 1), "--");
  context.SwVolumePoc = context.SwVolumeVah = context.SwVolumeVal = Infinity;
  assert.equal(context.TableCellText(0, 7, 1), "n/d (volume reel)");
  assert.equal(context.TableCellText(0, 8, 1), "n/d");
  assert.equal((source.match(/BullishBuffer\[latestSignalIndex\] =/g) || []).length, 1);
  assert.equal((source.match(/BearishBuffer\[latestSignalIndex\] =/g) || []).length, 1);
  assert(!/SwStats|SwSweep|SwAction|TAUX DE REUSSITE|SWEEP DU JOUR|ACTIONS/.test(source));
  console.log(path + ": signal and interpretation cases passed");
}
