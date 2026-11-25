// Exercise the shared, self-contained MQL expressions without a running terminal.
// MetaEditor compilation is still required to validate the complete indicators.
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const paths = [
  "MQL5/Indicators/Forex/silentwolfforex.mq5",
  "MQL5/Indicators/SyntheticIndices/silentwolfindices.mq5",
];
const robotSource = fs.readFileSync("MQL5/Experts/SWRobots.mq5", "utf8").replace(/\r\n/g, "\n");

function extract(source, name) {
  const start = source.search(new RegExp("\\b(?:string|bool|int|double|void) " + name + "\\("));
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
    .replace(/\b(?:string|bool|int|double|void)\s+(\w+)\(([^)]*)\)/,
      (_, name, args) => "function " + name + "(" +
        args.replace(/\bconst\s+/g, "")
          .replace(/\b(?:int|double|string|datetime)\s*&?\s*/g, "")
          .replace(/\[\]/g, "") + ")")
    .replace(/\b(?:bool|string|int|double|datetime)\s+/g, "let ")
    .replace(/\((?:int|double)\)/g, "")
    .replace(/FindConfirmedSignal\(bar,[\s\S]*?patternName, stop\)/,
      "((exitDirection = exits[bar] || 0), exitDirection !== 0)");
}

function runSelection(source, candidates, statuses, previousShift = -1, exits = {}, hasZones = true,
  oldestSignalIndex = 4, pivot = true) {
  const start = source.indexOf("   for(int i = searchOldestIndex; i >= 1; --i)");
  const end = source.indexOf('   if(fullRecalculation)\n      PrintFormat("SilentWolf : patterns=', start);
  assert(start >= 0 && end > start);
  const selection = source.slice(start, end)
    .replace(/bool accepted = FindConfirmedSignal\(i,[\s\S]*?patternName, signalStopPrice\);/,
      `bool accepted = (([direction, patternIndex, patternLength, patternName, signalStopPrice] =
        candidates[i] || [0, 0, 0, "", 0]), !!candidates[i]);`)
    .replace(/\(int\)/g, "")
    .replace(/ContextTargetsAtSignal\(entry1, stopPrice, direction, time\[i - 1\],\s*candidateTp1, candidateTp2\);/,
      "candidateTp1 = target1; candidateTp2 = target2;")
    .replace(/ContextTargetsAtSignal\(LatestEntry1Price,[\s\S]*?LatestTakeProfit2\);/,
      "LatestTakeProfit1 = target1; LatestTakeProfit2 = target2;")
    .replace(/\(double\)/g, "")
    .replace(/\b(?:ENUM_INDICATOR_READ|datetime|bool|string|int|double)\s+/g, "let ");
  const context = {
    candidates, statuses, exits, EMPTY_VALUE: Infinity, target1: 110, target2: 130,
    ChartZones: hasZones ? [{}] : [], ArraySize: values => values.length,
    time: Array.from({ length: 20 }, (_, i) => 100 - i),
    open: [], high: [], low: [], close: Array(20).fill(100),
    InpSwingLookbackBars: 1, rates_total: 20, oldestSignalIndex, previousShift,
    previousTime: previousShift < 0 ? 0 : 100 - previousShift,
    previousDirection: 1, previousName: "ancien",
    previousEntry: 100, previousRisk: 1, previousStop: 90,
    ActiveSignalTime: 0, ActiveSignalDirection: 0,
    PositionStateInitialized: true, REJECT_NONE: 0, INDICATOR_READ_PENDING: 1,
    IsConfirmedSwingPivot: () => pivot, EstimateLoss: () => 1,
    EffectiveMaxSignalAgeBars: () => 1,
    ReportDataIssue: () => {},
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
    let searchOldestIndex = ChartZones.length ? oldestSignalIndex : 0;
    let LatestEntry1Price = 0, LatestEntry1Risk = EMPTY_VALUE, LatestStopPrice = EMPTY_VALUE;
    let LatestTakeProfit1 = target1, LatestTakeProfit2 = target2;
    let previousTakeProfit1 = target1, previousTakeProfit2 = target2;
    let LatestSignalName = "";
    let LatestSignalStatus = "--";
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
  const bodies = ["SwSupportsSignals", "SwTrendAt", "ContextTargetPrice", "SignalStatus", "SignalIsActive", "SwSignalStrengthScore",
    "HasOppositeExit", "DisplayedSignalIndex", "TableFieldForRow",
    "TableLabelCellText", "TableCellText", "SwRefreshInfo"].map(name => extract(source, name));
  if (baseline) assert.deepEqual(bodies, baseline);
  else baseline = bodies;

  const context = {
    EMPTY_VALUE: Infinity,
    InpRsiOversold: 20,
    InpRsiOverbought: 80,
    _Point: 0.00001,
    _Digits: 5,
    SYMBOL_TRADE_TICK_SIZE: 1,
    tickSize: 0.00001,
    SymbolInfoDouble: () => context.tickSize,
    ReportDataIssue: () => { context.dataIssue = true; },
    MathCeil: Math.ceil,
    MathFloor: Math.floor,
    NormalizeDouble: (value, digits) => Number(value.toFixed(digits)),
    ArraySize: values => values.length,
    MathAbs: Math.abs,
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
    SwLatestSignalStrength: "n/d",
    DoubleToString: (value, digits) => value.toFixed(digits),
    TableLabelCellText: () => "LABEL",
    PriceText: value => value === Infinity ? "n/d" : String(value),
    SwEma: [0, 1, 2],
    emaValues: [3, 2, 1],
    historyBars: 250,
    Bars: () => context.historyBars,
    SwRead: () => true,
    iBarShift: () => -1,
    _Symbol: "TEST",
    _Period: 1,
    PERIOD_M5: 5, PERIOD_M15: 15, PERIOD_M30: 30,
    PERIOD_H1: 60, PERIOD_H4: 240,
    maxAge: 6,
    target1: 110,
    target2: 130,
    exits: {},
  };
  vm.createContext(context);
  vm.runInContext(bodies.map(translate).join("\n"), context);

  for (const period of [5, 15, 30, 60, 240]) {
    context._Period = period;
    assert.equal(context.SwSupportsSignals(), true);
  }
  for (const period of [1, 1440, 10080, 43200]) {
    context._Period = period;
    assert.equal(context.SwSupportsSignals(), false);
  }
  // Test actual monthly trend evaluation with enough and insufficient history.
  context._Period = 43200;
  const trendBody = translate(extract(source, "SwTrendAt"))
    .replace("SwRead(SwEma[0], shift, a)", "(a = emaValues[0], true)")
    .replace("SwRead(SwEma[1], shift, b)", "(b = emaValues[1], true)")
    .replace("SwRead(SwEma[2], shift, c)", "(c = emaValues[2], true)");
  vm.runInContext(trendBody, context);
  assert.equal(context.SwTrendAt(1), "HAUSSIERE");
  context.emaValues = [1, 2, 3];
  assert.equal(context.SwTrendAt(1), "BAISSIERE");
  context.historyBars = 201;
  assert.equal(context.SwTrendAt(1), "n/d");
  context.historyBars = 250;
  context.emaValues = [3, 2, 1];
  context._Period = 1;
  const target = context.ContextTargetPrice;
  assert.equal(target(100, 98, 1, [103, 105, 104, 100, 99, Infinity], 1), 104);
  assert.equal(target(100, 98, 1, [103, 105, 104, 100, 99, Infinity], 2), 105);
  assert.equal(target(100, 102, -1, [103, 95, 101, 100, 96, 97], 1), 96);
  assert.equal(target(100, 102, -1, [103, 95, 101, 100, 96, 97], 2), 95);
  assert.equal(target(100, 98, 1, [104, 104, 103, Infinity], 1), 104);
  assert.equal(target(100, 98, 1, [104, 104, 103, Infinity], 2), Infinity);
  assert.equal(target(100, 98, 1, [103, 99, Infinity], 1), 104);
  assert.equal(target(100, 102, -1, [97, 101, Infinity], 1), 96);
  assert.equal(target(100, 98, 1, [103, 99, Infinity], 2), Infinity);
  assert.equal(target(100, 100, 1, [104], 1), Infinity);
  context.tickSize = 0.1;
  context._Digits = 2;
  assert.equal(target(100.01, 99.96, 1, [], 1), 100.2);
  assert.equal(target(99.99, 100.04, -1, [], 1), 99.8);
  context.tickSize = 0;
  context.dataIssue = false;
  assert.equal(target(100, 98, 1, [], 1), Infinity);
  assert.equal(context.dataIssue, true);
  context.tickSize = 0.00001;
  context._Digits = 5;

  const strength = context.SwSignalStrengthScore;
  assert.equal(strength(1, 20, 10, "HAUSS.", "HAUSS."), 100);
  assert.equal(strength(-1, 80, 90, "BAISS.", "BAISS."), 100);
  assert.equal(strength(1, 19, 21, "AUCUNE", "AUCUNE"), 70);
  assert.equal(strength(1, 21, 21, "HAUSS.", "BAISS."), 55);
  assert.equal(strength(1, 10, 10, "n/d", "BAISS. (partiel)"), 70);
  assert.equal(strength(1, Infinity, 10, "HAUSS.", "HAUSS."), 85);
  assert.equal(strength(0, 10, 10, "HAUSS.", "HAUSS."), 0);

  const status = (high, low, index = 1) =>
    context.SignalStatus(index, 1, 100, 90, context.target1, context.target2, high, low);
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
  assert.equal(status([105], [95]), "ACTIF");
  assert.equal(status([110], [95]), "TP1 ATTEINT (FINAL)");
  context.target1 = 110;
  context.target2 = 130;
  context.maxAge = 1;
  assert.equal(status([105, 105], [95, 95], 2), "ACTIF");
  assert.equal(status([105, 105, 105], [95, 95, 95], 3), "PÉRIMÉ");
  context.target1 = 90;
  context.target2 = 70;
  assert.equal(context.SignalStatus(1, -1, 100, 110, 90, 70, [105], [90]), "TP1 ATTEINT");
  assert.equal(context.SignalStatus(1, -1, 100, 110, 90, 70, [110], [70]), "ORDRE INTRABAR INCONNU");

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
  assert.match(extract(source, "OnCalculate"), /int oldestSignalIndex = rates_total - 2;/);
  const sameSwing = [1, 2, 1, "meme swing", 90];
  assert.equal(runSelection(source, { 8: old, 1: sameSwing },
    { 8: "ACTIF", 1: "ACTIF" }, -1, {}, true, 10, false).index, 8);
  assert.equal(runSelection(source, { 8: old, 1: sameSwing },
    { 8: "ACTIF", 1: "ACTIF" }, -1, {}, true, 4, false).index, 1);
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
  assert.deepEqual(runSelection(source, { 1: recent }, { 1: "ACTIF" }, -1, {}, false),
    { index: -1, time: 0, direction: 0, status: "--" });
  assert.deepEqual(Array.from({ length: 13 }, (_, i) => context.TableFieldForRow(i + 1)),
    [0, 1, 2, 12, 11, 10, 3, 4, 5, 6, 7, 8, 9]);
  context.SwRefreshInfo();
  assert.equal(context.TableLabelCellText(11), "FORCE DU SIGNAL");
  assert.equal(context.SwLatestSignalStrength, "n/d");
  context.LatestSignalTime = 123;
  context.SwLatestSignalStrength = "85%";
  assert.equal(context.TableCellText(0, 5, 1), "85%");
  context.LatestSignalTime = 0;
  assert.equal(context.TableCellText(0, 6, 1), "HAUSSIERE");
  assert.equal(context.TableCellText(0, 1, 1), "--");
  assert(!/VWAP|Vwap|vwap/.test(source));
  assert.equal((source.match(/BullishBuffer\[latestSignalIndex\] =/g) || []).length, 1);
  assert.equal((source.match(/BearishBuffer\[latestSignalIndex\] =/g) || []).length, 1);
  assert(source.includes("#property indicator_buffers 8"));
  assert(source.includes("#property indicator_plots   8"));
  assert.equal((source.match(/SetIndexBuffer\([0-7],/g) || []).length, 8);
  assert(source.includes("SignalEntryBuffer[latestSignalIndex] = LatestEntry1Price;"));
  assert(source.includes("SignalStopBuffer[latestSignalIndex] = LatestStopPrice;"));
  assert(source.includes("SignalTp1Buffer[latestSignalIndex] = LatestTakeProfit1;"));
  assert(source.includes("SignalTp2Buffer[latestSignalIndex] = LatestTakeProfit2;"));
  assert(source.includes("SignalForceBuffer[latestSignalIndex] = SwLatestSignalStrengthValue;"));
  assert(robotSource.includes("const int SW_BUFFER_BUY = 0;"));
  assert(robotSource.includes("const int SW_BUFFER_SELL = 1;"));
  assert(robotSource.includes("const int SW_BUFFER_ENTRY = 2;"));
  assert(robotSource.includes("const int SW_BUFFER_STOP = 3;"));
  assert(robotSource.includes("const int SW_BUFFER_TP1 = 4;"));
  assert(robotSource.includes("const int SW_BUFFER_TP2 = 5;"));
  assert(robotSource.includes("const int SW_BUFFER_FORCE = 6;"));
  assert(robotSource.includes('#property tester_indicator "Silent Wolf Trading\\\\silentwolfforex.ex5"'));
  assert(robotSource.includes('#property tester_indicator "Silent Wolf Trading\\\\silentwolfindices.ex5"'));
  assert(robotSource.includes('input string InpMonitoredTimeframes = "M5,M15,M30,H1,H4";'));
  assert(robotSource.includes("IndicatorCreate(_Symbol, TimeframeStates[stateIndex].timeframe, IND_CUSTOM,"));
  assert(robotSource.includes("bool HasActiveTradeForSymbol()"));
  assert(robotSource.includes("CopyBuffer(handle, buffer, shift, 1, data)"));
  assert(!robotSource.includes("_Period"));
  assert(!/SwStats|SwSweep|SwAction|TAUX DE REUSSITE|SWEEP DU JOUR|ACTIONS/.test(source));
  console.log(path + ": signal and strength cases passed");
}

const orderContext = {
  EMPTY_VALUE: Infinity, _Point: 0.01, _Digits: 2, _Symbol: "TEST",
  InpMinimumSignalForce: 55, InpMagicNumber: 1, InpDeviationPoints: 20,
  SYMBOL_EXPIRATION_MODE: 1, SYMBOL_EXPIRATION_DAY: 1, ORDER_TIME_DAY: 1,
  TERMINAL_CONNECTED: 1, TERMINAL_TRADE_ALLOWED: 1, MQL_TRADE_ALLOWED: 1,
  ACCOUNT_TRADE_ALLOWED: 1, MathIsValidNumber: Number.isFinite,
  IsAlignedToTick: value => Math.abs(value * 100 - Math.round(value * 100)) < 1e-6,
  IsMarketSessionOpen: () => true, IsDirectionAllowed: () => true,
  TerminalInfoInteger: () => true, MQLInfoInteger: () => true,
  AccountInfoInteger: () => true, IsPaused: () => false,
  HasActiveTradeForSymbol: () => false, SkipSignal: () => {},
  SymbolInfoTick: (_, tick) => { tick.ask = 101; tick.bid = 99; return true; },
  calculateVolume: requirePartial => { orderContext.requirePartial = requirePartial; return true; },
  StoreSignalState: (...args) => { orderContext.stored = args; return true; },
  SignalComment: () => "signal", TradeResultAccepted: () => true,
  DoubleToString: value => String(value), PrintFormat: () => {},
  Trade: {
    SetExpertMagicNumber: () => {}, SetDeviationInPoints: () => {},
    SetTypeFillingBySymbol: () => {},
    BuyLimit: (...args) => { orderContext.order = args; return true; },
    SellLimit: (...args) => { orderContext.order = args; return true; },
  },
};
vm.createContext(orderContext);
vm.runInContext(translate(extract(robotSource, "ValidSignalPrices")), orderContext);
let orderCode = extract(robotSource, "PlaceSignalOrderLocked")
  .replace(/bool PlaceSignalOrderLocked\([\s\S]*?\)\n\{/,
    "function PlaceSignalOrder(signalTime, timeframe, direction, entry, stop, tp1, tp2, force)\n{")
  .replace("MqlTick tick;", "let tick = {};")
  .replace("SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE, expirationMode)",
    "((expirationMode = SYMBOL_EXPIRATION_DAY), true)")
  .replace("CalculatePositionVolume(direction, entry, stop, hasSecondTarget, volume)",
    "((volume = 1), calculateVolume(hasSecondTarget))")
  .replace(/"\s*\n\s*"/g, '" + "')
  .replace(/\b(?:bool|int|double|long|string)\s+/g, "let ");
vm.runInContext(orderCode, orderContext);
assert.equal(orderContext.ValidSignalPrices(1, 100, 98, 103.99, Infinity), false);
assert.equal(orderContext.ValidSignalPrices(-1, 100, 102, 96, Infinity), true);
assert.equal(orderContext.ValidSignalPrices(1, 100, 98, 104, 104), false);
assert.equal(orderContext.PlaceSignalOrder(1, 5, 1, 100, 98, 104, Infinity, 80), true);
assert.equal(orderContext.requirePartial, false);
assert.equal(orderContext.stored[5], 104);
assert.equal(orderContext.order[4], 104);
assert.equal(orderContext.PlaceSignalOrder(1, 5, 1, 100, 98, 104, 106, 80), true);
assert.equal(orderContext.requirePartial, true);
assert.equal(orderContext.stored[5], 106);
assert.equal(orderContext.order[4], 106);
assert.equal(orderContext.PlaceSignalOrder(1, 5, 1, 100, 98, 103, 106, 80), false);
assert.equal(orderContext.PlaceSignalOrder(1, 5, -1, 100, 102, 96, Infinity, 80), true);
assert.equal(orderContext.order[4], 96);
const manageCode = extract(robotSource, "ManageOpenPositionsLocked");
assert.match(manageCode, /if\(tp2 != tp1 && tp1Reached && !HasPendingEntryForSymbol\(\)\)\s+ManagePartialTarget/);
console.log("SWRobots: single and two target cases passed");
