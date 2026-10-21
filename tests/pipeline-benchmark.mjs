// Engine pipeline benchmark: one native `--bridge` document `evaluate` request
// per run for generated notebooks of 10, 30 and 60 code cells. Prints median
// wall time, request and response bytes, and the `workspaceCache` counters.
// A measurement, not a pass/fail gate. Node built-ins only.
//
//   zig build && node tests/pipeline-benchmark.mjs [path/to/roclet] [runs]
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const executable = process.argv[2] ?? "zig-out/bin/roclet";
const runs = Number(process.argv[3] ?? 5);

/** `a = 1`, then `out_i = a + i` (a `dbg` in every tenth cell), then one `expect`. */
export function notebook(cells) {
  const parts = ["# %%\na = 1"];
  for (let i = 1; i < cells - 1; i++) {
    parts.push(i % 10 === 0 ? `# %%\nout_${i} = {\n    dbg a\n    a + ${i}\n}` : `# %%\nout_${i} = a + ${i}`);
  }
  parts.push("# %%\nexpect a == 1");
  return `${parts.join("\n")}\n`;
}

const median = (values) => {
  const sorted = [...values].sort((x, y) => x - y);
  return sorted[Math.floor(sorted.length / 2)];
};

const directory = mkdtempSync(join(tmpdir(), "roclet-pipeline-"));
try {
  const rows = [];
  for (const cells of [10, 30, 60]) {
    const request = JSON.stringify({ operation: "document", action: "evaluate", format: "roc", source: notebook(cells) });
    const file = join(directory, `evaluate-${cells}.json`);
    writeFileSync(file, request);
    const times = [];
    let response = "";
    for (let run = 0; run < runs; run++) {
      const started = process.hrtime.bigint();
      const result = spawnSync(executable, ["--bridge", file], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
      times.push(Number(process.hrtime.bigint() - started) / 1e6);
      if (result.status !== 0) throw new Error(`roclet exited ${result.status}: ${result.stderr}`);
      response = result.stdout;
    }
    const parsed = JSON.parse(response);
    if (parsed.status !== "ok") throw new Error(`cells=${cells}: status ${parsed.status}: ${parsed.evaluation?.failure ?? ""}`);
    const { frontend_builds, lowerings, executions, prepared_hits, analyses } = parsed.workspaceCache;
    rows.push({
      cells,
      roots: parsed.evaluation.evaluated_roots.length,
      median_ms: Number(median(times).toFixed(1)),
      request_bytes: request.length,
      response_bytes: Buffer.byteLength(response),
      frontend_builds,
      lowerings,
      executions,
      prepared_hits,
      analyses: analyses ?? "-",
    });
  }
  console.table(rows);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
