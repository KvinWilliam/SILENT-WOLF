const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

function extract(source, name, returnType = "bool") {
  const start = source.indexOf(`${returnType} ${name}(`);
  assert(start >= 0, `${name} missing`);
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
  assert.match(source, /input bool\s+InpInternalBufferOnly\s*=\s*false/);
  const init = extract(source, "OnInit", "int");
  assert(init.indexOf("if(InpInternalBufferOnly)\n      return INIT_SUCCEEDED;")
    < init.indexOf("int drawingResult = DrawingInit();"));
  const deinit = extract(source, "OnDeinit", "void");
  assert(deinit.indexOf("if(InpInternalBufferOnly)") < deinit.indexOf("DrawingDeinit();"));
  assert.match(deinit, /if\(InpInternalBufferOnly\)[\s\S]*?IndicatorRelease\(AtrHandle\);[\s\S]*?return;/);
  const calculate = extract(source, "OnCalculate", "int");
  assert.match(calculate, /if\(!RefreshChartZones\(\)\)[\s\S]*?SignalReadyBuffer\[1\] = 0\.0;\s*return 0;/);
  assert.match(calculate, /if\(!RefreshInternalZones\(zonesChanged\)\)[\s\S]*?SignalReadyBuffer\[1\] = 0\.0;\s*return 0;/);
  const zones = extract(source, "RefreshChartZones");
  assert.match(zones, /ChartSymbol\(sourceChart\) != _Symbol/);
  assert.match(zones, /ObjectsTotal\(sourceChart, 0, OBJ_RECTANGLE\)/);
  assert.match(zones, /if\(objectCount < 0\)/);
  assert.match(zones, /!ObjectGetInteger\(sourceChart, objectName, OBJPROP_TIME, 0, time1\)/);
  assert.match(calculate, /if\(prev_calculated == 0 \|\| LastBarTime != time\[0\]\)/);
  assert.match(calculate, /if\(!InpInternalBufferOnly\) RaiseAlert\(message\);/);
  assert.match(calculate, /OldestZoneSignalIndex\(oldestSignalIndex, time\)/);
  assert.match(calculate, /int clearUpperBound = MathMin\(rates_total - 1, 1\);/);
  let boundCode = extract(source, "OldestZoneSignalIndex", "int")
    .replace("int OldestZoneSignalIndex(const int limit, const datetime &time[])",
      "function OldestZoneSignalIndex(limit, time)")
    .replace(/\b(?:int|datetime)\s+/g, "let ")
    .replace("(last - first) / 2", "Math.floor((last - first) / 2)");
  const bound = {
    ChartZones: [], ArraySize: values => values.length,
    _Period: 5, PeriodSeconds: () => 10,
  };
  vm.createContext(bound);
  vm.runInContext(boundCode, bound);
  const times = [100, 90, 80, 60, 50, 40];
  assert.equal(bound.OldestZoneSignalIndex(4, times), 0);
  bound.ChartZones = [{ start: 70 }];
  assert.equal(bound.OldestZoneSignalIndex(4, times), 2);
  bound.ChartZones = [{ start: 70 }, { start: 55 }];
  assert.equal(bound.OldestZoneSignalIndex(4, times), 3);
  bound.ChartZones = [{ start: 120 }];
  assert.equal(bound.OldestZoneSignalIndex(4, times), 0);

  let buttonCode = extract(source, "CreateToolButton")
    .replace("bool CreateToolButton(const int index)", "function CreateToolButton(index)")
    .replace(/\(ENUM_OBJECT\)/g, "")
    .replace(/\b(?:int|string)\s+/g, "let ");
  const button = {
    OBJ_BUTTON: 1, OBJPROP_TYPE: 2, CORNER_RIGHT_UPPER: 0,
    OBJPROP_CORNER: 1, OBJPROP_XDISTANCE: 1, OBJPROP_YDISTANCE: 1,
    OBJPROP_XSIZE: 1, OBJPROP_YSIZE: 1, OBJPROP_BGCOLOR: 1,
    OBJPROP_COLOR: 1, OBJPROP_BORDER_COLOR: 1, OBJPROP_FONTSIZE: 1,
    OBJPROP_FONT: 1, OBJPROP_TEXT: 1, OBJPROP_STATE: 1,
    OBJPROP_SELECTABLE: 1, OBJPROP_HIDDEN: 1,
    PANEL_X: 12, PANEL_Y: 34, BUTTON_WIDTH: 120, BUTTON_HEIGHT: 25, BUTTON_GAP: 8,
    clrWhite: 0, clrDimGray: 0, exists: true, type: 1, created: 0,
    ButtonName: index => `button${index}`, ToolColor: () => 0, ToolLabel: () => "tool",
    ObjectFind: () => button.exists ? 0 : -1,
    ObjectCreate: () => { button.created++; button.exists = true; return true; },
    ObjectGetInteger: () => button.type,
    ObjectSetInteger: () => true, ObjectSetString: () => true, Print: () => {},
  };
  vm.createContext(button);
  vm.runInContext(buttonCode, button);
  assert.equal(button.CreateToolButton(0), true);
  assert.equal(button.created, 0);
  button.exists = false;
  assert.equal(button.CreateToolButton(0), true);
  assert.equal(button.created, 1);
  button.type = 99;
  assert.equal(button.CreateToolButton(0), false);
  if (path.includes("Forex")) {
    const sessions = extract(source, "DrawTradingSession", "void");
    assert.match(sessions, /CopyHigh\(_Symbol, PERIOD_M5, t1, t2c, hi\)/);
    assert.match(sessions, /CopyLow\(_Symbol, PERIOD_M5, t1, t2c, lo\)/);
  }
  console.log(path + ": runtime cases passed");
}

