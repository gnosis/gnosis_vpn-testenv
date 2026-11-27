// Build summary.csv from per-exit JSONs in OUTDIR, print a table, then write the
// release-gate verdict (verdict.json + report.md) and exit 1 when it fails.
import { existsSync, readFileSync, writeFileSync, readdirSync } from "fs";

const OUTDIR = process.env.OUTDIR || ".";
// Only the per-exit records: the same directory also holds meta.json, verdict.json and the <EXIT>.nerdstats.json snapshots, which would otherwise land as blank rows.
const files = readdirSync(OUTDIR).filter(
  (f) =>
    f.endsWith(".json") &&
    f !== "meta.json" &&
    f !== "verdict.json" &&
    !f.endsWith(".nerdstats.json"),
);
const rows = [];

const cols = [
  "exit",
  "egress_loc",
  "egress_match",
  "colo",
  "nav_ok",
  "nav_total",
  "nav_fail_resp",
  "avg_load_ms",
  "crawl_ok",
  "crawl_avg_ms",
  "yt_video",
  "yt_res",
  "ping1111_avg_ms",
  "ping1111_loss",
  "gw_avg_ms",
  "dl1_mbps",
  "dl2_mbps",
  "ul1_mbps",
  "ul2_mbps",
  "st_lat_avg_ms",
  "st_jitter_ms",
  "dl_ok_runs",
  "dl_median_mbps",
  "dl_http_version",
  "wall_secs",
];

// Heavy pages (YouTube/CNN) and Reddit (403 to headless) are informational; these must load.
const GATE_REQUIRED_SITES = (
  process.env.GATE_REQUIRED_SITES || "wikipedia,bbc,github,amazon"
)
  .split(",")
  .filter(Boolean);

const median = (xs) => {
  if (!xs.length) return "";
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : +((s[m - 1] + s[m]) / 2).toFixed(2);
};

// <exit>.download.csv from download.sh; plain split is safe, no field holds a comma.
const readDownloads = (exit) => {
  const path = `${OUTDIR}/${exit}.download.csv`;
  if (!existsSync(path)) return null;
  const [header, ...lines] = readFileSync(path, "utf8").trim().split("\n");
  const keys = header.split(",");
  return lines.map((l) =>
    Object.fromEntries(l.split(",").map((v, i) => [keys[i], v]))
  );
};

// verdictFor(record) -> { pass, reasons } ; pass is null when there was nothing to judge
const verdictFor = (j) => {
  if (j.fatal_error) return { pass: false, reasons: [j.fatal_error] };
  if (j.browser_skipped) {
    return { pass: null, reasons: ["browser skipped, not judged"] };
  }
  const navs = j.navigations || [];
  const reasons = GATE_REQUIRED_SITES.flatMap((label) => {
    const n = navs.find((x) => x.label === label);
    if (!n) return [`${label}: not visited`];
    return n.outcome === "ok" ? [] : [`${label}: ${n.outcome}${n.error ? ` (${n.error})` : ""}`];
  });
  return { pass: reasons.length === 0, reasons };
};
const verdicts = {};

for (const f of files) {
  const j = JSON.parse(readFileSync(`${OUTDIR}/${f}`, "utf8"));
  const navs = j.navigations || [];
  const ok = navs.filter((n) => n.outcome === "ok");
  const avgLoad = ok.length
    ? Math.round(ok.reduce((a, n) => a + (n.load_ms || 0), 0) / ok.length)
    : "";
  const failResp = navs.reduce(
    (a, n) => a + (n.failed_responses || 0) + (n.request_failures || 0),
    0,
  );
  const st = j.speedtests || [];
  const p1111 = (j.ping || []).find((p) => p.target === "1.1.1.1") || {};
  // Whichever ping target isn't the public one is the tunnel gateway — its address is environment-specific (jura-dev 10.128.0.1, testenv 10.129.0.1).
  const pgw = (j.ping || []).find((p) => p.target !== "1.1.1.1") || {};
  const hops = j.crawl || [];
  const hopsOk = hops.filter((h) => h.outcome === "ok");
  const watch = navs.find((n) => n.video);
  const dls = readDownloads(j.exit) || [];
  const dlOk = dls.filter((d) => d.outcome === "ok");
  verdicts[j.exit] = verdictFor(j);
  rows.push({
    exit: j.exit,
    egress_loc: j.egress?.loc ?? "",
    egress_match: j.egress_match ?? "",
    colo: j.egress?.colo ?? "",
    nav_ok: ok.length,
    nav_total: navs.length,
    nav_fail_resp: failResp,
    avg_load_ms: avgLoad,
    crawl_ok: hops.length ? `${hopsOk.length}/${hops.length}` : "",
    crawl_avg_ms: hopsOk.length
      ? Math.round(hopsOk.reduce((a, h) => a + h.ms, 0) / hopsOk.length)
      : "",
    yt_video: j.youtube_video?.name ?? "",
    yt_res: watch?.video?.observed?.height
      ? `${watch.video.observed.height}p`
      : "",
    ping1111_avg_ms: p1111.avg_ms ?? "",
    ping1111_loss: p1111.loss_pct ?? "",
    gw_avg_ms: pgw.avg_ms ?? "",
    dl1_mbps: st[0]?.download?.mbps ?? "",
    dl2_mbps: st[1]?.download?.mbps ?? "",
    ul1_mbps: st[0]?.upload?.mbps ?? "",
    ul2_mbps: st[1]?.upload?.mbps ?? "",
    st_lat_avg_ms: st[0]?.latency?.avg_ms ?? "",
    st_jitter_ms: st[0]?.latency?.jitter_ms ?? "",
    dl_ok_runs: dls.length ? `${dlOk.length}/${dls.length}` : "",
    dl_median_mbps: median(dlOk.map((d) => +d.mbps)),
    dl_http_version: [...new Set(dlOk.map((d) => d.http_version))].join(" "),
    wall_secs: j.wall_secs ?? "",
  });
}

