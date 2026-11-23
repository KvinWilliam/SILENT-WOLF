// Execute the shared MQL calculations against simulated MT5 data.
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const paths = [
  "MQL5/Indicators/Forex/silentwolfforex.mq5",
  "MQL5/Indicators/SyntheticIndices/silentwolfindices.mq5",
];

function extract(source, name) {
  const start = source.search(new RegExp("\\b(?:string|bool|datetime|void) " + name + "\\("));
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

function translate(code) {
  return code
    .replace(/\b(?:string|bool|datetime|void)\s+(\w+)\(([^)]*)\)/,
      (_, name, args) => "function " + name + "(" +
        args.replace(/\bconst\s+/g, "")
          .replace(/\b(?:int|double|string|datetime|MqlRates)\s*&?\s*/g, "")
          .replace(/\[\]/g, "") + ")")
    .replace(/\bMqlDateTime parts;/g, "let parts = {};")
    .replace(/\bMqlRates rates\[\];/g, "let rates = [];")
    .replace(/\bdouble atr\[\];/g, "let atr = [];")
    .replace(/\bdouble current, previous;/g, "let current = {}, previous = {};")
    .replace(/\b(?:bool|string|int|long|double|datetime)\s+/g, "let ")
    .replace(/\(double\)/g, "")
    .replace(/SeriesInfoInteger\(_Symbol, _Period, SERIES_SYNCHRONIZED, synchronized\)/g,
      "(synchronized = seriesSync, true)")
    .replace(/SeriesInfoInteger\(_Symbol, _Period, SERIES_FIRSTDATE, firstDate\)/g,
      "(firstDate = firstHistoryDate, true)")
    .replace(/\bprevious\b/g, "previous.value")
    .replace(/\bcurrent\b/g, "current.value")
    .replace(/function SwCalculateVwap\(rates, current\.value, previous\.value\)/,
      "function SwCalculateVwap(rates, current, previous)")
    .replace(/let current\.value = \{\}, previous\.value = \{\};/,
      "let current = {}, previous = {};")
    .replace(/SwCalculateVwap\(rates, current\.value, previous\.value\)/,
      "SwCalculateVwap(rates, current, previous)");
}

const unix = s => Date.parse(s) / 1000;
const bar = (time, price, volume) =>
  ({ time, high: price, low: price, close: price, tick_volume: volume });