const robot = fs.readFileSync("MQL5/Experts/SWRobots.mq5", "utf8").replace(/\r\n/g, "\n");
const sourceContext = {
  MQL_TESTER: 1, SW_SOURCE_AUTO: 0, SW_SOURCE_FOREX: 1, SW_SOURCE_INDICES: 2,
  tester: true, InpIndicatorSource: 0, messages: [],
  MQLInfoInteger: () => sourceContext.tester,
  Print: message => sourceContext.messages.push(message),
};
vm.createContext(sourceContext);
vm.runInContext(extract(robot, "ValidateIndicatorSource")
  .replace("bool ValidateIndicatorSource()", "function ValidateIndicatorSource()")
  .replace(/"\s*\n\s*"/g, '" + "'), sourceContext);
assert.match(extract(robot, "OnInit", "int"), /if\(!ValidateIndicatorSource\(\)\)\s+return INIT_PARAMETERS_INCORRECT;/);
assert.equal(sourceContext.ValidateIndicatorSource(), false);
assert.match(sourceContext.messages[0], /historique fiable des zones/);
for (const source of [1, 2]) {
  sourceContext.InpIndicatorSource = source;
  assert.equal(sourceContext.ValidateIndicatorSource(), false);
}
sourceContext.InpIndicatorSource = 0;
sourceContext.tester = false;
assert.equal(sourceContext.ValidateIndicatorSource(), true);

let handleCode = extract(robot, "EnsureIndicatorHandle")
  .replace("bool EnsureIndicatorHandle(const int stateIndex)", "function EnsureIndicatorHandle(stateIndex)")
  .replace(/\bdatetime\s+/g, "let ");
const handle = {
  INVALID_HANDLE: -1, TimeframeStates: [{ indicatorHandle: 42, timeframe: 5 }],
  _Symbol: "TEST", IND_CUSTOM: 1, IndicatorConfig: [{}, {}], created: 0,
  ArraySize: value => value.length,
  RefreshIndicatorConfiguration: () => true, ResetLastError: () => {},
  IndicatorCreate: (...args) => { handle.args = args; handle.created++; return 43; },
  TimeCurrent: () => 1, LastIndicatorWarningTime: 0,
};
vm.createContext(handle);
vm.runInContext(handleCode, handle);
assert.equal(handle.EnsureIndicatorHandle(0), true);
assert.equal(handle.created, 0);
handle.TimeframeStates[0].indicatorHandle = -1;
assert.equal(handle.EnsureIndicatorHandle(0), true);
assert.equal(handle.created, 1);
assert.equal(handle.args[0], "TEST");
assert.equal(handle.args[1], 5);
assert.equal(handle.args[2], 1);
assert.equal(handle.args[3], 2);
assert.match(extract(robot, "ProcessPendingSignal", "void"),
  /nextSignalReadAttemptMs = GetTickCount64\(\) \+ 1000/);
console.log("SWRobots: indicator handle cases passed");

const schema = [...fs.readFileSync("MQL5/Indicators/Forex/silentwolfforex.mq5", "utf8")
  .matchAll(/^input\s+(?!group)(\w+)\s+(\w+)/gm)]
  .slice(0, 46)
  .map(([, type]) => type.startsWith("ENUM_") ? "TYPE_INT" : `TYPE_${type.toUpperCase()}`);
const indexSchema = [...fs.readFileSync("MQL5/Indicators/SyntheticIndices/silentwolfindices.mq5", "utf8")
  .matchAll(/^input\s+(?!group)(\w+)\s+(\w+)/gm)]
  .slice(0, 46)
  .map(([, type]) => type.startsWith("ENUM_") ? "TYPE_INT" : `TYPE_${type.toUpperCase()}`);
assert.deepEqual(indexSchema, schema);
let configCode = extract(robot, "RefreshIndicatorConfiguration")
  .replace("bool RefreshIndicatorConfiguration()", "function RefreshIndicatorConfiguration()")
  .replace("MqlParam parameters[];", "let parameters = [];")
  .replace(/ENUM_DATATYPE types\[\] = \{([\s\S]*?)\};/, "let types = [$1];")
  .replace(/\bENUM_INDICATOR kind = IND_CUSTOM;/, "let kind = IND_CUSTOM;")
  .replace(/\b(?:int|string|bool|datetime)\s+/g, "let ")
  .replace(/StringReplace\(path, .*?\);/, 'path = path.replaceAll("/", String.fromCharCode(92));')
  .replace("StringToLower(lowerPath);", "lowerPath = lowerPath.toLowerCase();");
