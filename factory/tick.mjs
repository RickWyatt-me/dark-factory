#!/usr/bin/env node
// One tick of the dispatcher, launched by launchd. This file exists for exactly one
// reason: macOS privacy protection (TCC) refuses background jobs access to ~/Documents
// unless the job's PROGRAM holds Full Disk Access, and on this Mac the granted binary
// is a node runtime, not /bin/bash (the System Settings picker would not take bash —
// Phase F, 2026-08-16). The grant attaches to the launchd job's program and covers its
// children (proven live: child bash under the granted node reads the repo; child bash
// under an ungranted program does not). So node fronts the tick and immediately hands
// off. Keep this dependency-free and boring — it must never be the thing that fails.
//
// Run by hand to see exactly what the scheduler runs:  node factory/tick.mjs
import { spawnSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const r = spawnSync("/bin/bash", [root + "/factory/orchestrator.sh"], {
  stdio: "inherit",
  cwd: root,
});
process.exit(r.status === null ? 1 : r.status);
