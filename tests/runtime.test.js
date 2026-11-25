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
vm.runInContext(extract(robot, "IndicatorPathForSource", "string")
  .replace("string IndicatorPathForSource(const int source)", "function IndicatorPathForSource(source)"),
sourceContext);
assert.match(extract(robot, "OnInit", "int"), /if\(!ValidateIndicatorSource\(\)\)\s+return INIT_PARAMETERS_INCORRECT;/);
assert.equal(sourceContext.ValidateIndicatorSource(), false);
assert.match(sourceContext.messages[0], /SW_SOURCE_FOREX \(silentwolfforex\).*SW_SOURCE_INDICES \(silentwolfindices\)/);
for (const [source, path] of [[1, "Silent Wolf Trading\\silentwolfforex"], [2, "Silent Wolf Trading\\silentwolfindices"]]) {
  sourceContext.InpIndicatorSource = source;
  assert.equal(sourceContext.ValidateIndicatorSource(), true);
  assert.equal(sourceContext.IndicatorPathForSource(source), path);
}
sourceContext.InpIndicatorSource = 0;
sourceContext.tester = false;
assert.equal(sourceContext.ValidateIndicatorSource(), true);

let handleCode = extract(robot, "EnsureIndicatorHandle")
  .replace("bool EnsureIndicatorHandle(const int stateIndex)", "function EnsureIndicatorHandle(stateIndex)")
  .replace(/\bdatetime\s+/g, "let ");
const handle = {
  INVALID_HANDLE: -1, TimeframeStates: [{ indicatorHandle: 42, timeframe: 5 }],
  _Symbol: "TEST", SelectedIndicatorPath: "test", created: 0,
  EnsureIndicatorSource: () => true, ResetLastError: () => {},
  iCustom: (...args) => { handle.args = args; handle.created++; return 43; },
  TimeCurrent: () => 1, LastIndicatorWarningTime: 0,
};
vm.createContext(handle);
vm.runInContext(handleCode, handle);
assert.equal(handle.EnsureIndicatorHandle(0), true);
assert.equal(handle.created, 0);
handle.TimeframeStates[0].indicatorHandle = -1;
assert.equal(handle.EnsureIndicatorHandle(0), true);
assert.equal(handle.created, 1);
assert.deepEqual(handle.args, ["TEST", 5, "test", true]);
assert.match(extract(robot, "ProcessPendingSignal", "void"),
  /nextSignalReadAttemptMs = GetTickCount64\(\) \+ 1000/);
console.log("SWRobots: indicator handle cases passed");