const makeParam = type => ({ type, integer_value: 0, double_value: 0, string_value: "" });
const visualParams = [makeParam("TYPE_STRING"), ...schema.map(makeParam)];
visualParams[0].string_value = "Indicators\\Forex\\silentwolfforex.ex5";
visualParams[3].double_value = 4;
visualParams[12].string_value = "custom-buy-prefix";
const config = {
  SW_SOURCE_AUTO: 0, SW_SOURCE_FOREX: 1, SW_SOURCE_INDICES: 2, InpIndicatorSource: 0,
  INVALID_HANDLE: -1, IND_CUSTOM: 3, IndicatorConfig: [], LastIndicatorWarningTime: 0,
  names: ["silentwolfforex"], visualParams, releases: 0,
  ChartIndicatorsTotal: () => config.names.length,
  ChartIndicatorName: (_, __, i) => config.names[i],
  ChartIndicatorGet: () => 10, IndicatorRelease: () => {},
  IndicatorParameters: (_, __, out) => {
    out.push(...config.visualParams.map(value => ({ ...value })));
    return out.length;
  },
  ReleaseIndicatorHandles: () => { config.releases++; },
  ArraySize: value => value.length,
  ArrayResize: (value, size) => { value.length = size; return size; },
  ChartID: () => 123, TimeCurrent: () => 100, Print: () => {}, GetLastError: () => 0,
  StringFind: (text, part) => text.indexOf(part),
  StringSubstr: (text, start) => text.slice(start), StringLen: text => text.length,
  ...Object.fromEntries(Array.from(new Set(["TYPE_STRING", ...schema]), type => [type, type])),
};
vm.createContext(config);
vm.runInContext(configCode, config);
assert.equal(config.RefreshIndicatorConfiguration(), true);
assert.equal(config.IndicatorConfig[0].string_value, "Forex\\silentwolfforex.ex5");
assert.equal(config.IndicatorConfig[1].integer_value, 1);
assert.equal(config.IndicatorConfig[2].integer_value, 123);
assert.equal(config.IndicatorConfig[3].double_value, 4);
assert.equal(config.IndicatorConfig[12].string_value, "custom-buy-prefix");
assert.equal(config.releases, 1);
assert.equal(config.RefreshIndicatorConfiguration(), true);
assert.equal(config.releases, 1, "unchanged parameters retain handles");
config.visualParams[3].double_value = 5;
assert.equal(config.RefreshIndicatorConfiguration(), true);
assert.equal(config.releases, 2, "changed parameters invalidate handles");
assert.equal(config.IndicatorConfig[3].double_value, 5);
config.visualParams[3].type = "TYPE_INT";
assert.equal(config.RefreshIndicatorConfiguration(), false);
assert.equal(config.IndicatorConfig.length, 0);
config.visualParams[3].type = "TYPE_DOUBLE";
config.InpIndicatorSource = 2;
assert.equal(config.RefreshIndicatorConfiguration(), false);
config.InpIndicatorSource = 0;
config.names = [];
assert.equal(config.RefreshIndicatorConfiguration(), false);
console.log("SWRobots: visual configuration cases passed");

function journalFunction(name) {
  return extract(robot, name)
    .replace(new RegExp(`bool ${name}\\([\\s\\S]*?\\)\\s*\\{`),
      name === "SameJournalRecord" || name === "ValidJournalTransition"
        ? `function ${name}(${name === "SameJournalRecord" ? "a, b" : "previous, next"}) {`
        : name === "ValidJournalRecord" ? `function ${name}(record) {`
        : name === "ReadSignalJournal" ? `function ${name}(path, record) {`
        : `function ${name}(path, record, create) {`)
    .replace(/SwJournalRecord first, second;/, "let first = {}, second = {};")
    .replace(/SwJournalRecord (previous|verified);/g, "let $1 = {};")
    .replace(/ZeroMemory\(previous\);/, "")
    .replace(/\b(?:string|int|long|ulong|bool|ushort)\s+/g, "let ")
    .replace(/\(ushort\)/g, "")
    .replace(/sizeof\(SwJournalRecord\)/g, "RECORD_SIZE")
    .replace(/record = first;/, "Object.assign(record, structuredClone(first));");
}
const files = new Map(), handles = new Map();
let nextFileHandle = 1;
const journal = {
  SW_JOURNAL_READY: 0, SW_JOURNAL_PENDING: 1, SW_JOURNAL_DONE: 2,
  ACCOUNT_SERVER: 1, ACCOUNT_LOGIN: 2, InpMagicNumber: 7, _Symbol: "EURUSD", RECORD_SIZE: 600, INVALID_HANDLE: -1,
  FILE_READ: 1, FILE_WRITE: 2, FILE_BIN: 4, SEEK_END: 2,
  SW_ERROR_FILE_NOT_FOUND: 5019,
  tornWrite: false, writes: 0,
  AccountInfoString: () => "Broker", AccountInfoInteger: () => 12345, StringLen: s => s.length,
  StringGetCharacter: (s, i) => s.charCodeAt(i), MathIsValidNumber: Number.isFinite,
  Print: () => {}, GetLastError: () => 0, ResetLastError: () => {}, structuredClone,
  FileIsExist: path => files.has(path),
  FileOpen: (path, flags) => {
    if ((flags & 2) && !(flags & 1)) files.set(path, []);
    if ((flags & 2) && !files.has(path)) files.set(path, []);
    if (!files.has(path)) return -1;
    const handle = nextFileHandle++;
    handles.set(handle, { path, offset: 0 });
    return handle;
  },
  FileSize: handle => files.get(handles.get(handle).path).length * 600,
  FileIsEnding: handle => handles.get(handle).offset >= files.get(handles.get(handle).path).length,
  FileReadStruct: (handle, output) => {
    const h = handles.get(handle);
    Object.assign(output, structuredClone(files.get(h.path)[h.offset++]));
    return 600;
  },
  FileWriteStruct: (handle, input) => {
    journal.writes++;
    if (journal.tornWrite && journal.writes % 2 === 0) return 0;
    const h = handles.get(handle);
    files.get(h.path).push(structuredClone(input));
    return 600;
  },
  FileSeek: handle => { handles.get(handle).offset = files.get(handles.get(handle).path).length; return true; },
  FileFlush: () => {}, FileClose: handle => handles.delete(handle),
};
vm.createContext(journal);
for (const name of ["SameJournalRecord", "ValidJournalRecord", "ValidJournalTransition",
  "ReadSignalJournal", "WriteSignalJournal"]) vm.runInContext(journalFunction(name), journal);
