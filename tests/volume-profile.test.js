// Execute the shared MQL profile calculations with a deterministic tick-feed mock.
// MetaEditor and an MT5 data feed remain necessary for platform-level validation.
const fs = require("node:fs");
const vm = require("node:vm");
const assert = require("node:assert/strict");

const paths = [
  "MQL5/Indicators/Forex/silentwolfforex.mq5",
  "MQL5/Indicators/SyntheticIndices/silentwolfindices.mq5",
];

function extract(source, name) {
  const start = source.search(new RegExp("\\bbool " + name + "\\("));
  assert(start >= 0, name + " missing");
  const open = source.indexOf("{", start);
  let end = open + 1;
  let depth = 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === "{") depth++;
    if (source[end] === "}") depth--;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}

function translate(code) {
  return code
    .replace(/\bbool\s+(\w+)\(([^)]*)\)/,
      (_, name, args) => "function " + name + "(" +
        args.replace(/\bconst\s+/g, "")
          .replace(/\b(?:ulong|int|double|SwVolumeBounds|MqlRates)\s*&?\s*/g, "")
          .replace(/\[\]/g, "") + ")")
    .replace(/\((?:int|double|ulong)\)/g, "")
    .replace(/\b(?:ulong|int|double|bool)\s+/g, "let ");
}

function feedContext(functions, ticks, capacity = 8192) {
  let error = 0;
  const context = {
    ArraySize: value => value.length,
    MathIsValidNumber: Number.isFinite,
    MathMin: Math.min,
    MathMax: Math.max,
    MathAbs: Math.abs,
    MathFloor: Math.floor,
    TICK_FLAG_BUY: 32,
    TICK_FLAG_SELL: 64,
    COPY_TICKS_ALL: 0,
    _Symbol: "TEST",
    SwVolumeTicks: [],
    SwVolumeBins: [0, 0, 0],
    SwVolumeMinPrice: Infinity,
    SwVolumeMaxPrice: -Infinity,
    SwVolumeProcessedTicks: 0,
    SwVolumeTickLimit: 1000000,
    SwVolumeStarted: 1000,
    SwVolumeTimeLimitMs: 1000,
    now: 1000,
    GetTickCount64: () => context.now,
    InpVolumeBars: 2,
    InpVolumeBins: 3,
    reason: "",
    SwVolumeUnavailable: message => { context.reason = message; },
    ResetLastError: () => { error = 0; },
    GetLastError: () => error,
    CopyTicksRange: (_, output, flags, from, to) => {
      assert.equal(flags, context.COPY_TICKS_ALL);
      const selected = ticks.filter(tick => tick.time_msc >= from && tick.time_msc <= to);
      output.splice(0, output.length, ...selected.slice(0, capacity));
      if (selected.length > capacity) error = 4407;
      return Math.min(selected.length, capacity);
    },
  };
  vm.createContext(context);
  const bounds = translate(functions[0]);
  const scanTicks = translate(functions[1])
    .replace("barVolume += volume;", "barVolume.value += volume;")
    .replace("from + (to - from) / 2", "from + Math.floor((to - from) / 2)");
  const scanBars = translate(functions[2])
    .replace("let barVolume = 0.0;", "let barVolume = { value: 0 };")
    .replace("MathIsValidNumber(barVolume)", "MathIsValidNumber(barVolume.value)")
    .replace("MathAbs(barVolume - expected)", "MathAbs(barVolume.value - expected)");
  vm.runInContext([bounds, scanTicks, scanBars].join("\n"), context);
  return context;
}

let baseline;
for (const path of paths) {
  const source = fs.readFileSync(path, "utf8");
  const functions = ["SwProfileBounds", "SwScanVolumeTicks", "SwScanVolumeBars"]
    .map(name => extract(source, name));
  if (baseline) assert.deepEqual(functions, baseline);
  else baseline = functions;

  const buy = (time_msc, last, volume_real, volume = 0) =>
    ({ time_msc, last, volume_real, volume, flags: 32 });
  const quote = time_msc => ({ time_msc, last: 999, volume_real: 99, volume: 99, flags: 2 });
  const ticks = [
    buy(10050, 99, 2), quote(10075), buy(10100, 100, 0, 3),
    buy(11000, 101, 1), buy(11050, 102, 6),
  ];
  const rates = [{ time: 11, real_volume: 7 }, { time: 10, real_volume: 5 }];
  const context = feedContext(functions, ticks, 2);
  assert.equal(context.SwScanVolumeBars(rates, 11999, 0), true);
  assert.equal(context.SwVolumeMinPrice, 99);
  assert.equal(context.SwVolumeMaxPrice, 102);
  assert.equal(context.SwScanVolumeBars(rates, 11999, 1), true);
  assert.deepEqual(Array.from(context.SwVolumeBins), [2, 3, 7]);
  let bounds = {};
  assert.equal(context.SwProfileBounds(context.SwVolumeBins, 0.7, bounds), true);
  assert.deepEqual(bounds, { poc: 2, lower: 1, upper: 2 });

  bounds = {};
  assert.equal(context.SwProfileBounds([5, 5, 1], 0.7, bounds), true);
  assert.deepEqual(bounds, { poc: 0, lower: 0, upper: 1 });
  bounds = {};
  assert.equal(context.SwProfileBounds([3, 10, 3], 0.8, bounds), true);
  assert.deepEqual(bounds, { poc: 1, lower: 0, upper: 1 });
  assert.equal(context.SwProfileBounds([0, 0], 0.7, {}), false);
  assert.equal(context.SwProfileBounds([1, -1], 0.7, {}), false);
  assert.equal(context.SwProfileBounds([1, NaN], 0.7, {}), false);
  assert.equal(context.SwProfileBounds([1], 0, {}), false);
  assert.equal(context.SwProfileBounds([1], 1.01, {}), false);

  const missing = feedContext(functions, [quote(10075), buy(11000, 101, 1)]);
  assert.equal(missing.SwScanVolumeBars(rates, 11999, 0), false);
  assert.equal(missing.reason, "n/d (donnees incompletes)");
  const invalid = feedContext(functions, [buy(10050, 99, NaN, 5)]);
  assert.equal(invalid.SwScanVolumeBars(rates, 11999, 0), false);
  assert.equal(invalid.reason, "n/d (volume invalide)");
  const sameMillisecond = feedContext(functions,
    [buy(10050, 99, 1), buy(10050, 99, 1), buy(10050, 99, 3)], 2);
  assert.equal(sameMillisecond.SwScanVolumeBars(rates, 11999, 0), false);
  assert.equal(sameMillisecond.reason, "n/d (trop de ticks par ms)");
  const limited = feedContext(functions, ticks);
  limited.SwVolumeTickLimit = 1;
  assert.equal(limited.SwScanVolumeBars(rates, 11999, 0), false);
  assert.equal(limited.reason, "n/d (limite ticks)");
  const slow = feedContext(functions, ticks);
  slow.now = 2000;
  assert.equal(slow.SwScanVolumeBars(rates, 11999, 0), false);
  assert.equal(slow.reason, "n/d (limite temps)");
  console.log(path + ": volume profile cases passed");
}
