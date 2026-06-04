#!/usr/bin/env node

const fs = require("node:fs");

const logPath = process.argv[2];
if (!logPath) {
  console.error("usage: parse-hvf-build-log.js <log>");
  process.exit(2);
}

const text = fs.readFileSync(logPath, "utf8").replace(/\x1b\[[0-9;]*m/g, "");
const lines = text.split(/\r?\n/);

const build = { jobs: undefined, start: undefined, end: undefined, elapsed: undefined, rc: undefined };
const compileStarts = [];
const artifacts = [];
const cpuSamples = [];

function normalizeName(name) {
  return String(name || "").replace(/_/g, "-");
}

let currentCpu = null;
for (const raw of lines) {
  let line = raw;
  let t = undefined;
  const stamped = line.match(/^===CARGO-LINE t=(\d+)=== ?(.*)$/);
  if (stamped) {
    t = Number(stamped[1]);
    line = stamped[2];
  }

  let m = line.match(/^===STARRYOS(?:-DEBUG)?-BUILD-START jobs=(\d+) start=(\d+)===/);
  if (m) {
    build.jobs = Number(m[1]);
    build.start = Number(m[2]);
    continue;
  }
  m = line.match(/^===STARRYOS(?:-DEBUG)?-BUILD-END jobs=(\d+) rc=(\d+) elapsed=(\d+)===/);
  if (m) {
    build.jobs = Number(m[1]);
    build.rc = Number(m[2]);
    build.elapsed = Number(m[3]);
    continue;
  }
  m = line.match(/^===STARRYOS(?:-DEBUG)?-BUILD-PASS jobs=(\d+) elapsed=(\d+)===/);
  if (m) {
    build.jobs = Number(m[1]);
    build.elapsed = Number(m[2]);
    continue;
  }

  m = line.match(/^\s*Compiling ([^ ]+) /);
  if (m) {
    compileStarts.push({ t, crate: m[1] });
    continue;
  }

  if (line.startsWith("{") && line.endsWith("}")) {
    try {
      const event = JSON.parse(line);
      if (event.reason === "compiler-artifact") {
        const targetName = normalizeName(event.target && event.target.name);
        artifacts.push({
          t,
          package_id: event.package_id,
          target: targetName,
          fresh: Boolean(event.fresh),
        });
      }
    } catch {
      // Ignore non-Cargo JSON-ish diagnostics.
    }
    continue;
  }

  m = line.match(/^===GUEST-CPU-MONITOR t=(\d+)===/);
  if (m) {
    currentCpu = { t: Number(m[1]), cpus: [] };
    continue;
  }
  if (currentCpu && /^cpu\d*\s+/.test(line)) {
    const fields = line.trim().split(/\s+/);
    currentCpu.cpus.push({
      label: fields[0],
      values: fields.slice(1).map((v) => Number(v)),
    });
    continue;
  }
  if (currentCpu && line.startsWith("loadavg=")) {
    currentCpu.loadavg = line.slice("loadavg=".length);
    continue;
  }
  if (currentCpu && line.startsWith("MemAvailable:")) {
    currentCpu.memAvailable = line.trim();
    continue;
  }
  if (currentCpu && /^===GUEST-CPU-MONITOR-END/.test(line)) {
    cpuSamples.push(currentCpu);
    currentCpu = null;
  }
}

function rel(t) {
  if (!t || !build.start) return undefined;
  return t - build.start;
}

function cpuBusy(a, b) {
  const ca = a.cpus.find((c) => c.label === "cpu");
  const cb = b.cpus.find((c) => c.label === "cpu");
  if (!ca || !cb) return undefined;
  const suma = ca.values.reduce((p, c) => p + c, 0);
  const sumb = cb.values.reduce((p, c) => p + c, 0);
  const idleA = (ca.values[3] || 0) + (ca.values[4] || 0);
  const idleB = (cb.values[3] || 0) + (cb.values[4] || 0);
  const total = sumb - suma;
  const idle = idleB - idleA;
  if (total <= 0 || idle < 0 || idle > total) return undefined;
  return ((total - idle) / total) * 100;
}

const milestones = [
  "core",
  "alloc",
  "compiler_builtins",
  "ax-hal",
  "ax-task",
  "rsext4",
  "ax-sync",
  "ax-fs-ng",
  "ax-net-ng",
  "ax-runtime",
  "starry-process",
  "ax-display",
  "starryos",
  "starry-kernel",
];

const firstStart = new Map();
for (const item of compileStarts) {
  const name = normalizeName(item.crate);
  if (!firstStart.has(name)) firstStart.set(name, item.t);
}

const artifactByTarget = new Map();
for (const item of artifacts) {
  if (item.t && item.target && !item.fresh) artifactByTarget.set(item.target, item.t);
}

console.log(`log: ${logPath}`);
console.log(`jobs: ${build.jobs ?? "unknown"}`);
console.log(`elapsed: ${build.elapsed ?? "unknown"}s`);
console.log(`compile-starts: ${compileStarts.length}`);
console.log(`compiler-artifacts: ${artifacts.length}`);

console.log("\nmilestones:");
const durations = [];
for (const name of milestones) {
  const key = normalizeName(name);
  const startT = firstStart.get(key);
  const doneT = artifactByTarget.get(key);
  const start = rel(startT);
  const done = rel(doneT);
  const duration = start !== undefined && done !== undefined ? done - start : undefined;
  if (duration !== undefined) durations.push({ name, duration, start, done });
  console.log(
    `${name.padEnd(18)} start=${start ?? "-"}s done=${done ?? "-"}s duration=${duration ?? "-"}s`,
  );
}

if (durations.length) {
  console.log("\nlongest milestone durations:");
  durations
    .sort((a, b) => b.duration - a.duration)
    .slice(0, 8)
    .forEach((item) => {
      console.log(`${item.name.padEnd(18)} ${item.duration}s (${item.start}s -> ${item.done}s)`);
    });
}

if (cpuSamples.length >= 2) {
  console.log("\ncpu samples:");
  for (let i = 1; i < cpuSamples.length; i += 1) {
    const a = cpuSamples[i - 1];
    const b = cpuSamples[i];
    const busy = cpuBusy(a, b);
    console.log(
      `${rel(a.t) ?? "-"}-${rel(b.t) ?? "-"}s busy=${busy === undefined ? "invalid-procstat" : busy.toFixed(1) + "%"} load=${a.loadavg || "-"}`,
    );
  }
}