const identity = text => Array.from({ length: 128 }, (_, i) => i < text.length ? text.charCodeAt(i) : 0);
const original = { version: 1, phase: 0, sequence: 1, positionId: 0,
  login: 12345, magic: 7, signalTime: 100, timeframe: 5, server: identity("Broker"),
  symbol: identity("EURUSD"), entry: 10, stop: 9, tp1: 12, tp2: 13,
  target: 0, closed: 0, requested: 0 };
assert.equal(journal.WriteSignalJournal("signal", original, true), true);
assert.equal(journal.WriteSignalJournal("signal", original, true), false);
const claimed = { ...original, sequence: 2, positionId: 123 };
assert.equal(journal.WriteSignalJournal("signal", claimed, false), true);
assert.equal(journal.WriteSignalJournal("signal", { ...claimed, sequence: 3, positionId: 999 }, false), false);
const pending = { ...claimed, sequence: 3, phase: 1, target: 1, requested: 1 };
assert.equal(journal.WriteSignalJournal("signal", pending, false), true);
let restored = {};
assert.equal(journal.ReadSignalJournal("signal", restored), true);
assert.equal(restored.phase, 1, "an interrupted request remains pending after reload");
const completed = { ...pending, sequence: 4, phase: 2, requested: 0, closed: 1 };
assert.equal(journal.WriteSignalJournal("signal", completed, false), true);
assert.equal(journal.WriteSignalJournal("signal", { ...completed, sequence: 5 }, false), false);
files.get("signal")[1].entry = 999;
assert.equal(journal.ReadSignalJournal("signal", {}), false, "mismatched copies fail closed");
assert.equal(journal.WriteSignalJournal("torn", original, true), true);
assert.equal(journal.WriteSignalJournal("torn", claimed, false), true);
journal.tornWrite = true;
assert.equal(journal.WriteSignalJournal("torn", pending, false), false);
assert.equal(journal.ReadSignalJournal("torn", {}), false, "incomplete append fails closed");
console.log("SWRobots: durable journal cases passed");

let copyCode = extract(robot, "CopySignalStateToPosition")
  .replace("bool CopySignalStateToPosition(const string comment, const ulong positionId)",
    "function CopySignalStateToPosition(comment, positionId)")
  .replace("SwJournalRecord record;", "let record = {};")
  .replace('string fields[4] = {"ENTRY", "STOP", "TP1", "TP2"};',
    'let fields = ["ENTRY", "STOP", "TP1", "TP2"];')
  .replace(/\b(?:datetime|ENUM_TIMEFRAMES|string|double|int)\s+/g, "let ")
  .replace(/\((?:long|int|double)\)/g, "")
  .replace("ParseSignalComment(comment, signalTime, timeframe)",
    "parseComment(comment, (time, tf) => { signalTime = time; timeframe = tf; })");
const attachedState = new Map();
const copy = {
  record: { sequence: 1, positionId: 0, signalTime: 100, timeframe: 5,
    entry: 10, stop: 9, tp1: 12, tp2: 13 },
  writes: 0, failWrite: false,
  parseComment: (_, assign) => { assign(100, 5); return true; },
  SignalJournalPath: (time, tf) => `${time}.${tf}`,
  ReadSignalJournal: (_, out) => { Object.assign(out, copy.record); return true; },
  WriteSignalJournal: (_, record) => {
    if (copy.failWrite) return false;
    copy.writes++; copy.record = { ...record }; return true;
  },
  PositionStateKey: (id, field) => `${id}.${field}`,
  GlobalVariableCheck: key => attachedState.has(key),
  GlobalVariableDel: key => attachedState.delete(key),
  GlobalVariableSet: (key, value) => { attachedState.set(key, value); return 1; },
  GlobalVariablesFlush: () => {}, ArraySize: value => value.length,
  GetLastError: () => 0, Print: () => {},
};
vm.createContext(copy);
vm.runInContext(copyCode, copy);
assert.equal(copy.CopySignalStateToPosition("SWR:100:5", 123), true);
assert.equal(copy.record.positionId, 123);
assert.equal(copy.writes, 1);
assert.equal(attachedState.get("123.READY"), 1);
assert.equal(copy.CopySignalStateToPosition("SWR:100:5", 123), true);
assert.equal(copy.writes, 1);
assert.equal(copy.CopySignalStateToPosition("SWR:100:5", 124), false);
assert.equal(attachedState.has("124.READY"), false);
copy.record.positionId = 0;
copy.failWrite = true;
assert.equal(copy.CopySignalStateToPosition("SWR:100:5", 125), false);
assert.equal(attachedState.has("125.READY"), false);
console.log("SWRobots: durable position binding cases passed");

let restoreCode = extract(robot, "RestorePositionState")
  .replace("bool RestorePositionState(const ulong positionId)", "function RestorePositionState(positionId)")
  .replace("SwJournalRecord record;", "let record = {};")
  .replace(/\b(?:double|int|ulong)\s+/g, "let ")
  .replace(/\((?:datetime|ENUM_TIMEFRAMES|ulong|long|int)\)/g, "")
  .replace(/GlobalVariableGet\((PositionStateKey\(positionId, "\w+"\)), (\w+)\)/g,
    "readState($1, value => $2 = value)");