// preserve intended exit order if present
const order = (process.env.EXIT_ORDER || "").split(",").filter(Boolean);
if (order.length)
  rows.sort((a, b) => order.indexOf(a.exit) - order.indexOf(b.exit));

const csv = [cols.join(",")]
  .concat(rows.map((r) => cols.map((c) => r[c]).join(",")))
  .join("\n");
// The file is what before/after runs get diffed against, so it stays; stdout is for eyeballing the run as it finishes and for piping straight into another tool.
writeFileSync(`${OUTDIR}/summary.csv`, csv + "\n");
console.log(`wrote ${OUTDIR}/summary.csv (${rows.length} exits)\n`);

// pretty table
const widths = cols.map((c) =>
  Math.max(c.length, ...rows.map((r) => String(r[c]).length)),
);
const line = (vals) =>
  vals.map((v, i) => String(v).padEnd(widths[i])).join("  ");
console.log(line(cols));
console.log(widths.map((w) => "-".repeat(w)).join("  "));
for (const r of rows) console.log(line(cols.map((c) => r[c])));

console.log("\n--- summary.csv ---");
process.stdout.write(csv + "\n");

// ─── Release-gate verdict ─────────────────────────────────────────────────────

const judged = Object.values(verdicts).filter((v) => v.pass !== null);
const gatePass = judged.length > 0 && judged.every((v) => v.pass);
const gateLabel = judged.length === 0 ? "NOT JUDGED" : gatePass ? "PASS" : "FAIL";

const meta = existsSync(`${OUTDIR}/meta.json`)
  ? JSON.parse(readFileSync(`${OUTDIR}/meta.json`, "utf8"))
  : {};
const gate = meta.gate ?? {};

writeFileSync(
  `${OUTDIR}/verdict.json`,
  JSON.stringify(
    {
      verdict: gateLabel,
      run_ts: meta.run_ts ?? "",
      network: gate.network ?? "",
      hoprd_version: gate.hoprd_version ?? "",
      client: {
        commit: meta.commits?.gnosis_vpn_client ?? "",
        version: gate.client_version ?? "",
      },
      testenv_commit: meta.commits?.testenv ?? "",
      identity: gate.identity ?? "",
      quick: meta.quick ?? false,
      required_sites: GATE_REQUIRED_SITES,
      exits: verdicts,
    },
    null,
    2,
  ) + "\n",
);

const mdRow = (vals) => `| ${vals.join(" | ")} |`;
const reportCols = [
  "exit",
  "nav_ok",
  "nav_total",
  "avg_load_ms",
  "crawl_ok",
  "dl1_mbps",
  "ul1_mbps",
  "dl_ok_runs",
  "dl_median_mbps",
  "dl_http_version",
  "ping1111_avg_ms",
];
const report = [
  `# Gnosis VPN release gate: ${gateLabel}`,
  "",
  `- network: \`${gate.network || "?"}\``,
  `- hoprd under test: \`${gate.hoprd_version || "?"}\``,
  `- client: \`${gate.client_version || "?"}\` @ \`${meta.commits?.gnosis_vpn_client || "?"}\``,
  `- testenv: \`${meta.commits?.testenv || "?"}\``,
  `- identity: \`${gate.identity || "?"}\``,
  `- run: \`${meta.run_ts ?? ""}\` (${meta.quick ? "quick" : "full"} profile, ${meta.client_mode ?? ""} mode)`,
  `- machine: ${meta.machine ?? ""}`,
  `- required sites: ${GATE_REQUIRED_SITES.join(", ")}`,
  "",
  "## Verdict per exit",
  "",
  mdRow(["exit", "verdict", "reasons"]),
  mdRow(["---", "---", "---"]),
  ...rows.map((r) => {
    const v = verdicts[r.exit];
    const label = v.pass === null ? "not judged" : v.pass ? "pass" : "FAIL";
    return mdRow([r.exit, label, v.reasons.join("; ") || "-"]);
  }),
  "",
  "## Measurements (informational)",
  "",
  mdRow(reportCols),
  mdRow(reportCols.map(() => "---")),
  ...rows.map((r) => mdRow(reportCols.map((c) => r[c] === "" ? "-" : r[c]))),
  "",
  "Raw data: `summary.csv`, `<exit>.json`, `<exit>.download.csv`, `meta.json` in this directory.",
  "",
].join("\n");
writeFileSync(`${OUTDIR}/report.md`, report);

console.log(`\n== release gate: ${gateLabel} (report: ${OUTDIR}/report.md)`);
for (const [exit, v] of Object.entries(verdicts)) {
  if (v.pass === false) console.log(`   ${exit}: ${v.reasons.join("; ")}`);
}
if (gateLabel === "FAIL") process.exit(1);