let baseline;
for (const path of paths) {
  const source = fs.readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  const names = ["SwSupportsVwap", "SwVwapAnchor", "SwVwapContext",
    "SwCalculateVwap", "SwUpdateVwap", "RaiseAlert"];
  const bodies = names.map(name => extract(source, name));
  if (baseline) assert.deepEqual(bodies, baseline);
  else baseline = bodies;
  const context = {
    PERIOD_M5: 5, PERIOD_M15: 15, PERIOD_M30: 30, PERIOD_H1: 60, PERIOD_H4: 240,
    _Period: 5, _Symbol: "TEST", EMPTY_VALUE: Infinity, INVALID_HANDLE: -1,
    InpShowTable: true, AtrHandle: 1, LatestSignalDirection: 1,
    SwVwap: Infinity, SwVwapDirection: "n/d", SwVwapDistanceAtr: Infinity,
    SwVwapPrice: Infinity, seriesSync: 1, firstHistoryDate: 1, history: [], atrValue: 4,
    InpEnablePush: true, InpEnableAlertPopup: false, InpEnableSound: false,
    InpEnableEmail: false, TERMINAL_NOTIFICATIONS_ENABLED: 1, MQL_TESTER: 2,
    notificationsEnabled: true, tester: false, sent: [], messages: [],
    ArraySize: values => values.length,
    MathIsValidNumber: Number.isFinite,
    TerminalInfoInteger: () => context.notificationsEnabled,
    MQLInfoInteger: () => context.tester,
    ResetLastError: () => {},
    GetLastError: () => 4517,
    SendNotification: text => { context.sent.push(text); return context.sendOk; },
    StringSubstr: (text, start, count) => text.substring(start, start + count),
    Print: (...args) => context.messages.push(args.join("")),
    TimeToStruct: (timestamp, parts) => {
      const date = new Date(timestamp * 1000);
      Object.assign(parts, { year: date.getUTCFullYear(), mon: date.getUTCMonth() + 1,
        day: date.getUTCDate(), day_of_week: date.getUTCDay(),
        hour: date.getUTCHours(), min: date.getUTCMinutes(), sec: date.getUTCSeconds() });
      return true;
    },
    StructToTime: p => Date.UTC(p.year, p.mon - 1, p.day, p.hour, p.min, p.sec) / 1000,
    iTime: () => context.history.at(-1)?.time || 0,
    CopyRates: (symbol, period, start, end, output) => {
      context.copyCalls = (context.copyCalls || 0) + 1;
      output.push(...context.history.filter(b => b.time >= start && b.time <= end));
      return output.length;
    },
    CopyBuffer: (handle, index, shift, count, output) => {
      if (context.atrValue === null) return -1;
      output.push(context.atrValue);
      return 1;
    },
  };
  vm.createContext(context);
  vm.runInContext(bodies.map(translate).join("\n"), context);

  const monday = unix("2026-11-23T00:00:00Z");
  const tuesday = unix("2026-11-24T10:00:00Z");
  const sunday = unix("2026-11-29T23:59:00Z");
  for (const period of [5, 15, 30, 60, 240]) {
    context._Period = period;
    assert.equal(context.SwSupportsVwap(), true);
  }
  context._Period = context.PERIOD_M5;
  assert.equal(context.SwVwapAnchor(tuesday), unix("2026-11-24T00:00:00Z"));
  context._Period = context.PERIOD_H4;
  assert.equal(context.SwVwapAnchor(tuesday), monday);
  assert.equal(context.SwVwapAnchor(sunday), monday);
  assert.equal(context.SwVwapAnchor(unix("2026-11-30T00:00:00Z")),
    unix("2026-11-30T00:00:00Z"));
  context._Period = context.PERIOD_M5;
  context.history = [bar(unix("2026-11-24T00:00:00Z"), 100, 1),
    bar(unix("2026-11-24T00:05:00Z"), 106, 3)];
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, 104.5);
  assert.equal(context.SwVwapDirection, "HAUSSIER");
  assert.equal(context.SwVwapDistanceAtr, 0.375);
  assert.equal(context.SwVwapContext(), "ALIGNE");
  context.LatestSignalDirection = -1;
  assert.equal(context.SwVwapContext(), "NON ALIGNE");
  context.history[1] = bar(unix("2026-11-24T00:05:00Z"), 94, 3);
  context.SwUpdateVwap();
  assert.equal(context.SwVwapDirection, "BAISSIER");
  assert.equal(context.SwVwapContext(), "ALIGNE");
  assert.equal(context.SwVwapDistanceAtr, -0.375);
  context.history = [bar(unix("2026-11-24T00:00:00Z"), 100, 1)];
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, 100);
  assert.equal(context.SwVwapDirection, "n/d");
  assert.equal(context.SwVwapContext(), "n/d");
  context.history[0].tick_volume = 0;
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, Infinity);
  context.history[0].tick_volume = -1;
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, Infinity);
  context.history[0].tick_volume = 1;
  context.firstHistoryDate = tuesday;
  const copyCalls = context.copyCalls;
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, Infinity);
  assert.equal(context.copyCalls, copyCalls + 1);
  context.firstHistoryDate = 1;
  context.seriesSync = 0;
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, Infinity);
  context.seriesSync = 1;
  context.atrValue = null;
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, 100);
  assert.equal(context.SwVwapDistanceAtr, Infinity);
  context.atrValue = Infinity;
  context.SwUpdateVwap();
  assert.equal(context.SwVwapDistanceAtr, Infinity);
  context.history[0].close = Infinity;
  context.SwUpdateVwap();
  assert.equal(context.SwVwap, Infinity);
  context._Period = 1440;
  assert.equal(context.SwSupportsVwap(), false);
  context.sendOk = true;
  context.RaiseAlert("x".repeat(300));
  assert.equal(context.sent.length, 1);
  assert.equal(context.sent[0].length, 255);
  context.tester = true;
  context.RaiseAlert("test");
  assert.equal(context.sent.length, 1);
  assert.match(context.messages.at(-1), /testeur MT5/);
  context.tester = false;
  context.notificationsEnabled = false;
  context.RaiseAlert("test");
  assert.equal(context.sent.length, 1);
  assert.match(context.messages.at(-1), /notifications MT5 ne sont pas activées/);
  context.notificationsEnabled = true;
  context.sendOk = false;
  context.RaiseAlert("test");
  assert.match(context.messages.at(-1), /4517/);
  assert(!/SwVolume|InpVolumeBars|InpVolumeBins|InpVolumeValueAreaPercent/.test(source));
  console.log(path + ": VWAP cases passed");
}