const restoredState = new Map([
  ["1.READY", 1], ["1.TIME", 100], ["1.TF", 5], ["1.ENTRY", 10],
  ["1.STOP", 9], ["1.TP1", 12], ["1.TP2", 13],
]);
const restore = {
  state: restoredState, journalAvailable: true, historyAvailable: false,
  positionRecord: { positionId: 1, signalTime: 100, timeframe: 5, entry: 10, stop: 9, tp1: 12, tp2: 13 },
  PositionStateKey: (id, field) => `${id}.${field}`,
  GlobalVariableCheck: key => restoredState.has(key),
  readState: (key, assign) => { if (!restoredState.has(key)) return false; assign(restoredState.get(key)); return true; },
  SignalJournalPath: (time, tf) => `${time}.${tf}`,
  ReadSignalJournal: (_, out) => {
    if (!restore.journalAvailable) return false;
    Object.assign(out, restore.positionRecord); return true;
  },
  HistorySelectByPosition: () => restore.historyAvailable,
  HistoryDealsTotal: () => 1, HistoryDealGetTicket: () => 99,
  HistoryDealGetInteger: (_, field) => field === 1 ? 2 : 7,
  HistoryDealGetString: () => "SWR:100:5",
  CopySignalStateToPosition: () => restore.journalAvailable,
  DEAL_ENTRY: 1, DEAL_ENTRY_IN: 2, DEAL_MAGIC: 3, DEAL_COMMENT: 4, InpMagicNumber: 7,
};
vm.createContext(restore);
vm.runInContext(restoreCode, restore);
assert.equal(restore.RestorePositionState(1), true);
restore.journalAvailable = false;
assert.equal(restore.RestorePositionState(1), false, "legacy or missing journals disable position management");
restore.journalAvailable = true;
restore.positionRecord.stop = 8;
assert.equal(restore.RestorePositionState(1), false, "cached state must match the journal");
restore.historyAvailable = true;
restoredState.clear();
assert.equal(restore.RestorePositionState(1), true, "history can restore expired cache from a valid journal");
console.log("SWRobots: position restore cases passed");

