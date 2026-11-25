// Exercise the shared alert dispatcher with simulated terminal responses.
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

for (const path of [
  "MQL5/Indicators/Forex/silentwolfforex.mq5",
  "MQL5/Indicators/SyntheticIndices/silentwolfindices.mq5",
]) {
  const source = fs.readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  assert.equal((source.match(/\bRaiseAlert\(message\);/g) || []).length, 1);
  const exitStart = source.indexOf("if(LastExitProcessedBarTime != time[confirmationIndex])");
  const entryStart = source.indexOf("// P3 (a) + C-R1", exitStart);
  assert(exitStart >= 0 && entryStart > exitStart);
  assert.match(source.slice(entryStart), /if\(!IndicatorDataPending && currentBarEntrySignal/);
  let exitBlock = source.slice(exitStart, entryStart);
  assert(!exitBlock.includes("RaiseAlert("));
  assert.match(source.slice(entryStart), /StringFormat\("ENTRÉE[\s\S]*?RaiseAlert\(message\);/);
  exitBlock = exitBlock.replace(
    /FindConfirmedSignal\(confirmationIndex, rates_total,[\s\S]*?alertStopPrice\)/,
    "((direction = exitDirection), confirmedPatternResult)");
  assert(!exitBlock.includes("FindConfirmedSignal("));
  exitBlock = exitBlock.replace(/\b(?:int|string|double|bool)\s+/g, "let ");
  const exitContext = {
    LastExitProcessedBarTime: 0, time: [0, 100], confirmationIndex: 1,
    ActiveSignalDirection: 1, ActiveSignalTime: 50, exitDirection: -1,
    confirmedPatternResult: true, IndicatorDataPending: true,
  };
  vm.runInNewContext(exitBlock, exitContext);
  assert.equal(exitContext.ActiveSignalDirection, 1);
  assert.equal(exitContext.LastExitProcessedBarTime, 0);
  exitContext.IndicatorDataPending = false;
  vm.runInNewContext(exitBlock, exitContext);
  assert.equal(exitContext.ActiveSignalDirection, 0);
  assert.equal(exitContext.ActiveSignalTime, 0);
  assert.equal(exitContext.LastExitProcessedBarTime, 100);
  exitContext.ActiveSignalDirection = 1;
  exitContext.ActiveSignalTime = 50;
  vm.runInNewContext(exitBlock, exitContext);
  assert.equal(exitContext.ActiveSignalDirection, 1);

  const start = source.indexOf("void RaiseAlert(");
  assert(start >= 0);
  const open = source.indexOf("{", start);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === "{") depth++;
    if (source[end] === "}") depth--;
  }
  assert.equal(depth, 0);
  const body = source.slice(start, end)
    .replace("void RaiseAlert(const string message)", "function RaiseAlert(message)")
    .replace(/\bdatetime\s+/g, "let ");
  const context = {
    InpEnablePush: true, InpEnableAlertPopup: false, InpEnableSound: false,
    InpEnableEmail: false, TERMINAL_NOTIFICATIONS_ENABLED: 1, MQL_TESTER: 2,
    notificationsEnabled: true, tester: false, sendOk: true, sent: [], messages: [],
    TerminalInfoInteger: () => context.notificationsEnabled,
    MQLInfoInteger: () => context.tester,
    ResetLastError: () => {},
    GetLastError: () => 4517,
    SendNotification: text => { context.sent.push(text); return context.sendOk; },
    StringSubstr: (text, start, count) => text.substring(start, start + count),
    Print: (...args) => context.messages.push(args.join("")),
  };
  vm.createContext(context);
  vm.runInContext(body, context);
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
  console.log(path + ": alert cases passed");
}