let closeCode = extract(robot, "ClosePartialByTicket")
  .replace(/bool ClosePartialByTicket\([\s\S]*?\)\s*\{/,
    "function ClosePartialByTicket(ticket, positionId, symbol, type, volume) {")
  .replace("MqlTick tick;", "let tick = {};")
  .replace(/\((?:ulong|ENUM_POSITION_TYPE)\)/g, "");
const close = {
  POSITION_SYMBOL: 1, POSITION_IDENTIFIER: 2, POSITION_MAGIC: 3, POSITION_TYPE: 4,
  POSITION_VOLUME: 5, POSITION_TYPE_BUY: 0, ORDER_TYPE_BUY: 0, ORDER_TYPE_SELL: 1,
  TRADE_ACTION_DEAL: 1, m_magic: 7, m_deviation: 20, m_request: {}, m_result: {},
  position: { symbol: "EURUSD", id: 123, magic: 7, type: 0, volume: 2 },
  sent: [],
  ClearStructures: () => { close.m_request = {}; close.m_result = {}; },
  PositionSelectByTicket: ticket => ticket === 10,
  PositionGetString: () => close.position.symbol,
  PositionGetInteger: field => ({ 2: close.position.id, 3: close.position.magic, 4: close.position.type })[field],
  PositionGetDouble: () => close.position.volume,
  SymbolInfoTick: (_, tick) => { tick.bid = 10; tick.ask = 11; return true; },
  FillingCheck: () => true, Print: () => {},
  OrderSend: request => { close.sent.push({ ...request }); return true; },
};
vm.createContext(close);
vm.runInContext(closeCode, close);
assert.equal(close.ClosePartialByTicket(10, 123, "EURUSD", 0, 1), true);
assert.equal(close.sent[0].position, 10);
assert.equal(close.sent[0].type, close.ORDER_TYPE_SELL);
close.position.type = 1;
assert.equal(close.ClosePartialByTicket(10, 123, "EURUSD", 0, 1), false);
assert.equal(close.ClosePartialByTicket(10, 123, "EURUSD", 1, 1), true);
assert.equal(close.sent[1].type, close.ORDER_TYPE_BUY);
assert.equal(close.ClosePartialByTicket(10, 999, "EURUSD", 1, 1), false);
assert.equal(close.ClosePartialByTicket(10, 123, "EURUSD", 1, 2), false);
assert.equal(close.sent.length, 2);
console.log("SWRobots: ticket-bound partial close cases passed");

const partialCode = extract(robot, "ManagePartialTarget", "void")
  .replace(/void ManagePartialTarget\([\s\S]*?\)\s*\{/,
    "function ManagePartialTarget(ticket, positionId, type, currentVolume) {")
  .replace(/double signalTime, signalTimeframe;[\s\S]*?return;/,
    'let signalTime = GlobalVariableGet(PositionStateKey(positionId, "TIME"));' +
    'let signalTimeframe = GlobalVariableGet(PositionStateKey(positionId, "TF"));' +
    'if(signalTime === undefined || signalTimeframe === undefined) return;')
  .replace("SwJournalRecord record;", "let record = {};")
  .replace(/\b(?:string|double)\s+/g, "let ")
  .replace(/\((?:double|datetime|ENUM_TIMEFRAMES|long|int)\)/g, "")
  .replace(/"\s*\n\s*"/g, '" + "');
const state = new Map();
const journals = new Map();
const partial = {
  InpTp1ClosePercent: 50, _Symbol: "TEST", SYMBOL_VOLUME_MIN: 1,
  SW_JOURNAL_READY: 0, SW_JOURNAL_PENDING: 1, SW_JOURNAL_DONE: 2,
  PositionStateKey: (id, field) => `${id}.${field}`,
  SignalJournalPath: (time, tf) => `${time}.${tf}`,
  ReadSignalJournal: (path, record) => {
    if (!journals.has(path)) return false;
    Object.assign(record, journals.get(path));
    return true;
  },
  WriteSignalJournal: (path, record) => {
    if (!partial.writeOk) return false;
    journals.set(path, { ...record });
    return true;
  },
  GlobalVariableCheck: key => state.has(key),
  GlobalVariableGet: key => state.get(key),
  GlobalVariableSet: (key, value) => { state.set(key, value); return 1; },
  GlobalVariableDel: key => state.delete(key), GlobalVariablesFlush: () => {},
  NormalizeVolumeDown: volume => Math.floor((volume + 1e-9) * 10) / 10,
  SymbolInfoDouble: () => 0.1, TimeCurrent: () => 1,
  GetLastError: () => 0, Print: () => {}, PrintFormat: () => {},
  Trade: { ResultVolume: () => partial.executed, ResultRetcode: () => 0,
    ResultRetcodeDescription: () => "" },
  ClosePartial: (_, __, ___, ____, volume) => { partial.requests.push(volume); return partial.ok; },
  MathIsValidNumber: Number.isFinite,
  executed: 0.4, requests: [], ok: true, writeOk: true,
};
vm.createContext(partial);
partial.deals = [];
partial.HistorySelectByPosition = () => true;
partial.HistoryDealsTotal = () => partial.deals.length;
partial.HistoryDealGetTicket = i => i + 1;
partial.DEAL_ENTRY = "e"; partial.DEAL_ENTRY_OUT = 1; partial.DEAL_MAGIC = "m"; partial.DEAL_VOLUME = "v";
partial.InpMagicNumber = 7;
partial.HistoryDealGetInteger = (t, p) => (p === "e" ? partial.deals[t - 1].entry : partial.deals[t - 1].magic);
partial.HistoryDealGetDouble = t => partial.deals[t - 1].volume;
const histCode = extract(robot, "ClosedVolumeFromHistory", "bool")
  .replace(/bool ClosedVolumeFromHistory\([\s\S]*?\)\s*\{/, "function ClosedVolumeFromHistory(positionId, ref) {")
  .replace("closed = 0.0;", "ref.v = 0.0;")
  .replace("closed += ", "ref.v += ")
  .replace(/\b(?:int|ulong|double)\s+/g, "let ")
  .replace(/\(ulong\)/g, "");
const reconCode = extract(robot, "ReconcilePendingPartial", "bool")
  .replace(/bool ReconcilePendingPartial\([\s\S]*?\)\s*\{/, "function ReconcilePendingPartial(path, record) {")
  .replace("double historyClosed;", "let hc = {v: 0};")
  .replace("ClosedVolumeFromHistory(record.positionId, historyClosed)", "ClosedVolumeFromHistory(record.positionId, hc)")
  .replace("double executed = historyClosed - record.closed;", "let executed = hc.v - record.closed;");
vm.runInContext(histCode + reconCode, partial);
vm.runInContext(partialCode, partial);
function initPartial(id) {
  state.set(`${id}.TIME`, id);
  state.set(`${id}.TF`, 5);
  journals.set(`${id}.5`, { positionId: id, signalTime: id, timeframe: 5,
    phase: 0, sequence: 2, target: 0, closed: 0, requested: 0 });
}
initPartial(123);
partial.ManagePartialTarget(10, 123, 0, 2);
assert.deepEqual(partial.requests, [1]);
assert.equal(journals.get("123.5").closed, 0.4);
assert.equal(journals.get("123.5").phase, 0);
partial.executed = 0.6;
partial.ManagePartialTarget(10, 123, 0, 1.6);
assert.deepEqual(partial.requests, [1, 0.6]);
assert.equal(journals.get("123.5").phase, 2);
partial.ManagePartialTarget(10, 123, 0, 1);
assert.equal(partial.requests.length, 2);
assert.equal(state.get("123.TP1DONE"), 1, "a completed TP1 must stop further journal reads");
partial.ok = false;
initPartial(124);
partial.ManagePartialTarget(11, 124, 0, 2);
assert.equal(journals.get("124.5").phase, 1);
partial.ManagePartialTarget(11, 124, 0, 2);
assert.equal(partial.requests.length, 3, "uncertain requests must not be repeated");
partial.deals = [{ entry: 1, magic: 7, volume: 0.4 }];
state.delete("124.TP1WARN");
partial.ManagePartialTarget(11, 124, 0, 1.6);
assert.equal(journals.get("124.5").phase, 0, "deals proving the execution reconcile a pending TP1");
assert.equal(journals.get("124.5").closed, 0.4);
assert.equal(partial.requests.length, 3, "reconciliation must not submit a request");
partial.deals = [{ entry: 1, magic: 0, volume: 1 }];
journals.set("124.5", { ...journals.get("124.5"), phase: 1, requested: 0.6, sequence: 10 });
state.delete("124.TP1WARN");
partial.ManagePartialTarget(11, 124, 0, 1.6);
assert.equal(journals.get("124.5").phase, 1, "foreign deals must not reconcile a pending TP1");
partial.deals = [];
partial.ok = true;
partial.writeOk = false;
initPartial(125);
partial.ManagePartialTarget(12, 125, 0, 2);
assert.equal(partial.requests.length, 3, "a failed durable write must prevent a request");
partial.writeOk = true;
initPartial(126);
journals.delete("126.5");
partial.ManagePartialTarget(13, 126, 0, 2);
assert.equal(partial.requests.length, 3, "missing journals must not trigger partial closes");
assert.match(extract(robot, "ProcessPendingSignal", "void"), /SW_BUFFER_READY[\s\S]*?ready != 1\.0/);
assert.match(extract(robot, "ProcessPendingSignal", "void"),
  /if\(!MarkCurrentBarProcessed\(stateIndex\)\)[\s\S]*?return;[\s\S]*?PlaceSignalOrder/);
const markCode = extract(robot, "MarkCurrentBarProcessed")
  .replace("bool MarkCurrentBarProcessed(const int stateIndex)", "function MarkCurrentBarProcessed(stateIndex)")
  .replace(/\b(?:bool|datetime)\s+/g, "let ");
const mark = {
  _Symbol: "EURUSD", TimeframeStates: [{
    timeframe: 5, lastProcessedSignalTime: 90, pendingSignalBarTime: 100,
    pendingSignalReadAttempts: 2, nextSignalReadAttemptMs: 200,
  }],
  iTime: () => 100, SaveLastProcessedSignalTime: () => false,
};
vm.createContext(mark);
vm.runInContext(markCode, mark);
assert.equal(mark.MarkCurrentBarProcessed(0), false);
assert.equal(mark.TimeframeStates[0].pendingSignalBarTime, 0);
console.log("SWRobots: partial execution and readiness cases passed");

let countCode = extract(robot, "CountStopLosses")
  .replace("bool CountStopLosses(int &todayCount, int &weekCount)",
    "function CountStopLosses()")
  .replace("todayCount = 0;", "let todayCount = 0;")
  .replace("weekCount = 0;", "let weekCount = 0;")
  .replace("MqlDateTime today;", "let today = {};")
  .replace("ulong seenWeek[], seenToday[];", "let seenWeek = [], seenToday = [];")
  .replace(/\b(?:int|long|ulong|double|datetime|bool)\s+/g, "let ")
  .replace(/\((?:ulong|datetime)\)/g, "")
  .replace(/HistoryDealGetInteger\(deal, (\w+), (\w+)\)/g,
    "readInteger(deal, $1, value => $2 = value)")
  .replace(/HistoryDealGetDouble\(deal, (\w+), (\w+)\)/g,
    "readDouble(deal, $1, value => $2 = value)")
  .replace(/!RememberPositionId\(positionId, (\w+), alreadySeen\)/g,
    "!(alreadySeen = RememberPositionId(positionId, $1)).ok")
  .replace(/if\(!alreadySeen\)/g, "if(!alreadySeen.seen)")
  .replace(/return true;\s*}$/, "return { todayCount, weekCount }; }");
const deals = [
  { magic: 7, reason: 1, entry: 2, position: 11, time: 100, profit: -5 },
  { magic: 7, reason: 1, entry: 2, position: 11, time: 210, profit: -5 },
  { magic: 7, reason: 1, entry: 2, position: 12, time: 220, profit: -3 },
  { magic: 7, reason: 1, entry: 2, position: 13, time: 220, profit: 1 },
];
const count = {
  DEAL_MAGIC: "magic", DEAL_REASON: "reason", DEAL_ENTRY: "entry",
  DEAL_POSITION_ID: "position", DEAL_TIME: "time", DEAL_PROFIT: "profit",
  DEAL_REASON_SL: 1, DEAL_ENTRY_OUT: 2, DEAL_ENTRY_OUT_BY: 3, InpMagicNumber: 7,
  failRead: false, failMemory: false,
  TimeCurrent: () => 250, ServerDayStart: () => 200,
  TimeToStruct: (_, output) => { output.day_of_week = 2; return true; },
  HistorySelect: () => true, HistoryDealsTotal: () => deals.length,
  HistoryDealGetTicket: i => i + 1,
  readInteger: (ticket, field, assign) => {
    if (count.failRead) return false;
    assign(deals[ticket - 1][field]); return true;
  },
  readDouble: (ticket, field, assign) => {
    if (count.failRead) return false;
    assign(deals[ticket - 1][field]); return true;
  },
  RememberPositionId: (id, seen) => {
    if (count.failMemory) return { ok: false };
    const already = seen.includes(id);
    if (!already) seen.push(id);
    return { ok: true, seen: already };
  },
  MathIsValidNumber: Number.isFinite, Print: () => {}, GetLastError: () => 0,
};
vm.createContext(count);
vm.runInContext(countCode, count);
assert.deepEqual({ ...count.CountStopLosses() }, { todayCount: 2, weekCount: 2 });
count.failRead = true;
assert.equal(count.CountStopLosses(), false);
count.failRead = false;
count.failMemory = true;
assert.equal(count.CountStopLosses(), false);
console.log("SWRobots: stop-loss count cases passed");

function translateTradeGuard(name) {
  return extract(robot, name)
    .replace(`bool ${name}()`, `function ${name}()`)
    .replace(/\b(?:int|long|ulong|string|bool)\s+/g, "let ")
    .replace(/\(ulong\)/g, "")
    .replace(/PositionGetString\((\w+), (\w+)\)/g, "readPositionString($1, value => $2 = value)")
    .replace(/PositionGetInteger\((\w+), (\w+)\)/g, "readPositionInteger($1, value => $2 = value)")
    .replace(/OrderGetString\((\w+), (\w+)\)/g, "readOrderString($1, value => $2 = value)")
    .replace(/OrderGetInteger\((\w+), (\w+)\)/g, "readOrderInteger($1, value => $2 = value)");
}
const guard = {
  ACCOUNT_MARGIN_MODE: 1, ACCOUNT_MARGIN_MODE_RETAIL_HEDGING: 2,
  POSITION_SYMBOL: 3, POSITION_MAGIC: 4, ORDER_SYMBOL: 5, ORDER_MAGIC: 6,
  _Symbol: "EURUSD", InpMagicNumber: 7, positions: [], orders: [], selected: null,
  broken: false, hedging: true,
  AccountInfoInteger: () => guard.hedging ? 2 : 1,
  PositionsTotal: () => guard.positions.length, OrdersTotal: () => guard.orders.length,
  PositionGetTicket: i => { guard.selected = guard.positions[i]; return guard.broken ? 0 : i + 1; },
  OrderGetTicket: i => { guard.selected = guard.orders[i]; return guard.broken ? 0 : i + 1; },
  readPositionString: (_, assign) => { assign(guard.selected.symbol); return true; },
  readPositionInteger: (_, assign) => { assign(guard.selected.magic); return true; },
  readOrderString: (_, assign) => { assign(guard.selected.symbol); return true; },
  readOrderInteger: (_, assign) => { assign(guard.selected.magic); return true; },
  Print: () => {}, GetLastError: () => 0,
};
vm.createContext(guard);
for (const name of ["HasActiveTradeForSymbol", "HasPendingEntryForSymbol"])
  vm.runInContext(translateTradeGuard(name), guard);
assert.equal(guard.HasActiveTradeForSymbol(), false);
guard.positions = [{ symbol: "EURUSD", magic: 8 }];
assert.equal(guard.HasActiveTradeForSymbol(), false);
guard.hedging = false;
assert.equal(guard.HasActiveTradeForSymbol(), true);
guard.positions = [];
guard.orders = [{ symbol: "EURUSD", magic: 7 }];
assert.equal(guard.HasPendingEntryForSymbol(), true);
guard.orders[0].magic = 8;
assert.equal(guard.HasPendingEntryForSymbol(), true, "netting must also block manual pending orders");
assert.equal(guard.HasActiveTradeForSymbol(), true, "netting must not merge with manual pending orders");
guard.hedging = true;
assert.equal(guard.HasPendingEntryForSymbol(), false);
guard.broken = true;
assert.equal(guard.HasPendingEntryForSymbol(), true, "unreadable pending orders block TP1");
assert.equal(guard.HasActiveTradeForSymbol(), true, "unreadable orders block entries");
console.log("SWRobots: active trade guard cases passed");

const cancelCode = extract(robot, "CancelPendingOrdersWhenPaused", "void")
  .replace("void CancelPendingOrdersWhenPaused()", "function CancelPendingOrdersWhenPaused()")
  .replace(/\b(?:int|long|ulong|string)\s+/g, "let ")
  .replace(/\(ulong\)/g, "")
  .replace(/OrderGetInteger\((\w+), (\w+)\)/g, "readOrderInteger($1, value => $2 = value)")
  .replace(/OrderGetString\((\w+), (\w+)\)/g, "readOrderString($1, value => $2 = value)");
const cancel = {
  NextPauseCheckMs: 0, InpMagicNumber: 7, ORDER_MAGIC: 1, ORDER_COMMENT: 2,
  TRADE_RETCODE_DONE: 10009, paused: true, selected: null, removed: [],
  orders: [
    { ticket: 1, magic: 7, comment: "SWR:123:5" },
    { ticket: 2, magic: 7, comment: "manual" },
    { ticket: 3, magic: 8, comment: "SWR:123:5" },
  ],
  GetTickCount64: () => 10000, IsPaused: () => cancel.paused,
  OrdersTotal: () => cancel.orders.length,
  OrderGetTicket: index => { cancel.selected = cancel.orders[index]; return cancel.selected.ticket; },
  readOrderInteger: (_, assign) => { assign(cancel.selected.magic); return true; },
  readOrderString: (_, assign) => { assign(cancel.selected.comment); return true; },
  StringFind: (text, prefix) => text.indexOf(prefix), PrintFormat: () => {}, Print: () => {}, GetLastError: () => 0,
  Trade: {
    SetExpertMagicNumber: () => {},
    OrderDelete: ticket => { cancel.removed.push(ticket); return true; },
    ResultRetcode: () => 10009,
  },
};
vm.createContext(cancel);
vm.runInContext(cancelCode, cancel);
cancel.CancelPendingOrdersWhenPaused();
assert.deepEqual(cancel.removed, [1]);
cancel.NextPauseCheckMs = 0;
cancel.paused = false;
cancel.CancelPendingOrdersWhenPaused();
assert.deepEqual(cancel.removed, [1]);
console.log("SWRobots: pause cancellation cases passed");
